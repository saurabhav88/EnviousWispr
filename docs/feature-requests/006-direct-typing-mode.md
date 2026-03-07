# Feature: Direct Typing Mode

**ID:** 006
**Category:** Clipboard & Output
**Priority:** Medium
**Inspired by:** Handy — `enigo.text()` bypasses clipboard entirely
**Status:** Ready for Implementation

## Problem

The current paste mechanism always uses the clipboard (write to NSPasteboard → simulate Cmd+V). This clobbers the clipboard (partially addressed by feature 005) and may not work in all contexts (e.g., secure input fields that block paste).

## Proposed Solution

Add a "Direct Typing" output mode that simulates individual keystrokes via `CGEvent` to type the transcript character-by-character into the active text field, bypassing the clipboard entirely.

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Models/AppSettings.swift` | Add `OutputMode` enum |
| `Sources/EnviousWispr/Services/PasteService.swift` | Add `typeText(_:)` async method using `CGEvent` + `keyboardSetUnicodeString` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `outputMode: OutputMode` property; branch delivery on mode |
| `Sources/EnviousWispr/App/AppState.swift` | Add `outputMode: OutputMode` persisted setting, wire to pipeline |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add `OutputMode` picker in "Behavior" section of `GeneralSettingsView` |

## New Files

None.

## Implementation Plan

### Step 1 — Define `OutputMode` enum in `AppSettings.swift`

`OutputMode` replaces the implicit combination of `autoCopyToClipboard` and `autoPasteToActiveApp` flags with a single, explicit three-way choice. The existing flags are kept for backward compatibility and are derived from `outputMode` at the pipeline level.

```swift
/// Controls how the finished transcript is delivered to the user.
enum OutputMode: String, Codable, CaseIterable, Sendable {
    /// Write the transcript to the system clipboard only (current default).
    case clipboard
    /// Simulate Cmd+V paste into the frontmost app (uses clipboard transiently).
    /// Feature 005 can save/restore the prior clipboard contents around this.
    case clipboardPaste
    /// Type the transcript character-by-character via CGEvent, bypassing the
    /// clipboard entirely. Slower for long texts; works in secure input fields.
    case directTyping
}
```

`OutputMode` is separate from `autoCopyToClipboard`. A user can have `outputMode = .directTyping` and still want `autoCopyToClipboard = true` so the text also lands on the clipboard. The pipeline honours both independently.

### Step 2 — Add `typeText(_:)` to `PasteService`

`CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `virtualKey: 0` combined with `CGEvent.keyboardSetUnicodeString` is the canonical layout-independent way to inject Unicode characters on macOS. Each character is posted as a key-down + key-up pair. The method is `async` so the pipeline can `await` it and `Task.sleep` between characters without blocking.

```swift
/// Type a string character-by-character using CGEvent Unicode injection.
///
/// This bypasses the clipboard entirely. Each Unicode scalar is delivered
/// as a synthetic key-down/key-up event with `keyboardSetUnicodeString`.
///
/// - Parameters:
///   - text: The text to type.
///   - delay: Inter-character delay in milliseconds. Defaults to 5 ms —
///     fast enough to feel instant, slow enough for most apps to keep up.
static func typeText(_ text: String, interCharacterDelayMs: Int = 5) async {
    let source = CGEventSource(stateID: .hidSystemState)

    for scalar in text.unicodeScalars {
        var uchar = UniChar(scalar.value & 0xFFFF)

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: 0,
                                    keyDown: true) else { continue }
        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uchar)
        keyDown.post(tap: .cghidEventTap)

        guard let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: 0,
                                  keyDown: false) else { continue }
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uchar)
        keyUp.post(tap: .cghidEventTap)

        if interCharacterDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(interCharacterDelayMs))
        }
    }
}
```

**Unicode scalar truncation note:** `UniChar` is a 16-bit type. Characters above U+FFFF (emoji, supplementary planes) need a surrogate pair. Extend the loop to emit two `UniChar` values for scalars above U+FFFF:

```swift
for scalar in text.unicodeScalars {
    var uchars: [UniChar]
    if scalar.value <= 0xFFFF {
        uchars = [UniChar(scalar.value)]
    } else {
        // Encode as UTF-16 surrogate pair
        let value = scalar.value - 0x10000
        uchars = [
            UniChar(0xD800 + (value >> 10)),
            UniChar(0xDC00 + (value & 0x3FF))
        ]
    }

    guard let keyDown = CGEvent(keyboardEventSource: source,
                                virtualKey: 0,
                                keyDown: true) else { continue }
    keyDown.keyboardSetUnicodeString(stringLength: uchars.count, unicodeString: &uchars)
    keyDown.post(tap: .cghidEventTap)

    guard let keyUp = CGEvent(keyboardEventSource: source,
                              virtualKey: 0,
                              keyDown: false) else { continue }
    keyUp.keyboardSetUnicodeString(stringLength: uchars.count, unicodeString: &uchars)
    keyUp.post(tap: .cghidEventTap)

    if interCharacterDelayMs > 0 {
        try? await Task.sleep(for: .milliseconds(interCharacterDelayMs))
    }
}
```

### Step 3 — Add `outputMode` property to `TranscriptionPipeline.swift`

```swift
var outputMode: OutputMode = .clipboard
```

Update the delivery block in `stopAndTranscribe()` to branch on `outputMode`. The existing `autoPasteToActiveApp` flag is now driven by whether the mode is `.clipboardPaste`, maintaining backward compatibility with the `AppState` hotkey callbacks that still set `autoPasteToActiveApp` directly.

```swift
// Auto-copy/paste delivery
let deliveryText = transcript.displayText

switch outputMode {
case .directTyping:
    // Re-activate the target app before typing.
    if let app = targetApp, !app.isTerminated {
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
    }
    await PasteService.typeText(deliveryText)
    // Optionally also copy to clipboard so the text is retrievable.
    if autoCopyToClipboard {
        PasteService.copyToClipboard(deliveryText)
    }

case .clipboardPaste:
    if let app = targetApp, !app.isTerminated {
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
    }
    // Feature 005 save/restore path.
    let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
        ? PasteService.saveClipboard()
        : nil
    let changeCountAfterPaste = PasteService.pasteToActiveApp(deliveryText)
    if let snapshot {
        try? await Task.sleep(for: .milliseconds(300))
        PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
    }

case .clipboard:
    PasteService.copyToClipboard(deliveryText)
}

targetApp = nil
```

The `autoPasteToActiveApp` property is retained on the pipeline for the push-to-talk hotkey path in `AppState` (which sets it to `true` directly). When `autoPasteToActiveApp` is `true` and `outputMode` is `.clipboard`, the pipeline upgrades to `.clipboardPaste` behaviour automatically so existing hotkey wiring keeps working without changes to `AppState`.

### Step 4 — Add setting to `AppState.swift`

```swift
var outputMode: OutputMode {
    didSet {
        UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode")
        pipeline.outputMode = outputMode
    }
}
```

In `init()`:

```swift
outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .clipboard
// ... after pipeline init:
pipeline.outputMode = outputMode
```

### Step 5 — Add picker to `GeneralSettingsView` in `SettingsView.swift`

Replace the existing `Toggle("Auto-copy to clipboard", ...)` in `Section("Behavior")` with a broader output-mode control:

```swift
Section("Output") {
    Picker("Delivery mode", selection: $state.outputMode) {
        Text("Copy to clipboard").tag(OutputMode.clipboard)
        Text("Paste to active app").tag(OutputMode.clipboardPaste)
        Text("Direct typing (bypass clipboard)").tag(OutputMode.directTyping)
    }

    switch appState.outputMode {
    case .clipboard:
        Text("The transcript is written to your clipboard after each recording.")
            .font(.caption)
            .foregroundStyle(.secondary)
    case .clipboardPaste:
        Text("The transcript is pasted directly into whichever app was active when you started recording.")
            .font(.caption)
            .foregroundStyle(.secondary)
    case .directTyping:
        Text("The transcript is typed character-by-character into the active app. Slower for long texts but never touches your clipboard.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    if appState.outputMode == .directTyping {
        Text("Direct typing requires Accessibility permission and may be slow for long transcripts.")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
```

The old `Toggle("Auto-copy to clipboard", ...)` is removed since `OutputMode.clipboard` covers that intent. The "Restore clipboard after paste" toggle from feature 005 remains and should be indented under `.clipboardPaste` mode — it is hidden when `outputMode == .directTyping` because the clipboard is never written.

## New Types / Properties

| Symbol | Location | Description |
| ------ | -------- | ----------- |
| `OutputMode` | `AppSettings.swift` | Enum: `.clipboard`, `.clipboardPaste`, `.directTyping` |
| `PasteService.typeText(_:interCharacterDelayMs:)` | `PasteService.swift` | Async; types Unicode via `CGEvent` + `keyboardSetUnicodeString` |
| `TranscriptionPipeline.outputMode: OutputMode` | `TranscriptionPipeline.swift` | Controls delivery branch in `stopAndTranscribe()` |
| `AppState.outputMode: OutputMode` | `AppState.swift` | Persisted setting, wired to pipeline |

## Testing Strategy

1. **Basic ASCII typing**: Set `outputMode = .directTyping`, dictate a short English phrase, verify it appears verbatim in a text field (e.g., TextEdit) without touching the clipboard.

2. **Unicode / emoji typing**: Dictate text containing accented characters and emoji. Verify all characters are received correctly, including those above U+FFFF (surrogate-pair path).

3. **Clipboard isolation**: Set `outputMode = .directTyping` and `autoCopyToClipboard = false`. Place a known value on the clipboard before dictating. After typing completes, assert the clipboard value is unchanged.

4. **Long text performance**: Feed a 500-word transcript through `typeText`. Measure elapsed time; assert it completes within a reasonable bound (e.g., < 10 s at 5 ms/char for 500 chars).

5. **Mode persistence**: Change `outputMode` to `.directTyping`, quit and relaunch the app, verify the mode is restored.

6. **Accessibility permission required**: Attempt `typeText` without Accessibility permission and verify a graceful error rather than a crash (events are silently dropped by the OS; the pipeline should surface an appropriate state).

7. **Smoke test** (`run-smoke-test` skill): Switch to each of the three modes in turn and confirm the transcript lands in the correct place.

## Risks & Considerations

- Much slower than clipboard paste for long texts. The default 5 ms inter-character delay yields ~200 chars/s — a 500-word transcript (~3000 chars) takes ~15 seconds. Consider warning users in the UI for transcripts above a threshold, or allowing the delay to be reduced.
- Unicode/emoji support above U+FFFF requires surrogate-pair encoding. The implementation handles this explicitly.
- Some apps (Terminal, password fields with secure input) may ignore or reorder synthetic keystrokes. This mode cannot work in apps that have secure input enabled — the clipboard paste path is still preferable in those cases.
- Accessibility permission is still required for `CGEvent` posting via `.cghidEventTap`.
- `outputMode` should default to `.clipboard` to preserve current behaviour for existing users on upgrade. Push-to-talk hotkey callbacks in `AppState` continue to set `autoPasteToActiveApp = true` which overrides to `.clipboardPaste` behaviour, so no regression.
