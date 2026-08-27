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

    // MARK: The clipboard fallback's own refusals (#2465)
    //
    // Six members, and every one of them names a state in which the guarded synthetic Copy was NOT
    // attempted or did not answer. They live on this set rather than on a second one for the reason
    // the doc above gives: the panel line and `refuse_reason` are one slot, and a second enum would
    // be two vocabularies for one question.
    //
    // **`SelectionReader` produces none of them**, the same way it produces neither
    // `wordsUnavailable` nor `nothingSelected`. Their producer is `SelectionAcquisition` in
    // Pipeline, which composes this reader with a clipboard transaction. That boundary is asserted
    // rather than assumed — `noReadOutcomeIsAnAcquisitionRefusal` requires every reader path to
    // stay out of them.

    /// macOS is in secure input mode, so keystrokes are not ours to synthesize.
    ///
    /// Process-wide rather than a property of an element: something on the machine has taken secure
    /// input, and posting a chord into it is exactly what that mode exists to prevent.
    case secureInputActive = "secure_input_active"
    /// The user's own shortcut modifiers never came up, so a Copy chord would land under them.
    ///
    /// Retryable, and the only one of these six that resolves itself: it means the shortcut is
    /// still physically held. Quick Add fires on key-DOWN, so this is a real state rather than a
    /// theoretical one.
    case modifiersHeld = "modifiers_held"
    /// The Copy was posted and the app never answered.
    ///
    /// **Replaces nothing.** `nothingSelected` still means the honest empty case, where the read
    /// succeeded and there was nothing highlighted. This one means we asked twice, by two
    /// mechanisms, and the second one also declined.
    case copyRefused = "copy_refused"
    /// macOS has not authorised this app to POST events.
    ///
    /// **Distinct from `accessibilityNotTrusted`, and the distinction is not pedantic.** Posting is
    /// gated by `CGPreflightPostEventAccess`, which is a different grant from the Accessibility one
    /// we already hold to READ. Inferring one from the other is how a user ends up told to turn on a
    /// permission that is already on.
    case eventPostingNotTrusted = "event_posting_not_trusted"
    /// The clipboard is too large to preserve within budget, so we decline rather than risk it.
    ///
    /// The one member of this six that cannot be decided before the copy is attempted, because it
    /// is a property of the payload rather than of the machine.
    case clipboardTooLarge = "clipboard_too_large"
    /// The clipboard fallback is off, by the user's setting or by the remote-desktop denylist.
    case copyFallbackDisabled = "copy_fallback_disabled"
    /// The application the read was taken from is no longer at the process we remembered.
    ///
    /// **Its own member rather than folded into `copyRefused`, and the seventh in a plan that
    /// enumerated six.** It is reachable mainly from the menu-bar door, which can sit open long
    /// enough for the target to quit and its pid to be recycled — and a recycled pid belongs to a
    /// stranger, so "it did not answer" would be a sentence about the wrong process. Distinct in
    /// telemetry too, because it is the verdict one Live UAT case exists to produce.
    case targetApplicationGone = "target_application_gone"
  }

  /// Everything the acquisition ladder needs about the application a read was taken from, FROM THE
  /// SAME SAMPLE that read used (#2465).
  ///
  /// **The single most important property in this file's new surface.** `Frontmost` below exists
  /// because taking the pid in one place and the identity one call later described two different
  /// applications — cloud review found it on PR #2428. A ladder one layer up that re-asks
  /// `NSWorkspace.shared.frontmostApplication` for a pid to post a Copy chord at recreates that
  /// exact defect, and it would post the chord at whatever came forward in between.
  ///
  /// So the pid is HANDED OUT with the read rather than re-derived, and nothing downstream samples
  /// the workspace again.
  public struct AcquisitionContext: Equatable, Sendable {
    /// The process the read was taken from. Nil when nothing was frontmost, which is a refusal the
    /// read already returned.
    public let pid: pid_t?
    /// That same application's bundle identifier, from the same `NSRunningApplication`.
    ///
    /// Two consumers: the remote-desktop denylist, and the menu-bar door's re-check that the
    /// remembered pid still carries the identifier it was sampled with. A menu can sit open long
    /// enough for a pid to be recycled.
    public let bundleIdentifier: String?
    /// The focused element's Accessibility subrole, when one was read.
    ///
    /// **Read only where it is about to be used**, which is why it is optional for two different
    /// reasons: the element may not advertise one, and we may not have asked. See
    /// `SubroleSampling` below — this costs a third Accessibility operation, and the success path
    /// does not pay it.
    public let focusedSubrole: String?

    public init(pid: pid_t?, bundleIdentifier: String?, focusedSubrole: String?) {
      self.pid = pid
      self.bundleIdentifier = bundleIdentifier
      self.focusedSubrole = focusedSubrole
    }

    /// Whether the focused element is a secure text field.
    ///
    /// A SECOND guard behind `IsSecureEventInputEnabled`, not a replacement for it. Secure input
    /// mode is the real protection and is process-wide; this catches a password field in an app
    /// that never enabled it. The cost of being wrong here is a password on the clipboard, which is
    /// the one outcome in this whole feature worth a redundant check.
    public var focusedElementIsSecure: Bool {
      focusedSubrole == (kAXSecureTextFieldSubrole as String)
    }
  }

  /// Whether a read should also sample the focused element's subrole.
  ///
  /// **An explicit parameter with no default, because a defaulted argument is how a capability
  /// becomes unreachable to a grep** (`validation-discipline.md`, the silent-empty table's last
  /// row). Both call sites say which they want.
  enum SubroleSampling {
    /// `read(timeout:)`. Two Accessibility operations, exactly as documented, unchanged.
    case skip
    /// `readForAcquisition(timeout:)`. A THIRD operation, on the focused handle we already hold and
    /// already bounded, and only on the outcomes the fallback can act on. A successful read pays
    /// nothing, so the menu's documented worst case is unchanged for the case it renders from.
    case whenFallbackEligible
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
  /// `timeout` bounds EACH Accessibility operation, in seconds. Nil keeps the system default.
  ///
  /// **PER OPERATION, not per call.** This makes two round trips — the focused-element lookup and
  /// the selected-text read — so the worst case a caller should plan for is TWICE this value. An
  /// earlier version's comment claimed it bounded how long the menu waits; it did not.
  ///
  /// **Zero is refused rather than honoured.** Accessibility reads a zero messaging timeout as
  /// "use the system default", so `timeout: 0` would REMOVE the bound rather than tighten it — the
  /// most obviously safe number producing the least safe behaviour.
  ///
  /// **A caller that must not block passes one.** The menu-bar door renders inside
  /// `menuNeedsUpdate`, which AppKit requires to be synchronous — so a frontmost application whose
  /// Accessibility provider stalls would hold the main actor and the menu simply would not open.
  /// The default is far longer than a menu can wait.
  @MainActor
  public static func read(timeout: Float? = nil) -> Result {
    performRead(timeout: timeout, subrole: .skip).result
  }

  /// The same read, handing back the sample it was taken from (#2465).
  ///
  /// **Side-effect free, exactly like `read`.** It touches no clipboard, posts no event and makes no
  /// decision about a fallback. The only thing it adds is that the caller learns WHICH application
  /// answered, from the sample the read itself used, so a ladder one layer up never has to ask the
  /// workspace a second time. See `AcquisitionContext`.
  ///
  /// **Three Accessibility operations in the fallback-eligible cases, two otherwise.** The subrole
  /// is read off the focused handle this call already holds and already bounded, and only where
  /// something is about to act on it.
  @MainActor
  public static func readForAcquisition(
    timeout: Float? = nil
  ) -> (result: Result, context: AcquisitionContext) {
    performRead(timeout: timeout, subrole: .whenFallbackEligible)
  }

  /// The one live read both entry points share.
  ///
  /// **One implementation rather than two, deliberately.** A second copy is how the two doors come
  /// to disagree about the timeout, the ordering of the guards, or which pid the element read used
  /// — which is the class `classify` was extracted to close one level down.
  @MainActor
  private static func performRead(
    timeout: Float?,
    subrole: SubroleSampling
  ) -> (result: Result, context: AcquisitionContext) {
    precondition(timeout.map { $0 > 0 } ?? true, "a zero or negative AX timeout removes the bound")
    // Frontmost is read here rather than inside the check because it is the LIVE half. Current
    // because this runs on the main run loop from a hotkey or a Service, with events flowing;
    // `NSWorkspace.frontmostApplication` is stale only where nothing is pumping the run loop, which
    // is not a state this entry point can be called from.
    let frontmost = Frontmost.current()

    // Built once, from that one sample, and carried by EVERY return below including the refusals.
    // A caller that only learns the application on success cannot re-check it later without taking
    // a second sample, which is the defect this type exists to prevent.
    let sampled = AcquisitionContext(
      pid: frontmost.pid, bundleIdentifier: frontmost.bundleIdentifier, focusedSubrole: nil)

    if let refusal = refusalBeforeReading(isTrusted: AXIsProcessTrusted(), frontmost: frontmost) {
      return (.refused(refusal), sampled)
    }
    // Safe: `refusalBeforeReading` returns non-nil for a nil or non-positive pid. The pid used for
    // the element read is the SAME sample the guard judged, so the refusal and the read can never
    // describe two different applications.
    guard let pid = frontmost.pid else { return (.refused(.noFocusedElement), sampled) }

    // **Handed to the query rather than set here.** `focusedElement` creates its OWN application
    // element, so a timeout set on a handle made here reaches nothing — it did not, and the line
    // that tried is gone. The parameter has existed all along.
    //
    // **Three outcomes, and they are three different sentences to the user.** A failed or timed-out
    // query is NOT an app that has nothing focused: telling someone to click into the text cannot
    // help when the provider never answered. The distinction only started mattering when this read
    // gained a cap, which makes the timeout branch the likely one. Cloud review, PR #2427.
    let focusedOutcome =
      timeout.map({ PasteService.focusedElement(pid: pid, messagingTimeout: Double($0)) })
      ?? PasteService.focusedElement(pid: pid)

    let focused: AXUIElement
    if case .element(let element) = focusedOutcome {
      focused = element
    } else {
      // Safe: `refusalForFocusedElement` returns non-nil for every non-element outcome.
      return (.refused(refusalForFocusedElement(focusedOutcome) ?? .unreadable), sampled)
    }

    // **And bound the FOCUSED handle separately, because a descendant does not inherit one.** This
    // repo learned that in #1332 and wrote it down twice — `PasteService.firstPasteItem`:
    // "Descendant handles do NOT inherit an ancestor's messaging timeout", and `findPasteMenuItem`:
    // "The timeout binds ONE element, so every handle we message has to be bounded, not just this
    // one."
    //
    // Bounding only the application is the shape that LOOKS bounded: the app answers the focused
    // query promptly, and then the attribute read below — the call that actually stalls — runs
    // against a handle nothing capped.
    if let timeout { AXUIElementSetMessagingTimeout(focused, timeout) }

    var valueRef: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &valueRef)

    // The raw CF value is handed on UNERASED. `valueRef as? String` here would turn "the attribute
    // answered with something that is not a string" into `nil`, which reads as "nothing selected" —
    // and it would do it in the one function no test can reach.
    let result = resolve(error: error, value: valueRef)

    // **The third operation, and only where something will act on it.** `isFallbackEligible` is the
    // same predicate the ladder branches on, asked HERE so the subrole comes off the handle this
    // call already holds — a second read would need a second focused-element lookup, which is a
    // second sample of exactly the kind this whole type refuses.
    guard subrole == .whenFallbackEligible, isFallbackEligible(result) else {
      return (result, sampled)
    }
    var subroleRef: CFTypeRef?
    let subroleError = AXUIElementCopyAttributeValue(
      focused, kAXSubroleAttribute as CFString, &subroleRef)
    // A missing subrole is the ORDINARY case, not a failure: plenty of elements advertise none.
    // Type-checked before the cast for the same reason the selection is — an attribute answering
    // with a number is a broken element, and `as? String` would report it as "no subrole".
    let focusedSubrole: String? = {
      guard subroleError == .success, let subroleRef,
        CFGetTypeID(subroleRef) == CFStringGetTypeID()
      else { return nil }
      return subroleRef as? String
    }()

    return (
      result,
      AcquisitionContext(
        pid: sampled.pid, bundleIdentifier: sampled.bundleIdentifier,
        focusedSubrole: focusedSubrole)
    )
  }

  /// Whether an outcome is one the clipboard fallback may act on (#2465).
  ///
  /// **Three, and every other outcome is terminal because asking a second time cannot help.** A
  /// missing Accessibility grant, our own app being in front, a selection past the store's ceiling,
  /// an unreadable answer: none of those becomes true because we posted a Copy. These three are the
  /// shapes an app takes when it HAS a selection on screen and publishes nothing usable — the
  /// measured WhatsApp case answers `.success` with `""`, and a terminal answers `noValue`.
  ///
  /// Lives here, beside `resolve`, rather than in the ladder: it is a statement about what an
  /// Accessibility answer MEANS, which is this file's job, and the ladder that consumes it is one
  /// module up.
  public static func isFallbackEligible(_ result: Result) -> Bool {
    switch result {
    case .noSelection:
      return true
    case .refused(let why):
      switch why {
      case .selectionUnsupported, .selectionUnavailable:
        return true
      // Enumerated rather than defaulted, so adding a member forces the question to be answered
      // here too. A `default` would silently make every future refusal terminal, which is the safe
      // direction and still the wrong way to decide it.
      case .accessibilityNotTrusted, .noFrontmostApplication, .noFocusedElement, .ownApplication,
        .unreadable, .selectionTooLong, .wordsUnavailable, .nothingSelected, .secureInputActive,
        .modifiersHeld, .copyRefused, .eventPostingNotTrusted, .clipboardTooLarge,
        .copyFallbackDisabled, .targetApplicationGone:
        return false
      }
    case .text:
      return false
    }
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
    /// That same application's bundle identifier, nil when it has none to report.
    ///
    /// **Stored rather than reduced to a Bool at the sample site (#2465).** `isOurs` used to be the
    /// stored value, which was enough while the only question was "is this us". The acquisition
    /// ladder asks two more — is this a remote-desktop client, and does the pid a menu remembered
    /// still carry the identifier it was sampled with — and answering either from a second sample
    /// is the defect this type was created to close. One string, every predicate derived from it,
    /// so two answers about one application cannot disagree.
    let bundleIdentifier: String?

    /// Whether that same application is one of ours, by `AppBundleIdentity`.
    ///
    /// Derived, never stored: a stored copy is a second value that can drift from the identifier it
    /// was supposed to summarise.
    var isOurs: Bool { AppBundleIdentity.isOurs(bundleIdentifier) }

    /// The live read: one `NSRunningApplication`, both facts taken off it.
    ///
    /// The only member of this file that touches the workspace, so it is the only thing a test
    /// cannot reach — and all it does is sample once. Everything that DECIDES anything is pure.
    @MainActor
    static func current() -> Frontmost {
      let app = NSWorkspace.shared.frontmostApplication
      return Frontmost(pid: app?.processIdentifier, bundleIdentifier: app?.bundleIdentifier)
    }
  }

  // MARK: - The decisions, which are pure

  /// Which refusal a focused-element outcome becomes, or nil when there is an element to read.
  ///
  /// **Pure and separate from `read()` for the reason the guard below is: otherwise no test can
  /// reach it.** The distinction it draws is the whole of PR #2427's second finding — a query that
  /// FAILED or timed out is not an app with nothing focused, and telling the user to click into the
  /// text cannot help when the provider never answered.
  static func refusalForFocusedElement(_ outcome: PasteService.FocusedElement) -> Refusal? {
    switch outcome {
    case .element: return nil
    case .none: return .noFocusedElement
    case .queryFailed: return .unreadable
    }
  }

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
