# Feature: CLI Remote Control

**ID:** 003
**Category:** Hotkeys & Input
**Priority:** Medium
**Inspired by:** Handy — `handy --toggle-transcription` / `--cancel` CLI flags
**Status:** Ready for Implementation

## Problem

EnviousWispr can only be controlled via its GUI (hotkeys, menu bar). There is no way to trigger recording from scripts, shell aliases, Automator workflows, or other automation tools.

## Proposed Solution

Add CLI argument handling so a second instance of the app can send commands to the running instance. Common approach on macOS: use `NSDistributedNotificationCenter` or a Unix domain socket to communicate between the CLI invocation and the running app.

Commands to support:

- `EnviousWispr --toggle` — start/stop recording
- `EnviousWispr --cancel` — cancel current recording
- `EnviousWispr --status` — print current pipeline state

## Design

### IPC Strategy

Two complementary mechanisms are used:

1. **`NSDistributedNotificationCenter`** — fire-and-forget commands (`--toggle`, `--cancel`). Low overhead, no reply needed.
2. **`CFMessagePort`** (named Mach port) — synchronous request/reply for `--status`. The running app creates a local port; the CLI instance sends a message and waits for the reply string.

### Invocation Path

When the app launches and detects a recognized CLI flag in `CommandLine.arguments`, it:

1. Posts the appropriate distributed notification (or sends a CFMessagePort message for `--status`).
2. Waits just long enough for the reply (status only).
3. Calls `exit(0)` (or `exit(1)` on error) immediately — it never completes the full app launch.

The running app instance registers as a listener for these notifications in `applicationDidFinishLaunching`.

### Notification Names

```text
com.enviouswispr.cmd.toggle
com.enviouswispr.cmd.cancel
```

### CFMessagePort Name

```text
com.enviouswispr.status
```

---

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/App/AppDelegate.swift` | Register distributed notification observers; create CFMessagePort for status; wire to pipeline actions |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `cancelRecording()` method |
| `Sources/EnviousWispr/App/AppState.swift` | Add `cancelRecording()` convenience wrapper |

## New Files to Create

| File | Purpose |
| ---- | ------- |
| `Sources/EnviousWispr/Services/CLIHandler.swift` | Encapsulates all CLI detection, notification posting, CFMessagePort client logic, and early-exit behavior. Called from the very start of `applicationDidFinishLaunching`. |
| `Sources/EnviousWispr/Services/RemoteCommandServer.swift` | Runs inside the persistent app instance. Registers the CFMessagePort server and the distributed notification observers. |

---

## Step-by-Step Implementation Plan

### Step 1 — Add `cancelRecording()` to `TranscriptionPipeline`

Add the method directly after `toggleRecording()` in `TranscriptionPipeline.swift`:

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

`cancelRecording()` is synchronous and `@MainActor`-isolated (it inherits isolation from the class). Unlike `stopAndTranscribe()` it discards all audio immediately and returns to `.idle` rather than transitioning through `.transcribing`.

### Step 2 — Add `cancelRecording()` convenience to `AppState`

Add after the existing `toggleRecording()` in `AppState.swift`:

```swift
/// Cancel an in-progress recording without transcribing.
func cancelRecording() {
    pipeline.cancelRecording()
}
```

### Step 3 — Create `CLIHandler.swift`

This file is responsible for the *sending* side (the short-lived CLI invocation).

```swift
// Sources/EnviousWispr/Services/CLIHandler.swift

import Foundation
import AppKit

/// Handles CLI arguments when EnviousWispr is invoked from the command line.
///
/// Call `CLIHandler.handleIfNeeded()` at the very top of
/// `applicationDidFinishLaunching(_:)`. If a known CLI flag is found the
/// method posts the appropriate IPC message and terminates the process;
/// control never returns to the caller in that case.
enum CLIHandler {

    // MARK: - Notification names (must match RemoteCommandServer)

    static let toggleNotification = "com.enviouswispr.cmd.toggle"
    static let cancelNotification = "com.enviouswispr.cmd.cancel"
    static let statusPortName     = "com.enviouswispr.status" as CFString

    // MARK: - Public entry point

    /// Inspect `CommandLine.arguments` and, if a CLI flag is present, send
    /// the appropriate command to the running app instance, then exit.
    ///
    /// Returns only when no CLI flag is present (normal app launch).
    static func handleIfNeeded() {
        let args = CommandLine.arguments.dropFirst() // drop argv[0]

        if args.contains("--toggle") {
            sendNotification(named: toggleNotification)
            exit(0)
        }

        if args.contains("--cancel") {
            sendNotification(named: cancelNotification)
            exit(0)
        }

        if args.contains("--status") {
            let status = queryStatus()
            print(status)
            exit(0)
        }
    }

    // MARK: - Private helpers

    private static func sendNotification(named name: String) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name(name),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        // Give the notification a moment to be dispatched by the OS.
        Thread.sleep(forTimeInterval: 0.1)
    }

    private static func queryStatus() -> String {
        // Connect to the named Mach port created by the running app instance.
        guard let port = CFMessagePortCreateRemote(nil, statusPortName) else {
            return "error: EnviousWispr is not running"
        }

        var replyData: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(
            port,
            0,           // msgid (unused)
            nil,         // data (no payload needed)
            2.0,         // sendTimeout seconds
            2.0,         // rcvTimeout seconds
            CFRunLoopMode.defaultMode.rawValue,
            &replyData
        )

        guard result == kCFMessagePortSuccess,
              let data = replyData?.takeRetainedValue() as Data?,
              let text = String(data: data, encoding: .utf8) else {
            return "error: no response from app (code \(result))"
        }

        return text
    }
}
```

### Step 4 — Create `RemoteCommandServer.swift`

This file runs inside the *persistent* app instance and listens for commands.

```swift
// Sources/EnviousWispr/Services/RemoteCommandServer.swift

import Foundation
import AppKit

/// Registers IPC listeners so the running app instance can receive CLI commands.
///
/// Lifecycle:
///   - `start(appState:)` is called once from `applicationDidFinishLaunching`.
///   - The server holds a strong reference to the CFMessagePort and
///     distributed notification observers for the lifetime of the app.
@MainActor
final class RemoteCommandServer {

    private var notificationObservers: [NSObjectProtocol] = []
    private var statusPort: CFMessagePort?
    // Keep the callback alive (CFMessagePort holds an unretained pointer).
    private var statusCallback: CFMessagePortCallBack?

    func start(appState: AppState) {
        registerNotificationObservers(appState: appState)
        startStatusPort(appState: appState)
    }

    // MARK: - Distributed notifications (fire-and-forget)

    private func registerNotificationObservers(appState: AppState) {
        let center = DistributedNotificationCenter.default()

        let toggleObs = center.addObserver(
            forName: Notification.Name(CLIHandler.toggleNotification),
            object: nil,
            queue: .main
        ) { [weak appState] _ in
            guard let appState else { return }
            Task { @MainActor in
                await appState.toggleRecording()
            }
        }

        let cancelObs = center.addObserver(
            forName: Notification.Name(CLIHandler.cancelNotification),
            object: nil,
            queue: .main
        ) { [weak appState] _ in
            guard let appState else { return }
            Task { @MainActor in
                appState.cancelRecording()
            }
        }

        notificationObservers = [toggleObs, cancelObs]
    }

    // MARK: - CFMessagePort (synchronous status reply)

    private func startStatusPort(appState: AppState) {
        // Use a C-compatible callback via a static trampoline.
        // We pass `appState` as the `info` pointer (retained via Unmanaged).
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passRetained(appState).toOpaque(),
            retain: { ptr in ptr },
            release: { ptr in
                // Release when the port is invalidated.
                if let ptr { Unmanaged<AppState>.fromOpaque(ptr).release() }
            },
            copyDescription: nil
        )

        let callback: CFMessagePortCallBack = { _, _, _, info in
            guard let info else { return nil }
            // CFMessagePort callbacks run on the port's run loop thread (main).
            // AppState is @MainActor so accessing it here (main thread) is safe
            // when the port is scheduled on the main run loop (see below).
            let appState = Unmanaged<AppState>.fromOpaque(info).takeUnretainedValue()
            let stateText = appState.pipelineState.statusText
            let data = stateText.data(using: .utf8) as CFData?
            return data.map { Unmanaged.passRetained($0) }
        }

        statusCallback = callback // retain

        var isNew: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(
            nil,
            CLIHandler.statusPortName,
            callback,
            &context,
            &isNew
        ) else {
            print("[RemoteCommandServer] Failed to create CFMessagePort — another instance may be running.")
            return
        }

        // Schedule on the main run loop so the callback runs on the main thread,
        // which is required for accessing @MainActor-isolated AppState.
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        statusPort = port
    }

    deinit {
        notificationObservers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
        }
        if let port = statusPort {
            CFMessagePortInvalidate(port)
        }
    }
}
```

### Step 5 — Wire into `AppDelegate`

Modify `AppDelegate.swift` in two places.

**5a. Add a stored property for the server:**

```swift
// Add to AppDelegate's stored properties:
private var remoteCommandServer: RemoteCommandServer?
```

**5b. Insert at the very top of `applicationDidFinishLaunching(_:)`, before any other setup:**

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // --- CLI handling must come first ---
    // If this launch was triggered by a CLI flag (e.g. --toggle, --status),
    // CLIHandler sends the IPC command and calls exit(). Control never returns
    // to this function in the CLI case.
    CLIHandler.handleIfNeeded()

    // --- Normal persistent app launch continues below ---

    // Start listening for remote commands from future CLI invocations.
    let server = RemoteCommandServer()
    server.start(appState: appState)
    remoteCommandServer = server

    // ... existing setup code unchanged ...
    NSApp.setActivationPolicy(.accessory)
    // ... rest of the existing method ...
}
```

---

## New Types / Properties

| Symbol | Location | Description |
| ------ | -------- | ----------- |
| `CLIHandler` (enum) | `CLIHandler.swift` | Stateless namespace for CLI detection and IPC send logic |
| `CLIHandler.toggleNotification` | `CLIHandler.swift` | Distributed notification name for `--toggle` |
| `CLIHandler.cancelNotification` | `CLIHandler.swift` | Distributed notification name for `--cancel` |
| `CLIHandler.statusPortName` | `CLIHandler.swift` | CFMessagePort name for `--status` queries |
| `RemoteCommandServer` | `RemoteCommandServer.swift` | `@MainActor` class; holds observers and CFMessagePort |
| `AppDelegate.remoteCommandServer` | `AppDelegate.swift` | Keeps `RemoteCommandServer` alive for the app lifetime |
| `TranscriptionPipeline.cancelRecording()` | `TranscriptionPipeline.swift` | Stop audio, discard samples, reset to `.idle` |
| `AppState.cancelRecording()` | `AppState.swift` | Convenience wrapper over `pipeline.cancelRecording()` |

---

## Testing Strategy

### Manual Smoke Tests

After building with `swift build -c release`:

```bash
APP=".build/release/EnviousWispr.app/Contents/MacOS/EnviousWispr"

# 1. Launch the app normally
open -a EnviousWispr

# 2. Toggle recording on
$APP --toggle
# Expected: menu bar icon changes to recording state

# 3. Toggle recording off
$APP --toggle
# Expected: pipeline transitions through transcribing → complete

# 4. Start recording, then cancel
$APP --toggle
sleep 1
$APP --cancel
# Expected: icon returns to idle immediately, no transcript created

# 5. Check status
$APP --status
# Expected output: one of: "Ready", "Recording", "Transcribing", "Polishing", "Complete", or "Error: ..."

# 6. Status when app not running
# Kill EnviousWispr, then:
$APP --status
# Expected: "error: EnviousWispr is not running"
```

### Unit / Integration Tests

- Test that `CLIHandler.handleIfNeeded()` is a no-op when `CommandLine.arguments` contains no recognized flags.
- Test `TranscriptionPipeline.cancelRecording()` in isolation:
  - In `.idle` state: verify state remains `.idle`.
  - In `.recording` state: verify state transitions to `.idle` and `audioCapture.isCapturing` becomes `false`.
  - In `.transcribing` state: verify it is a no-op.

### Security Considerations

- `NSDistributedNotificationCenter` is **system-wide**: any process on the machine can post `com.enviouswispr.cmd.toggle`. This is acceptable for a local desktop utility but means a malicious local process could trigger recording. Mitigation: the app only starts/stops recording; no sensitive data is exposed via the IPC channel.
- The CFMessagePort is named and accessible to all local processes. The status reply is the same string shown in the menu bar — not sensitive.
- Future hardening option: include a per-session random token in the notification `userInfo` and validate it in the server (token stored in a shared NSUserDefaults suite).

---

## Risks & Considerations

- **Second instance vs. CLI invocation:** `CLIHandler.handleIfNeeded()` must run *before* `setupStatusItem()` and the Sparkle updater setup. If it exits early, those systems are never initialized — intentional and correct.
- **CFMessagePort on Apple Silicon:** Named Mach ports work identically on Apple Silicon. No architecture-specific concerns.
- **Sandboxing:** If the app is ever sandboxed, `NSDistributedNotificationCenter` requires the `com.apple.security.temporary-exception.mach-lookup.global-name` entitlement for the port name. Current app is not sandboxed.
- **Multiple CLI invocations in flight:** Each `--toggle` or `--cancel` invocation posts a notification and exits immediately; there is no queuing issue since the running app processes them sequentially on the main actor.
