# Hands-Free Recording Mode

**Date:** 2026-03-10
**Status:** Approved
**Competitive Reference:** [Wispr Flow analysis](../../competitors/wisprflow/hands-free-mode-reverse-engineering.md)

---

## Summary

Add double-press-to-lock recording to the existing push-to-talk system. Default behavior is unchanged: hold the record key to dictate, release to stop. Double-pressing within 500ms switches to persistent "hands-free" recording that ignores key releases. A single press while locked stops recording. Triple-press within 500ms cancels/discards.

Always enabled — no settings toggle for v1.

---

## State Machine

### New State (HotkeyService)

```swift
/// true when recording is locked into hands-free mode
var isRecordingLocked: Bool = false

/// Timestamp of the key-down that started the current recording
var recordingStartTime: Date? = nil

/// 500ms timer waiting for a possible double-press before stopping PTT
var debounceTask: Task<Void, Never>? = nil
```

### Constant

```swift
/// Double-press detection window and debounce delay (milliseconds)
static let handsFreeDebounceDelayMs: UInt64 = 500
```

Add to `TimingConstants` in `Constants.swift`. Use as `Task.sleep(for: .milliseconds(TimingConstants.handsFreeDebounceDelayMs))`.

### Action Down (Key Press)

```
1. If pipeline is processing/transcribing → ignore
   (throttle: only log/notify if lastActionTime > 500ms ago)

2. If NOT currently recording:
   → isRecordingLocked = false
   → recordingStartTime = Date()
   → debounceTask?.cancel()
   → Task { await onStartRecording?() }

3. Else if recording AND (Date() - recordingStartTime <= 500ms):
   a. If isRecordingLocked:
      → "Triple press — cancel"
      → debounceTask?.cancel()
      → Task { await onCancelRecording?() }
   b. Else:
      → "Double press — lock"
      → debounceTask?.cancel()      // Cancel pending PTT stop from first release
      → isRecordingLocked = true
      → Task { await onLocked?() }

4. Else if recording AND isRecordingLocked:
   → "Single press while locked — stop"
   → Task { await onStopRecording?() }
```

### Action Up (Key Release)

```
1. If NOT recording → ignore

2. If isRecordingLocked → ignore (release suppression)

3. If (Date() - recordingStartTime <= 500ms):
   → debounceTask?.cancel()
   → debounceTask = Task { @MainActor in
       try? await Task.sleep(for: .milliseconds(500))
       guard !Task.isCancelled else { return }
       if stillRecording && !isRecordingLocked {
           await onStopRecording?()
       }
     }

4. Else:
   → normal PTT release
   → Task { await onStopRecording?() }
```

### Cleanup (on stop/cancel/escape/VAD auto-stop)

```
isRecordingLocked = false
recordingStartTime = nil
debounceTask?.cancel()
debounceTask = nil
```

---

## Callbacks

### Existing (unchanged signatures)

- `onStartRecording: (() async -> Void)?` — start pipeline
- `onStopRecording: (() async -> Void)?` — stop pipeline, transcribe

### New

- `onLocked: (() async -> Void)?` — notify AppState that recording switched to hands-free (overlay transition)

### Already Exists (verify cleanup)

- `onCancelRecording: (() async -> Void)?` — already wired (HotkeyService line 72, AppState line 248). Verify that the existing `cancelRecording()` path also clears `isRecordingLocked` in both HotkeyService and AppState.

---

## AppState Wiring

```swift
// In AppState.init, after existing hotkey callback setup:

hotkeyService.onLocked = { [weak self] in
    self?.isRecordingLocked = true
    // Overlay will react to this via @Observable
}

// onCancelRecording already exists and routes to cancelRecording()
// which uses the existing .cancelRecording PipelineEvent.
// Ensure cancelRecording() also clears isRecordingLocked:
hotkeyService.onCancelRecording = { [weak self] in
    self?.isRecordingLocked = false
    self?.cancelRecording()  // existing method, uses .cancelRecording event
}
```

Expose `isRecordingLocked: Bool` as a published property on AppState so the overlay can read it.

**Important:** HotkeyService cleanup (clearing `isRecordingLocked`, `recordingStartTime`, `debounceTask`) must happen inside HotkeyService itself, before invoking the callback. AppState cannot reach back into HotkeyService to clear these. The pattern is:

```swift
// Inside HotkeyService, before calling the callback:
private func performCleanup() {
    isRecordingLocked = false
    recordingStartTime = nil
    debounceTask?.cancel()
    debounceTask = nil
}
// Then: performCleanup(); Task { await onStopRecording?() }
```

---

## Overlay Changes

**Note:** `RecordingOverlayView` is defined inside `RecordingOverlayPanel.swift` (not a separate file).

### Normal PTT Mode (no change)

```
[Rainbow Lips (current size)] [Timer "0:03"]
```

### Hands-Free Locked Mode

```
[Rainbow Lips (2x size, smooth transition)]
```

- Timer fades out
- Lips scale up to 2x with animation
- Transition: `withAnimation(.easeInOut(duration: 0.3))`

### How `isRecordingLocked` Reaches the Overlay

`RecordingOverlayView` currently receives only `audioLevelProvider` — it has no access to AppState. Two options:

**Option A (recommended): Add `isRecordingLocked: Bool` parameter to `RecordingOverlayView` and pass it through `createPanel()`.** The `RecordingOverlayPanel.show(intent:audioLevelProvider:)` method already accepts parameters — add `isRecordingLocked` to the call site. AppState calls `show()` with the current lock state.

**Option B: Add a new `OverlayIntent` case `.recordingLocked(audioLevel: Float)`.** This is heavier and changes the protocol. Not recommended for v1.

### Panel Dimensions

Current panel: `width: 185, height: 44`. RainbowLipsIcon is 24pt. At 2x scale → 48pt, which exceeds the 44pt height. The timer disappears, freeing horizontal space. **Locked mode panel dimensions: `width: 120, height: 64`.** Narrower (no timer text), taller (2x lips). Animate the frame change with the same 0.3s easing.

### Implementation (inside RecordingOverlayPanel.swift)

```swift
// In RecordingOverlayView:
let isRecordingLocked: Bool  // new parameter

RainbowLipsIcon(audioLevel: audioLevel)
    .scaleEffect(isRecordingLocked ? 2.0 : 1.0)
    .animation(.easeInOut(duration: 0.3), value: isRecordingLocked)

Text(formattedDuration)
    .opacity(isRecordingLocked ? 0 : 1)
    .animation(.easeInOut(duration: 0.3), value: isRecordingLocked)
```

---

## Anti-Spam Protections (5 Layers)

### Layer 1: Processing State Gate

Before any action-down, check if the pipeline is in a processing state (transcribing, polishing, loading model). If so, reject entirely. Throttle the "still processing" notification using `lastActionTime` — only show it if the last press was > 500ms ago, otherwise silently ignore.

### Layer 2: Debounce Timer

The 500ms debounce timer on quick releases prevents premature PTT stops. Cancelled on double-press (lock) or new recording start.

### Layer 3: Release Suppression

When `isRecordingLocked == true`, all key releases are ignored. Recording only stops via explicit key press, Escape, or VAD auto-stop.

### Layer 4: Triple-Press Escape Valve

Third press within 500ms of `recordingStartTime` while locked → cancel everything. Prevents frustration from accidental double-press locks.

### Layer 5: recordingTask Serialization (existing)

Each new press/release cancels the prior `recordingTask`, preventing zombie start/stop operations from rapid key spam. This existing mechanism continues to work unchanged.

---

## Edge Cases

### Modifier Key Spurious Events

`NSEvent.flagsChanged` fires when ANY modifier changes, not just our target. The existing HotkeyService already filters by specific key code — no change needed. The `isModifierHeld` flag correctly tracks only the target modifier.

### Escape Key While Locked

The cancel hotkey (Escape) is registered when entering recording state and unregistered on exit. It calls `onCancelRecording` on HotkeyService, which calls `performCleanup()` (clearing `isRecordingLocked`, `recordingStartTime`, `debounceTask`) before invoking the callback. AppState's `cancelRecording()` then clears its own `isRecordingLocked` property and handles the pipeline.

### VAD 5-Minute Auto-Stop While Locked

The VAD manager's `maxRecordingDuration` (300s) auto-stop fires `stopAndTranscribe()` regardless of lock state. This is correct — we don't want infinite recordings. The cleanup path clears `isRecordingLocked`.

### App Deactivation While Locked

If the user switches apps while in locked hands-free mode, recording continues (same as current PTT behavior if somehow held). The VAD auto-stop provides the safety net.

### Key Auto-Repeat

Only relevant for non-modifier keys. Carbon `kEventHotKeyPressed` does not fire for auto-repeat. NSEvent.flagsChanged does not auto-repeat. No change needed.

---

## Files to Modify

| File | Change |
|------|--------|
| `Services/HotkeyService.swift` | Add `isRecordingLocked`, `recordingStartTime`, `debounceTask`, `performCleanup()`. Rewrite press/release handlers in **both** `handleCarbonHotkey()` and `handleFlagsChanged()` with the state machine. Add `onLocked` callback. Verify `onCancelRecording` cleanup clears lock state. |
| `App/AppState.swift` | Wire `onLocked` callback. Expose `isRecordingLocked` property. Update `cancelRecording()` to clear `isRecordingLocked`. Pass `isRecordingLocked` to overlay `show()` calls. |
| `Views/Overlay/RecordingOverlayPanel.swift` | Add `isRecordingLocked: Bool` parameter to `RecordingOverlayView` and `createPanel()`. Animate lips 2x scale, fade timer. Adjust panel frame to `120x64` when locked, `185x44` when normal. |
| `Utilities/Constants.swift` | Add `TimingConstants.handsFreeDebounceDelayMs: UInt64 = 500`. |

**No changes needed to `DictationPipeline.swift`** — `.cancelRecording` PipelineEvent already exists.

### Critical: Dual Handler Paths

HotkeyService has two separate PTT handlers that BOTH need the state machine:

1. `handleCarbonHotkey()` (lines ~249-282) — key+modifier combos via Carbon `RegisterEventHotKey`
2. `handleFlagsChanged()` (lines ~288-333) — modifier-only keys via `NSEvent.flagsChanged`

Both share `isRecordingLocked`, `recordingStartTime`, and `debounceTask`. Extract the state machine logic into a shared method (e.g. `handleRecordAction(isPress: Bool)`) called by both handlers. The existing `isModifierHeld` flag continues to work — it tracks press/release edges, and the second key-down after a release correctly arrives as `isPress && !isModifierHeld`.

---

## What's NOT in v1

- Clickable X (dismiss) and Stop buttons on overlay — future enhancement
- Settings toggle to disable hands-free — add if users complain about 500ms PTT delay
- Sound feedback differentiation (lock sound vs start sound) — future with feature #012
- POPO nudge ("Switch to hands-free mode" after 60s of PTT) — nice organic discovery, later
- Shortcut collision detection (auto-cancel if other modifiers detected within 1s) — nice-to-have, later
- Deeplink API for hands-free start/stop — later

---

## Testing Strategy

1. **Normal PTT unchanged** — hold > 500ms, release → stops and transcribes (no delay)
2. **Double-press locks** — press, release quickly, press again within 500ms → recording continues, lips grow 2x, timer hidden
3. **Release suppressed while locked** — release key after locking → recording continues
4. **Single press stops locked recording** — while locked, press record key → stops and transcribes
5. **Triple-press cancels** — three presses within 500ms → recording cancelled/discarded
6. **Quick PTT debounce** — press and release within 500ms, don't press again → recording stops after 500ms debounce timer
7. **Escape cancels locked mode** — while locked, press Escape → recording cancelled, lock cleared
8. **VAD auto-stop while locked** — record for 5 minutes in locked mode → auto-stops, lock cleared
9. **Spam during processing** — press record key repeatedly while transcribing → ignored, no crash
10. **Modifier key filtering** — while recording with Option, press Command → no spurious double-press detection
