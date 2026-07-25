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

  /// Outcome of a Tier 1 Accessibility insertion attempt.
  ///
  /// Three states, not two, because "we could not prove it worked" and "it
  /// definitely did not happen" demand opposite responses. Retrying an
  /// unproven write is what double-pastes.
  public enum AXInsertOutcome: Equatable, Sendable {
    /// The requested mutation is positively verified. Stop the cascade.
    case verified
    /// No mutation landed: the write was refused, failed, or provably left the
    /// field untouched. Continuing to Tier 2 is safe.
    case noMutation
    /// The write reported success but the result cannot be proven. The mutation
    /// MAY already be in the document, so the cascade must NOT paste again.
    case unverifiable
  }

  /// Everything read around a Tier 1 write, so the decision itself stays pure
  /// and testable. The live AX round-trips happen in `insertViaAccessibility`;
  /// this struct is what they produce.
  internal struct AXInsertProbe: Equatable, Sendable {
    /// UTF-16 length of the text we asked to insert. AX ranges are UTF-16.
    let insertedUTF16Length: Int
    /// UTF-16 length of the selection being replaced. Zero for a plain caret.
    let selectionLengthBefore: Int
    /// `AXNumberOfCharacters` before the write.
    let countBefore: Int
    /// `AXNumberOfCharacters` after the write; nil when unreadable.
    let countAfter: Int?
    /// Whether reading the inserted span back matched the text we sent.
    /// Nil when the span could not be read at all.
    let readBackMatched: Bool?
    /// True only when the COMPLETE field is identical before and after the
    /// write. A window around the original selection is not enough: the
    /// selection can move between AX calls, so an equal-length write elsewhere
    /// would leave both the count and the original window untouched. Since
    /// `.noMutation` is what authorises a second paste, it needs whole-field
    /// proof.
    let fieldUnchanged: Bool?
  }

  /// Decide whether a Tier 1 write is verified, provably absent, or unprovable.
  ///
  /// Pure so it can be tested without a live AX element, matching the existing
  /// `isPasteShortcut` precedent where AX traversal is live-only and the
  /// decision is unit-tested.
  ///
  /// BOTH directions demand positive evidence, because the two ways of being
  /// wrong are opposite and both are user-visible: claiming success wrongly
  /// discards the dictation, and claiming nothing-happened wrongly pastes it
  /// twice. Neither character count nor read-back alone settles it.
  internal static func classifyInsertOutcome(_ probe: AXInsertProbe) -> AXInsertOutcome {
    let expectedAfter =
      probe.countBefore + probe.insertedUTF16Length - probe.selectionLengthBefore

    guard let after = probe.countAfter else {
      // The write reported success and the result is entirely unreadable. It
      // may already be in the document, so retrying risks duplicating it.
      return .unverifiable
    }

    // Success needs the exact expected length AND our exact text at the
    // insertion span. Read-back alone is not proof: if the caret sits just
    // before text identical to the dictation and the app ignores the write,
    // read-back matches and we would silently drop the user's dictation.
    if after == expectedAfter, probe.readBackMatched == true {
      return .verified
    }

    // Retry is allowed only when the WHOLE field is proven byte-identical. An
    // unchanged character count is not proof, and neither is an unchanged
    // window around the original selection: the selection can move between AX
    // calls, so an equal-length write elsewhere leaves both intact. Electron
    // apps report a successful write and genuinely leave the field untouched;
    // they reach Tier 2 through here, and they must, or they lose automatic
    // paste entirely.
    if after == probe.countBefore, probe.fieldUnchanged == true {
      return .noMutation
    }

    return .unverifiable
  }

  /// Exact UTF-16 code-unit identity.
  ///
  /// Swift's `String ==` is canonical-equivalence-aware, so it reports two
  /// different combining-mark orderings as equal even though the stored code
  /// units differ — verified locally: `"a\u{0301}\u{0323}"` and
  /// `"a\u{0323}\u{0301}"` have equal UTF-16 counts, compare `==` true, and are
  /// NOT code-unit identical. A destination that reorders marks would therefore
  /// look untouched, and `.noMutation` would authorise a second paste over a
  /// write that landed. AX lengths and ranges are UTF-16, so compare in UTF-16.
  internal static func stringsHaveIdenticalUTF16(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
  }

  /// Read `AXSelectedTextRange` as a UTF-16 range. Nil when unreadable.
  private static func selectedRange(of element: AXUIElement) -> CFRange? {
    var rangeRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      &rangeRef
    )
    guard err == .success, let value = rangeRef else { return nil }
    // A successful read does NOT promise the value is an AXValue — this is a
    // foreign app's accessibility implementation. Check the CF type before
    // casting; the paste path must not be crashable by a misbehaving app.
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    // swift-format-ignore: NeverForceUnwrap — guarded by the CFGetTypeID check.
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  /// Read `length` UTF-16 units starting at `location`. Nil when unreadable.
  private static func string(of element: AXUIElement, at location: Int, length: Int) -> String? {
    guard location >= 0, length >= 0 else { return nil }
    var range = CFRange(location: location, length: length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var resultRef: CFTypeRef?
    let err = AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      rangeValue,
      &resultRef
    )
    guard err == .success else { return nil }
    return resultRef as? String
  }

  /// Insert text directly into an AX element at the cursor position.
  /// Uses kAXSelectedTextAttribute which inserts at cursor / replaces selection.
  ///
  /// Returns a tri-state, not a Bool. `noMutation` is the only outcome the
  /// caller may retry: `unverifiable` means the write may already have landed,
  /// and pasting again would duplicate the user's text.
  public static func insertViaAccessibility(_ text: String, element: AXUIElement)
    -> AXInsertOutcome
  {
    // Verify the element is a text field or text area.
    var roleRef: CFTypeRef?
    let roleErr = AXUIElementCopyAttributeValue(
      element,
      kAXRoleAttribute as CFString,
      &roleRef
    )
    guard roleErr == .success, let role = roleRef as? String else {
      return .noMutation
    }
    guard textRoles.contains(role) else { return .noMutation }

    // Verify the element is writable (not read-only).
    var settableRef: DarwinBoolean = false
    let settableErr = AXUIElementIsAttributeSettable(
      element,
      kAXValueAttribute as CFString,
      &settableRef
    )
    guard settableErr == .success, settableRef.boolValue else { return .noMutation }

    // Everything needed to verify the result must be readable BEFORE we write.
    // The retired code wrote first and only then discovered it could not read
    // the field, leaving a possibly-landed write reported as failure — the same
    // double-paste defect in a second location. Bailing here is free: nothing
    // has been mutated, so Tier 2 is safe.
    var charCountBefore: CFTypeRef?
    AXUIElementCopyAttributeValue(
      element,
      kAXNumberOfCharactersAttribute as CFString,
      &charCountBefore
    )
    guard let countBefore = charCountBefore as? Int, countBefore >= 0 else {
      return .noMutation
    }
    guard let rangeBefore = selectedRange(of: element) else { return .noMutation }
    // A foreign app can report a range that does not fit its own field. Reject
    // rather than compute verification windows from impossible values.
    guard
      rangeBefore.location >= 0,
      rangeBefore.length >= 0,
      rangeBefore.location <= countBefore,
      rangeBefore.length <= countBefore - rangeBefore.location
    else { return .noMutation }

    let insertionStart = rangeBefore.location
    let selectionLength = rangeBefore.length
    let insertedLength = text.utf16.count

    // Whole-field before-image. Only this can later prove that NO mutation
    // landed, because the selection may move between AX calls and an
    // equal-length write elsewhere would leave a local window untouched.
    //
    // An empty field is short-circuited rather than read: a zero-length range
    // read succeeds in TextEdit but that is one app's behaviour, and an empty
    // text box is the most common dictation target of all. Deriving `""` from
    // the count makes the common case independent of per-app AX quirks.
    //
    // Cost, measured rather than assumed (`ax_read_cost_by_size.py`): the read
    // is NOT flat past ~10k characters, it is roughly linear at 0.07 ms per 10k.
    // A 200,000-character field costs 1.5 ms per read, so about 3 ms for the
    // before and after pair. Acceptable against a sub-second pipeline budget.
    let fieldBefore: String
    if countBefore == 0 {
      fieldBefore = ""
    } else if let read = string(of: element, at: 0, length: countBefore) {
      fieldBefore = read
    } else {
      // Without a before-image, a successful AX call could never be proven
      // harmless. Bail while nothing has been mutated; Tier 2 is safe here.
      return .noMutation
    }

    // Insert at cursor via kAXSelectedTextAttribute.
    let err = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFTypeRef
    )
    guard err == .success else { return .noMutation }

    // From here the write may have landed, so every remaining failure is
    // `unverifiable`, never `noMutation`.
    var charCountAfter: CFTypeRef?
    AXUIElementCopyAttributeValue(
      element,
      kAXNumberOfCharactersAttribute as CFString,
      &charCountAfter
    )
    let countAfter = (charCountAfter as? Int).flatMap { $0 >= 0 ? $0 : nil }

    // Positive proof of success: our exact text sits at the insertion span.
    let readBackMatched = string(of: element, at: insertionStart, length: insertedLength)
      .map { stringsHaveIdenticalUTF16($0, text) }

    // Positive proof of NO success: the complete field still has identical
    // UTF-16 code units.
    let fieldUnchanged = countAfter.flatMap { after -> Bool? in
      guard after == countBefore else { return false }
      if after == 0 { return fieldBefore.isEmpty }
      return string(of: element, at: 0, length: after)
        .map { stringsHaveIdenticalUTF16($0, fieldBefore) }
    }

    return classifyInsertOutcome(
      AXInsertProbe(
        insertedUTF16Length: insertedLength,
        selectionLengthBefore: selectionLength,
        countBefore: countBefore,
        countAfter: countAfter,
        readBackMatched: readBackMatched,
        fieldUnchanged: fieldUnchanged
      ))
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
