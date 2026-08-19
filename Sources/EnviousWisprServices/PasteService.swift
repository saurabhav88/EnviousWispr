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

  // MARK: - Clipboard
  //
  // Every entry point below takes the board as a DEFAULTED parameter rather than
  // reaching for `NSPasteboard.general` internally. Production passes nothing and
  // gets the user's clipboard, exactly as before; tests pass an isolated
  // `NSPasteboard.withUniqueName()` board so a test run can never write to the
  // developer's real clipboard (#2146).
  //
  // The parameter is the whole fix, so do not "simplify" it away: with the
  // singleton hard-coded here, seven tests wrote fixture text to the founder's
  // clipboard and the change-count guard below then DECLINED to put it back,
  // because a concurrently-running suite had advanced the count. The guard is
  // correct; the shared board was the defect.

  /// Copy text to the supplied pasteboard.
  public static func copyToClipboard(_ text: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// Copy text to the supplied pasteboard and return its resulting change count.
  public static func copyToClipboardReturningChangeCount(
    _ text: String,
    to pasteboard: NSPasteboard = .general
  ) -> Int {
    copyToClipboard(text, to: pasteboard)
    return pasteboard.changeCount
  }

  /// Capture the supplied pasteboard's contents for later restoration.
  public static func saveClipboard(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
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
  ///   - pasteboard: Defaults to the user's clipboard. Tests pass an isolated board.
  public static func restoreClipboard(
    _ snapshot: ClipboardSnapshot,
    changeCountAfterPaste: Int,
    on pasteboard: NSPasteboard = .general
  ) {
    // Read once, up front. The unstructured logging `Task` below then captures
    // an `Int` instead of the `NSPasteboard` reference, and the number it
    // reports is the one the guard actually decided on rather than whatever the
    // board holds by the time the task runs.
    let observedChangeCount = pasteboard.changeCount

    // If the change count has advanced beyond what we set, a third-party
    // tool wrote to the clipboard — don't clobber their change.
    guard observedChangeCount == changeCountAfterPaste else {
      Task {
        await AppLogger.shared.log(
          "Clipboard restore skipped: changeCount advanced "
            + "(expected \(changeCountAfterPaste), got \(observedChangeCount))",
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

      // One reader for both answers (#1332). The third attribute keeps its own
      // local read because nothing decides on it; it is diagnostic only.
      let settability = readAXSettability(of: axElement)
      func settable(_ attr: String) -> Bool {
        var s: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(axElement, attr as CFString, &s)
        return err == .success && s.boolValue
      }

      let msg =
        "AXDiag capture: app=\(bundleId) role=\(role) subrole=\(subrole) "
        + "valueSettable=\(settability.value.rawValue) "
        + "selTextSettable=\(settability.selectedText.rawValue) "
        + "selRangeSettable=\(settable("AXSelectedTextRange"))"
      await AppLogger.shared.log(msg, level: .info, category: "AXDiag")
    }
  }

  /// Whether a foreign app will accept a write to one of its attributes.
  ///
  /// THREE states, not a Bool, and that is the whole point. `AXUIElementIsAttributeSettable`
  /// can fail to answer, and collapsing "it said no" together with "it did not
  /// say" is what turns a defensive check into a self-inflicted regression:
  /// Tier 1 is 18x faster than the keyboard route, so treating an unanswered
  /// query as a refusal would drop apps onto the slow path for a transient AX
  /// hiccup (#1332).
  public enum AXSettableState: String, Equatable, Sendable {
    case settable
    case notSettable = "not_settable"
    case unreadable
  }

  /// Both settability answers, sampled together at one moment.
  ///
  /// Kept as a PAIR because the interesting fact is the DISAGREEMENT. Measured
  /// live on 2026-08-19: iTerm2 reports `AXValue` settable and `AXSelectedText`
  /// NOT settable, 60 of 60 samples, and Tier 1 has never once succeeded there
  /// in 944 pastes. WhatsApp and the loginwindow password field answer the same
  /// way. TextEdit and Chrome answer settable to both, and Tier 1 wins there.
  public struct AXSettability: Equatable, Sendable {
    public let value: AXSettableState
    public let selectedText: AXSettableState

    /// One closed token rather than two fields, so a telemetry consumer can
    /// group on the combination without joining.
    public var telemetryValue: String {
      "value_\(value.rawValue)__selected_text_\(selectedText.rawValue)"
    }
  }

  /// The single reader for both answers.
  ///
  /// `AXDiag` and the Tier 1 guard used to ask this question separately, with
  /// different attributes and different collapsing of a failed query. This is
  /// the consolidation site. Its result is NOT cached across the gap between
  /// capture and insertion: `AXDiag` samples at capture time and the write
  /// happens later, so a stored answer would be about a different moment.
  package static func readAXSettability(of element: AXUIElement) -> AXSettability {
    func read(_ attribute: CFString) -> AXSettableState {
      var answer: DarwinBoolean = false
      guard AXUIElementIsAttributeSettable(element, attribute, &answer) == .success else {
        return .unreadable
      }
      return answer.boolValue ? .settable : .notSettable
    }
    return AXSettability(
      value: read(kAXValueAttribute as CFString),
      selectedText: read(kAXSelectedTextAttribute as CFString)
    )
  }

  /// The reason that corresponds to a classified outcome, so the mapping lives
  /// in ONE place rather than at each construction site.
  package static func declineReason(for outcome: AXInsertOutcome) -> AXDeclineReason? {
    switch outcome {
    case .verified: return nil
    case .noMutation: return .noMutation
    case .unverifiable: return .unverifiable
    }
  }

  /// Whether a Tier 1 write must be skipped for this element.
  ///
  /// Pure, so the one decision this adds is testable without a live AX element —
  /// matching the precedent `classifyInsertOutcome`, `dispositionForAXDirect`
  /// and `classifyPasteFocus` already set in this file, where the AX round trips
  /// are live-only and the DECISION they feed is the part a test can hold.
  ///
  /// Only `.notSettable` refuses. `.unreadable` proceeds, because an unanswered
  /// query is not a refusal and treating it as one would cost the fast route on
  /// a transient AX failure.
  package static func tier1IsRefused(by settability: AXSettability) -> Bool {
    settability.selectedText == .notSettable
  }

  /// Why a Tier 1 accessibility write did not deliver.
  ///
  /// Tier 1 is 18x faster than the keyboard route (p50 15ms against 267ms) and
  /// loses 76% of the time even when the caret was read in a real text field —
  /// 7,295 declines a month, and until #1332 not one of them recorded a cause.
  /// This is that cause, as a closed set so it can be grouped on.
  ///
  /// The `notAttempted*` cases are decided by the CASCADE before this function
  /// is called, and they are the majority: a reason set covering only this
  /// function's own exits would be nil for most declines, which is the same
  /// silent gap it exists to close.
  public enum AXDeclineReason: String, Equatable, Sendable {
    case accessibilityDenied = "not_attempted_accessibility_denied"
    case focusMissing = "not_attempted_focus_missing"
    case focusNonText = "not_attempted_focus_non_text"
    case roleUnreadable = "role_unreadable"
    case roleNotText = "role_not_text"
    case selectedTextNotSettable = "selected_text_not_settable"
    case countUnreadableOrInvalid = "count_unreadable_or_invalid"
    case rangeUnreadable = "range_unreadable"
    case rangeInvalid = "range_invalid"
    case beforeImageUnreadableOrIncomplete = "before_image_unreadable_or_incomplete"
    case focusUnconfirmed = "focus_unconfirmed"
    case setFailed = "set_failed"
    case noMutation = "no_mutation"
    case unverifiable
  }

  /// What a Tier 1 attempt produced, including the evidence behind it.
  ///
  /// Replaces a `(outcome, submitted)` tuple. The decision evidence used to be
  /// discarded at this return boundary, which is why nothing downstream could
  /// say why the fast route lost.
  package struct AXInsertResult: Sendable {
    package let outcome: AXInsertOutcome
    package let submitted: PastePayloadKind?
    package let declineReason: AXDeclineReason?
    package let settability: AXSettability?

    package init(
      outcome: AXInsertOutcome,
      submitted: PastePayloadKind?,
      declineReason: AXDeclineReason?,
      settability: AXSettability?
    ) {
      self.outcome = outcome
      self.submitted = submitted
      self.declineReason = declineReason
      self.settability = settability
    }

    /// A decline before any write was attempted. `.noMutation` is the outcome
    /// in every case, because nothing was mutated — the reason is what tells
    /// the two dozen ways of getting here apart.
    static func declined(
      _ reason: AXDeclineReason, settability: AXSettability? = nil
    ) -> AXInsertResult {
      AXInsertResult(
        outcome: .noMutation, submitted: nil, declineReason: reason, settability: settability)
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
    // Overflow-checked, because every number here came from a foreign process
    // and this file already treats them as hostile everywhere else. A malformed
    // app reporting a character count near `Int.max` would otherwise TRAP on
    // this addition and take the app down mid-paste (Codex review r4). An
    // unusable count cannot prove the write did nothing, so it is unverifiable
    // — the outcome that suppresses retries rather than inviting one.
    let base = probe.countBefore - probe.selectionLengthBefore
    let (expectedAfter, overflowed) = base.addingReportingOverflow(probe.insertedUTF16Length)
    guard !overflowed else { return .unverifiable }

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

  // MARK: - Caret context (#1785)

  /// Which of the two payloads a route actually submitted.
  ///
  /// `legacy` is today's text and is always available; `repaired` is the
  /// contextual candidate and may only be submitted by a route that has just
  /// re-checked the field. Plan §6 is the sole authority on which route may
  /// commit which, and this type is how a route reports what it did.
  package enum PastePayloadKind: String, Equatable, Sendable {
    case legacy
    case repaired
  }

  /// Choose the payload for a destination write, at the route's LAST boundary
  /// before it writes.
  ///
  /// Fails closed on every uncertainty: no candidate, no evidence, no element,
  /// or a field that has moved since the candidate was computed all select
  /// today's payload. The only way to get the repaired text is positive proof
  /// that the field is still exactly as it was.
  /// Which payload a clipboard route may commit.
  ///
  /// **The re-read is now conditional, and that is the whole change.** It used
  /// to run for every candidate. Measured on the founder's machine on
  /// 2026-08-04: the app read the caret, correctly decided `lowercased_first`,
  /// and then the re-read failed and threw the correction away — on most
  /// terminal dictations. The trace showed the re-read stopping before it could
  /// resolve anything, in 1.7 ms, nowhere near any deadline.
  ///
  /// Removing it entirely is safe for every rule but one, and the reason is that
  /// a clipboard route cannot rewrite what is already on screen. It inserts at
  /// the caret, so a stale context can only make the text WE INSERT wrong. For
  /// casing and spacing that is one letter or one space — exactly the cost of
  /// refusing. Guarding a wrong capital with a check that produces a wrong
  /// capital is not a guard.
  ///
  /// `candidateDeletesDictatedText` is the exception. The duplicate-seam rule
  /// removes a word the user actually said, so a stale caret there loses
  /// content rather than trading one blemish for another. That asymmetry is
  /// what the re-read is worth paying for, and the only thing it is worth
  /// paying for.
  ///
  /// Nothing here decides WHERE the paste lands. The write goes to whatever is
  /// focused either way; this only chooses between two strings.
  ///
  /// `requireCaretUnchanged` is a SEPARATE trigger for the same re-check,
  /// independent of `candidateDeletesDictatedText`. That existing gate was
  /// calibrated for "the caret shifted slightly within the same field" (worst
  /// case: one wrong capital) and a trailing-space/seam-casing candidate never
  /// sets it — so without this parameter, a retry-sourced element (which
  /// carries only a same-APP guarantee, never same-window/tab) would commit
  /// with no live re-check at all. Default `false` is byte-identical to
  /// today's behavior for every existing caller.
  package static func payloadAtCommitBoundary(
    legacy: String,
    repaired: String?,
    context: CaretContext?,
    element: AXUIElement?,
    candidateDeletesDictatedText: Bool,
    requireCaretUnchanged: Bool = false,
    terminalBudget: TerminalResolutionBudget? = nil,
    // Injected seam, defaulting to the real check. Deleting-candidate cases
    // can force the "changed" direction deterministically with a real-but-
    // mismatched AX element; the "unchanged" direction this parameter adds
    // has no such trick from a test process, so it needs a seam to be
    // testable at all.
    caretUnchangedCheck: (AXUIElement, CaretContext, TerminalResolutionBudget?) -> Bool =
      caretUnchanged
  ) -> (text: String, kind: PastePayloadKind) {
    guard let repaired, let context, let element else { return (legacy, .legacy) }
    guard candidateDeletesDictatedText || requireCaretUnchanged else {
      return (repaired, .repaired)
    }
    guard caretUnchangedCheck(element, context, terminalBudget)
    else { return (legacy, .legacy) }
    return (repaired, .repaired)
  }

  /// Which payload the Tier 1 accessibility write may commit.
  ///
  /// Extracted so the rule can be tested. It was previously inline, where the
  /// only reachable test had to pass a nil element and therefore passed for the
  /// wrong reason — it proved "no element means legacy", not the rule itself.
  package static func accessibilityWritePayload(
    legacy: String,
    repaired: String?,
    context: CaretContext?,
    rangeBefore: CFRange,
    fieldBefore: String
  ) -> (text: String, kind: PastePayloadKind) {
    // Screen evidence can NEVER authorise this route. Tier 1's authorisation
    // rests on real selection offsets and matching surrounding windows read from
    // the field microseconds before it writes. A screen-derived context has
    // neither — its offsets are synthesised from the parsed line and its right
    // window is empty by construction — so every check below would compare
    // against something that was never read from the field. Tier 1 always
    // submits today's payload in a terminal.
    guard context?.isScreenDerived != true else { return (legacy, .legacy) }
    guard let repaired, let context,
      rangeBefore.location == context.selectionLocation,
      rangeBefore.length == context.selectionLength,
      contextWindowsStillMatch(context, inFieldBefore: fieldBefore)
    else { return (legacy, .legacy) }
    return (repaired, .repaired)
  }

  /// A bounded read of the text either side of the caret, taken at insertion
  /// time. Carries no `AXValue` state — only plain strings and UTF-16 offsets —
  /// so nothing about a foreign app's accessibility handles escapes Services.
  ///
  /// The selected text itself is EXCLUDED from both windows: the right window
  /// begins after the selection, because a replacement is about to consume it.
  package struct CaretContext: Equatable, Sendable {
    /// Text immediately before the selection, bounded by the window size.
    package let leftWindow: String
    /// Text immediately after the selection, bounded by the window size.
    package let rightWindow: String
    /// UTF-16 offset of the selection's start.
    package let selectionLocation: Int
    /// UTF-16 length of the selection. Zero for a plain caret.
    package let selectionLength: Int

    /// Non-nil when this context came from a terminal's rendered SCREEN rather
    /// than from a real caret, carrying the complete evidence all three gates
    /// agreed on.
    ///
    /// Typed provenance is load-bearing in three places: repair enforces
    /// terminal-only policy, screen evidence is barred from authorising the
    /// Tier 1 accessibility write, and commit revalidation is source-aware. The
    /// evidence participates in equality, so a screen that scrolled, a CLI that
    /// exited, or focus that moved all fail revalidation — a screen-derived
    /// context has no selection offsets to compare, so this IS its identity.
    package let terminalEvidence: TerminalEvidence?

    /// Whether `leftWindow` begins at the very start of what the user can edit,
    /// so its first token has no hidden prefix.
    ///
    /// STORED, not inferred. Pipeline used to derive it as
    /// `leftWindow.utf16.count == selectionLocation`, which is exact for a real
    /// caret and meaningless for a terminal: both values come from the same
    /// string there, so a screen-derived context ALWAYS claimed to reach the
    /// start — including when the row read was the tail of a wrapped line with
    /// text hidden above it. That claim lets `completeLeftToken` treat a wrap
    /// fragment as a complete word, which authorises the one repair rule that
    /// DELETES a dictated word.
    package let leftReachesDocumentStart: Bool

    /// Whether this context was derived from a terminal screen.
    package var isScreenDerived: Bool { terminalEvidence != nil }

    package init(
      leftWindow: String, rightWindow: String, selectionLocation: Int, selectionLength: Int,
      leftReachesDocumentStart: Bool, terminalEvidence: TerminalEvidence? = nil
    ) {
      self.leftWindow = leftWindow
      self.rightWindow = rightWindow
      self.selectionLocation = selectionLocation
      self.selectionLength = selectionLength
      self.leftReachesDocumentStart = leftReachesDocumentStart
      self.terminalEvidence = terminalEvidence
    }
  }

  /// The accessibility messaging timeout applied to a destination before any
  /// read. A failure bound, not a latency target — single owner, so the terminal
  /// path can restore exactly this value after tightening it.
  package static let axMessagingTimeoutSeconds: Double = 0.5

  /// How many UTF-16 units to read either side. One character is provably not
  /// enough — `"home. "` and `"home, "` both end in a space and need opposite
  /// decisions — so the reader takes a window and the rule walks back within it.
  /// Single authority for the literal; no call site repeats it.
  package static let caretContextWindow = 20

  /// Plan the ranges and assemble the context, with no accessibility calls.
  ///
  /// All arithmetic is UTF-16, and every comparison is written to avoid
  /// overflow: `length <= characterCount - location` rather than
  /// `location + length <= characterCount`, because the latter can wrap on
  /// hostile input from a foreign process.
  ///
  /// `readRange` returns nil when that span cannot be read. A required non-empty
  /// span failing means the whole context fails open, because a partially-read
  /// context would silently produce a wrong repair.
  static func assembleCaretContext(
    characterCount: Int,
    selectionLocation: Int,
    selectionLength: Int,
    window: Int,
    readRange: (Int, Int) -> String?
  ) -> CaretContext? {
    guard window > 0 else { return nil }
    guard characterCount >= 0, selectionLocation >= 0, selectionLength >= 0 else { return nil }
    guard selectionLocation <= characterCount else { return nil }
    guard selectionLength <= characterCount - selectionLocation else { return nil }

    // Left: the window's worth of text ending at the selection start.
    let leftStart = selectionLocation >= window ? selectionLocation - window : 0
    let leftLength = selectionLocation - leftStart
    let leftWindow: String
    if leftLength == 0 {
      leftWindow = ""
    } else if let read = readRange(leftStart, leftLength), read.utf16.count == leftLength {
      leftWindow = read
    } else {
      // A read that returns the WRONG number of units is malformed, not usable.
      // The field may have changed between the count read and this one, so the
      // text no longer describes the geometry we planned against. Accepting it
      // would repair confidently against truncated or oversized context, and the
      // later selection revalidation cannot detect that because the offsets
      // still look consistent.
      return nil
    }

    // Right: begins AFTER the selection, since a replacement consumes it.
    let rightStart = selectionLocation + selectionLength
    let available = characterCount - rightStart
    let rightLength = min(window, available)
    let rightWindow: String
    if rightLength <= 0 {
      rightWindow = ""
    } else if let read = readRange(rightStart, rightLength), read.utf16.count == rightLength {
      rightWindow = read
    } else {
      return nil
    }

    // Whitespace exhaustion. If the bounded left window starts PAST offset zero
    // and holds nothing but spaces and tabs, the nearest real character lies
    // outside what we read — so we cannot tell a continuation from a line or
    // field start, and guessing would produce a wrong capital. Refuse. Reaching
    // offset zero, or finding a newline, makes the boundary positively known.
    if leftStart > 0, !leftWindow.isEmpty,
      leftWindow.allSatisfy({ $0 == " " || $0 == "\t" })
    {
      return nil
    }

    return CaretContext(
      leftWindow: leftWindow,
      rightWindow: rightWindow,
      selectionLocation: selectionLocation,
      selectionLength: selectionLength,
      // The window reached offset zero exactly when it is as long as the
      // caret's offset — the same test Pipeline used to make, moved to the one
      // place that actually knows the geometry.
      leftReachesDocumentStart: leftStart == 0)
  }

  /// The app-scoped `kAXFocusedUIElementAttribute` query shared by every
  /// caller that wants "what is focused in THIS process right now" — never a
  /// system-wide query, which can answer for a different app.
  ///
  /// Owns every defensive check around that one AX round-trip: process trust,
  /// a usable pid, the messaging timeout bound, CF type validation before the
  /// cast, and confirming the returned element actually belongs to the
  /// process that was asked, not one AX resolved to on its own.
  private static func focusedElementQuery(
    pid: pid_t,
    messagingTimeout: Double
  ) -> AXUIElement? {
    guard AXIsProcessTrusted(), pid > 0 else { return nil }

    let application = AXUIElementCreateApplication(pid)
    // Bound every subsequent read. A wedged destination must not hang the
    // dictation path; this is a failure bound, not a latency target.
    AXUIElementSetMessagingTimeout(application, Float(messagingTimeout))

    var focusedRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
      let focusedValue = focusedRef,
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else { return nil }
    // swift-format-ignore: NeverForceUnwrap — guarded by the CFGetTypeID check.
    let focused = focusedValue as! AXUIElement

    var focusedPID: pid_t = 0
    guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == pid else {
      return nil
    }
    return focused
  }

  /// Read the text either side of the caret in the app that owns `element`.
  ///
  /// Synchronous, non-throwing, and fail-open: ANY unavailable, malformed,
  /// stale, mismatched or unreadable state returns nil, and the caller keeps
  /// today's behaviour. Nothing here mutates the destination.
  ///
  /// The focused element is re-read from the owning application immediately
  /// before use and required to match the captured handle. A stale handle can
  /// name an element the user has since left, and repairing against the wrong
  /// field is worse than not repairing at all.
  /// Re-read the focused element of the app that owns `element` and return it
  /// only when it is still the SAME element.
  ///
  /// The single owner of "is the user still in the field we captured". Both the
  /// context read and the route-final revalidation go through it, so the two
  /// cannot come to disagree about what identity means.
  ///
  /// Returns nil for untrusted accessibility, a dead process, an unreadable
  /// focus, or a different element — every one of which means "do not repair".
  static func freshFocusedElement(
    matching element: AXUIElement,
    messagingTimeout: Double = axMessagingTimeoutSeconds
  ) -> AXUIElement? {
    // Resolve the owning process from the captured element itself — never from
    // `NSWorkspace.frontmostApplication`, which is stale without a run loop,
    // and never from a system-wide element, which can answer for another app.
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }

    guard let fresh = focusedElementQuery(pid: pid, messagingTimeout: messagingTimeout) else {
      return nil
    }

    // The user may have moved on since capture. Repairing against a different
    // field would edit text they never dictated into.
    guard CFEqual(fresh, element) else { return nil }
    return fresh
  }

  /// The currently focused element of a KNOWN app process, used when there is
  /// no prior captured element to match against — e.g. the record-start
  /// capture failed and this is a delivery-time retry. `pid` scopes the query
  /// by construction, so this can never target an app the caller did not ask
  /// for.
  ///
  /// This proves same-APP only, never same-window/tab within that app —
  /// callers that need the stronger guarantee re-verify at commit time via
  /// `payloadAtCommitBoundary`'s `requireCaretUnchanged`.
  package static func focusedElement(
    inAppWithPID pid: pid_t,
    messagingTimeout: Double = axMessagingTimeoutSeconds
  ) -> AXUIElement? {
    focusedElementQuery(pid: pid, messagingTimeout: messagingTimeout)
  }

  /// Whether the field is still EXACTLY as it was when a contextual candidate
  /// was computed: same focused element, same selection, and the same text on
  /// either side of it.
  ///
  /// This is the last question asked before a route commits a repaired payload.
  /// It fails CLOSED — unreadable is treated as changed — because the cost of a
  /// wrong "unchanged" is text repaired against evidence that no longer holds,
  /// while the cost of a wrong "changed" is merely today's behaviour.
  ///
  /// The SURROUNDING TEXT is compared, not just the offsets (Codex review r2).
  /// An editor, a collaborator, or an autoformatter can rewrite nearby
  /// characters without moving the selection at all — turning a preceding `, `
  /// into `. ` leaves every offset identical while inverting whether the next
  /// word should be lowercased. Offsets alone would have called that unchanged
  /// and committed a repair computed from punctuation that is no longer there.
  package static func caretUnchanged(
    element: AXUIElement,
    since context: CaretContext,
    terminalBudget: TerminalResolutionBudget? = nil
  ) -> Bool {
    // The SAME budget as the initial read, so resolution plus every commit check
    // share one cumulative per-delivery bound rather than one bound each.
    //
    // Marked so the trace says WHICH phase spent the budget. This one runs after
    // the target app has been activated, which the initial read does not, and it
    // was invisible until now because `CURSOR_REPAIR` is logged before the paste.
    terminalBudget?.mark("recheck")
    guard let fresh = readCaretContext(element: element, terminalBudget: terminalBudget) else {
      return false
    }
    return fresh == context
  }

  /// Whether the text either side of the selection still matches the evidence a
  /// candidate was computed from, checked against a whole-field image rather
  /// than a fresh read.
  ///
  /// The Tier 1 write already holds the complete field, captured microseconds
  /// before it writes, so it can answer this without another accessibility call
  /// — and from an image closer to the write than any re-read could be.
  ///
  /// Fails CLOSED: a window that cannot be sliced, because the field shrank or
  /// an offset lands inside a surrogate pair, counts as changed.
  static func contextWindowsStillMatch(_ context: CaretContext, inFieldBefore field: String)
    -> Bool
  {
    let units = field.utf16.count
    let selectionEnd = context.selectionLocation + context.selectionLength
    guard context.selectionLocation >= 0, context.selectionLength >= 0,
      selectionEnd <= units
    else { return false }

    let leftStart = max(0, context.selectionLocation - context.leftWindow.utf16.count)
    guard let left = utf16Slice(of: field, from: leftStart, to: context.selectionLocation),
      left == context.leftWindow
    else { return false }

    let rightEnd = min(units, selectionEnd + context.rightWindow.utf16.count)
    guard let right = utf16Slice(of: field, from: selectionEnd, to: rightEnd),
      right == context.rightWindow
    else { return false }
    return true
  }

  /// A substring by UTF-16 offsets, or nil when the range is not addressable —
  /// out of bounds, inverted, or landing inside a surrogate pair.
  static func utf16Slice(of text: String, from start: Int, to end: Int) -> String? {
    guard start >= 0, end >= start, end <= text.utf16.count else { return nil }
    let utf16 = text.utf16
    guard
      let startIndex = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
      let endIndex = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex)
    else { return nil }
    return String(utf16[startIndex..<endIndex])
  }

  /// How much of a terminal's rendered screen Gate 2 may read.
  ///
  /// 6,000 UTF-16 units, MEASURED rather than chosen: 2,000 lost the opening
  /// boundary row on long Claude Code input, while 6,000 retained it at every
  /// length up to 4,800 typed characters. Never a whole-field `AXValue` read —
  /// on a terminal that is the ENTIRE scrollback.
  package static let terminalScreenTailUnits = 6000

  /// Read the bounded tail of a terminal's rendered screen.
  ///
  /// The returned length must EQUAL the requested length. A short or long
  /// result, a boundary landing inside a surrogate pair, or an app with no
  /// parameterized-range support all refuse — a partially-read screen would
  /// silently produce a wrong input line.
  static func terminalScreenTail(of element: AXUIElement) -> String? {
    var countRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
      let characterCount = countRef as? Int, characterCount > 0
    else { return nil }

    let length = min(characterCount, terminalScreenTailUnits)
    let location = characterCount - length
    guard let tail = string(of: element, at: location, length: length),
      tail.utf16.count == length
    else { return nil }
    return tail
  }

  /// Resolve a terminal context for `element`, or nil.
  ///
  /// Gate 0 reads the bundle identifier from the element's OWN pid rather than
  /// from anything the caller measured earlier.
  static func terminalCaretContext(
    element: AXUIElement,
    budget: TerminalResolutionBudget,
    breaker: TerminalCircuitBreaker,
    onRefusal: ((TerminalContextRefusal) -> Void)? = nil
  ) -> CaretContext? {
    // REVALIDATE FOCUS FIRST — the captured element may be a tab the user has
    // since left.
    //
    // The caret path has always done this through `freshFocusedElement`, and the
    // terminal path was reading the captured handle directly. So when the user
    // switched tabs after recording started, the caret read correctly refused
    // the stale element and the screen read then went to that same stale
    // element anyway, describing a tab that is no longer in front of them.
    // Cloud review found it; the discipline already existed one function away.
    guard
      let fresh = budget.step(
        applying: element, label: "focused",
        {
          freshFocusedElement(matching: element, messagingTimeout: max(0.005, budget.remaining))
        })
    else { return nil }

    var pid: pid_t = 0
    guard AXUIElementGetPid(fresh, &pid) == .success else { return nil }

    let dependencies = TerminalContextResolver.Dependencies(
      bundleIdentifier: { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier },
      // The FILTERED sweep (#1943). Gate 1 only ever accepts a process holding a
      // controlling terminal, so reading every other process's argv/environment
      // blob was work whose result was always discarded — and it was the step
      // that blew the budget and latched terminal insertion off (#1941).
      scanProcesses: { TerminalProcessScanner.liveTerminalSnapshot() },
      readScreenTail: {
        budget.step(applying: fresh, label: "screen") { terminalScreenTail(of: fresh) }
      })

    // The typed refusal is REPORTED, not discarded. §8 of the plan lists eight
    // distinct outcomes, and cloud review found every one of them collapsing
    // into "unreadable" at the caller — which is exactly the diagnosability gap
    // that cost three rounds of guessing during founder testing on 2026-07-26.
    let result = TerminalContextResolver.resolve(
      targetPID: pid, budget: budget, breaker: breaker, dependencies: dependencies)
    guard let evidence = result.evidence else {
      if case .refused(let reason) = result { onRefusal?(reason) }
      return nil
    }

    // The right window is EMPTY BY CONSTRUCTION. Under the founder's
    // end-of-line assumption there is no text after the cursor to read, and this
    // is what keeps the drop-our-full-stop rule inert in terminals.
    return CaretContext(
      leftWindow: evidence.located.inputLine,
      rightWindow: "",
      selectionLocation: evidence.located.inputLine.utf16.count,
      selectionLength: 0,
      // A wrapped line's tail has text hidden above it, so its first token may
      // be a fragment. The parser is the only thing that knows a row was
      // dropped, so it says so rather than leaving it to be inferred from
      // offsets that cannot express it.
      leftReachesDocumentStart: !evidence.located.leftWasCut,
      terminalEvidence: evidence)
  }

  package static func readCaretContext(
    element: AXUIElement,
    window: Int = caretContextWindow,
    terminalBudget: TerminalResolutionBudget? = nil,
    terminalBreaker: TerminalCircuitBreaker = .shared,
    onTerminalRefusal: ((TerminalContextRefusal) -> Void)? = nil
  ) -> CaretContext? {
    // CLASS, enumerated rather than patched — this is the THIRD review round to
    // find the same shape, so every path is accounted for here instead of the
    // one that was reported.
    //
    // THE RULE: on a delivery that could touch a terminal, EVERY accessibility
    // read is bounded by the remaining budget. There are exactly four paths out
    // of this function, and each one states its bound:
    //
    //   1. not a terminal       -> today's default, unchanged.
    //   2. breaker already open -> BOUNDED. Round 3 found this returning to the
    //                              0.5 s default, so a terminal known to be
    //                              wedged still cost half a second on every
    //                              later dictation — the exact cost the breaker
    //                              exists to stop paying.
    //   3. read overran         -> BOUNDED, charged, breaker armed.
    //   4. normal               -> BOUNDED, charged.
    //
    // Rounds one and two each fixed one path and left the others; the fix is a
    // single place that computes the bound, not another branch that remembers to.
    //
    // GATE 0 FIRST, and this ordering is load-bearing rather than tidy.
    //
    // Production supplies a budget on EVERY delivery, so gating the terminal
    // policy on "was a budget passed" applied it to every app in the product.
    // Cloud review caught both consequences: an ordinary app's caret read was
    // being squeezed from the 0.5 s failure bound down to 100 ms, so a slow but
    // perfectly honest field could start failing to read where it used to
    // succeed; and an ordinary app with the caret at the start of a non-empty
    // field matched the terminal signature, so Gate 0's refusal was reported as
    // terminal telemetry for something that is not a terminal.
    //
    // Asking "is this app a terminal" costs one bundle-id lookup and no
    // accessibility call, so it is asked BEFORE any policy is applied. A
    // non-terminal delivery then takes exactly today's path: default timeout, no
    // budget charged, no terminal outcome recorded.
    var targetPID: pid_t = 0
    let hasPID = AXUIElementGetPid(element, &targetPID) == .success
    let surface =
      hasPID
      ? NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
        .flatMap(TerminalSurface.init(bundleIdentifier:))
      : nil

    guard let terminalBudget, surface != nil, hasPID else {
      // Path 1. Not a terminal delivery — byte-identical to today.
      return caretDerivedContext(element: element, window: window)
    }

    if terminalBreaker.isOpen(for: targetPID) {
      // Path 2. Still read the caret — every other app's behaviour depends on it
      // — but never at the default timeout, because this target is known wedged.
      onTerminalRefusal?(.breakerOpen)
      return caretDerivedContext(element: element, window: window, budget: terminalBudget)
    }

    // Each read inside charges the shared budget as it goes, so this checks a
    // total that is already accurate rather than timing the block from outside.
    var context = caretDerivedContext(
      element: element, window: window, budget: terminalBudget)

    // `nil` label and zero cost: every read inside `caretDerivedContext` already
    // recorded itself through `budget.step`, so this is an exhaustion CHECK and
    // not a cost. Labelling it would add a phantom zero-cost entry to the trace.
    if TerminalContextResolver.overspent(
      by: 0, label: nil, budget: terminalBudget, breaker: terminalBreaker, pid: targetPID)
    {
      // Path 3. Whatever came back arrived too late to spend more time on.
      onTerminalRefusal?(.deadline)
      return context
    }

    // Path 4. The terminal signature, and the exact condition the shipped repair
    // already refuses on: no usable left anchor with a non-empty right window. A
    // terminal reports a caret pinned at 0 while its character count grows, so
    // the "text after the caret" is really the TOP of the scrollback.
    //
    // Gate 0 inside the resolver is what stops this firing in an honest app
    // whose user simply put the cursor at the very start of a document.
    let looksLikeATerminal =
      context == nil
      || (context?.leftWindow.isEmpty == true && context?.rightWindow.isEmpty == false)
    guard looksLikeATerminal else { return context }

    context =
      terminalCaretContext(
        element: element, budget: terminalBudget, breaker: terminalBreaker,
        onRefusal: onTerminalRefusal) ?? context
    return context
  }

  /// Today's selected-range read, unchanged. Split out so the terminal path can
  /// reuse it without duplicating a single accessibility call.
  /// Today's selected-range read.
  ///
  /// When a `budget` is supplied, EVERY accessibility call inside is wrapped so
  /// the cap applies to all of them TOGETHER (founder 2026-07-28: "it has to be
  /// a 100 ms cap for all the questions"; the cumulative rule stands, the value
  /// is 200 ms since 2026-08-05 — `TerminalResolutionBudget.defaultTotal` owns
  /// why). Passing no budget is today's path
  /// exactly, at the standard failure timeout — which is what every non-terminal
  /// app takes.
  static func caretDerivedContext(
    element: AXUIElement,
    window: Int,
    budget: TerminalResolutionBudget? = nil
  ) -> CaretContext? {
    // One helper, so no read can be added later that forgets to be counted.
    func bounded<T>(_ label: String, _ body: () -> T) -> T {
      guard let budget else { return body() }
      return budget.step(applying: element, label: label, body)
    }

    guard
      let fresh = bounded(
        "focused",
        {
          freshFocusedElement(
            matching: element,
            messagingTimeout: budget.map { max(0.005, $0.remaining) } ?? axMessagingTimeoutSeconds)
        })
    else { return nil }

    // Role is read from the FRESH element, never the captured handle.
    var roleRef: CFTypeRef?
    guard
      bounded(
        "role", { AXUIElementCopyAttributeValue(fresh, kAXRoleAttribute as CFString, &roleRef) })
        == .success,
      let role = roleRef as? String, textRoles.contains(role)
    else { return nil }

    var countRef: CFTypeRef?
    guard
      bounded(
        "count",
        {
          AXUIElementCopyAttributeValue(
            fresh, kAXNumberOfCharactersAttribute as CFString, &countRef)
        }) == .success,
      let characterCount = countRef as? Int
    else { return nil }

    guard let range = bounded("range", { selectedRange(of: fresh) }) else { return nil }

    return assembleCaretContext(
      characterCount: characterCount,
      selectionLocation: range.location,
      selectionLength: range.length,
      window: window,
      readRange: { location, length in
        bounded("range_read", { string(of: fresh, at: location, length: length) })
      })
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

  /// Whether a Tier 1 write may proceed given the focus-match requirement.
  ///
  /// Extracted as a pure function so this ONE new decision (#1980, whole-diff
  /// review P1) is testable without live AX state. `insertViaAccessibility`
  /// itself cannot be driven deterministically end to end — its role,
  /// settable, range, and field reads are all live AX calls — but the rule
  /// this guard adds can be, matching the existing precedent of
  /// `classifyInsertOutcome` / `dispositionForAXDirect` / `classifyPasteFocus`.
  package static func mayCommitAccessibilityWrite(
    requireFocusedElementMatch: Bool,
    isFocused: Bool
  ) -> Bool {
    !requireFocusedElementMatch || isFocused
  }

  /// Insert text directly into an AX element at the cursor position.
  /// Uses kAXSelectedTextAttribute which inserts at cursor / replaces selection.
  ///
  /// Returns a tri-state, not a Bool. `noMutation` is the only outcome the
  /// caller may retry: `unverifiable` means the write may already have landed,
  /// and pasting again would duplicate the user's text.
  ///
  /// Takes BOTH payloads rather than one chosen by the caller, and reports which
  /// it submitted. The choice belongs here because this function already reads
  /// the selected range in the same breath as the write (#1785, plan §6): a
  /// caller-side check would be check-then-write with an AX round trip in the
  /// gap. For a RECORD-START-captured handle, element identity needs no
  /// separate check — the write targets the very handle the candidate was
  /// computed against, and its content/selection re-check (`accessibilityWritePayload`)
  /// already catches any change.
  ///
  /// That is NOT sufficient for a retry-sourced handle (#1980, whole-diff
  /// review): the content/selection check proves the FIELD hasn't changed,
  /// never that the user is still FOCUSED on it. A background browser tab's
  /// field can report byte-identical content long after the user switched
  /// away, which is exactly how a retry-recovered element (same-APP, never
  /// same-window/tab) can end up stale. `requireFocusedElementMatch` closes
  /// that gap with a live focus re-check immediately before the write.
  package static func insertViaAccessibility(
    legacy: String,
    repaired: String? = nil,
    context: CaretContext? = nil,
    element: AXUIElement,
    requireFocusedElementMatch: Bool = false
  ) -> AXInsertResult {
    // Verify the element is a text field or text area.
    var roleRef: CFTypeRef?
    let roleErr = AXUIElementCopyAttributeValue(
      element,
      kAXRoleAttribute as CFString,
      &roleRef
    )
    guard roleErr == .success, let role = roleRef as? String else {
      return .declined(.roleUnreadable)
    }
    guard textRoles.contains(role) else { return .declined(.roleNotText) }

    // Verify the element will accept the write we are about to make.
    //
    // The retired check asked about `kAXValueAttribute` while the write below
    // targets `kAXSelectedTextAttribute`. Those are different questions and real
    // apps answer them differently: iTerm2 says yes to the first and no to the
    // second, and then returns `.success` from a write that changes nothing —
    // measured 225 times out of 225 on 2026-08-19. Tier 1 has never once
    // succeeded there in 944 production pastes (#1332).
    //
    // Only a POSITIVE refusal skips. An unanswerable query proceeds exactly as
    // before, because collapsing "no" together with "did not say" would drop an
    // app onto the 18x-slower route for a transient AX failure.
    let settability = readAXSettability(of: element)
    if tier1IsRefused(by: settability) {
      return .declined(.selectedTextNotSettable, settability: settability)
    }

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
      return .declined(.countUnreadableOrInvalid, settability: settability)
    }
    guard let rangeBefore = selectedRange(of: element) else {
      return .declined(.rangeUnreadable, settability: settability)
    }
    // A foreign app can report a range that does not fit its own field. Reject
    // rather than compute verification windows from impossible values.
    guard
      rangeBefore.location >= 0,
      rangeBefore.length >= 0,
      rangeBefore.location <= countBefore,
      rangeBefore.length <= countBefore - rangeBefore.location
    else { return .declined(.rangeInvalid, settability: settability) }

    // The payload choice, made from the range this function just read rather
    // than from anything the caller measured earlier. A contextual candidate is
    // committed ONLY when the selection is still exactly where it was when that
    // candidate was computed; anything else — no candidate, no evidence, or a
    // caret that moved — takes today's payload. Plan §6.
    let insertionStart = rangeBefore.location
    let selectionLength = rangeBefore.length

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
    //
    // The read must return EXACTLY `countBefore` units. A foreign app that
    // truncates the string yields a before-image that is not the field: if the
    // write then lands beyond the truncated span, an equally-truncated after-read
    // compares identical, `fieldUnchanged` says nothing happened, and Tier 2
    // pastes the dictation a SECOND time into a field that already has it. The
    // caret-context reader has always demanded this; the verification path had
    // not (Codex review r2).
    let fieldBefore: String
    if countBefore == 0 {
      fieldBefore = ""
    } else if let read = string(of: element, at: 0, length: countBefore),
      read.utf16.count == countBefore
    {
      fieldBefore = read
    } else {
      // Without a trustworthy before-image, a successful AX call could never be
      // proven harmless. Bail while nothing has been mutated; Tier 2 is safe.
      return .declined(.beforeImageUnreadableOrIncomplete, settability: settability)
    }

    // The payload choice, made from the range AND the surrounding text this
    // function just read, rather than from anything the caller measured earlier.
    // A contextual candidate is committed ONLY when the field still looks
    // exactly as it did when that candidate was computed.
    //
    // The windows are sliced out of the before-image already in hand, so this
    // strictness costs no extra accessibility call. Offsets alone are not
    // enough (Codex review r2): rewriting a preceding `, ` as `. ` leaves every
    // offset identical while inverting whether the next word should be
    // lowercased.
    let payload = accessibilityWritePayload(
      legacy: legacy, repaired: repaired, context: context, rangeBefore: rangeBefore,
      fieldBefore: fieldBefore)
    let text = payload.text
    let insertedLength = text.utf16.count

    // #1980 whole-diff review (P1): the field-content re-check above cannot
    // prove the user is still FOCUSED on this element — only that its content
    // hasn't changed. For a retry-sourced handle that is not enough (see the
    // doc comment above), so require a live focus re-check immediately before
    // the write, narrowing the TOCTOU window to the smallest this function can
    // offer. Nothing has been mutated yet, so `.noMutation` is correct: Tier 2
    // remains free to try.
    //
    // #1980 whole-diff review round 2 (P2): `isFocused` MUST be computed only
    // when `requireFocusedElementMatch` is true. Function arguments are not
    // lazy in Swift, so passing `freshFocusedElement(matching:) != nil`
    // directly as an argument evaluates it unconditionally — an extra AX
    // round-trip (up to the full messaging timeout against a slow/wedged app)
    // on EVERY Tier 1 write, including the common, unaffected, non-retried
    // path this plan's own goals require to stay byte-identical. The `if`
    // below is what makes the skip real.
    if requireFocusedElementMatch {
      guard
        mayCommitAccessibilityWrite(
          requireFocusedElementMatch: true,
          isFocused: freshFocusedElement(matching: element) != nil)
      else {
        return .declined(.focusUnconfirmed, settability: settability)
      }
    }

    // Insert at cursor via kAXSelectedTextAttribute.
    let err = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFTypeRef
    )
    guard err == .success else { return .declined(.setFailed, settability: settability) }

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
    // The after-read is held to the same exact length as the before-image: a
    // truncated read that happens to match a truncated before-image is not proof
    // that nothing changed, and this value is what AUTHORISES a second paste.
    let fieldUnchanged = countAfter.flatMap { after -> Bool? in
      guard after == countBefore else { return false }
      if after == 0 { return fieldBefore.isEmpty }
      guard let read = string(of: element, at: 0, length: after),
        read.utf16.count == after
      else { return nil }
      return stringsHaveIdenticalUTF16(read, fieldBefore)
    }

    let outcome = classifyInsertOutcome(
      AXInsertProbe(
        insertedUTF16Length: insertedLength,
        selectionLengthBefore: selectionLength,
        countBefore: countBefore,
        countAfter: countAfter,
        readBackMatched: readBackMatched,
        fieldUnchanged: fieldUnchanged
      ))
    // The write was attempted with this payload, whatever the verification says
    // afterwards — including an outcome later classified `unverifiable`, where
    // the text may already be in the document.
    return AXInsertResult(
      outcome: outcome,
      submitted: payload.kind,
      declineReason: Self.declineReason(for: outcome),
      settability: settability
    )
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
  /// Per-element cap on accessibility messaging while probing a foreign app's
  /// menu bar. One second, unchanged from what the retired `"AXTimeout"` write
  /// intended; the difference is that this one takes effect.
  private static let menuProbeAXTimeout: Float = 1.0

  public enum MenuItemProbeResult {
    case found(AXUIElement)
    case confirmedAbsent
    /// The bounded traversal reached its depth limit with children it never
    /// opened. Distinct from `.unreadable` (an AX read FAILED) and from
    /// `.confirmedAbsent` (we looked everywhere and there is no ⌘V item),
    /// because this one is our own limit rather than the app's answer — and
    /// because keeping it separate is what makes the alert-suppression
    /// projection in #1332 measurable instead of assumed.
    case depthLimited
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
    //
    // `AXUIElementSetMessagingTimeout` is the API for this. The retired line
    // wrote a non-existent "AXTimeout" ATTRIBUTE and discarded the result, so
    // the cap this comment promises has never actually been in force — found by
    // the chunk-1a build review, #1332. The timeout binds ONE element, so every
    // handle we message has to be bounded, not just this one.
    _ = AXUIElementSetMessagingTimeout(app, menuProbeAXTimeout)
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
  ///
  /// Returns `.depthLimited` when the bound is reached with children still
  /// unopened. THREE kinds of not-found, deliberately not collapsed: the app
  /// answered and there is none (`.confirmedAbsent`), a read failed
  /// (`.unreadable`), or we stopped first (`.depthLimited`). Only the first is
  /// evidence, and #1332's alert suppression is allowed to rely on it alone.
  @MainActor
  private static func firstPasteItem(in element: AXUIElement, depth: Int) -> MenuItemProbeResult {
    // Descendant handles do NOT inherit an ancestor's messaging timeout.
    _ = AXUIElementSetMessagingTimeout(element, menuProbeAXTimeout)

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

    // menu bar(0) → menu-bar-item(1) → menu(2) → menu-item(3); allow a little
    // slack for apps that nest an extra group, but stay bounded.
    //
    // The bound is read AFTER the children, because the two answers it has to
    // separate are "nothing left to look at" and "more to look at, and I
    // stopped". Returning `.confirmedAbsent` for both is a fail-OPEN in the one
    // function whose job is to tell confirmed from unknown: an app nesting its
    // Paste command deeper than this would be reported as having none
    // (#1332, Codex grounded review r2).
    guard depth <= 4 else {
      return children.isEmpty ? .confirmedAbsent : .depthLimited
    }

    var encounteredUnreadableBranch = false
    var encounteredDepthLimit = false
    for child in children {
      _ = AXUIElementSetMessagingTimeout(child, menuProbeAXTimeout)
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
      case .depthLimited: encounteredDepthLimit = true
      case .unreadable: encounteredUnreadableBranch = true
      }
    }
    // A failed READ outranks a self-imposed limit: if any branch was unreadable
    // the whole answer is unknown for the stronger reason, and collapsing the
    // two would lose that.
    if encounteredUnreadableBranch { return .unreadable }
    return encounteredDepthLimit ? .depthLimited : .confirmedAbsent
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

  /// Return keyboard focus to a specific field captured earlier (#2087).
  ///
  /// Activating the app alone puts the caret wherever that app last left it,
  /// which after a cancel is often a different field than the one the user was
  /// dictating into. `captureFocusedElement` already stamped a 1-second
  /// `AXTimeout` on this handle, so a dead or wedged element fails fast here
  /// rather than hanging the press.
  ///
  /// Best effort by contract: the field may be gone, the window closed, or the
  /// app quit. Returns whether focus was accepted so a caller can tell the two
  /// apart; nothing downstream should REQUIRE it, because an app-only target is
  /// a normal, documented case.
  @discardableResult
  public static func focusElement(_ element: AXUIElement) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    return AXUIElementSetAttributeValue(
      element,
      kAXFocusedAttribute as CFString,
      true as CFTypeRef
    ) == .success
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
