# Feature: Auto-Submit After Paste

**ID:** 007
**Category:** Clipboard & Output
**Priority:** Medium
**Inspired by:** Handy — optional Enter/Ctrl+Enter/Cmd+Enter after paste
**Status:** Ready for Implementation

## Problem

After pasting a transcript, users often need to press Enter to submit (chat apps, search bars, terminal). This extra step breaks the flow of voice-to-action.

## Proposed Solution

Add a configurable auto-submit setting that sends a keystroke after pasting:

- Off (default)
- Enter
- Cmd+Enter (common in Slack, Discord)
- Ctrl+Enter

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Models/AppSettings.swift` | Add `AutoSubmitMode` enum |
| `Sources/EnviousWispr/Services/PasteService.swift` | Add `sendSubmitKeystroke(_:)` static method |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `autoSubmitMode: AutoSubmitMode` property; fire submit keystroke at end of delivery block |
| `Sources/EnviousWispr/App/AppState.swift` | Add `autoSubmitMode: AutoSubmitMode` persisted setting, wire to pipeline |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add picker + orange warning in "Output" section of `GeneralSettingsView` |

## New Files

None.

## Implementation Plan

### Step 1 — Define `AutoSubmitMode` enum in `AppSettings.swift`

```swift
/// Controls which keystroke (if any) is sent after the transcript is delivered.
///
/// Defaults to `.off` for safety — accidentally submitting an incomplete
/// message in a chat or terminal command is a data-loss risk.
enum AutoSubmitMode: String, Codable, CaseIterable, Sendable {
    /// No keystroke sent after delivery.
    case off
    /// Send Return (⏎).
    case enter
    /// Send Cmd+Return (⌘⏎) — common submit shortcut in Slack, Discord, Notion.
    case cmdEnter
    /// Send Ctrl+Return (⌃⏎) — used in some terminal multiplexers and IDEs.
    case ctrlEnter

    var displayName: String {
        switch self {
        case .off:       return "Off"
        case .enter:     return "Enter (⏎)"
        case .cmdEnter:  return "Cmd+Enter (⌘⏎)"
        case .ctrlEnter: return "Ctrl+Enter (⌃⏎)"
        }
    }
}
```

### Step 2 — Add `sendSubmitKeystroke(_:)` to `PasteService`

```swift
/// Send the keystroke associated with an `AutoSubmitMode`.
///
/// No-op when `mode == .off`.
static func sendSubmitKeystroke(_ mode: AutoSubmitMode) {
    guard mode != .off else { return }

    let source = CGEventSource(stateID: .hidSystemState)

    let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: UInt16(kVK_Return),
        keyDown: true
    )
    let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: UInt16(kVK_Return),
        keyDown: false
    )

    switch mode {
    case .off:
        break
    case .enter:
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    case .cmdEnter:
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    case .ctrlEnter:
        keyDown?.flags = .maskControl
        keyUp?.flags   = .maskControl
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

### Step 3 — Add `autoSubmitMode` to `TranscriptionPipeline.swift`

**New property:**

```swift
var autoSubmitMode: AutoSubmitMode = .off
```

**Updated delivery block in `stopAndTranscribe()` — the complete combined flow for all three features:**

The ordering is strictly: save clipboard (005) → deliver text (005/006) → restore clipboard (005) → submit keystroke (007). The submit must fire after restoration so the clipboard is clean before the target app handles Enter (some apps copy the field contents on submit).

```swift
let deliveryText = transcript.displayText

switch outputMode {
case .directTyping:
    if let app = targetApp, !app.isTerminated {
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
    }
    await PasteService.typeText(deliveryText)
    if autoCopyToClipboard {
        PasteService.copyToClipboard(deliveryText)
    }
    // 150 ms post-delivery pause before submit — direct typing ends
    // asynchronously and the target app needs a moment to settle.
    if autoSubmitMode != .off {
        try? await Task.sleep(for: .milliseconds(150))
        PasteService.sendSubmitKeystroke(autoSubmitMode)
    }

case .clipboardPaste:
    if let app = targetApp, !app.isTerminated {
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
    }
    let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
        ? PasteService.saveClipboard()
        : nil
    let changeCountAfterPaste = PasteService.pasteToActiveApp(deliveryText)
    // Restore clipboard BEFORE submit so the board is clean.
    if let snapshot {
        try? await Task.sleep(for: .milliseconds(300))
        PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
    }
    if autoSubmitMode != .off {
        // Additional 150 ms after restore to let the target app process paste.
        try? await Task.sleep(for: .milliseconds(150))
        PasteService.sendSubmitKeystroke(autoSubmitMode)
    }

case .clipboard:
    PasteService.copyToClipboard(deliveryText)
    // Auto-submit is intentionally a no-op in clipboard-only mode:
    // there is no active text field to submit.
}

targetApp = nil
```

**Total timing budget for `.clipboardPaste` + save/restore + auto-submit:**

- 150 ms: app re-activation settle
- Cmd+V event: ~0 ms (synchronous CGEvent)
- 300 ms: clipboard restore delay
- 150 ms: post-restore / pre-submit settle
- Return event: ~0 ms

Total: ~600 ms from paste to submit keystroke. This is fast enough to feel fluid while giving even slow apps (Electron, web-based) time to process paste.

### Step 4 — Add setting to `AppState.swift`

Following the established `didSet` / UserDefaults pattern:

```swift
var autoSubmitMode: AutoSubmitMode {
    didSet {
        UserDefaults.standard.set(autoSubmitMode.rawValue, forKey: "autoSubmitMode")
        pipeline.autoSubmitMode = autoSubmitMode
    }
}
```

In `init()`:

```swift
autoSubmitMode = AutoSubmitMode(rawValue: defaults.string(forKey: "autoSubmitMode") ?? "") ?? .off
// ... after pipeline init:
pipeline.autoSubmitMode = autoSubmitMode
```

### Step 5 — Add picker to `GeneralSettingsView` in `SettingsView.swift`

Add inside the `Section("Output")` block introduced by feature 006, beneath the delivery-mode picker:

```swift
Picker("Auto-submit", selection: $state.autoSubmitMode) {
    ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
        Text(mode.displayName).tag(mode)
    }
}

if appState.autoSubmitMode != .off {
    HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.caption)
        Text("Auto-submit will press \(appState.autoSubmitMode.displayName) after every paste. Make sure you trust the content before enabling this.")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

if appState.autoSubmitMode != .off && appState.outputMode == .clipboard {
    Text("Auto-submit has no effect in clipboard-only mode. Switch to \"Paste to active app\" or \"Direct typing\".")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

The orange warning is always visible when auto-submit is not `.off`, matching the pattern used for the experimental VAD dual-buffer toggle.

## New Types / Properties

| Symbol | Location | Description |
| ------ | -------- | ----------- |
| `AutoSubmitMode` | `AppSettings.swift` | Enum: `.off`, `.enter`, `.cmdEnter`, `.ctrlEnter` |
| `AutoSubmitMode.displayName` | `AppSettings.swift` | Human-readable label with Unicode key glyphs |
| `PasteService.sendSubmitKeystroke(_:)` | `PasteService.swift` | Posts Return key event with appropriate modifier flags |
| `TranscriptionPipeline.autoSubmitMode: AutoSubmitMode` | `TranscriptionPipeline.swift` | Controls whether and which submit keystroke fires |
| `AppState.autoSubmitMode: AutoSubmitMode` | `AppState.swift` | Persisted setting, wired to pipeline |

## Testing Strategy

1. **Off by default**: Fresh install or app upgrade — assert `autoSubmitMode == .off` and no spurious Return keystrokes are ever sent.

2. **Enter mode — chat app**: Enable `.enter`, dictate a phrase into a chat input field (e.g., Messages or a terminal), verify the message is submitted and only one Return is sent.

3. **Cmd+Enter mode**: Enable `.cmdEnter`, dictate into a Slack-style input that submits on Cmd+Enter (not bare Enter). Verify submission. Verify bare Enter was NOT sent.

4. **Ctrl+Enter mode**: Enable `.ctrlEnter`, verify modifier flags on the posted event are exactly `.maskControl` with no `.maskCommand`.

5. **Clipboard-only mode no-op**: Set `outputMode = .clipboard` and `autoSubmitMode = .enter`. Dictate — assert no Return keystroke is sent (confirmed via event tap or by verifying no submission in a text field).

6. **Timing with save/restore (005 + 007)**: Enable both `restoreClipboardAfterPaste` and `autoSubmitMode = .enter`. Dictate into a text field, verify: (a) transcript pasted, (b) original clipboard restored, (c) Enter sent after clipboard restored, (d) field submitted with correct content.

7. **Direct typing + auto-submit (006 + 007)**: Enable `outputMode = .directTyping` and `autoSubmitMode = .enter`. Verify typing completes and Enter fires after the 150 ms post-delivery delay.

8. **Persistence**: Change to `.cmdEnter`, quit and relaunch, verify mode is restored.

## Risks & Considerations

- Dangerous if enabled globally — could accidentally submit incomplete messages, execute terminal commands, or trigger destructive actions in forms. The default is `.off` and the orange UI warning is always shown when active.
- Auto-submit is a no-op in `OutputMode.clipboard` mode: there is no known active text field. The UI warns the user about this combination.
- The 150 ms post-delivery delay before the submit keystroke is not guaranteed to be sufficient for all apps. Electron and browser-based apps that debounce input events may need more time. If issues arise, consider making the delay configurable.
- Push-to-talk flow: `autoSubmitMode` applies regardless of whether recording was started via hotkey or UI button, since both paths converge in `stopAndTranscribe()`. This is the desired behaviour.
- Combined feature ordering (005 + 006 + 007): the delivery sequence is deterministic and tested end-to-end: save clipboard → deliver text → restore clipboard → submit. The submit keystroke is always the final step.
