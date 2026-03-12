# BT Audio Crash — Fix Briefing

**Issue**: `ew-0ga` — Bluetooth headphones cause EXC_BAD_ACCESS crash
**Reproduce**: Connect Bose BT headphones → launch app → trigger recording via hotkey → crash within seconds
**No crash**: Without BT headphones, app is fully stable (PTT, double-click hands-free, all work)

## Crash Signature

```
EXC_BAD_ACCESS (SIGSEGV) — KERN_INVALID_ADDRESS at 0x1 or 0x1e
Thread 0 (main thread):
  objc_msgSend / objc_opt_class
  swift_getObjectType
  swift_task_isMainExecutorImpl
  swift_task_isCurrentExecutorWithFlagsImpl
  MainActor.assumeIsolated (Timer callback in MenuBarIconAnimator)
```

The crash address (0x1, 0x1e) means the Swift runtime is dereferencing a corrupted isa pointer when checking the main executor. Something corrupted memory BEFORE this point.

## What Happens During BT Recording

When PTT is pressed with BT headphones connected:

1. **AudioDeviceEnumerator.recommendedInputDevice()** (`AudioDeviceManager.swift:150`) detects BT output + active media → returns built-in mic ID
2. **AudioCaptureManager.startEnginePhase()** (`AudioCaptureManager.swift:134`) calls `setInputDevice()` to switch to built-in mic
3. `setInputDevice()` (`AudioCaptureManager.swift:104`) writes to `kAudioOutputUnitProperty_CurrentDevice` via `AudioUnitSetProperty`
4. `engine.inputNode.setVoiceProcessingEnabled(true)` (line 167) — modifies audio graph
5. `engine.start()` (line 193) — starts the audio engine
6. **Meanwhile**: BT audio stack performs A2DP→SCO codec switch (background threads)
7. `.AVAudioEngineConfigurationChange` notification may fire (line 182) → `handleEngineConfigurationChange()` → `recoverFromCodecSwitch()`

## Suspect Areas

### 1. `setInputDevice()` — CoreAudio AudioUnit property write
`AudioCaptureManager.swift:104-126` — Writes `kAudioOutputUnitProperty_CurrentDevice` on the calling thread (main) while the BT audio stack may be reconfiguring the audio graph on another thread. CoreAudio property writes are supposed to be thread-safe but may not be under BT codec switching on macOS 26.4 beta.

### 2. `engine.inputNode` access during BT codec switch
Accessing `engine.inputNode` during a BT codec switch can trigger internal AVAudioEngine reconfiguration. The `inputNode` property itself may be internally recreated. If this happens concurrently with a Timer callback on the main thread that accesses an @MainActor property, the corrupted internal state could leak.

### 3. `setVoiceProcessingEnabled(true)` during BT transition
Line 167 — Voice processing changes the entire audio graph topology. Combined with a BT codec switch, this could create a race condition in CoreAudio internals.

### 4. `recoverFromCodecSwitch()` — the recovery path itself
`AudioCaptureManager.swift:461-550` — This method removes the tap, stops the engine, polls for format stabilization, then rebuilds. But `handleEngineConfigurationChange()` is dispatched via `Task { @MainActor in }` (line 187) — the crash may happen BEFORE this task runs, while the audio thread is still touching shared state.

### 5. `makeTapHandler` — audio thread callback
`AudioCaptureManager.swift:657-721` — The tap handler is `nonisolated` and runs on the audio I/O thread. It accesses `audioConverter`, `continuation`, and calls `onSamples` (which creates `Task { @MainActor in }`). During a BT codec switch, the `audioConverter` may become invalid, or buffer memory may be corrupted.

## Key Files

| File | Lines | Role |
|------|-------|------|
| `Audio/AudioCaptureManager.swift` | 722 | Main suspect — engine lifecycle, tap handler, BT recovery |
| `Audio/AudioDeviceManager.swift` | 169 | Device enumeration, BT detection, transport type queries |
| `App/MenuBarIconAnimator.swift` | 312 | Crash site (victim, not cause) — Timer callbacks with `MainActor.assumeIsolated` |
| `Services/HotkeyService.swift` | 582 | Secondary crash site (victim) — Carbon event handler with `MainActor.assumeIsolated` |

## Diagnostic Approach

1. **Connect BT headphones, add logging** to `setInputDevice()`, `startEnginePhase()`, and `recoverFromCodecSwitch()` to trace exactly what runs before the crash
2. **Check if crash happens during engine start or during recording** — add a log right after `engine.start()` succeeds
3. **Test with `MallocScribble=1`** — we already know this prevents the crash (timing change), confirming it's a race condition
4. **Try delaying `engine.start()` after `setInputDevice()`** — give CoreAudio time to finish BT routing
5. **Try running `setInputDevice()` on a non-main thread** — decouple from the main run loop

## Research Context

From Swift Forums: `MainActor.assumeIsolated` crashes are known when called from non-Swift-concurrency contexts (Timer, Carbon, NSEvent). Our crash is EXC_BAD_ACCESS (corrupted pointer), not EXC_BREAKPOINT (assertion) — this is memory corruption, not an isolation check failure. The `MainActor.assumeIsolated` calls are the VICTIM, not the cause.

Replacing with `DispatchQueue.main.async` won't fix the underlying memory corruption — it'll just move the crash to the next pointer dereference. The fix needs to be in the audio layer.
