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
/// in `EnviousWisprServices`, whose dependencies are Core and ObservabilityCore and nothing else,
/// and `ClipboardCleanup` is here in Pipeline, which depends ON Services. Calling one from the other
/// reverses the direction `scripts/check-dependency-direction.sh` enforces at the push gate, so it
/// is a build failure rather than a preference. `architecture-rules.md` FACT: dependency-direction
/// settles it twice over: the Features layer must not own the clipboard, and this layer is the one
/// that owns sequencing, fallback contracts and telemetry, which is exactly what a ladder is.
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
  static func mayAttempt(
    secureInputActive: Bool,
    postingAuthorised: Bool,
    targetStillPresent: Bool,
    fallbackEnabled: Bool,
    context: SelectionReader.AcquisitionContext
  ) -> SelectionReader.Refusal? {
    guard let pid = context.pid, pid > 0 else { return .noFrontmostApplication }
    guard targetStillPresent else { return .targetApplicationGone }
    guard !secureInputActive, !context.focusedElementIsSecure else { return .secureInputActive }
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
  /// A context with no bundle identifier to compare cannot be checked this way, so a live process at
  /// that pid is all this can honestly require.
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
      // The cap expired while the board was still moving. What is there now is what we own, and
      // saying so is more honest than reporting that the app never answered, which is false — it
      // answered, repeatedly, and we ran out of patience.
      return board.changeCount
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
