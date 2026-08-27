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
/// `AXSelectedTextRange` at zero. Terminals do a related thing: they advertise the attribute and
/// answer it with nothing. There is no Accessibility route to either, proven by exhaustion in the
/// issue and independently by two web-grounded models.
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
/// | Exhaustive enum consumption | nothing found; every enum here is switched exhaustively |
/// | Unsafe default consumption | nothing found; the menu's missing `representedObject` collapses to a refusing empty context |
///
/// **What a further finding would have to look like, so this is falsifiable rather than hopeful:** an
/// axis not in that table. A new member on an axis already listed is an adjudication error on one
/// row, which is a smaller thing and does not reopen the enumeration.
///
/// **That prediction was then tested, which is the only reason it is worth anything.** The
/// confirming round returned exactly one code finding and it was a WRONG ROW on the lifetime axis,
/// not a missing axis — which is what a complete enumeration fails like, and what an incomplete one
/// does not.
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
    /// The text was HANDED to us by macOS rather than obtained at all.
    ///
    /// The Services door, which the system gives the user's selection directly. It belongs in this
    /// set rather than borrowing `accessibility`, because "the clipboard was never touched" is true
    /// of both and is not the question this field answers.
    case handed
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

    public init(
      result: SelectionReader.Result,
      context: SelectionReader.AcquisitionContext,
      acquired: Acquired,
      acquisitionMs: Int?,
      clipboardRestore: ClipboardRestore
    ) {
      self.result = result
      self.context = context
      self.acquired = acquired
      self.acquisitionMs = acquisitionMs
      self.clipboardRestore = clipboardRestore
    }
  }

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
  static let modifierReleaseCapMs = 250
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
    timeout: Float? = nil,
    board: NSPasteboard = .general
  ) async -> Outcome {
    let (result, context) = SelectionReader.readForAcquisition(timeout: timeout)
    return await acquire(
      following: result, context: context, fallbackEnabled: fallbackEnabled, board: board)
  }

  /// The menu-bar door's CLICK path: a read already happened, against a context it remembered.
  ///
  /// **The menu cannot do the read here and must not redo it.** `menuNeedsUpdate` has to be
  /// synchronous, so the row is drawn from a bounded read taken while the user's own application was
  /// still frontmost. By click time the frontmost application is us — which is why #2412 stopped
  /// re-reading — so the sample this is handed is the only one that is about the user's document.
  ///
  /// **That the fallback works from here at all was measured, not assumed.** A word highlighted in
  /// WhatsApp, Finder brought to the front, the chord aimed at WhatsApp's remembered pid: the word
  /// came back, two-way controlled, with a screenshot confirming the highlight survived the app
  /// switch. A backgrounded application answers a chord aimed at its pid, and the plan said the
  /// opposite until somebody asked why.
  public static func acquire(
    following result: SelectionReader.Result,
    context: SelectionReader.AcquisitionContext,
    fallbackEnabled: Bool,
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
        clipboardRestore: .notTouched)
    }
    return await attemptCopyFallback(
      context: context, fallbackEnabled: fallbackEnabled, board: board)
  }

  // MARK: - The ladder

  private static func attemptCopyFallback(
    context: SelectionReader.AcquisitionContext,
    fallbackEnabled: Bool,
    board: NSPasteboard
  ) async -> Outcome {
    let started = ContinuousClock.now
    func elapsedMs() -> Int {
      Int(started.duration(to: .now) / .milliseconds(1))
    }
    func refusing(_ why: SelectionReader.Refusal) -> Outcome {
      Outcome(
        result: .refused(why), context: context, acquired: .nothing,
        acquisitionMs: elapsedMs(), clipboardRestore: .notTouched)
    }

    // STEP 1 — the policy questions, all of them, in a declared order. Nothing has been touched.
    if let refusal = mayAttempt(
      secureInputActive: IsSecureEventInputEnabled(),
      // The sample's own answer, which is the freshest thing available here: the read that produced
      // this context took it moments ago. Step 2b re-probes it live, because "moments ago" stops
      // being good enough once the modifier wait has run.
      focusedElementIsSecure: context.focusedElementIsSecure,
      postingAuthorised: CGPreflightPostEventAccess(),
      targetStillPresent: targetStillPresent(context),
      fallbackEnabled: fallbackEnabled,
      context: context)
    {
      await log(
        context: context, acquired: .nothing, refusal: refusal, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(refusal)
    }
    // Safe: `mayAttempt` returns non-nil for a nil or non-positive pid.
    guard let pid = context.pid else { return refusing(.noFrontmostApplication) }

    // Resolved once, before anything is posted, so a layout we cannot read refuses instead of
    // pressing whatever key happens to sit at position 8 on an ANSI board.
    guard let copyKey = SyntheticCopyChord.copyKeyCode() else {
      await log(
        context: context, acquired: .nothing, refusal: .copyRefused, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(.copyRefused)
    }

    // STEP 2 — wait for the user's own chord to come up. Still nothing touched.
    guard await modifiersCleared() else {
      await log(
        context: context, acquired: .nothing, refusal: .modifiersHeld, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(.modifiersHeld)
    }

    // STEP 2b — RE-ASK the policy questions, because step 2 can have taken a quarter of a second.
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
    if let refusal = mayAttempt(
      secureInputActive: IsSecureEventInputEnabled(),
      focusedElementIsSecure: SelectionReader.isSecureField(
        SelectionReader.secureFocusProbe(pid: pid, timeout: secureProbeTimeout)),
      postingAuthorised: CGPreflightPostEventAccess(),
      targetStillPresent: targetStillPresent(context),
      fallbackEnabled: fallbackEnabled,
      context: context)
    {
      await log(
        context: context, acquired: .nothing, refusal: refusal, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(refusal)
    }

    // STEP 3 — take the board over. This is the line the file's doc comment is about: past it, the
    // pending cleanup is cancelled and we are the only party left who will restore anything.
    guard
      case .granted(let payload, let baseline) = ClipboardCleanup.beginTakeover(
        maximumBytes: maximumPreservedClipboardBytes, from: board)
    else {
      await log(
        context: context, acquired: .nothing, refusal: .clipboardTooLarge, ms: elapsedMs(),
        restore: .notTouched)
      return refusing(.clipboardTooLarge)
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
      let restored = PasteService.restoreClipboard(
        payload, changeCountAfterPaste: ownedChangeCount, on: board)
      let restore: ClipboardRestore = restored ? .restored : .declined
      let refusal: SelectionReader.Refusal? = {
        if case .refused(let why) = result { return why }
        return nil
      }()
      await log(
        context: context, acquired: acquired, refusal: refusal, ms: elapsedMs(), restore: restore)
      return Outcome(
        result: result, context: context, acquired: acquired,
        acquisitionMs: elapsedMs(), clipboardRestore: restore)
    }

    // STEP 4 — one chord, never retried. A copy can have side effects in an app that binds it to
    // something else, and a retry doubles them.
    switch SyntheticCopyChord.post(at: pid, copyKeyCode: copyKey) {
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
    guard let settled = await settledChangeCountAfterCopy(board: board, from: ownedChangeCount)
    else {
      return await concluding(.refused(.copyRefused), acquired: .nothing)
    }
    ownedChangeCount = settled

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

  /// Whether the remembered pid is still the application it was sampled as.
  ///
  /// **Resolves a remembered identity rather than asking who is frontmost.** That distinction is the
  /// whole point: `NSWorkspace.shared.frontmostApplication` would answer about a different
  /// application, and by the time the menu-bar door reaches here the answer would be us. A pid is a
  /// reusable handle, and a menu can sit open long enough for one to be recycled.
  ///
  /// **A context with no bundle identifier to compare gets a WEAKER check, and that is the second
  /// deliberate fail-open the type doc names.** All that remains is "a process still exists at this
  /// pid", which a recycled pid also satisfies. Refusing instead would block the fallback in every
  /// unbundled application to close a window that requires the target to quit AND its pid to be
  /// reissued AND the user to still be looking at a menu, so the check is weakened rather than the
  /// feature. What it must not do is pretend to be the same check, which is why this says so.
  private static func targetStillPresent(_ context: SelectionReader.AcquisitionContext) -> Bool {
    guard let pid = context.pid, pid > 0,
      let running = NSRunningApplication(processIdentifier: pid)
    else { return false }
    guard let sampled = context.bundleIdentifier else { return true }
    return running.bundleIdentifier == sampled
  }

  /// Wait for the four modifier flags to be clear, or give up.
  ///
  /// Returns false on the cap and on cancellation. A cancelled wait means ABANDON, never fall
  /// through and post anyway.
  private static func modifiersCleared() async -> Bool {
    let interesting: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
    var waited = 0
    while waited < modifierReleaseCapMs {
      if CGEventSource.flagsState(.hidSystemState).isDisjoint(with: interesting) { return true }
      guard await pause(milliseconds: modifierPollIntervalMs) else { return false }
      waited += modifierPollIntervalMs
    }
    // One last read, so a release landing in the final interval is not reported as a hold.
    return CGEventSource.flagsState(.hidSystemState).isDisjoint(with: interesting)
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
    from baseline: Int
  ) async -> Int? {
    var waited = 0

    while waited < copyAnswerCapMs {
      guard await pause(milliseconds: copyPollIntervalMs) else { return nil }
      waited += copyPollIntervalMs

      let moved = board.changeCount
      guard moved != baseline else { continue }

      // The board moved. Now require it to HOLD STILL before reading: an app writing several
      // representations can be observed part-way through, and reading on the first change is how a
      // rich copy comes back as an empty string.
      var settled = moved
      while waited < copyAnswerCapMs {
        guard await pause(milliseconds: copySettleMs) else { return nil }
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

  /// A cancellation-aware sleep. False means the task was cancelled and the caller must abandon.
  ///
  /// **`do/catch`, never `try?`.** `try? await Task.sleep` swallows the cancellation and falls
  /// straight through to the next statement, performing the work early — the same trap
  /// `ClipboardCleanup` documents, and here it would post a keystroke into a cancelled invocation.
  private static func pause(milliseconds: Int) async -> Bool {
    do {
      try await Task.sleep(for: .milliseconds(milliseconds))
      return true
    } catch {
      return false
    }
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
