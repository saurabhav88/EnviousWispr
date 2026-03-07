# Feature: Unix Signal Integration

**ID:** 004
**Category:** Hotkeys & Input
**Priority:** Low
**Inspired by:** Handy — SIGUSR1/SIGUSR2 for shell/WM integration
**Status:** Ready for Implementation

## Problem

Power users and automation tools (Hammerspoon, Raycast, shell scripts) cannot trigger EnviousWispr actions without simulating keystrokes. Unix signals provide a lightweight IPC mechanism.

## Proposed Solution

Handle `SIGUSR1` and `SIGUSR2` in the app process:

- `SIGUSR1` → toggle recording (start if idle, stop if recording)
- `SIGUSR2` → cancel current recording

Users can then control the app via `kill -USR1 $(pgrep EnviousWispr)`.

## Design

### Signal Handling Strategy

Standard C signal handlers (`signal()` / `sigaction()`) are unsafe for complex work — they may only call async-signal-safe functions. The correct approach for Swift/GCD apps is `DispatchSource.makeSignalSource()`, which:

1. Masks the signal from the default handler (`signal(SIGUSR1, SIG_IGN)`).
2. Installs a `DispatchSource` that fires a block on a chosen queue when the signal arrives.
3. Dispatches the actual work to `@MainActor` from that block.

This is the **only** correct approach in a Swift 6 / GCD app. It avoids all async-signal-safety restrictions and integrates cleanly with Swift concurrency.

### Signal-to-Action Mapping

| Signal | Action |
| ------ | ------ |
| `SIGUSR1` | `appState.toggleRecording()` |
| `SIGUSR2` | `appState.cancelRecording()` |

### Dependency on Feature 003

`cancelRecording()` on `TranscriptionPipeline` and `AppState` is also required by feature 003 (CLI remote control). If 003 is implemented first, that method already exists. If 004 is implemented first, add `cancelRecording()` as described in Step 1 below.

---

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/App/AppDelegate.swift` | Call `SignalHandler.start(appState:)` in `applicationDidFinishLaunching` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `cancelRecording()` (if not already added by feature 003) |
| `Sources/EnviousWispr/App/AppState.swift` | Add `cancelRecording()` convenience wrapper (if not already added by feature 003) |

## New Files to Create

| File | Purpose |
| ---- | ------- |
| `Sources/EnviousWispr/Services/SignalHandler.swift` | Installs `DispatchSource` signal sources for SIGUSR1 and SIGUSR2; dispatches to `@MainActor` |

---

## Step-by-Step Implementation Plan

### Step 1 — Add `cancelRecording()` to `TranscriptionPipeline` (if not already present)

Skip this step if feature 003 has already been implemented. Otherwise, add the method directly after `toggleRecording()` in `TranscriptionPipeline.swift`:

```swift
/// Cancel an in-progress recording without transcribing.
/// No-op if the pipeline is not in the `.recording` state.
func cancelRecording() {
    guard state == .recording else { return }

    // Stop VAD monitoring task first so it cannot call stopAndTranscribe().
    vadMonitorTask?.cancel()
    vadMonitorTask = nil

    // Stop audio capture and discard all accumulated samples.
    _ = audioCapture.stopCapture()
    silenceDetector = nil
    targetApp = nil
    currentTranscript = nil

    state = .idle
}
```

### Step 2 — Add `cancelRecording()` convenience to `AppState` (if not already present)

Add after the existing `toggleRecording()` in `AppState.swift`:

```swift
/// Cancel an in-progress recording without transcribing.
func cancelRecording() {
    pipeline.cancelRecording()
}
```

### Step 3 — Create `SignalHandler.swift`

```swift
// Sources/EnviousWispr/Services/SignalHandler.swift

import Foundation

/// Installs GCD-based signal sources for SIGUSR1 and SIGUSR2.
///
/// Call `SignalHandler.start(appState:)` once from
/// `applicationDidFinishLaunching(_:)`. The sources are retained for the
/// lifetime of the process in static storage.
///
/// Signal → Action mapping:
///   SIGUSR1 → appState.toggleRecording()
///   SIGUSR2 → appState.cancelRecording()
enum SignalHandler {

    // Static storage keeps the DispatchSources alive for the process lifetime.
    private static var usr1Source: DispatchSourceSignal?
    private static var usr2Source: DispatchSourceSignal?

    /// Install signal handlers. Safe to call multiple times (subsequent calls
    /// are no-ops because the sources are already created).
    static func start(appState: AppState) {
        guard usr1Source == nil else { return }

        // Step A: Tell the kernel to ignore the default signal disposition so
        // the DispatchSource gets to handle it exclusively.
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)

        // Step B: Create DispatchSources on a background queue.
        // The handler block will hop back to the main actor for AppState access.
        let queue = DispatchQueue(label: "com.enviouswispr.signals", qos: .userInitiated)

        let src1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        src1.setEventHandler { [weak appState] in
            guard let appState else { return }
            Task { @MainActor in
                await appState.toggleRecording()
            }
        }
        src1.resume()
        usr1Source = src1

        let src2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: queue)
        src2.setEventHandler { [weak appState] in
            guard let appState else { return }
            Task { @MainActor in
                appState.cancelRecording()
            }
        }
        src2.resume()
        usr2Source = src2
    }
}
```

Key design decisions in this snippet:

- `signal(SIGUSR1, SIG_IGN)` / `signal(SIGUSR2, SIG_IGN)` must precede `DispatchSource.makeSignalSource`. Without this, the OS may deliver the signal via the default handler (which terminates the process for SIGUSR1/SIGUSR2 on Darwin) before the GCD source has a chance to intercept it.
- The sources are stored in `static var` properties — they are never cancelled because the app needs them for its entire lifetime.
- The event handler captures `appState` weakly and hops to `@MainActor` via `Task { @MainActor in ... }`. This is the correct pattern for bridging an unstructured GCD callback into Swift 6 strict concurrency without `nonisolated(unsafe)` hacks.
- The dedicated serial `DispatchQueue` ensures signal events are serialized if two signals arrive in rapid succession.

### Step 4 — Wire into `AppDelegate`

Add one call at the end of `applicationDidFinishLaunching(_:)`, after `appState` and `setupStatusItem()` are ready:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ... existing setup unchanged ...

    // Install SIGUSR1 / SIGUSR2 handlers.
    SignalHandler.start(appState: appState)
}
```

No stored property is needed in `AppDelegate` because `SignalHandler` retains the sources in its own static storage.

---

## New Types / Properties

| Symbol | Location | Description |
| ------ | -------- | ----------- |
| `SignalHandler` (enum) | `SignalHandler.swift` | Stateless namespace; owns static `DispatchSourceSignal` references |
| `SignalHandler.usr1Source` | `SignalHandler.swift` | Static `DispatchSourceSignal` for SIGUSR1; kept alive for process lifetime |
| `SignalHandler.usr2Source` | `SignalHandler.swift` | Static `DispatchSourceSignal` for SIGUSR2; kept alive for process lifetime |
| `TranscriptionPipeline.cancelRecording()` | `TranscriptionPipeline.swift` | Stop audio, discard samples, reset to `.idle` (shared with feature 003) |
| `AppState.cancelRecording()` | `AppState.swift` | Convenience wrapper over `pipeline.cancelRecording()` (shared with feature 003) |

---

## Testing Strategy

### Manual Smoke Tests

Build and launch the app, then use `pgrep` to find its PID:

```bash
# Launch normally
open -a EnviousWispr

PID=$(pgrep -x EnviousWispr)
echo "App PID: $PID"

# 1. Toggle recording on via SIGUSR1
kill -USR1 $PID
# Expected: menu bar icon changes to recording state

# 2. Toggle recording off via SIGUSR1
kill -USR1 $PID
# Expected: pipeline transitions through transcribing → complete

# 3. Start recording, cancel via SIGUSR2
kill -USR1 $PID
sleep 1
kill -USR2 $PID
# Expected: icon returns to idle immediately; no transcript is created

# 4. SIGUSR2 when idle (no-op)
kill -USR2 $PID
# Expected: no state change, app remains running

# 5. Rapid double SIGUSR1
kill -USR1 $PID; kill -USR1 $PID
# Expected: toggles on then off without crashing; final state is idle or transcribing
```

### Regression / Stability Tests

- Send 20 SIGUSR1 signals in a tight loop (`for i in $(seq 20); do kill -USR1 $PID; done`). App must not crash or deadlock.
- Send SIGUSR2 while in `.transcribing` state (pipeline should be a no-op).
- Restart the app and confirm signals still work (static sources are re-created on each launch).

### Concurrency Correctness

- All mutations of `AppState` and `TranscriptionPipeline` happen on `@MainActor`, whether triggered by signal, hotkey, or CLI. The `Task { @MainActor in }` hop in the signal handler ensures this.
- There is no shared mutable state between the signal `DispatchQueue` and the main actor — the queue only enqueues a `Task`, which is safe.

---

## Risks & Considerations

- **Signal masking order:** `signal(SIGUSRn, SIG_IGN)` must be called *before* `DispatchSource.makeSignalSource`. Reversing the order creates a race window during which the default handler could fire and terminate the process. The `start()` implementation above follows the correct order.
- **`weak appState` capture:** `AppState` is owned by `AppDelegate`. If the app tears down `AppDelegate` before cancelling the sources (which cannot happen in practice since sources live in static storage), the weak reference protects against a dangling pointer. The guard ensures the Task is not enqueued on a deallocated object.
- **Interaction with LLDB / debugger:** Signal sources are paused while the process is stopped in a debugger. This is expected behavior and not a bug.
- **Overlap with feature 003 (CLI remote control):** Both features require `cancelRecording()` on `TranscriptionPipeline` and `AppState`. Implement the shared methods once and reuse. Signal sources and CLIHandler/RemoteCommandServer are fully independent and can coexist without conflict.
- **System signals:** SIGUSR1 and SIGUSR2 are reserved for application use by POSIX and are not used by macOS frameworks or the Swift runtime, making them safe choices for this purpose.
