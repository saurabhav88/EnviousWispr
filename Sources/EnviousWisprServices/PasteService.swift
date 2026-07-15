import AppKit
import ApplicationServices
import Carbon.HIToolbox
import EnviousWisprCore

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
public enum PasteTier: String, Sendable {
  case axDirect = "ax_direct"
  case cgEvent = "cgevent"
  case appleScript = "applescript"
  /// Language-agnostic Edit > Paste menu command driven via Accessibility
  /// (#729). Used for non-text container roles (Word/Excel/Numbers/OneNote)
  /// where Cmd+V can't be aimed at a writable element.
  case menuPaste = "menu_paste"
  case clipboardOnly = "clipboard_only"
}

public struct PasteElementDiagnostics: Equatable, Sendable {
  private static let maxAttributeLength = 128
  private static let allowedAttributeCharacters = CharacterSet.alphanumerics.union(
    CharacterSet(charactersIn: "._:-"))

  public let role: String?
  public let subrole: String?
  public let roleSource: String
  public let subroleStatus: String

  public init(role: String?, subrole: String?, roleSource: String, subroleStatus: String) {
    self.role = Self.sanitizedAXAttribute(role)
    self.subrole = Self.sanitizedAXAttribute(subrole)
    self.roleSource = roleSource
    self.subroleStatus = subroleStatus
  }

  public static let missing = PasteElementDiagnostics(
    role: nil, subrole: nil, roleSource: "missing", subroleStatus: "missing")
  public static let unavailable = PasteElementDiagnostics(
    role: nil, subrole: nil, roleSource: "unavailable", subroleStatus: "unavailable")

  public static func sanitizedAXAttribute(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let sanitizedScalars = trimmed.unicodeScalars.map { scalar in
      Self.allowedAttributeCharacters.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(sanitizedScalars).prefix(Self.maxAttributeLength)
    return sanitized.isEmpty ? nil : String(sanitized)
  }
}

/// Handles copying text to clipboard and pasting into the active app.
public enum PasteService {

  /// AX roles that accept text insertion.
  static let textRoles: Set<String> = [
    kAXTextFieldRole as String,
    kAXTextAreaRole as String,
    kAXComboBoxRole as String,
    "AXSearchField",
  ]

  /// Check if an AX element has a text input role (AXTextField, AXTextArea, etc.).
  public static func isTextFieldRole(_ element: AXUIElement) -> Bool {
    var roleRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(
      element, kAXRoleAttribute as CFString, &roleRef
    )
    guard err == .success, let role = roleRef as? String else { return false }
    return textRoles.contains(role)
  }

  /// Reads privacy-safe role metadata from the captured AX element handle.
  /// This is queried at paste time, not snapshotted at recording start.
  public static func capturedElementDiagnostics(_ element: AXUIElement?) -> PasteElementDiagnostics
  {
    guard let element else { return .missing }

    var roleRef: CFTypeRef?
    let roleErr = AXUIElementCopyAttributeValue(
      element, kAXRoleAttribute as CFString, &roleRef
    )
    guard
      roleErr == .success,
      let role = PasteElementDiagnostics.sanitizedAXAttribute(roleRef as? String)
    else {
      return .unavailable
    }

    var subroleRef: CFTypeRef?
    let subroleErr = AXUIElementCopyAttributeValue(
      element, kAXSubroleAttribute as CFString, &subroleRef
    )
    let subrole =
      subroleErr == .success
      ? PasteElementDiagnostics.sanitizedAXAttribute(subroleRef as? String)
      : nil
    let subroleStatus: String =
      subroleErr == .success
      ? (subrole == nil ? "missing" : "present")
      : "unavailable"

    return PasteElementDiagnostics(
      role: role,
      subrole: subrole,
      roleSource: "captured_target",
      subroleStatus: subroleStatus
    )
  }

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
      Task {
        await AppLogger.shared.log(
          "Clipboard restore skipped: changeCount advanced (expected \(changeCountAfterPaste), got \(pasteboard.changeCount))",
          level: .verbose, category: "PasteService"
        )
      }
      return
    }

    // Prior clipboard was empty — restore to empty by clearing our own paste
    // text off the board, rather than leaving it behind (#729 Codex diff review).
    guard !snapshot.items.isEmpty else {
      pasteboard.clearContents()
      return
    }

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

  /// Append a trailing space to text so consecutive dictations are naturally separated.
  /// Same approach as WisprFlow — simpler and more reliable than reading cursor context via AX.
  public static func appendTrailingSpace(_ text: String) -> String {
    text.hasSuffix(" ") ? text : text + " "
  }

  // MARK: - Tier 1: AX Direct Insertion

  /// Capture the system-wide focused UI element (the specific text field, not just the app).
  /// Sets a 1-second AX timeout on the element to avoid hanging on misbehaving apps.
  /// Returns nil if no element is focused or accessibility is not trusted.
  public static func captureFocusedElement() -> AXUIElement? {
    guard AXIsProcessTrusted() else {
      Task {
        await AppLogger.shared.log(
          "AXDiag capture: not trusted",
          level: .info, category: "AXDiag"
        )
      }
      return nil
    }
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(
      systemWide,
      kAXFocusedUIElementAttribute as CFString,
      &focusedRef
    )
    guard err == .success, let ref = focusedRef else {
      Task {
        await AppLogger.shared.log(
          "AXDiag capture: systemWide focus FAILED err=\(err.rawValue)",
          level: .info, category: "AXDiag"
        )
      }
      return nil
    }
    let element = ref as! AXUIElement
    AXUIElementSetAttributeValue(
      element,
      "AXTimeout" as CFString,
      Float(1.0) as CFTypeRef
    )
    logElementDiagnostics(element)
    return element
  }

  /// Log role, subrole, and key settability signals for the focused element.
  /// One line per paste; used to diagnose cascade fall-throughs in the wild
  /// (e.g., the Chromium lazy-AX case uncovered in #277).
  ///
  /// Runs off the caller's thread so the extra AX round-trips don't add
  /// latency to the PTT-to-recording start path.
  private static func logElementDiagnostics(_ element: AXUIElement) {
    nonisolated(unsafe) let axElement = element
    let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<nil>"
    Task.detached {
      var roleRef: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
      let role = (roleRef as? String) ?? "<nil>"

      var subroleRef: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleRef)
      let subrole = (subroleRef as? String) ?? "<nil>"

      func settable(_ attr: String) -> Bool {
        var s: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(axElement, attr as CFString, &s)
        return err == .success && s.boolValue
      }

      let msg =
        "AXDiag capture: app=\(bundleId) role=\(role) subrole=\(subrole) "
        + "valueSettable=\(settable("AXValue")) " + "selTextSettable=\(settable("AXSelectedText")) "
        + "selRangeSettable=\(settable("AXSelectedTextRange"))"
      await AppLogger.shared.log(msg, level: .info, category: "AXDiag")
    }
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

  /// Outcome of a Tier-2 CGEvent paste attempt. `dispatched` means the Cmd+V
  /// keystroke was successfully posted; `cgEventCreationFailed` means CGEvent
  /// construction failed (typically an Accessibility trust / permission issue).
  /// Both cases carry the pasteboard change count needed by `restoreClipboard`.
  public enum PasteDispatchResult: Sendable {
    case dispatched(changeCount: Int)
    case cgEventCreationFailed(accessibilityTrusted: Bool, changeCount: Int)

    public var changeCount: Int {
      switch self {
      case .dispatched(let c): return c
      case .cgEventCreationFailed(_, let c): return c
      }
    }
  }

  /// Copy text to clipboard and simulate Cmd+V to paste into the frontmost app.
  /// - Returns: `PasteDispatchResult` telling the caller whether the keystroke
  ///   was posted and exposing the pasteboard change count for clipboard restore.
  @discardableResult
  public static func pasteToActiveApp(_ text: String) -> PasteDispatchResult {
    let pasteStart = CFAbsoluteTimeGetCurrent()
    let accessibilityTrusted = AXIsProcessTrusted()

    let pasteboard = NSPasteboard.general
    let previousChangeCount = pasteboard.changeCount
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let changeCountAfterWrite = pasteboard.changeCount
    let clipboardWriteSuccess = pasteboard.changeCount != previousChangeCount

    guard dispatchCmdV() else {
      Task {
        await AppLogger.shared.log(
          "Paste attempt: accessibility=\(accessibilityTrusted), cgEventAttempted=false, clipboardWrite=\(clipboardWriteSuccess) — Failed to create CGEvent",
          level: .info, category: "PasteService"
        )
      }
      return .cgEventCreationFailed(
        accessibilityTrusted: accessibilityTrusted,
        changeCount: changeCountAfterWrite
      )
    }

    let pasteEnd = CFAbsoluteTimeGetCurrent()
    Task {
      await AppLogger.shared.log(
        "Paste attempt: accessibility=\(accessibilityTrusted), cgEventAttempted=true, "
          + "clipboardWrite=\(clipboardWriteSuccess), elapsed=\(String(format: "%.3f", pasteEnd - pasteStart))s",
        level: .info, category: "PasteService"
      )
    }

    return .dispatched(changeCount: changeCountAfterWrite)
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

  // MARK: - Tier 2c: Language-agnostic Edit > Paste via Accessibility menu (#729)

  /// True when an AX menu item's command-key equivalent is exactly ⌘V (no
  /// extra modifiers). Pure, language-agnostic predicate: it matches the
  /// keyboard shortcut, never the localized menu title.
  ///
  /// - `cmdChar` is `AXMenuItemCmdChar` (the shortcut character; "v" / "V").
  /// - `modifiers` is `AXMenuItemCmdModifiers`, where `0` ==
  ///   `kAXMenuItemModifierNone` (Command only). `1<<3` ==
  ///   `kAXMenuItemModifierNoCommand` denotes the ABSENCE of ⌘ and must not
  ///   match; Shift/Option/Control bits (`1<<0`/`1<<1`/`1<<2`) also exclude.
  ///   So a plain ⌘V item has `modifiers == 0`.
  public static func isPasteShortcut(cmdChar: String?, modifiers: Int) -> Bool {
    guard let cmdChar else { return false }
    return cmdChar.lowercased() == "v" && modifiers == 0
  }

  /// Outcome of walking an app's menu bar for the ⌘V-shortcut Paste item.
  /// Distinguishes "read fine, no matching item" from "couldn't read the menu
  /// bar at all" — collapsing both into one `nil` hid a real AX failure behind
  /// the same telemetry label as a genuine no-target refusal (#1435).
  public enum MenuItemProbeResult {
    case found(AXUIElement)
    case confirmedAbsent
    case unreadable
  }

  /// Outcome of reading an AX menu item's enabled state.
  public enum MenuItemEnabledResult {
    case enabled
    case disabled
    case unreadable
  }

  /// Walk the app's menu bar to find the Edit > Paste item, identified by its
  /// ⌘V shortcut rather than its (localized) title. Bounded traversal depth
  /// (menu bar → top menus → items). Live-only (like `captureFocusedElement` /
  /// `forceActivateApp`); the pure matching logic is covered by
  /// `isPasteShortcut` unit tests.
  @MainActor
  public static func findPasteMenuItem(pid: pid_t) -> MenuItemProbeResult {
    let app = AXUIElementCreateApplication(pid)
    // Cap AX round-trips so a misbehaving app can't hang the paste path.
    AXUIElementSetAttributeValue(app, "AXTimeout" as CFString, Float(1.0) as CFTypeRef)
    var menuBarRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
      let menuBar = menuBarRef
    else { return .unreadable }
    return firstPasteItem(in: menuBar as! AXUIElement, depth: 0)
  }

  /// Depth-bounded search for the first ⌘V menu item under `element`.
  /// Propagates `.unreadable` from any AX read that fails for a reason OTHER
  /// than "this attribute genuinely doesn't apply here"
  /// (`.attributeUnsupported`/`.noValue`, the normal shape for a leaf item
  /// with no children or no shortcut) — a deeper traversal failure is the same
  /// bug this type exists to fix, one level down (#1435 grounded review r1).
  @MainActor
  private static func firstPasteItem(in element: AXUIElement, depth: Int) -> MenuItemProbeResult {
    // menu bar(0) → menu-bar-item(1) → menu(2) → menu-item(3); allow a little
    // slack for apps that nest an extra group, but stay bounded.
    guard depth <= 4 else { return .confirmedAbsent }

    var childrenRef: CFTypeRef?
    let childrenRead = AXUIElementCopyAttributeValue(
      element, kAXChildrenAttribute as CFString, &childrenRef)
    if childrenRead == .attributeUnsupported || childrenRead == .noValue {
      // At depth 0, `element` IS the menu bar itself -- a working app's menu
      // bar always exposes its top-level menus, so a read failure here means
      // we couldn't traverse it at all, not that we confirmed no target
      // (cloud Codex review, PR #1559). Deeper levels stay .confirmedAbsent:
      // a terminal menu item genuinely having no submenu is the normal case.
      return depth == 0 ? .unreadable : .confirmedAbsent
    }
    guard childrenRead == .success, let children = childrenRef as? [AXUIElement] else {
      return .unreadable
    }

    var encounteredUnreadableBranch = false
    for child in children {
      var cmdCharRef: CFTypeRef?
      let commandRead = AXUIElementCopyAttributeValue(
        child, "AXMenuItemCmdChar" as CFString, &cmdCharRef)
      switch commandRead {
      case .success:
        guard let command = cmdCharRef as? String else {
          encounteredUnreadableBranch = true
          break
        }
        if command.lowercased() == "v" {
          var modifiersRef: CFTypeRef?
          let modifiersRead = AXUIElementCopyAttributeValue(
            child, "AXMenuItemCmdModifiers" as CFString, &modifiersRef)
          guard modifiersRead == .success, let modifiers = modifiersRef as? Int else {
            encounteredUnreadableBranch = true
            break
          }
          if isPasteShortcut(cmdChar: command, modifiers: modifiers) {
            return .found(child)
          }
        }
      case .attributeUnsupported, .noValue:
        break
      default:
        encounteredUnreadableBranch = true
      }

      switch firstPasteItem(in: child, depth: depth + 1) {
      case .found(let item): return .found(item)
      case .confirmedAbsent: break
      case .unreadable: encounteredUnreadableBranch = true
      }
    }
    return encounteredUnreadableBranch ? .unreadable : .confirmedAbsent
  }

  /// Whether an AX menu item is currently enabled. Apps disable Edit > Paste
  /// when there is no paste target focused or the clipboard is empty — this is
  /// the Scenario-A-vs-B discriminator, so it MUST be read AFTER our text is on
  /// the clipboard. Distinguishes a genuinely-disabled item from an AX read
  /// that failed or returned a non-Bool value (#1435).
  @MainActor
  public static func isMenuItemEnabled(_ item: AXUIElement) -> MenuItemEnabledResult {
    var ref: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &ref) == .success,
      let enabled = ref as? Bool
    else { return .unreadable }
    return enabled ? .enabled : .disabled
  }

  /// Trigger a menu item's default action (AXPress) — equivalent to the user
  /// clicking it. Returns true on success.
  @MainActor
  public static func pressMenuItem(_ item: AXUIElement) -> Bool {
    AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
  }

  // MARK: - App Activation via Accessibility

  /// Force-activate an app by PID using the Accessibility API.
  /// Bypasses macOS 14+ restrictions on background processes stealing focus.
  /// Requires Accessibility permission (AXIsProcessTrusted).
  public static func forceActivateApp(pid: pid_t) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let axApp = AXUIElementCreateApplication(pid)
    let result = AXUIElementSetAttributeValue(
      axApp,
      "AXFrontmost" as CFString,
      true as CFTypeRef
    )
    return result == .success
  }

  // MARK: - Private

  /// Send Cmd+V keystroke via CGEvent. Returns true on success.
  @discardableResult
  private static func dispatchCmdV() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let keyDown = CGEvent(
        keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
      let keyUp = CGEvent(
        keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
    else { return false }
    keyDown.flags = .maskCommand
    keyDown.post(tap: .cgAnnotatedSessionEventTap)
    keyUp.flags = .maskCommand
    keyUp.post(tap: .cgAnnotatedSessionEventTap)
    return true
  }
}
