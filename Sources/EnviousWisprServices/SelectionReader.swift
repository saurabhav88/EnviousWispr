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
    /// **EnviousWispr is the frontmost application, so there is nothing of the user's to read
    /// (#2413).**
    ///
    /// Reachable because the shortcut is GLOBAL and our own Settings window has text fields: press
    /// it while editing a custom word and, without this, the reader hands back the half-typed edit
    /// as a word to add.
    ///
    /// **Named for what is CHECKED, not for what is assumed.** An earlier version called this
    /// `ownSelection` and its copy said "That selection is inside EnviousWispr" — but nothing here
    /// reads a selection, and a caret in an empty field of ours produces this refusal too. Asserting
    /// a selection the code never looked at is the false-sentence class this guard exists to stop,
    /// committed inside the guard itself.
    ///
    /// Its own member rather than `nothingSelected` because the causes differ and so does the fix:
    /// this one is "you are in our app", which names no fault of the user's and has one remedy.
    case ownApplication = "own_application"
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
    /// The saved words could not be re-read, so there is nothing trustworthy to rank against.
    ///
    /// **The one member `SelectionReader` itself never produces**, and that is deliberate rather
    /// than sloppy. This set is the panel's one reason line AND the telemetry `refuse_reason`, and
    /// there is one of each — so the set is "why the panel has nothing to rank", which has two
    /// producers. Splitting it would give the same slot two enums to reconcile. The boundary is
    /// asserted instead of assumed: `noReadOutcomeIsWordsUnavailable` requires every reader path to
    /// stay out of this case.
    case wordsUnavailable = "words_unavailable"
    /// The read SUCCEEDED and the user had selected nothing. The ordinary case, not a fault.
    ///
    /// **The second member `SelectionReader` never produces, for the same reason as the one above**
    /// — this set is the panel's reason line and the telemetry `refuse_reason`, and there is one of
    /// each — but it is worth its own entry because of what it replaced. `.noSelection` used to be
    /// mapped onto `selectionUnavailable`, whose sentence names TERMINALS and accuses the frontmost
    /// app of withholding a selection. Pressing the shortcut in TextEdit having highlighted nothing
    /// is the most likely way to reach a refusal at all, and it got a confident diagnosis of an app
    /// that had done nothing wrong, instead of "select a word first".
    ///
    /// Two states, one slot, and the collapse pointed at the accusatory member: exactly the
    /// three-valued shape `validation-discipline` describes, where the unhandled input lands in a
    /// neighbouring branch and inherits a claim that was never about it.
    case nothingSelected = "nothing_selected"
  }

  /// The longest selection worth reading, in Unicode scalars.
  ///
  /// Not a number invented here: it is the store's own ceiling
  /// (`CustomWordsImportLimits.maximumStoredValueScalars`), so anything past it could never be
  /// saved and a panel offering it would be confidently wrong. It is also a real bound on work —
  /// the scorer's edit distance builds an (m+1)x(n+1) matrix PER CANDIDATE, so a document-sized
  /// selection against a few hundred words is not a slow ranking, it is a frozen app.
  public static var maximumSelectionScalars: Int {
    CustomWordsImportLimits.maximumStoredValueScalars
  }

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
    let frontmost = Frontmost.current()

    if let refusal = refusalBeforeReading(isTrusted: AXIsProcessTrusted(), frontmost: frontmost) {
      return .refused(refusal)
    }
    // Safe: `refusalBeforeReading` returns non-nil for a nil or non-positive pid. The pid used for
    // the element read is the SAME sample the guard judged, so the refusal and the read can never
    // describe two different applications.
    guard let pid = frontmost.pid, let focused = PasteService.focusedElementQuery(pid: pid) else {
      return .refused(.noFocusedElement)
    }

    var valueRef: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &valueRef)

    // The raw CF value is handed on UNERASED. `valueRef as? String` here would turn "the attribute
    // answered with something that is not a string" into `nil`, which reads as "nothing selected" —
    // and it would do it in the one function no test can reach.
    return resolve(error: error, value: valueRef)
  }

  // MARK: - The frontmost application, sampled ONCE

  /// Everything the guard needs to know about the frontmost application, from ONE sample.
  ///
  /// **A type rather than two parameters, because two parameters is exactly how this went wrong.**
  /// The pid was read in `read()` and the bundle identity in a DEFAULT ARGUMENT one call later —
  /// two reads of a mutable global at two moments, which a switch in between makes describe two
  /// different applications. Found by cloud review on PR #2428, one round after the identity check
  /// itself was wrong.
  ///
  /// The previous version of this file documented a window here as a known limit. That note was
  /// about a DIFFERENT gap (refusal versus element read) and, worse, it made an unclosable window
  /// the story while this closable one sat under it.
  struct Frontmost: Equatable {
    /// nil when nothing is frontmost, which is a refusal rather than a fact about us.
    let pid: pid_t?
    /// Whether that same application is one of ours, by `AppBundleIdentity`.
    let isOurs: Bool

    /// The live read: one `NSRunningApplication`, both facts taken off it.
    ///
    /// The only member of this file that touches the workspace, so it is the only thing a test
    /// cannot reach — and all it does is sample once. Everything that DECIDES anything is pure.
    @MainActor
    static func current() -> Frontmost {
      let app = NSWorkspace.shared.frontmostApplication
      return Frontmost(pid: app?.processIdentifier, isOurs: AppBundleIdentity.isOurs(app?.bundleIdentifier))
    }
  }

  // MARK: - The decisions, which are pure

  /// Why a read cannot even be attempted, or nil to go ahead.
  ///
  /// Split from `read()` so both refusals are reachable from a test. Trust and frontmost are asked
  /// together because they are the two questions with no Accessibility round trip behind them; the
  /// element read has its own function below rather than four optionals in one.
  ///
  /// **No default for `frontmost`, deliberately.** It carried a live `NSWorkspace` read until cloud
  /// review found that this made a SECOND sample, one call after `read()` took the first. A default
  /// that reaches out to a mutable global is a second sample waiting for a caller who omits it.
  static func refusalBeforeReading(
    isTrusted: Bool,
    frontmost: Frontmost,
    ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
  ) -> Refusal? {
    guard isTrusted else { return .accessibilityNotTrusted }
    guard let frontmostPID = frontmost.pid, frontmostPID > 0 else {
      return .noFrontmostApplication
    }
    // **Refuse our own app (#2413), and no ordering discipline can replace this.** The two comments
    // in this file and in `QuickAddCoordinator.begin` say to read BEFORE activating ourselves, which
    // is right and is what makes the ordinary case work. It cannot help when the user is ALREADY
    // inside our app when they press the shortcut — the binding is global, our Settings window has
    // text fields, and there is no "before" in which another application is frontmost.
    //
    // `ownPID` is a parameter with a live default so the decision is reachable from a test; the
    // production call site never passes it.
    // **Identity, not just this process, and identity is a FAMILY rather than a string.** A second
    // EnviousWispr — an installed release build beside a dev build — has a different pid, so a
    // pid-only check reads its text. That is the ordinary state of a development machine.
    //
    // The first version of this guard compared against `Bundle.main.bundleIdentifier`, which is
    // `.dev` in a dev build and not in a release one, so it answered NOT OURS for precisely the
    // pair it was written to catch. `AppBundleIdentity` owns the closed set; the pid comparison
    // stays for the case where there is no identifier to read at all.
    guard frontmostPID != ownPID, !frontmost.isOurs else { return .ownApplication }

    // **What remains, now that both facts come from one sample.** The guard judges a snapshot and
    // the element read uses that snapshot's own pid, so the two cannot describe different
    // applications. A switch between the sample and the read still means the pid names an
    // application that is no longer frontmost — but it is the SAME application throughout, and
    // Accessibility answers for the process rather than for whoever is in front, so the read stays
    // about the selection the user made. Closing that too would mean asking the workspace to hold
    // still, which it does not offer.
    return nil
  }

  /// Map one Accessibility answer onto what the user is told.
  ///
  /// Separated from the round trip so every branch is reachable from a test without fabricating an
  /// `AXUIElement`. Only `noFocusedElement` stays untested by construction: it is one guard over a
  /// live AX call whose result cannot be produced without a real element, and Live UAT covers it.
  static func resolve(error: AXError, value: CFTypeRef?) -> Result {
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

    // A successful read with no value is the same fact as `noValue` from the user's side: nothing
    // was selected. It reaches here rather than the refusal branch because the attribute answered.
    guard let value else { return .noSelection }

    // Type-checked before the cast, the same way `PasteService.focusedElementQuery` validates the
    // element it is handed. An attribute answering with a number or a boolean is a broken element,
    // not an empty selection, and `as? String` alone would collapse the two into `noSelection`.
    guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else {
      return .refused(.unreadable)
    }

    return classify(text)
  }

  /// What a candidate selection IS, independent of where it came from.
  ///
  /// **Extracted so the two doors cannot disagree, which they did.** Door A arrives here through
  /// `resolve`; door B is HANDED text by the Services system and reached the coordinator as
  /// `.text(raw)` with none of this applied — so a whitespace-only Service selection opened a panel
  /// on an empty string with no stated reason, and an oversized one bypassed the ceiling entirely
  /// and went to the scorer. Anything one door validates and the other does not is a defect by
  /// construction; the fix is one function, not a second copy of three checks.
  ///
  /// TRIM FIRST, then measure. The ceiling exists to bound what gets STORED, and what gets stored is
  /// the trimmed string — so measuring the untrimmed one refuses a short word that happened to be
  /// dragged with a lot of surrounding space, and reports whitespace-only text as "too long" when
  /// the honest answer is "nothing selected".
  public static func classify(_ text: String) -> Result {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .noSelection }

    guard trimmed.unicodeScalars.count <= maximumSelectionScalars else {
      return .refused(.selectionTooLong)
    }
    return .text(trimmed)
  }
}
