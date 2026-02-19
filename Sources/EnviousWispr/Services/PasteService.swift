import AppKit
import Carbon.HIToolbox

/// Immutable snapshot of all pasteboard contents at a point in time.
struct ClipboardSnapshot: Sendable {
    /// Raw data keyed by pasteboard type, preserving every representation.
    let items: [[NSPasteboard.PasteboardType: Data]]
    /// `NSPasteboard.changeCount` at the moment the snapshot was taken.
    let changeCount: Int
}

/// Handles copying text to clipboard and pasting into the active app.
enum PasteService {
    /// Copy text to the system clipboard.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

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
        guard pasteboard.changeCount == changeCountAfterPaste else {
            print("[PasteService] Clipboard restore skipped: changeCount advanced (expected \(changeCountAfterPaste), got \(pasteboard.changeCount))")
            return
        }

        // Nothing to restore (clipboard was already empty).
        guard !snapshot.items.isEmpty else { return }

        pasteboard.clearContents()
        let pbItems: [NSPasteboardItem] = snapshot.items.map { itemDict in
            let pbItem = NSPasteboardItem()
            for (type, data) in itemDict {
                pbItem.setData(data, forType: type)
            }
            return pbItem
        }
        pasteboard.writeObjects(pbItems)
    }

    /// Copy text to clipboard and simulate Cmd+V to paste into the frontmost app.
    ///
    /// Requires Accessibility permission.
    /// - Returns: The pasteboard `changeCount` after our write, needed by `restoreClipboard`.
    @discardableResult
    static func pasteToActiveApp(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("[PasteService] Failed to create CGEventSource — check Accessibility permissions")
            return changeCountAfterWrite
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            print("[PasteService] Failed to create CGEvent for Cmd+V")
            return changeCountAfterWrite
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)

        return changeCountAfterWrite
    }
}
