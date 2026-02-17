import AppKit
import Carbon.HIToolbox

/// Handles copying text to clipboard and pasting into the active app.
enum PasteService {
    /// Copy text to the system clipboard.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copy text to clipboard and simulate Cmd+V to paste into the frontmost app.
    ///
    /// Requires Accessibility permission.
    static func pasteToActiveApp(_ text: String) {
        copyToClipboard(text)

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
    }
}
