# Feature: Debug Mode Toggle

**ID:** 019
**Category:** Developer Experience
**Priority:** Medium
**Inspired by:** Handy — Cmd/Ctrl+Shift+D toggle, verbose logging, log directory access
**Status:** Ready for Implementation

## Problem

When users report bugs, there is no way to capture detailed diagnostic information. Developers must ask users to rebuild with logging changes. There is no runtime toggle for verbose logging.

## Proposed Solution

Add a debug mode that can be toggled at runtime:

1. **Hotkey:** Cmd+Shift+D toggles debug mode on/off
2. **When enabled:** verbose logging to `~/Library/Logs/EnviousWispr/`, plus OSLog subsystem entries visible in Console.app
3. **Log scope:** audio pipeline details, VAD decisions, ASR timing, LLM request/response (API keys redacted by design)
4. **Settings:** "Open Log Directory" button in a new Diagnostics settings tab; log level picker
5. **Auto-disable:** debug mode resets to off on app restart (non-persistent by default)
6. **Menu bar badge:** status item title suffix " [DEBUG]" when active

## Files to Modify

- `Sources/EnviousWispr/App/AppState.swift` — add `isDebugModeEnabled: Bool` (non-persisted), `debugLogLevel: DebugLogLevel` (persisted); wire Cmd+Shift+D via `HotkeyService` or direct `NSEvent` monitor
- `Sources/EnviousWispr/App/AppDelegate.swift` — update `populateMenu(_:)` to show "[DEBUG]" badge in status text when debug is active; add global `NSEvent` monitor for Cmd+Shift+D
- `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` — add `AppLogger.shared.log()` call sites at key pipeline transitions
- `Sources/EnviousWispr/Audio/AudioCaptureManager.swift` — log sample counts, audio level, format info on capture start/stop
- `Sources/EnviousWispr/Views/Settings/SettingsView.swift` — add a "Diagnostics" tab containing `DiagnosticsSettingsView`

## New Files

- `Sources/EnviousWispr/Utilities/AppLogger.swift` — the `actor AppLogger` with OSLog integration, file log rotation, and API-key redaction
- `Sources/EnviousWispr/Utilities/DebugLogLevel.swift` — `enum DebugLogLevel` with cases and display names
- `Sources/EnviousWispr/Views/Settings/DiagnosticsSettingsView.swift` — new settings tab: enable toggle, log level picker, "Open Log Directory" button, "Copy Log Path" button

## Implementation Plan

### Step 1: Define DebugLogLevel

```swift
// Sources/EnviousWispr/Utilities/DebugLogLevel.swift

enum DebugLogLevel: String, CaseIterable, Codable, Sendable, Comparable {
    case info    = "info"
    case verbose = "verbose"
    case debug   = "debug"

    var displayName: String {
        switch self {
        case .info:    return "Info (default)"
        case .verbose: return "Verbose"
        case .debug:   return "Debug (all events)"
        }
    }

    // Comparable: info < verbose < debug
    private var order: Int {
        switch self { case .info: return 0; case .verbose: return 1; case .debug: return 2 }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}
```

### Step 2: Implement AppLogger actor

`AppLogger` is an `actor` so all log writes are serialized without locks. OSLog messages go to the unified logging system (visible in Console.app filtered by subsystem `com.enviouswispr.app`). File logging activates only when `isDebugModeEnabled` is true, writing to `~/Library/Logs/EnviousWispr/app.log` with rotation.

```swift
// Sources/EnviousWispr/Utilities/AppLogger.swift
import Foundation
import OSLog

/// Centralised logging for EnviousWispr.
///
/// - OSLog entries are always emitted (at the appropriate level) and are
///   visible in Console.app under subsystem "com.enviouswispr.app".
/// - File logging to ~/Library/Logs/EnviousWispr/ is active only while
///   isDebugModeEnabled is true.
/// - API keys and secrets are never logged — callers must redact before passing.
actor AppLogger {
    static let shared = AppLogger()

    // MARK: - Configuration (set from MainActor)
    private(set) var isDebugModeEnabled: Bool = false
    private(set) var logLevel: DebugLogLevel = .info

    // MARK: - OSLog subsystem
    private let oslog = Logger(subsystem: "com.enviouswispr.app", category: "pipeline")

    // MARK: - File logging
    /// Max size of a single log file before rotation (10 MB).
    private let maxFileSize: Int = 10 * 1024 * 1024
    /// Maximum number of rotated log files to keep.
    private let maxFileCount: Int = 5

    private var logDirectory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
    }
    private var currentLogURL: URL { logDirectory.appendingPathComponent("app.log") }
    private var fileHandle: FileHandle?

    private init() {}

    // MARK: - Control

    func setDebugMode(_ enabled: Bool) {
        isDebugModeEnabled = enabled
        if enabled {
            openFileHandleIfNeeded()
            log("Debug mode enabled", level: .info, category: "AppLogger")
        } else {
            fileHandle?.closeFile()
            fileHandle = nil
            log("Debug mode disabled", level: .info, category: "AppLogger")
        }
    }

    func setLogLevel(_ level: DebugLogLevel) {
        logLevel = level
    }

    // MARK: - Logging

    /// Log a message. Call sites use fire-and-forget Task syntax:
    ///   Task { await AppLogger.shared.log("message", level: .verbose, category: "Pipeline") }
    func log(_ message: String, level: DebugLogLevel = .info, category: String = "App") {
        // Always emit to OSLog at the appropriate level
        switch level {
        case .info:    oslog.info("[\(category)] \(message)")
        case .verbose: oslog.debug("[\(category)] \(message)")
        case .debug:   oslog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        }

        // Only write to file when debug mode is active and message meets the level threshold
        guard isDebugModeEnabled, level <= logLevel else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        writeToFile(data)
    }

    // MARK: - File management

    private func openFileHandleIfNeeded() {
        guard fileHandle == nil else { return }
        let dir = logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: currentLogURL.path) {
            FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: currentLogURL)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ data: Data) {
        guard let fh = fileHandle else { return }
        fh.write(data)
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
              let size = attrs[.size] as? Int,
              size >= maxFileSize else { return }

        fileHandle?.closeFile()
        fileHandle = nil

        // Rotate: app.log -> app.1.log -> app.2.log ... up to maxFileCount
        let dir = logDirectory
        for i in stride(from: maxFileCount - 1, through: 1, by: -1) {
            let old = dir.appendingPathComponent("app.\(i).log")
            let new = dir.appendingPathComponent("app.\(i + 1).log")
            try? FileManager.default.moveItem(at: old, to: new)
        }
        try? FileManager.default.moveItem(at: currentLogURL,
                                          to: dir.appendingPathComponent("app.1.log"))

        // Delete oldest if over limit
        let oldest = dir.appendingPathComponent("app.\(maxFileCount + 1).log")
        try? FileManager.default.removeItem(at: oldest)

        openFileHandleIfNeeded()
    }

    // MARK: - Utilities

    func logDirectoryURL() -> URL { logDirectory }

    func clearLogs() throws {
        fileHandle?.closeFile()
        fileHandle = nil
        let dir = logDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "log" {
            try FileManager.default.removeItem(at: file)
        }
        if isDebugModeEnabled { openFileHandleIfNeeded() }
    }
}
```

**API key redaction by design:** `AppLogger` never inspects the content of messages. Callers are responsible for not passing secrets. The LLM connector call sites log the model name and response length only — never the API key or full prompt/response body.

### Step 3: Add isDebugModeEnabled to AppState

`isDebugModeEnabled` is intentionally not persisted — it resets to `false` on every launch, as debug mode should not be accidentally left on in production:

```swift
// AppState.swift — add properties:
var isDebugModeEnabled: Bool = false {
    didSet {
        Task { await AppLogger.shared.setDebugMode(isDebugModeEnabled) }
    }
}

var debugLogLevel: DebugLogLevel {
    didSet {
        UserDefaults.standard.set(debugLogLevel.rawValue, forKey: "debugLogLevel")
        Task { await AppLogger.shared.setLogLevel(debugLogLevel) }
    }
}

// In init(), load persisted log level (but NOT debug mode):
debugLogLevel = DebugLogLevel(
    rawValue: defaults.string(forKey: "debugLogLevel") ?? ""
) ?? .info
// Wire log level to logger at launch (debug mode starts false):
Task { await AppLogger.shared.setLogLevel(debugLogLevel) }
```

### Step 4: Register Cmd+Shift+D global hotkey in AppDelegate

Add a local+global `NSEvent` monitor in `AppDelegate.applicationDidFinishLaunching(_:)`. This uses the same pattern as the existing hotkey infrastructure — extract key codes before dispatching to `MainActor`:

```swift
// AppDelegate.swift — in applicationDidFinishLaunching, after setupStatusItem():
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let keyCode = event.keyCode
    if flags == [.command, .shift] && keyCode == 2 { // keyCode 2 = D
        Task { @MainActor [weak self] in
            self?.toggleDebugMode()
        }
        return nil // Consume the event
    }
    return event
}

NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let keyCode = event.keyCode
    if flags == [.command, .shift] && keyCode == 2 {
        Task { @MainActor [weak self] in
            self?.toggleDebugMode()
        }
    }
}
```

```swift
// AppDelegate.swift — add helper:
@MainActor
private func toggleDebugMode() {
    appState.isDebugModeEnabled.toggle()
    updateIcon()
    // Rebuild menu to show/hide [DEBUG] badge
    if let menu = statusItem?.menu { populateMenu(menu) }
}
```

### Step 5: Update AppDelegate.populateMenu for the debug badge

```swift
// AppDelegate.swift — in populateMenu(_:):
// Change the status line to include [DEBUG] when active:
let debugBadge = appState.isDebugModeEnabled ? " [DEBUG]" : ""
let statusText = "\(state.statusText) — \(backend)\(debugBadge)"
let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
statusMenuItem.isEnabled = false
```

### Step 6: Add log call sites in TranscriptionPipeline

Log calls are fire-and-forget `Task` dispatches so they never block the pipeline:

```swift
// TranscriptionPipeline.swift — startRecording():
Task { await AppLogger.shared.log(
    "Recording started. Backend: \(asrManager.currentBackend)",
    level: .info, category: "Pipeline"
) }

// stopAndTranscribe() — after rawSamples captured:
Task { await AppLogger.shared.log(
    "Captured \(rawSamples.count) samples (\(String(format: "%.2f", Double(rawSamples.count)/16000))s)",
    level: .verbose, category: "Pipeline"
) }

// After VAD filtering:
Task { await AppLogger.shared.log(
    "VAD filtered to \(samples.count) samples (\(String(format: "%.1f", Double(samples.count)/Double(rawSamples.count)*100))% voiced)",
    level: .verbose, category: "Pipeline"
) }

// After ASR result:
Task { await AppLogger.shared.log(
    "ASR complete: \(result.text.count) chars, lang=\(result.language ?? "?"), " +
    "duration=\(String(format: "%.2f", result.duration))s, " +
    "processingTime=\(String(format: "%.2f", result.processingTime))s",
    level: .info, category: "Pipeline"
) }

// LLM polish (NEVER log the API key or full response):
Task { await AppLogger.shared.log(
    "LLM polish requested: provider=\(llmProvider.rawValue), model=\(llmModel)",
    level: .verbose, category: "LLM"
) }
Task { await AppLogger.shared.log(
    "LLM polish complete: \(polishedText?.count ?? 0) chars",
    level: .verbose, category: "LLM"
) }
```

### Step 7: Add DiagnosticsSettingsView and wire into SettingsView

```swift
// Sources/EnviousWispr/Views/Settings/DiagnosticsSettingsView.swift
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Debug Mode") {
                Toggle("Enable debug mode", isOn: $state.isDebugModeEnabled)
                Text("Resets to off on next launch. Toggle with Cmd+Shift+D from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.isDebugModeEnabled {
                    Picker("Log Level", selection: $state.debugLogLevel) {
                        ForEach(DebugLogLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                }
            }

            Section("Log Files") {
                HStack {
                    Button("Open Log Directory") {
                        Task {
                            let url = await AppLogger.shared.logDirectoryURL()
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Button("Copy Log Path") {
                        Task {
                            let url = await AppLogger.shared.logDirectoryURL()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }
                    }

                    Button("Clear Logs") {
                        Task {
                            try? await AppLogger.shared.clearLogs()
                        }
                    }
                    .foregroundStyle(.red)
                }

                Text("Logs are stored at ~/Library/Logs/EnviousWispr/. Maximum 10 MB per file, 5 files retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OSLog") {
                Text("All log events are also sent to the macOS unified logging system. View them in Console.app by filtering for subsystem: com.enviouswispr.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Console.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

```swift
// SettingsView.swift — add tab in TabView:
DiagnosticsSettingsView()
    .tabItem {
        Label("Diagnostics", systemImage: "ladybug")
    }
```

Also increase the settings window height slightly since there is now a fifth tab:

```swift
// SettingsView.swift — update frame:
.frame(width: 520, height: 500)  // was 480
```

## Testing Strategy

1. **Toggle hotkey:** Press Cmd+Shift+D while the main window is focused. Verify `isDebugModeEnabled` flips and the menu bar status text gains " [DEBUG]". Press again — badge disappears.

2. **Global hotkey:** Switch focus to another app (e.g. Terminal), press Cmd+Shift+D. Verify debug mode toggles. Note: requires Accessibility permission for global key monitoring.

3. **Log file creation:** Enable debug mode. Perform a transcription. Check that `~/Library/Logs/EnviousWispr/app.log` was created and contains pipeline entries (sample counts, ASR timing). Confirm no API key or secret text appears.

4. **Log rotation:** Create a test that writes >10MB to `AppLogger.shared` in a tight loop. Verify that `app.log` is renamed to `app.1.log` and a fresh `app.log` starts. After 5 rotations, verify `app.6.log` is deleted.

5. **No file logging when disabled:** Disable debug mode. Perform a transcription. Verify `app.log` is not modified (check `mtime`). OSLog entries should still be emitted (visible in Console.app).

6. **API key non-leakage:** Enable debug mode with log level "Debug". Trigger an LLM polish with a real API key. Open `app.log` and search for the key prefix (e.g. "sk-"). Confirm it does not appear.

7. **Persistence of log level, not mode:** Set log level to "Verbose". Quit and relaunch. Verify log level picker still shows "Verbose". Verify debug mode toggle is off (not persisted across launches).

8. **"Open Log Directory" button:** Click the button in Diagnostics settings. Verify Finder opens to `~/Library/Logs/EnviousWispr/`.

9. **"Clear Logs" button:** Create a log file, click "Clear Logs". Verify all `.log` files in the directory are deleted.

10. **Settings tab visibility:** Open Settings window. Verify the "Diagnostics" tab appears as the fifth tab with the ladybug icon.

## Risks & Considerations

- Must not log API keys or sensitive data even in debug mode — mitigated by caller-side discipline and documented convention; `AppLogger` is passive
- Log files should have rotation/size limits to prevent disk fill — mitigated by 10MB/file, 5 files max policy
- Performance impact of verbose logging should be minimal — mitigated by fire-and-forget `Task` dispatch; no synchronous blocking
- OSLog is the native macOS logging framework — OSLog used as primary backend; file log is supplementary for easy export to developers
- Global Cmd+Shift+D monitor requires Accessibility permission — same permission already required for push-to-talk hotkey; no new entitlement needed
- The debug toggle is not persisted to prevent accidental permanent-debug builds shipped to users
