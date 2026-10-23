import AppKit
import Carbon.HIToolbox
import CoreGraphics
import EnviousWisprCore
import EnviousWisprServices

/// Gets the word the user highlighted, falling back to a guarded synthetic Copy when the app
/// publishes no selection (#2465).
///
/// **The problem, in one line.** WhatsApp highlights a word on screen and tells the rest of the Mac
/// that nothing is selected. It is an iPad app ported to the Mac, the focused element is the compose
/// field rather than the bubble, and a full window walk found every `AXSelectedText` empty and every
/// `AXSelectedTextRange` at zero. There is no Accessibility route to it, proven by exhaustion in the
/// issue and independently by two web-grounded models.
///
/// **The issue also names TERMINALS as a member of this class, and Live UAT on 2026-08-27 falsified
/// that for the one on this machine:** ghostty with a word selected answers through Accessibility,
/// `acquired=ax`, clipboard untouched. The #2381 measurement (a terminal advertising
/// `AXSelectedText` and answering `kAXErrorNoValue`) was real when taken and is not true of that
/// build now. So this ladder is a safety net for terminals rather than the mechanism that fixes
/// them — worth knowing before anyone cites terminals as the reason it exists.
///
/// **Why this lives in Pipeline and not in `SelectionReader`.** It cannot live there: the reader is
/// in `EnviousWisprServices`, whose dependencies are Core and ObservabilityCore and nothing else
/// (`Package.swift`), and `ClipboardCleanup` is here in Pipeline, which depends ON Services.
///
/// **Two separate mechanisms say no, and they are named separately on purpose.** Under SwiftPM the
/// import does not resolve, so it is a compiler failure. `scripts/check-dependency-direction.sh` is
/// a second gate at push time. Merging them into one sentence would be the comment shape that
/// retires a check instead of failing it — and it would be wrong in a way that matters, because the
/// Xcode build shares one build-products search path, so a declared edge there ORDERS the link
/// rather than gating imports (measured by the #2455 session, 2026-08-26, which is why that script
/// now scans `Tests/` too).
///
/// `architecture-rules.md` FACT: dependency-direction settles it twice over on top of that: the
/// Features layer must not own the clipboard, and this layer is the one that owns sequencing,
/// fallback contracts and telemetry, which is exactly what a ladder is.
///
/// **What it owns: acquisition, and nothing else.** No ranking, no panel state, no word storage. The
/// reader still decides what an Accessibility answer MEANS and `ClipboardCleanup` still owns the
/// clipboard's lifecycle; this composes the two and adds the guards that bound a synthetic keystroke.
///
/// **The three things that will bite an editor**, all of them measured rather than reasoned:
///
/// 1. The chord must be bracketed by explicit `flagsChanged` events or Command latches down
///    machine-wide. `SyntheticCopyChord` owns that; do not post from here.
/// 2. **Once the takeover is granted, EVERY exit restores.** Cancelling the pending cleanup means
///    nothing else will ever put the user's clipboard back, so an early return between the takeover
///    and the restore strands our own dictation payload on their board and destroys what they had
///    copied — strictly worse than never having attempted the fallback. Enforced structurally: after
///    the takeover there is exactly one `return` shape, `concluding(...)`, and it is the only site
///    that calls `restoreClipboard`.
/// 3. **Never resample the frontmost application.** The pid the chord is aimed at comes from the
///    same sample the read used. `SelectionReader.Frontmost` exists because taking the pid in one
///    place and the identity one call later described two different applications, found by cloud
///    review on PR #2428; asking `NSWorkspace` again here recreates that defect one layer up and
///    posts a keystroke at whatever came forward in between.
///
/// **AND ONE DEFECT CLASS. THE FIRST ATTEMPT TO NAME IT WAS A FALSE CONSOLIDATION, WHICH IS THE
/// PART WORTH KEEPING.**
///
/// Two local review rounds each returned one finding, so the rule is to stop taking rounds and
/// enumerate the class instead. The first enumeration named it "a value has more states at its
/// producer than at the caller reading it" and listed nine members, derived by grepping this file
/// and `SyntheticCopyChord` for reduced return values.
///
/// **A refutation run — a reviewer asked to name an AXIS rather than a member — refuted it, and was
/// right on both counts.** The two originating findings are NOT the same root: the pasteboard's
/// change count is an IDENTITY inference (the producer returns a counter and the caller invents
/// authorship), while the AX subrole was a genuine STATE-COUNT reduction. They share only the much
/// wider statement that a caller assumed more than its evidence proved, which is not an enumerable
/// class. A missing axis is invisible from inside an enumeration by construction, so no amount of
/// re-reading the nine members could have produced this.
///
/// **The axes, from that run, with what each found here:**
///
/// | Axis | Here |
/// |---|---|
/// | State count | `resolveSubrole` was a real member; FIXED, fails closed |
/// | Provenance | `changeCount` proves a write happened, never WHOSE. Undecidable with public APIs; documented at the poll site, not mitigated away |
/// | Ordering | `beginTakeover` sampled the payload and its baseline at two moments; FIXED by bracketing |
/// | Correlated-value atomicity | the same site, the same fix |
/// | Lifetime | FIXED TWICE, and the second time is the lesson. The first fix re-asked the policy questions after the modifier wait and passed the same stale context, so three of four inputs were live and the fourth — the one whose failure mode is a secret on the clipboard — still answered from memory, inside a block whose comment said it was live. `focusedElementIsSecure` is now a PARAMETER, so no call site can read it off a sample without saying so, and step 2b probes the target's focus live and fails closed |
/// | Identity of INSTANCE | pid plus bundle id proves the same application KIND, not the same launch. See `targetStillPresent` |
/// | Concurrent OWNERSHIP of one resource | **the axis this table did not have.** Quick Add's takeover and a dictation delivery are two owners of one pasteboard, and the takeover registered nothing, so a delivery starting mid-fallback saw an idle `ClipboardCleanup`. Found by the confirming round; fixed by making the takeover visible, letting delivery inherit from it, and having the limb ABANDON |
/// | Exhaustive enum consumption | nothing found; every enum here is switched exhaustively |
/// | Unsafe default consumption | nothing found; the menu's missing `representedObject` collapses to a refusing empty context |
///
/// **What a further finding would have to look like, so this is falsifiable rather than hopeful:** an
/// axis not in that table. A new member on an axis already listed is an adjudication error on one
/// row, which is a smaller thing and does not reopen the enumeration.
///
/// **That prediction was then tested twice, which is the only reason any of it is worth anything,
/// and it failed the second time.** The first confirming round returned a WRONG ROW on the lifetime
/// axis — the shape a complete enumeration fails like. The next round returned a MISSING AXIS:
/// concurrent ownership of one resource, which every row above is blind to because every row above
/// is about ONE value's states, ordering or provenance rather than about two owners.
///
/// The lesson is not that the enumeration should have been longer. It is that an axis list built by
/// sweeping VALUES cannot contain an axis about RELATIONSHIPS between transactions, and the sweep
/// that produced it — grep the file for reduced returns — could not have surfaced one. A second
/// refutation run asked specifically about concurrency would have; it was not run because the first
/// one came back with four axes and that felt like enough.
@MainActor
public enum SelectionAcquisition {

  // MARK: - What happened

  /// How the text was obtained.
  ///
  /// **A support reader cannot otherwise tell a working app from one that only works because we paid
  /// for it with the user's clipboard**, and nobody can measure how large the fallback class is,
  /// which is the number the screen-context question will want.
  public enum Acquired: String, Sendable {
    /// Accessibility answered. The clipboard was never touched.
    case accessibility = "ax"
    /// The synthetic Copy answered.
    case clipboardCopy = "copy"
    /// Neither did.
    case nothing = "none"
  }

  /// What became of the user's clipboard.
  public enum ClipboardRestore: String, Sendable {
    /// Put back exactly as it was.
    case restored
    /// Declined, because something else wrote to the board while we held it. Their write survives,
    /// which is correct, and it is the one outcome a user would actually feel.
    case declined
    /// Never taken over, so there was nothing to put back.
    case notTouched = "not_touched"
    /// A dictation delivery claimed the board mid-takeover and inherited the user's clipboard, so
    /// this invocation restored nothing on purpose (#2465).
    ///
    /// Its own value rather than `declined`, because `declined` means "somebody wrote and their
    /// write survives" and this means "the heart took the board and owns putting it back". They
    /// need different answers if the fallback ever looks expensive in the funnel.
    case supersededByDelivery = "superseded_by_delivery"
  }

  /// One acquisition, as facts.
  ///
  /// **A struct rather than the enum an earlier design had**, because the panel needs the result and
  /// telemetry needs the path, the duration and the restore outcome, and an enum of three cases
  /// carries none of them. It could not even separate "refused before attempting" from "attempted
  /// and got nothing".
  public struct Outcome: Sendable {
    /// What to show the user. The same closed type both other doors produce.
    public let result: SelectionReader.Result
    /// The application this was about, from the sample the read used.
    public let context: SelectionReader.AcquisitionContext
    public let acquired: Acquired
    /// Wall-clock cost of the whole ladder, nil when no fallback was attempted.
    public let acquisitionMs: Int?
    public let clipboardRestore: ClipboardRestore
    /// How long the user's shortcut keys took to come up after the fallback started waiting for
    /// them (#2481), in whole milliseconds. Nil when no wait cleared: the fallback never reached
    /// the wait, or the keys were still held at the cap. Not the whole key hold: the wait starts a
    /// few milliseconds after the press.
    public let modifierReleaseMs: Int?
    /// What the bring-back step found (#3986). Nil when the ladder ended before that step.
    public let bringBack: BringBack?

    /// `modifierReleaseMs` and `bringBack` default to nil only for constructors outside the ladder
    /// (tests, the panel's own doors); every `Outcome` the ladder builds passes both explicitly.
    public init(
      result: SelectionReader.Result,
      context: SelectionReader.AcquisitionContext,
      acquired: Acquired,
      acquisitionMs: Int?,
      clipboardRestore: ClipboardRestore,
      modifierReleaseMs: Int? = nil,
      bringBack: BringBack? = nil
    ) {
      self.result = result
      self.context = context
      self.acquired = acquired
      self.acquisitionMs = acquisitionMs
      self.clipboardRestore = clipboardRestore
      self.modifierReleaseMs = modifierReleaseMs
      self.bringBack = bringBack
    }
  }

  /// What the bring-back step (STEP 2a) found, as `quick_add.opened` `bring_back` (#3986).
  ///
  /// A pid-targeted Copy does nothing in an app that is not in front (measured 2026-10-23: Chrome,
  /// Safari and TextEdit behind Finder copied nothing), so the step brings the sampled app back
  /// first. Measured on Chrome and Finder (2026-10-23), a status-item click keeps the user's app
  /// in front, so the menu door usually answers `not_needed`; with one of our own windows open it is
  /// not yet measured.
  public enum BringBack: String, Sendable, CaseIterable {
    /// The target was already frontmost; nothing was activated.
    case notNeeded = "not_needed"
    /// The target was brought back and observed frontmost within the deadline.
    case front
    /// The target did not come to the front within the deadline.
    case timedOut = "timed_out"
    /// The target quit, or its pid now names another application.
    case targetGone = "target_gone"
  }

  /// The live readings the ladder waits on, injected so tests drive time and keys by hand (#3986).
  ///
  /// Readings and time only, never a decision: every guard still runs on what these return.
  public struct Environment: Sendable {
    /// A monotonic reading. Waits end when THIS says the deadline passed, not after a count of
    /// sleeps: a loaded main actor makes each sleep longer than asked.
    public var now: @MainActor @Sendable () -> ContinuousClock.Instant
    /// A cancellation-aware sleep. A cancelled sleep returns early; the poll then sees
    /// `Task.isCancelled` and abandons.
    public var sleep: @MainActor @Sendable (Duration) async -> Void
    /// Whether any of Command, Shift, Option or Control is down, read from the HID state.
    public var modifiersHeld: @MainActor @Sendable () -> Bool
    /// Process-wide secure keyboard entry (`IsSecureEventInputEnabled`).
    var secureInputActive: @MainActor @Sendable () -> Bool
    /// The live subrole probe of a pid's focused element (`SelectionReader.secureFocusProbe`). The
    /// ladder decides with `SelectionReader.isSecureField`, which treats `.unreadable` as secure.
    var secureFocusProbe: @MainActor @Sendable (pid_t) -> SelectionReader.SubroleOutcome
    /// The event-posting grant (`CGPreflightPostEventAccess`).
    var postingAuthorised: @MainActor @Sendable () -> Bool
    /// Whether the sampled pid is still the application it was sampled as.
    var targetStillPresent: @MainActor @Sendable (SelectionReader.AcquisitionContext) -> Bool
    /// The virtual key for "c" on the active layout, nil when it cannot be read.
    var copyKeyCode: @MainActor @Sendable () -> CGKeyCode?
    /// The frontmost application's pid.
    var frontmostPID: @MainActor @Sendable () -> pid_t?
    /// Ask macOS to bring a pid to the front. Fire and forget; the poll is the oracle.
    var activate: @MainActor @Sendable (pid_t) -> Void
    /// Post one Copy chord at a pid. The live form is `SyntheticCopyChord.post`.
    var postCopy: @MainActor @Sendable (pid_t, CGKeyCode) -> SyntheticCopyChord.PostResult

    /// The full injected form, for tests. Every reading is injected and every guard still runs on
    /// it; nothing here can supply a decision.
    init(
      now: @escaping @MainActor @Sendable () -> ContinuousClock.Instant,
      sleep: @escaping @MainActor @Sendable (Duration) async -> Void,
      modifiersHeld: @escaping @MainActor @Sendable () -> Bool,
      secureInputActive: @escaping @MainActor @Sendable () -> Bool,
      secureFocusProbe: @escaping @MainActor @Sendable (pid_t) -> SelectionReader.SubroleOutcome,
      postingAuthorised: @escaping @MainActor @Sendable () -> Bool,
      targetStillPresent: @escaping @MainActor @Sendable (SelectionReader.AcquisitionContext) -> Bool,
      copyKeyCode: @escaping @MainActor @Sendable () -> CGKeyCode?,
      frontmostPID: @escaping @MainActor @Sendable () -> pid_t?,
      activate: @escaping @MainActor @Sendable (pid_t) -> Void,
      postCopy: @escaping @MainActor @Sendable (pid_t, CGKeyCode) -> SyntheticCopyChord.PostResult
    ) {
      self.now = now
      self.sleep = sleep
      self.modifiersHeld = modifiersHeld
      self.secureInputActive = secureInputActive
      self.secureFocusProbe = secureFocusProbe
      self.postingAuthorised = postingAuthorised
      self.targetStillPresent = targetStillPresent
      self.copyKeyCode = copyKeyCode
      self.frontmostPID = frontmostPID
      self.activate = activate
      self.postCopy = postCopy
    }

    /// The production readings.
    ///
    /// **`.hidSystemState`, not `.combinedSessionState`:** the chord this ladder posts sets and
    /// clears flags in the HID state (`SyntheticCopyChord.post`), and reading one state while the
    /// other is written is how a clear looks like it never happened.
    public static let live = Environment(
      now: { ContinuousClock.now },
      sleep: { duration in
        // A cancelled sleep returns early and every caller checks `Task.isCancelled` right after
        // it, so the cancellation is never spent as "time passed": a `try?` here followed by work
        // with no such check is the trap `ClipboardCleanup` documents, and here it would post a
        // keystroke into a cancelled invocation.
        do { try await Task.sleep(for: duration) } catch {}
      },
      modifiersHeld: {
        !CGEventSource.flagsState(.hidSystemState).isDisjoint(
          with: [.maskCommand, .maskShift, .maskAlternate, .maskControl])
      },
      secureInputActive: { IsSecureEventInputEnabled() },
      secureFocusProbe: { pid in
        SelectionReader.secureFocusProbe(pid: pid, timeout: secureProbeTimeout)
      },
      postingAuthorised: { CGPreflightPostEventAccess() },
      targetStillPresent: { SelectionAcquisition.liveTargetStillPresent($0) },
      copyKeyCode: { SyntheticCopyChord.copyKeyCode() },
      frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
      // The AX route first, as Paste Last Dictation does: macOS 14+ refuses a background process
      // the foreground through `activate()` alone, so that is only the fallback.
      activate: { pid in
        if !PasteService.forceActivateApp(pid: pid) {
          NSRunningApplication(processIdentifier: pid)?.activate()
        }
      },
      postCopy: { pid, key in SyntheticCopyChord.post(at: pid, copyKeyCode: key) })
  }

  /// How long the bring-back step waits for the target to be observed in front, and how often it
  /// looks. The same values Paste Last Dictation uses for the same wait.
  static let activationDeadline: Duration = .milliseconds(500)
  static let activationPollInterval: Duration = .milliseconds(10)

  // MARK: - Budgets
  //
  // This feature's own policy, kept here rather than in `TimingConstants`, which belongs to the
  // dictation pipeline. Quick Add is deletable as three directories and one call, and a number of
  // its left behind in a shared constants file is a piece of it that does not go.

  /// The largest clipboard worth holding in memory to preserve.
  ///
  /// Past it we decline rather than risk it, which is `clipboardTooLarge`. Eight megabytes covers a
  /// screenshot and a page of rich text several times over; a clipboard past it is a file the user
  /// would notice us copying.
  static let maximumPreservedClipboardBytes = 8 * 1024 * 1024

  /// How long to wait for the user's own shortcut modifiers to come up.
  ///
  /// **Not a theoretical state.** Quick Add fires on key DOWN, so at the moment this runs the user's
  /// chord is still physically held, and a Copy posted underneath it reaches the app as their chord
  /// plus C rather than as Command plus C.
  ///
  /// **1.5 s, argued rather than measured (#2481, CTO decision 2026-10-04).** Two populations: a
  /// deliberate three-key press lifts in a few hundred milliseconds, a stuck key stays down for
  /// seconds or more. The old 250 ms cap split the first group: the founder hit it in ordinary use
  /// (2026-08-27), and production refusals clustered at 289 to 318 ms. The wait ends the moment the
  /// keys come up, so a longer cap costs a normal press nothing. Reopen it from the
  /// `modifier_release_ms` distribution on `quick_add.opened` and the `modifiers_held` share.
  static let modifierReleaseCap: Duration = .milliseconds(1500)
  static let modifierPollIntervalMs = 8

  /// How long to give the app to answer the Copy.
  ///
  /// Measured at 37 to 49 ms in the proof of concept, on the fastest Mac we own. The cap is an order
  /// of magnitude above that because the number that matters is the slowest SUPPORTED Mac, which is
  /// not this one and cannot be calibrated here.
  static let copyAnswerCapMs = 400
  static let copyPollIntervalMs = 5

  /// After the board first moves, how long it must hold still before we read it.
  ///
  /// A pasteboard write is not atomic from a reader's side: an app writing several representations
  /// can be observed part-way. Reading on the first change is how a rich copy comes back as an empty
  /// string.
  static let copySettleMs = 20

  /// How long the live secure-field probe waits for the target, PER Accessibility operation.
  ///
  /// Short on purpose. It runs immediately before a keystroke is posted, so a stalled provider here
  /// delays a gesture the user is waiting on — and the probe FAILS CLOSED, so a timeout costs them
  /// the fallback rather than costing them a secret.
  static let secureProbeTimeout: Float = 0.15

  // MARK: - The two entry points

  /// The shortcut door: read, and fall back if the read found nothing to use.
  ///
  /// **Performs the read ITSELF rather than taking one.** A context passed in is a context that
  /// could have come from anywhere, including a second sample of the workspace, which is the one
  /// thing this whole type is built to prevent.
  public static func acquire(
    fallbackEnabled: Bool,
    environment: Environment,
    timeout: Float? = nil,
    board: NSPasteboard = .general
  ) async -> Outcome {
    // The subrole is sampled ONLY where it can be acted on. With the fallback off, asking would
    // add an Accessibility operation whose failure would change the answer the user gets, for a
    // feature they opted out of.
    let (result, context) = SelectionReader.readForAcquisition(
      timeout: timeout, sampleSubrole: fallbackEnabled)
    return await acquire(
      following: result, context: context, fallbackEnabled: fallbackEnabled,
      environment: environment, board: board)
  }

  /// The menu-bar door's CLICK path: a read already happened, against a context it remembered.
  ///
  /// **The menu cannot do the read here and must not redo it.** `menuNeedsUpdate` has to be
  /// synchronous, so the row is drawn from a bounded read taken while the user's own application was
  /// still frontmost, and the sample this is handed is that read's (#2412 stopped re-reading).
  ///
  /// **What the click leaves in front was measured, twice, with different answers.** On 2026-08-26
  /// a word highlighted in WhatsApp with Finder brought to the front came back from a chord at
  /// WhatsApp's pid. On 2026-10-23 (#3986), real clicks on the status item and its row left the
  /// user's app (Chrome, Finder) frontmost throughout, and Chrome, Safari and TextEdit put behind
  /// another app copied nothing. So the ordinary case needs no activation, and step 2a brings the
  /// target back for the case that does.
  public static func acquire(
    following result: SelectionReader.Result,
    context: SelectionReader.AcquisitionContext,
    fallbackEnabled: Bool,
    environment: Environment,
    board: NSPasteboard = .general
  ) async -> Outcome {
    guard SelectionReader.isFallbackEligible(result) else {
      // Either the read worked, or it failed in a way a second attempt cannot change. Both are
      // terminal and neither touches the clipboard.
      return Outcome(
        result: result,
        context: context,
        acquired: { if case .text = result { return .accessibility } else { return .nothing } }(),
        acquisitionMs: nil,
        clipboardRestore: .notTouched,
        // Neither step ran: the fallback was never attempted.
        modifierReleaseMs: nil, bringBack: nil)
    }
    return await attemptCopyFallback(
      context: context, fallbackEnabled: fallbackEnabled, environment: environment, board: board)
  }

  // MARK: - The ladder

  private static func attemptCopyFallback(
    context: SelectionReader.AcquisitionContext,
    fallbackEnabled: Bool,
    environment: Environment,
    board: NSPasteboard
  ) async -> Outcome {
    let started = ContinuousClock.now
    func elapsedMs() -> Int {
      Int(started.duration(to: .now) / .milliseconds(1))
    }
    // Set once the shortcut-key wait clears (#2481); nil before it and when it did not. Captured by
    // reference by every exit below, so a later refusal still reports how long the keys took.
    var modifierReleaseMs: Int? = nil
    // Set by STEP 2a; nil before it. Captured the same way.
    var bringBack: BringBack? = nil
    func refusing(_ why: SelectionReader.Refusal) -> Outcome {
      Outcome(
        result: .refused(why), context: context, acquired: .nothing,
        acquisitionMs: elapsedMs(), clipboardRestore: .notTouched,
        modifierReleaseMs: modifierReleaseMs, bringBack: bringBack)
    }

    // STEP 1 — the policy questions, all of them, in a declared order. Nothing has been touched.
    //
    // **Through `liveRefusal` like every other site, and the exception it used to make is gone.**
    // It passed `context.focusedElementIsSecure` — the sample's own answer, freshest thing available
    // and genuinely correct here, since the read that produced it happened microseconds ago. But an
    // exception is a thing to remember, and five review rounds of this exact class say the thing to
    // remember is what gets forgotten. The cost of removing it is one bounded probe on a path that
    // is about to spend hundreds of milliseconds anyway, and it only runs where the fallback is
    // eligible at all.
    //
    // The pid is unwrapped FIRST because `liveRefusal` probes that process. Its own guard refuses a
    // nil or non-positive pid, so this returns the same refusal for the same reason rather than
    // inventing one — and it is the first question `mayAttempt` asks, so the order is preserved.
    guard let pid = context.pid, pid > 0 else {
      await log(
        context: context, acquired: .nothing, refusal: .noFrontmostApplication, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(.noFrontmostApplication)
    }
    if let refusal = liveRefusal(pid: pid, context: context, fallbackEnabled: fallbackEnabled, environment) {
      await log(
        context: context, acquired: .nothing, refusal: refusal, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(refusal)
    }

    // STEP 2 — wait for the user's own chord to come up. Still nothing touched.
    let release = await awaitModifierRelease(environment)
    guard let releasedAfter = modifierReleaseMilliseconds(release) else {
      await log(
        context: context, acquired: .nothing, refusal: .modifiersHeld, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(.modifiersHeld)
    }
    modifierReleaseMs = releasedAfter
    await AppLogger.shared.log(
      "modifiers clear release_ms=\(releasedAfter)", level: .info, category: "QuickAdd")

    // STEP 2a — bring the sampled app back to the front if it is not there (#3986). Still nothing
    // touched.
    //
    // A pid-targeted Copy does nothing in an app that is not in front (measured 2026-10-23), and
    // posting it anyway would spend the 400 ms answer wait and a clipboard takeover on a known
    // no-op. A status-item click kept the user's app in front in the measured cases (Chrome, Finder,
    // 2026-10-23); this is the guard for the cases that do not, which are not yet measured.
    //
    // **Identity is re-checked BEFORE activating**, because step 2 can take 1.5 s, long enough for
    // the target to quit and its pid to be reissued: bringing a stranger forward is a visible side
    // effect of its own. Steps 2b and 3b then re-ask every safety question AFTER the app came
    // forward, which is when a password field could become focused.
    //
    // **Cancellation is checked first, on both branches:** the log line above suspends, and a
    // cancelled invocation must reach neither the activation nor the chord. It maps like an expired
    // activation wait: target gone if it is gone, otherwise a refused copy.
    // `bringBack` stays nil: the step did not run, and `timed_out` would claim a wait that never
    // happened.
    if Task.isCancelled {
      let gone = !environment.targetStillPresent(context)
      let refusal: SelectionReader.Refusal = gone ? .targetApplicationGone : .copyRefused
      await logStep("2a", refusal: refusal)
      return refusing(refusal)
    }
    if environment.frontmostPID() == pid {
      bringBack = .notNeeded
    } else {
      guard environment.targetStillPresent(context) else {
        bringBack = .targetGone
        await logStep("2a", refusal: .targetApplicationGone)
        return refusing(.targetApplicationGone)
      }
      environment.activate(pid)
      switch await DeadlinePoll.wait(
        within: activationDeadline, every: activationPollInterval, now: environment.now,
        sleep: environment.sleep, { environment.frontmostPID() == pid })
      {
      case .met:
        bringBack = .front
      case .expired:
        let gone = !environment.targetStillPresent(context)
        bringBack = gone ? .targetGone : .timedOut
        let refusal: SelectionReader.Refusal = gone ? .targetApplicationGone : .copyRefused
        await logStep("2a", refusal: refusal)
        return refusing(refusal)
      case .cancelled:
        // Not a timeout: the wait was abandoned, so the measurement stays absent.
        let gone = !environment.targetStillPresent(context)
        let refusal: SelectionReader.Refusal = gone ? .targetApplicationGone : .copyRefused
        await logStep("2a", refusal: refusal)
        return refusing(refusal)
      }
    }

    // STEP 2b — RE-ASK the policy questions, because step 2 can have taken up to 1.5 seconds.
    //
    // **The LIFETIME axis, and it is the one a first reading of this ladder does not see.** Step 1's
    // answers were correct when they were taken and are used much later: secure input is a mode the
    // user can enter by clicking into a password field, and the target can quit, both of them while
    // we wait for their fingers to come off the shortcut. A check that is correct at the moment it
    // runs and stale at the moment it matters is not a guard.
    //
    // Same context, deliberately — this re-asks the LIVE questions and never re-samples the
    // application, which would be the defect the type doc's third numbered point is about. Still
    // before the takeover, so a refusal here leaves the clipboard genuinely untouched.
    // **All FOUR inputs are live here, and an earlier version of this block got three.** It re-read
    // secure input, posting authorisation and target liveness, then passed the same stale `context`
    // whose `focusedElementIsSecure` was sampled before the wait. So the one guard whose failure
    // mode is a secret on the clipboard was the one still answering from memory, inside a block
    // whose own comment said it was live. `secureFocusProbe` asks the SAME pid, right now, and
    // `isSecureField` answers TRUE when it cannot tell.
    if let refusal = liveRefusal(pid: pid, context: context, fallbackEnabled: fallbackEnabled, environment) {
      await log(
        context: context, acquired: .nothing, refusal: refusal, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(refusal)
    }

    // STEP 3 — take the board over. This is the line the file's doc comment is about: past it, the
    // pending cleanup is cancelled and we are the only party left who will restore anything.
    //
    // Each takeover outcome gets the refusal that is TRUE of it. Collapsing them would put "your
    // clipboard is too large to be kept safe" in front of a user whose clipboard is nothing of the
    // kind — a confident sentence about a state the code never checked.
    let takeover = ClipboardCleanup.beginTakeover(
      maximumBytes: maximumPreservedClipboardBytes, from: board)
    guard
      case .granted(let payload, let baseline, let token) = takeover
    else {
      let refusal: SelectionReader.Refusal = {
        switch takeover {
        case .clipboardTooLarge: return .clipboardTooLarge
        // The board kept moving, which says nothing about its size. `unreadable` is the only member
        // of the set that is TRUE here: we could not get a clean read.
        case .boardTooBusy: return .unreadable
        // A dictation just wrote the board and its target is still reading it. Transient by design,
        // and `unreadable` is the honest sentence: we could not read the selection this time.
        case .deliveryInFlight: return .unreadable
        // Unreachable in production — one `isAcquiring` flag guards both doors — and answered
        // honestly regardless.
        case .alreadyInFlight: return .unreadable
        case .granted: return .unreadable
        }
      }()
      await log(
        context: context, acquired: .nothing, refusal: refusal, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(refusal)
    }

    // The board count we OWN: the takeover baseline at first, then the settled copy count.
    var ownedChangeCount = baseline

    /// The ONLY way out from here, and the only site that restores.
    ///
    /// Every exit below returns through this: posting failed, the app declined, the copy landed
    /// empty, it was oversized, `classify` refused, or it worked. That is the structure the doc
    /// comment promises, and it is checkable by grepping this function for `return` — every one of
    /// them after this point is a `concluding(...)`.
    func concluding(_ result: SelectionReader.Result, acquired: Acquired) async -> Outcome {
      // **A dictation delivery took the board while we held it, and the heart does not yield to a
      // limb (#2465).** It has already inherited the user's real clipboard from our takeover and
      // written its own payload, so restoring here would pull that payload off the board before the
      // target app has read the paste it already posted — the wrong-text failure, reached through
      // Quick Add. We restore NOTHING and say so.
      guard !ClipboardCleanup.wasSuperseded(token) else {
        ClipboardCleanup.endTakeover(token)
        await log(
          context: context, acquired: .nothing, refusal: .copyRefused, ms: elapsedMs(),
          restore: .supersededByDelivery)
        return Outcome(
          result: .refused(.copyRefused), context: context, acquired: .nothing,
          acquisitionMs: elapsedMs(), clipboardRestore: .supersededByDelivery,
          modifierReleaseMs: modifierReleaseMs, bringBack: bringBack)
      }
      ClipboardCleanup.endTakeover(token)

      // **Restoring an UNCHANGED board is a write nobody asked for.** When the chord was never
      // posted, or the target never answered, `ownedChangeCount` is still the takeover baseline and
      // the board holds exactly what it held — so a restore clears and rewrites the user's
      // clipboard for nothing. That costs a clipboard-history entry the help page does not promise,
      // and it can DROP representations `boundedSaveClipboard` declined to materialize.
      //
      // **The exception this used to carry is GONE, and its absence is now guaranteed rather than
      // handled.** A takeover that consumed a fresh pending cleanup could leave OUR dictation
      // payload on the board with the count unmoved, which looks identical to "nothing happened".
      // `beginTakeover` now REFUSES in that window instead of granting, so a granted takeover never
      // holds our payload and an unmoved count always means nothing happened.
      guard ownedChangeCount != baseline else {
        await log(
          context: context, acquired: acquired, refusal: refusalOf(result), ms: elapsedMs(),
          restore: .notTouched)
        return Outcome(
          result: result, context: context, acquired: acquired,
          acquisitionMs: elapsedMs(), clipboardRestore: .notTouched,
          modifierReleaseMs: modifierReleaseMs, bringBack: bringBack)
      }

      // The user's clipboard after we copied THEIR selection, not a dictation: no marker added.
      let restored = PasteService.restoreClipboard(
        payload, changeCountAfterPaste: ownedChangeCount, markTransient: false, on: board)
      let restore: ClipboardRestore = restored ? .restored : .declined
      let refusal = refusalOf(result)
      await log(
        context: context, acquired: acquired, refusal: refusal, ms: elapsedMs(), restore: restore)
      return Outcome(
        result: result, context: context, acquired: acquired,
        acquisitionMs: elapsedMs(), clipboardRestore: restore,
        modifierReleaseMs: modifierReleaseMs, bringBack: bringBack)
    }

    // STEP 3b — the LAST live check of every policy question, immediately before the chord.
    //
    // **A THIRD site on the lifetime axis, and the one with no wait to point at.** Step 2b probes
    // before the takeover, which looked like the last possible moment. It is not: `beginTakeover`
    // MATERIALIZES the clipboard, and a lazily-provided representation is produced by another
    // process on demand — unbounded, synchronous, and entirely outside our control. A user can
    // click into a password field inside it.
    //
    // The previous two instances were "the check runs before a 250 ms wait". This one is "the check
    // runs before an operation whose duration nobody bounds", which is why counting the waits was
    // never going to find it. Found by cloud review on PR #2472.
    //
    // **It asks EVERY question, not the secure ones.** A first version probed only secure state, and
    // the next round pointed out that a pid can be reused while that same provider stalls — so the
    // target can quit and a stranger inherit the chord. `liveRefusal` is what stops a site here
    // being assembled from whichever questions the last finding was about.
    //
    // Past the takeover, so a refusal returns through `concluding` and honours the restore
    // obligation — and because nothing has been posted, the board is unchanged and the no-write
    // path leaves the user's clipboard alone.
    if let refusal = liveRefusal(pid: pid, context: context, fallbackEnabled: fallbackEnabled, environment) {
      return await concluding(.refused(refusal), acquired: .nothing)
    }

    // STEP 3c — the last two readings before the chord, with no wait (#3986). Ported from Paste
    // Last Dictation, which re-checks after its own activation: the user can switch apps, or press
    // a modifier again, during the takeover. A Copy under a held modifier reaches the app as a
    // different shortcut; one at an app that left the front does nothing. Nothing awaits between a
    // passing check and the post. A cancelled invocation never posts.
    //
    // **The copy key is resolved HERE, not before the waits:** the shortcut wait and the
    // bring-back can take two seconds, long enough for the user to switch keyboard layout, and a
    // key resolved under the old layout would press a different Command shortcut under the new
    // one. A layout we cannot read refuses instead of pressing whatever sits at position 8 on an
    // ANSI board.
    guard let copyKey = environment.copyKeyCode() else {
      await logStep("3c", refusal: .copyRefused)
      return await concluding(.refused(.copyRefused), acquired: .nothing)
    }
    if Task.isCancelled || environment.frontmostPID() != pid {
      await logStep("3c", refusal: .copyRefused)
      return await concluding(.refused(.copyRefused), acquired: .nothing)
    }
    if environment.modifiersHeld() {
      await logStep("3c", refusal: .modifiersHeld)
      return await concluding(.refused(.modifiersHeld), acquired: .nothing)
    }

    // STEP 4 — one chord, never retried. A copy can have side effects in an app that binds it to
    // something else, and a retry doubles them.
    switch environment.postCopy(pid, copyKey) {
    case .notPosted:
      return await concluding(.refused(.copyRefused), acquired: .nothing)
    case .clearFailed:
      // NOT a refusal. The chord went out and the word may already be on the board, so refusing here
      // would throw away a capture to report a machine state the user cannot act on differently.
      // Loud, because a stuck Command is the worst thing this feature can do to a machine.
      await AppLogger.shared.log(
        "Quick Add acquisition: the Command clear event could not be posted; "
          + "modifier state may be stuck",
        level: .info, category: "QuickAdd")
    case .posted:
      break
    }

    // STEP 5 — wait for the board to move, then for it to hold still.
    //
    // **KNOWN LIMIT, and it is the sharpest edge in this file: `changeCount` says the board moved,
    // never WHO moved it.** macOS publishes no writer identity for the pasteboard, so a write that
    // lands between our chord and our read is indistinguishable from the target answering. If the
    // target answers in the measured 37 to 49 ms the window is that small; if it never answers we
    // poll to the cap, and a write inside that window is misattributed to it.
    //
    // THREE ways to mis-decide this were considered and REJECTED, all stated so nobody re-derives
    // them as improvements:
    //
    // - **Counting the increments** (`settled == baseline + 1` means one writer) is not sound. A
    //   single logical copy can advance `changeCount` more than once, because an app that calls
    //   `clearContents()` and then writes objects increments it at each step. The check would fire
    //   on ordinary copies in ordinary apps, and a partial check that looks complete is worse than
    //   no check.
    // - **A sentinel write before the chord** would make the board's content ours, so a change is
    //   provably somebody's write. It does not distinguish WHOSE, it costs the user a third
    //   clipboard-history entry, and the help page's honesty about those entries is the reason
    //   there are only two.
    // - **Refusing when the bytes come back UNCHANGED** (the board moved and holds exactly what the
    //   user already had, so a rewrite rather than an answer) was built, tested, and REVERTED. It
    //   does not address this finding's actual harm, which is the restore overwriting a NEWER value
    //   with DIFFERENT bytes, and it breaks an ordinary flow: copy the correct spelling from
    //   somewhere, paste it, highlight it, press the shortcut. That user gets a refusal for a copy
    //   that worked perfectly.
    //
    // **So there is no check here, deliberately, and the residue is documented rather than
    // mitigated away.** A user who copies something else inside this window, in an app that did not
    // answer, sees the wrong word in the panel and loses that copy to the restore. The panel showing
    // the word before anything is written is this feature's safety property and it still holds; the
    // help page and the release notes both state the window rather than promising it away.
    //
    // The 400 ms cap is not shortened to narrow the window either. It is sized for the slowest
    // SUPPORTED Mac, not for this one, and trading the feature's reliability everywhere against a
    // rare race is the wrong direction.
    guard
      let settled = await settledChangeCountAfterCopy(
        board: board, from: ownedChangeCount, environment: environment)
    else {
      return await concluding(.refused(.copyRefused), acquired: .nothing)
    }
    ownedChangeCount = settled

    // **Asked again HERE, not only at the exit.** `concluding` re-checks before restoring, which
    // stops us writing over a delivery's payload — but the poll above suspends, so by this line the
    // board may belong to a dictation, and the next statement READS it. Without this the panel can
    // offer the user their own dictated text as the word they highlighted. Losing the restore was
    // the loud half of round 5's finding; this is the quiet half.
    guard !ClipboardCleanup.wasSuperseded(token) else {
      return await concluding(.refused(.copyRefused), acquired: .nothing)
    }

    // STEP 6 — classify through the reader's own function, so the doors cannot disagree about
    // trimming or the store's ceiling. There is no second copy of either.
    let copied = board.string(forType: .string) ?? ""
    let classified = SelectionReader.classify(copied)
    let acquired: Acquired = {
      if case .text = classified { return .clipboardCopy }
      return .nothing
    }()
    return await concluding(classified, acquired: acquired)
  }

  /// The refusal inside a result, or nil for a success.
  ///
  /// Extracted because the exit function reports it from two places since the confirming round added
  /// the no-write path, and two copies of a three-line unwrap is how the two come to disagree.
  private static func refusalOf(_ result: SelectionReader.Result) -> SelectionReader.Refusal? {
    if case .refused(let why) = result { return why }
    return nil
  }

  // MARK: - The decisions, which are pure

  /// Why the fallback must not be attempted, or nil to go ahead.
  ///
  /// **Precedence is DECLARED rather than emergent**, because more than one of these can hold at
  /// once and the refusal set carries one value. The order is not arbitrary: each earlier member
  /// names a state in which attempting anything at all would be wrong, and the later ones only
  /// matter once there is something to attempt against.
  ///
  /// 1. **No usable process** — there is no subject. Unreachable in production given a
  ///    fallback-eligible result, and stated rather than force-unwrapped.
  /// 2. **The target is gone** — the pid we remembered is not that application any more. Checked
  ///    before secure input because a process that no longer exists has nothing to protect, and
  ///    posting at a recycled pid reaches a stranger.
  /// 3. **Secure input** — macOS is protecting keystrokes, which is exactly what we are about to
  ///    synthesize.
  /// 4. **Event posting not authorised** — a different grant from the Accessibility one we already
  ///    hold to read, asked with `CGPreflightPostEventAccess` and never inferred from
  ///    `AXIsProcessTrusted`.
  /// 5. **Off for this app** — the user's setting, or a client whose keystrokes leave this machine.
  ///
  /// **The clipboard budget is deliberately NOT here.** The payload does not exist at this point, so
  /// its size is unknowable, and a predicate that cannot be evaluated where it is written is a
  /// predicate that silently passes. It lives in the takeover at step 3.
  ///
  /// **`focusedElementIsSecure` is a PARAMETER, not read off the context, and that is a fix rather
  /// than a style choice.** It used to be derived from `context`, which made this function LOOK
  /// live at both call sites while one of its inputs was sampled before a quarter-second wait. The
  /// confirming review round found it: focus moving into a password field during that wait left
  /// this guard reading the old answer, and the failure mode is a secret on the clipboard. A
  /// parameter forces each call site to say WHERE its answer came from.
  static func mayAttempt(
    secureInputActive: Bool,
    focusedElementIsSecure: Bool,
    postingAuthorised: Bool,
    targetStillPresent: Bool,
    fallbackEnabled: Bool,
    context: SelectionReader.AcquisitionContext
  ) -> SelectionReader.Refusal? {
    guard let pid = context.pid, pid > 0 else { return .noFrontmostApplication }
    guard targetStillPresent else { return .targetApplicationGone }
    guard !secureInputActive, !focusedElementIsSecure else { return .secureInputActive }
    guard postingAuthorised else { return .eventPostingNotTrusted }
    guard fallbackEnabled, !isKeystrokeForwarding(context.bundleIdentifier) else {
      return .copyFallbackDisabled
    }
    return nil
  }

  /// Applications that forward keystrokes to another machine or another operating system.
  ///
  /// **OPEN-WORLD and best effort, stated rather than implied.** There is no authority that
  /// enumerates every remote-desktop or virtual-machine client, so this list is a sample of the
  /// common ones and the next one to appear will not be in it. The real escape is the global setting
  /// in Clipboard preferences, which is why this feature has one; a per-app list would be a settings
  /// feature riding inside a bug fix.
  ///
  /// The hazard it covers is specific: in these apps a synthetic Copy is delivered to somebody
  /// else's session, where it means whatever it means there.
  static let keystrokeForwardingBundleIdentifiers: Set<String> = [
    "com.apple.ScreenSharing",
    "com.microsoft.rdc.macos",
    "com.teamviewer.TeamViewer",
    "com.realvnc.vncviewer",
    "com.philandro.anydesk",
    "com.p5sys.jump.mac.viewer",
    "com.citrix.receiver.icaviewer.mac",
    "com.nulana.remotixmac",
    "com.splashtop.MacBusiness",
    "com.parallels.desktop.console",
    "com.vmware.fusion",
    "com.utmapp.UTM",
    "org.virtualbox.app.VirtualBox",
  ]

  /// **Nil FAILS OPEN, deliberately, and the reason is that the alternative buys nothing.** An
  /// application with no bundle identifier is not on any denylist, so refusing there would block the
  /// fallback in every unbundled binary in exchange for no protection at all: every remote-desktop
  /// and virtual-machine client ships bundled. Stated rather than left to a reader to notice,
  /// because "nil means not forwarding" is exactly the collapse the type doc enumerates.
  static func isKeystrokeForwarding(_ bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return keystrokeForwardingBundleIdentifiers.contains(bundleIdentifier)
  }

  // MARK: - The live half

  /// Every LIVE policy question, asked at once, for one sampled application.
  ///
  /// **This exists because "a site that asks a SUBSET looks identical to a site that asks all of
  /// them" produced a finding in FIVE consecutive review rounds.** Step 1 asked all five questions.
  /// Step 2b was added and passed one stale value. Step 3b was added and asked only the subrole.
  /// Then 3b asked both secure signals but not target liveness — a pid can be reused while a lazy
  /// pasteboard provider stalls the takeover. Each fix was correct and each left the next gap,
  /// because the sites were assembled by hand from whichever questions the last finding was about.
  ///
  /// A caller cannot invoke this with a subset. That is the whole point, and it is why this is a
  /// function rather than a longer comment above three call sites.
  ///
  /// The SAMPLED context goes in unchanged: this re-asks the live questions and never re-samples
  /// the application, which is the defect the type doc's third numbered point is about.
  ///
  /// The readings come from `environment` (#3986): `.live` in production, injected in tests. The
  /// decision is always `mayAttempt`, so a test can choose what is observed, never what is decided.
  @MainActor
  private static func liveRefusal(
    pid: pid_t,
    context: SelectionReader.AcquisitionContext,
    fallbackEnabled: Bool,
    _ environment: Environment
  ) -> SelectionReader.Refusal? {
    mayAttempt(
      secureInputActive: environment.secureInputActive(),
      focusedElementIsSecure: SelectionReader.isSecureField(environment.secureFocusProbe(pid)),
      postingAuthorised: environment.postingAuthorised(),
      targetStillPresent: environment.targetStillPresent(context),
      fallbackEnabled: fallbackEnabled,
      context: context)
  }

  /// Whether the remembered pid is still the application it was sampled as.
  ///
  /// **Resolves a remembered identity rather than asking who is frontmost.** That distinction is the
  /// whole point: `NSWorkspace.shared.frontmostApplication` would answer about a different
  /// application whenever the user has moved on, and step 2a may itself have changed it. A pid is a
  /// reusable handle, and a menu can sit open long enough for one to be recycled.
  ///
  /// **A context with no bundle identifier to compare gets a WEAKER check, and that is the second
  /// deliberate fail-open the type doc names.** All that remains is "a process still exists at this
  /// pid", which a recycled pid also satisfies. Refusing instead would block the fallback in every
  /// unbundled application to close a window that requires the target to quit AND its pid to be
  /// reissued AND the user to still be looking at a menu, so the check is weakened rather than the
  /// feature. What it must not do is pretend to be the same check, which is why this says so.
  static func liveTargetStillPresent(_ context: SelectionReader.AcquisitionContext) -> Bool {
    guard let pid = context.pid, pid > 0,
      let running = NSRunningApplication(processIdentifier: pid)
    else { return false }
    guard let sampled = context.bundleIdentifier else { return true }
    return running.bundleIdentifier == sampled
  }

  /// Wait for the four modifier flags to be clear, up to `modifierReleaseCap`, on `environment`'s
  /// clock (#2481).
  ///
  /// Through `DeadlinePoll`, so the order is Paste Last Dictation's: a release first observed at
  /// or past the cap expires rather than counts, and a cancelled wait means ABANDON, never fall
  /// through and post anyway.
  @MainActor
  static func awaitModifierRelease(_ environment: Environment) async -> DeadlinePoll.Result {
    await DeadlinePoll.wait(
      within: modifierReleaseCap, every: .milliseconds(modifierPollIntervalMs),
      now: environment.now, sleep: environment.sleep, { !environment.modifiersHeld() })
  }

  /// The wait's answer as whole milliseconds to continue with, or nil to refuse `.modifiersHeld`.
  ///
  /// Cancellation refuses the same way the cap does, as before: nothing is posted either way.
  static func modifierReleaseMilliseconds(_ result: DeadlinePoll.Result) -> Int? {
    switch result {
    case .met(let elapsed): return Int(elapsed / .milliseconds(1))
    case .expired, .cancelled: return nil
    }
  }

  /// Poll for the board to move, then for it to stop moving, and return the count we then own.
  ///
  /// Nil means the app never answered within the cap, or the wait was cancelled.
  ///
  /// **Settling matters and is not defensive padding.** An app writing several representations can
  /// be observed part-way through, and reading on the first change is how a rich copy comes back as
  /// an empty string.
  private static func settledChangeCountAfterCopy(
    board: NSPasteboard,
    from baseline: Int,
    environment: Environment
  ) async -> Int? {
    var waited = 0

    while waited < copyAnswerCapMs {
      await environment.sleep(.milliseconds(copyPollIntervalMs))
      if Task.isCancelled { return nil }
      waited += copyPollIntervalMs

      let moved = board.changeCount
      guard moved != baseline else { continue }

      // The board moved. Now require it to HOLD STILL before reading: an app writing several
      // representations can be observed part-way through, and reading on the first change is how a
      // rich copy comes back as an empty string.
      var settled = moved
      while waited < copyAnswerCapMs {
        await environment.sleep(.milliseconds(copySettleMs))
        if Task.isCancelled { return nil }
        waited += copySettleMs
        let after = board.changeCount
        if after == settled { return settled }
        settled = after
      }
      // **The cap expired while the board was STILL MOVING, and this refuses.** An earlier version
      // returned `board.changeCount` here and proceeded as the board's owner, on the reasoning that
      // the app had answered repeatedly and we had run out of patience. That reasoning defends the
      // wrong thing: what we ran out of is any moment at which the board held still, so there is no
      // count we can honestly claim, and claiming one means reading a value mid-write and then
      // restoring over a writer who is still going.
      //
      // Refusing leaves `ownedChangeCount` at the takeover baseline, which the board has long since
      // passed — so the restore DECLINES and the active writer's value survives, which is the
      // outcome we want. Found by a refutation run against this file's own class enumeration, which
      // had this member's cost recorded as "both refuse and restore". It did not.
      return nil
    }
    return nil
  }

  /// Which step refused, for the two steps whose refusal shares a reason with an earlier step
  /// (#3986): Live UAT reads it to tell the last check from the first.
  private static func logStep(_ step: String, refusal: SelectionReader.Refusal) async {
    await AppLogger.shared.log(
      "Quick Add acquisition: refused at step=\(step) reason=\(refusal.rawValue)",
      level: .info, category: "QuickAdd")
  }

  /// One support line per invocation. Never the word, on any path, including under Debug Mode.
  private static func log(
    context: SelectionReader.AcquisitionContext,
    acquired: Acquired,
    refusal: SelectionReader.Refusal?,
    ms: Int,
    restore: ClipboardRestore
  ) async {
    await AppLogger.shared.log(
      "Quick Add acquisition: acquired=\(acquired.rawValue) "
        + "reason=\(refusal?.rawValue ?? "none") ms=\(ms) "
        + "clipboard=\(restore.rawValue) app=\(context.bundleIdentifier ?? "unknown")",
      level: .info, category: "QuickAdd")
  }
}
