import AppKit
import ApplicationServices
import EnviousWisprCore
import Foundation

/// Reads the text the user has selected in whatever app is in front (#2381).
///
/// **One Accessibility round trip, on an explicit user gesture, and nothing else.** It does not
/// observe, poll, cache, or write. The string it returns is held in memory by its caller, shown to
/// the user, and either saved to the local word library or discarded — it is never logged and never
/// leaves the machine.
///
/// The decision is split in two on purpose. `resolve` is pure and carries every branch, so the
/// mapping from what Accessibility said to what the user is told is unit-tested. `read()` performs
/// the live round trip and is proven by Live UAT, because a fabricated `AXUIElement` would test our
/// idea of Accessibility rather than Accessibility — the same split `PasteService` keeps.
public enum SelectionReader {

  /// What the user selected, or why we could not tell.
  public enum Result: Equatable, Sendable {
    /// A usable selection, already trimmed.
    case text(String)
    /// The read succeeded and there was nothing selected.
    case noSelection
    /// We could not read a selection, and the panel says which of these it was.
    case refused(Refusal)
  }

  /// Every reason a read can fail, as a closed set.
  ///
  /// Closed because it is BOTH the user-facing copy key and the telemetry `refuse_reason`, and a
  /// reason that exists in one and not the other is how a dashboard comes to disagree with what the
  /// user was told. Adding a member forces every consumer to say what it does with it.
  public enum Refusal: String, Equatable, Sendable, CaseIterable {
    /// The user has not granted Accessibility. The only refusal they can act on.
    case accessibilityNotTrusted = "accessibility_not_trusted"
    /// No application was frontmost, or it had no process to ask.
    case noFrontmostApplication = "no_frontmost_application"
    /// The frontmost application reported no focused element.
    case noFocusedElement = "no_focused_element"
    /// The focused element does not expose selected text at all (`kAXErrorAttributeUnsupported`).
    case selectionUnsupported = "selection_unsupported"
    /// The attribute is advertised but answered with no value (`kAXErrorNoValue`).
    ///
    /// Kept apart from `selectionUnsupported` because it is the TERMINAL case and it lies: measured
    /// in Ghostty with text visibly highlighted, the attribute is listed in the element's attribute
    /// names and still answers `-25212` with a zero-length range. Collapsing the two would hide
    /// that a whole class of app reports a selection it will not hand over.
    case selectionUnavailable = "selection_unavailable"
    /// Any other Accessibility error.
    case unreadable = "unreadable"
    /// A selection too long to be stored as a word, so reading it further cannot help.
    case selectionTooLong = "selection_too_long"
  }

  /// The longest selection worth reading, in Unicode scalars.
  ///
  /// Not a number invented here: it is the store's own ceiling
  /// (`CustomWordsImportLimits.maximumStoredValueScalars`), so anything past it could never be
  /// saved and a panel offering it would be confidently wrong. It is also a real bound on work —
  /// the scorer's edit distance builds an (m+1)x(n+1) matrix PER CANDIDATE, so a document-sized
  /// selection against a few hundred words is not a slow ranking, it is a frozen app.
  public static var maximumSelectionScalars: Int { CustomWordsImportLimits.maximumStoredValueScalars }

  // MARK: - The live read

  /// Read the selection from the frontmost application.
  ///
  /// **Call this BEFORE activating our own app**, or the frontmost application is us and the answer
  /// is about our own window.
  ///
  /// Per-application, never system-wide: `AXUIElementCreateSystemWide()` can answer for a different
  /// process than the one the user is looking at, and the whole point here is to read the app they
  /// just made a selection in.
  @MainActor
  public static func read() -> Result {
    // Frontmost is read here rather than inside the check because it is the LIVE half. Current
    // because this runs on the main run loop from a hotkey or a Service, with events flowing;
    // `NSWorkspace.frontmostApplication` is stale only where nothing is pumping the run loop, which
    // is not a state this entry point can be called from.
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier

    if let refusal = refusalBeforeReading(isTrusted: AXIsProcessTrusted(), frontmostPID: frontmost) {
      return .refused(refusal)
    }
    // Safe: `refusalBeforeReading` returns non-nil for a nil or non-positive pid.
    guard let pid = frontmost, let focused = PasteService.focusedElementQuery(pid: pid) else {
      return .refused(.noFocusedElement)
    }

    var valueRef: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &valueRef)

    return resolve(error: error, value: valueRef as? String)
  }

  // MARK: - The decisions, which are pure

  /// Why a read cannot even be attempted, or nil to go ahead.
  ///
  /// Split from `read()` so both refusals are reachable from a test. Trust and frontmost are asked
  /// together because they are the two questions with no Accessibility round trip behind them; the
  /// element read has its own function below rather than four optionals in one.
  static func refusalBeforeReading(isTrusted: Bool, frontmostPID: pid_t?) -> Refusal? {
    guard isTrusted else { return .accessibilityNotTrusted }
    guard let frontmostPID, frontmostPID > 0 else { return .noFrontmostApplication }
    return nil
  }

  /// Map one Accessibility answer onto what the user is told.
  ///
  /// Separated from the round trip so every branch is reachable from a test without fabricating an
  /// `AXUIElement`. Only `noFocusedElement` stays untested by construction: it is one guard over a
  /// live AX call whose result cannot be produced without a real element, and Live UAT covers it.
  static func resolve(error: AXError, value: String?) -> Result {
    switch error {
    case .success:
      break
    case .attributeUnsupported:
      return .refused(.selectionUnsupported)
    case .noValue:
      return .refused(.selectionUnavailable)
    default:
      return .refused(.unreadable)
    }

    // A successful read with no string is the same fact as `noValue` from the user's side: nothing
    // was selected. It reaches here rather than the refusal branch because the attribute answered.
    guard let value else { return .noSelection }

    guard value.unicodeScalars.count <= maximumSelectionScalars else {
      return .refused(.selectionTooLong)
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? .noSelection : .text(trimmed)
  }
}
