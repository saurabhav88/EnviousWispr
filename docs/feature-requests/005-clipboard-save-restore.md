# Feature: Clipboard Save/Restore

**ID:** 005
**Category:** Clipboard & Output
**Priority:** High
**Inspired by:** Handy — saves/restores prior clipboard contents around paste
**Status:** Ready for Implementation

## Problem

When EnviousWispr pastes a transcript, it writes to `NSPasteboard.general`, clobbering whatever the user had previously copied. This is frustrating if the user had something important on the clipboard.

## Proposed Solution

Before writing the transcript to the clipboard:
1. Save the current clipboard contents (all types, not just string)
2. Write the transcript
3. Simulate Cmd+V paste
4. After a short delay, restore the original clipboard contents

## Files to Modify

| File | Change |
| ------ | -------- |
| `Sources/EnviousWispr/Services/PasteService.swift` | Add `ClipboardSnapshot` struct, `saveClipboard()`, `restoreClipboard(_:)`, and `pasteWithSaveRestore(_:)` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Replace `PasteService.pasteToActiveApp()` call with `pasteWithSaveRestore()`, add 300ms async delay before restore |
| `Sources/EnviousWispr/App/AppState.swift` | Add `restoreClipboardAfterPaste: Bool` persisted setting, wire to pipeline |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add toggle under "Behavior" section in `GeneralSettingsView` |

## New Files

None. `ClipboardSnapshot` lives in `PasteService.swift` to keep clipboard logic co-located.

## Implementation Plan

### Step 1 — Add `ClipboardSnapshot` to `PasteService.swift`

`ClipboardSnapshot` captures every data representation currently on the pasteboard so all types (plain text, RTF, file URLs, images, etc.) survive the round-trip.

```swift
/// Immutable snapshot of all pasteboard contents at a point in time.
struct ClipboardSnapshot {
    /// Raw data keyed by pasteboard type, preserving every representation.
    let items: [[NSPasteboard.PasteboardType: Data]]
    /// `NSPasteboard.changeCount` at the moment the snapshot was taken.
    /// Used to detect whether a third party modified the clipboard during
    /// the paste window, in which case we skip the restore.
    let changeCount: Int
}
```

### Step 2 — Add `saveClipboard()` to `PasteService`

```swift
/// Capture the current pasteboard contents for later restoration.
static func saveClipboard() -> ClipboardSnapshot {
    let pasteboard = NSPasteboard.general
    var items: [[NSPasteboard.PasteboardType: Data]] = []

    for item in pasteboard.pasteboardItems ?? [] {
        var dict: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) {
                dict[type] = data
            }
        }
        if !dict.isEmpty {
            items.append(dict)
        }
    }

    return ClipboardSnapshot(items: items, changeCount: pasteboard.changeCount)
}
```

### Step 3 — Add `restoreClipboard(_:)` to `PasteService`

The method checks whether the pasteboard `changeCount` matches the value captured immediately after our own write. If a third-party clipboard manager has modified the board in the interim, we skip the restore to avoid undoing the user's intentional copy action.

```swift
/// Restore a previously saved clipboard snapshot.
///
/// - Parameters:
///   - snapshot: The snapshot to restore.
///   - changeCountAfterPaste: The `changeCount` observed immediately after
///     our own paste write. Pass this value so we can detect if a clipboard
///     manager has modified the board before the restore fires.
static func restoreClipboard(_ snapshot: ClipboardSnapshot, changeCountAfterPaste: Int) {
    let pasteboard = NSPasteboard.general

    // If the change count has advanced beyond what we set, a third-party
    // tool wrote to the clipboard — don't clobber their change.
    guard pasteboard.changeCount == changeCountAfterPaste else { return }

    // Nothing to restore (clipboard was already empty).
    guard !snapshot.items.isEmpty else { return }

    pasteboard.clearContents()
    for itemDict in snapshot.items {
        let pbItem = NSPasteboardItem()
        for (type, data) in itemDict {
            pbItem.setData(data, forType: type)
        }
        pasteboard.writeObjects([pbItem])
    }
}
```

### Step 4 — Add `pasteToActiveApp(text:saveRestore:)` to `PasteService`

Rename the existing `pasteToActiveApp(_:)` to add the optional save/restore path. Keep the old signature as a convenience wrapper so callers that don't care about save/restore are unchanged.

```swift
/// Copy text to clipboard, simulate Cmd+V, and optionally restore the prior
/// clipboard contents. Returns the `changeCount` recorded immediately after
/// writing — callers that perform the restore asynchronously need this value.
///
/// - Parameters:
///   - text: The transcript text to paste.
///   - snapshot: If non-nil, the restore will use `changeCountAfterPaste`
///     returned from this call to guard against third-party modifications.
/// - Returns: The pasteboard `changeCount` after our write, needed by
///   `restoreClipboard(_:changeCountAfterPaste:)`.
@discardableResult
static func pasteToActiveApp(_ text: String, snapshot: ClipboardSnapshot? = nil) -> Int {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let changeCountAfterWrite = pasteboard.changeCount

    let source = CGEventSource(stateID: .hidSystemState)

    let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: UInt16(kVK_ANSI_V),
        keyDown: true
    )
    keyDown?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)

    let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: UInt16(kVK_ANSI_V),
        keyDown: false
    )
    keyUp?.flags = .maskCommand
    keyUp?.post(tap: .cghidEventTap)

    return changeCountAfterWrite
}
```

`restoreClipboard` is **not** called here — it is called by `TranscriptionPipeline` after a `Task.sleep` of 300 ms, because `PasteService` methods are synchronous and the async delay must live in the pipeline.

### Step 5 — Update `TranscriptionPipeline.swift`

Add a stored property for the setting and update the delivery block in `stopAndTranscribe()`.

**New property (alongside other `var` pipeline settings):**

```swift
var restoreClipboardAfterPaste: Bool = false
```

**Updated delivery block in `stopAndTranscribe()`:**

```swift
if autoPasteToActiveApp {
    if let app = targetApp, !app.isTerminated {
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
    }

    // Optionally snapshot the clipboard before writing the transcript.
    let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
        ? PasteService.saveClipboard()
        : nil

    let changeCountAfterPaste = PasteService.pasteToActiveApp(transcript.displayText)

    // Restore after a 300 ms delay — long enough for the target app to
    // consume the pasteboard contents but short enough to feel instant.
    if let snapshot {
        try? await Task.sleep(for: .milliseconds(300))
        PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
    }
} else if autoCopyToClipboard {
    PasteService.copyToClipboard(transcript.displayText)
}
```

### Step 6 — Add setting to `AppState.swift`

Following the established pattern for every other persisted setting:

```swift
var restoreClipboardAfterPaste: Bool {
    didSet {
        UserDefaults.standard.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste")
        pipeline.restoreClipboardAfterPaste = restoreClipboardAfterPaste
    }
}
```

In `init()`, load from defaults and wire to the pipeline:

```swift
restoreClipboardAfterPaste = defaults.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? false
// ... after pipeline init:
pipeline.restoreClipboardAfterPaste = restoreClipboardAfterPaste
```

### Step 7 — Add toggle to `GeneralSettingsView`

Add inside the existing `Section("Behavior")` block, beneath the "Auto-copy to clipboard" toggle:

```swift
Toggle("Restore clipboard after paste", isOn: $state.restoreClipboardAfterPaste)
Text("Saves and restores whatever was on your clipboard before pasting the transcript.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

## New Types / Properties

| Symbol | Location | Description |
| ------ | -------- | ----------- |
| `ClipboardSnapshot` | `PasteService.swift` | Struct capturing all pasteboard items and `changeCount` |
| `PasteService.saveClipboard() -> ClipboardSnapshot` | `PasteService.swift` | Reads all types from `NSPasteboard.general` |
| `PasteService.restoreClipboard(_:changeCountAfterPaste:)` | `PasteService.swift` | Writes snapshot back; no-ops if change count mismatch |
| `PasteService.pasteToActiveApp(_:snapshot:) -> Int` | `PasteService.swift` | Existing method extended with optional snapshot param; returns post-write change count |
| `TranscriptionPipeline.restoreClipboardAfterPaste: Bool` | `TranscriptionPipeline.swift` | Controls whether save/restore path is taken |
| `AppState.restoreClipboardAfterPaste: Bool` | `AppState.swift` | Persisted setting, wired to pipeline |

## Testing Strategy

1. **Unit test `ClipboardSnapshot` round-trip**: Write a known string + RTF blob to `NSPasteboard.general`, call `saveClipboard()`, write something else, call `restoreClipboard`, assert original values are back for all types.

2. **Change-count guard test**: After calling `saveClipboard()`, manually increment the change count by writing to the pasteboard externally, then call `restoreClipboard` with the stale `changeCountAfterPaste` — assert the pasteboard was NOT restored.

3. **Smoke test** (`run-smoke-test` skill): Enable the toggle, dictate, verify the transcript appears in the target app, then verify the original clipboard item is restored after ~400 ms.

4. **Empty clipboard edge case**: Call `saveClipboard()` on an empty pasteboard, paste, restore — assert no crash and pasteboard remains in a valid state.

5. **Large clipboard item**: Put a >1 MB image on the clipboard, save, paste, restore — assert no performance regression.

## Risks & Considerations

- `NSPasteboard` can contain multiple types (string, RTF, images, files) — must save/restore all. The implementation copies raw `Data` for every type, which handles this.
- Timing: 300 ms is long enough for most apps to complete a paste but is not guaranteed. If issues arise with slow apps, consider making the delay user-configurable.
- `changeCount` check protects against clipboard managers that watch the pasteboard and write immediately after a change. If a clipboard manager fires within the 300 ms window, we deliberately skip the restore to avoid overwriting the user's intended copy.
- This feature only activates when `autoPasteToActiveApp` is `true` (i.e., the user is using the paste-to-app flow). Pure clipboard copy mode is unaffected.
- Feature 007 (Auto-Submit) must fire **after** the clipboard is restored, not before. The pipeline delivery order must be: paste → restore clipboard → submit keystroke.
