import AppKit
import EnviousWisprCore
import ApplicationServices
import Carbon.HIToolbox

/// Immutable snapshot of all pasteboard contents at a point in time.
public struct ClipboardSnapshot: Sendable {
    /// Raw data keyed by pasteboard type, preserving every representation.
    public let items: [[NSPasteboard.PasteboardType: Data]]
    /// `NSPasteboard.changeCount` at the moment the snapshot was taken.
    public let changeCount: Int

    public init(items: [[NSPasteboard.PasteboardType: Data]], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }
}

/// Which paste tier succeeded — logged for compatibility analytics.
public enum PasteTier: String {
    case axDirect = "ax_direct"
    case cgEvent = "cgevent"
    case appleScript = "applescript"
    case clipboardOnly = "clipboard_only"
}

/// Handles copying text to clipboard and pasting into the active app.
public enum PasteService {

    /// AX roles that accept text insertion.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    /// Copy text to the system clipboard.
    public static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copy text to clipboard and return the resulting change count.
    public static func copyToClipboardReturningChangeCount(_ text: String) -> Int {
        copyToClipboard(text)
        return NSPasteboard.general.changeCount
    }

    /// Capture the current pasteboard contents for later restoration.
    public static func saveClipboard() -> ClipboardSnapshot {
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
    public static func restoreClipboard(_ snapshot: ClipboardSnapshot, changeCountAfterPaste: Int) {
        let pasteboard = NSPasteboard.general

        // If the change count has advanced beyond what we set, a third-party
        // tool wrote to the clipboard — don't clobber their change.
        guard pasteboard.changeCount == changeCountAfterPaste else {
            Task { await AppLogger.shared.log(
                "Clipboard restore skipped: changeCount advanced (expected \(changeCountAfterPaste), got \(pasteboard.changeCount))",
                level: .verbose, category: "PasteService"
            ) }
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

    // MARK: - Tier 1: AX Direct Insertion

    /// Capture the system-wide focused UI element (the specific text field, not just the app).
    /// Sets a 1-second AX timeout on the element to avoid hanging on misbehaving apps.
    /// Returns nil if no element is focused or accessibility is not trusted.
    public static func captureFocusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let ref = focusedRef else { return nil }
        // AXUIElement is a CFTypeRef — cast is always valid after the success guard above.
        let element = ref as! AXUIElement
        // Set timeout once at capture — persists for the element's lifetime.
        AXUIElementSetAttributeValue(
            element,
            "AXTimeout" as CFString,
            Float(1.0) as CFTypeRef
        )
        return element
    }

    /// Insert text directly into an AX element at the cursor position.
    /// Uses kAXSelectedTextAttribute which inserts at cursor / replaces selection.
    /// Returns true only if the text verifiably appeared in the element.
    public static func insertViaAccessibility(_ text: String, element: AXUIElement) -> Bool {
        // Verify the element is a text field or text area.
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRef
        )
        guard roleErr == .success, let role = roleRef as? String else {
            return false
        }
        guard textRoles.contains(role) else { return false }

        // Verify the element is writable (not read-only).
        var settableRef: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settableRef
        )
        guard settableErr == .success, settableRef.boolValue else { return false }

        // Snapshot character count before insertion for verification.
        var charCountBefore: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &charCountBefore
        )
        let countBefore = (charCountBefore as? Int) ?? -1

        // Insert at cursor via kAXSelectedTextAttribute.
        let err = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard err == .success else { return false }

        // Verify text actually appeared (Electron apps report success but don't render).
        // If we can't read character counts, treat as unverified and fall through to Tier 2.
        var charCountAfter: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &charCountAfter
        )
        let countAfter = (charCountAfter as? Int) ?? -1

        if countBefore < 0 || countAfter < 0 {
            return false  // Can't verify — let Tier 2 handle it
        }
        return countAfter > countBefore
    }

    // MARK: - Tier 2: CGEvent Cmd+V

    /// Copy text to clipboard and simulate Cmd+V to paste into the frontmost app.
    /// - Returns: The pasteboard `changeCount` after our write, needed by `restoreClipboard`.
    @discardableResult
    public static func pasteToActiveApp(_ text: String) -> Int {
        let pasteStart = CFAbsoluteTimeGetCurrent()
        let accessibilityTrusted = AXIsProcessTrusted()

        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount
        let clipboardWriteSuccess = pasteboard.changeCount != previousChangeCount

        guard dispatchCmdV() else {
            Task { await AppLogger.shared.log(
                "Paste attempt: accessibility=\(accessibilityTrusted), cgEventAttempted=false, clipboardWrite=\(clipboardWriteSuccess) — Failed to create CGEvent",
                level: .info, category: "PasteService"
            ) }
            return changeCountAfterWrite
        }

        let pasteEnd = CFAbsoluteTimeGetCurrent()
        Task { await AppLogger.shared.log(
            "Paste attempt: accessibility=\(accessibilityTrusted), cgEventAttempted=true, " +
            "clipboardWrite=\(clipboardWriteSuccess), elapsed=\(String(format: "%.3f", pasteEnd - pasteStart))s",
            level: .info, category: "PasteService"
        ) }

        return changeCountAfterWrite
    }

    // MARK: - Tier 2b: AppleScript Edit > Paste

    /// Paste via AppleScript by clicking the Edit > Paste menu item via process ID.
    /// Requires the target app to be frontmost. Returns true on success.
    public static func pasteViaAppleScript(pid: pid_t) -> Bool {
        let script = """
        tell application "System Events"
            tell (first process whose unix id is \(pid))
                click menu item "Paste" of menu "Edit" of menu bar 1
            end tell
        end tell
        """
        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&error)
        return error == nil
    }

    /// Simulate Cmd+V keystroke to paste from clipboard into the active app.
    public static func simulatePaste() {
        dispatchCmdV()
    }

    // MARK: - Private

    /// Send Cmd+V keystroke via CGEvent. Returns true on success.
    @discardableResult
    private static func dispatchCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
