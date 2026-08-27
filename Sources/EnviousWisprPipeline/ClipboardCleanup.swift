import AppKit
import EnviousWisprCore
import EnviousWisprServices

/// Clipboard hygiene that outlives the delivery which scheduled it (#2197).
///
/// **Why this type exists.** Every clipboard paste route waits 200 ms before
/// handing the user's clipboard back, so the target app has time to read what we
/// put there. That wait used to sit *inside* the awaited delivery call, so the
/// dictation's own completion — terminal state, telemetry, overlay dismissal,
/// readiness for the next one — queued behind it. Nothing downstream of delivery
/// reads the restored board, so nothing needed to wait.
///
/// The delay is unchanged, the change-count guard is unchanged, and the user's
/// clipboard comes back at the same wall-clock moment it always did. What
/// changes is that the dictation no longer waits for it.
///
/// **DO NOT REPLACE THIS WITH "DETECT WHEN THE APP HAS READ IT". It was built,
/// measured, and refused.** The obvious improvement is to stop waiting a fixed
/// period and instead learn the moment the target app reads the pasteboard —
/// macOS offers exactly that, via lazy provision: declare a type with an owner
/// and `pasteboard(_:provideDataForType:)` fires when a client asks for the
/// bytes. The mechanism works. Apps read in 2.0-38 ms, exactly one read per
/// paste, and lazily provided text does paste correctly.
///
/// It is unusable because **the callback proves SOMEONE read the board, never
/// WHO.** A clipboard manager reads it the same way the target app does, both
/// are other processes, and the promise is one-shot — whoever reads first spends
/// the signal. Restoring on a stolen read puts the user's PREVIOUS clipboard
/// into their document instead of their dictation, on the one path that must
/// never fail.
///
/// Timing cannot separate them, and that was measured rather than assumed:
/// thefts land at 0.0 ms and 3.2 ms after the keystroke, against a fastest
/// genuine app read of 2.0 ms. The distributions overlap, so no threshold
/// exists. (The probe and the full write-up live outside the repo — `docs/` and
/// `.claude/` are gitignored — which is why the conclusion is recorded HERE, in
/// the file someone would edit while re-deriving it.)
///
/// **The one new thing is pending work, and it needs its own bookkeeping.**
/// Cleanup can still be outstanding after `deliver` has returned, which creates
/// states that could not previously exist. The plan enumerates them
/// exhaustively (`docs/feature-requests/issue-2197-…`, "the class, enumerated");
/// the three that shape this file are:
///
/// 1. A later delivery must not photograph a board that still holds OUR payload
///    — it would save the previous dictation as "the user's clipboard" and then
///    faithfully restore it. `snapshotForDelivery` inherits instead.
/// 2. …but it MUST photograph when the board has moved, or a stale snapshot
///    overwrites something the user copied during the window. That is the same
///    bug inverted and strictly worse: misplacing a clipboard versus destroying
///    one.
/// 3. Cancellation must mean ABANDON, never "run it now". `try? await
///    Task.sleep` swallows a cancellation and falls straight through to the
///    body, performing it *early* — before the target app has read the payload
///    we already posted. That is the wrong-text failure, and `try?` is the
///    shorter, equivalent-looking spelling a later tidy-up would reach for.
///
/// **On 3, measured rather than asserted, because the first version of this
/// comment overstated it.** Two mechanisms protect that outcome — the
/// `do/catch` here and the `pending?.id == id` identity check below — and a
/// mutation run showed they are fully redundant: removing EITHER alone leaves
/// the suite green, because the other still covers every reachable path.
/// Removing BOTH is caught. So neither line is individually load-bearing, and
/// neither should be deleted on the grounds that a test still passes without
/// it. That is what defence in depth looks like from inside a mutation run, and
/// it is easy to misread as a vacuous test.
///
/// The same is true of both production `task.cancel()` calls below. Removing
/// either one also leaves the suite green because the identity check refuses the
/// stale task when it wakes. Cancellation still matters: it abandons superseded
/// work immediately instead of retaining and waking it later. A green
/// single-line mutant is evidence of the backstop, not evidence that either
/// cancellation is dead code (#2215).
@MainActor
public enum ClipboardCleanup {

  /// The two kinds of pending cleanup.
  ///
  /// Modelled as one enum rather than a snapshot plus a flag because they carry
  /// *different inputs*: a restore holds the user's clipboard, a legacy rewrite
  /// holds replacement text. A type that could represent only the first had no
  /// answer for what a later delivery should inherit while a rewrite was
  /// pending — found by review, and the reason this is an enum.
  private enum Operation {
    /// Put the user's clipboard back.
    case restore(ClipboardSnapshot)
    /// Replace our contextual payload with the legacy one, so a manual ⌘V pastes
    /// what the user expects. Only ever pending when clipboard restore is OFF,
    /// because `mustRewriteClipboardToLegacy` requires `!willRestoreUserClipboard`.
    case legacyRewrite(String)

    var label: String {
      switch self {
      case .restore: return "restore"
      case .legacyRewrite: return "legacy_rewrite"
      }
    }
  }

  private struct Pending {
    /// Identity, so a task can tell whether the slot is still ITS work. Without
    /// it, delivery N completing clears a slot that now belongs to N+1, and
    /// N+1's cleanup becomes invisible to the next inherit check and to
    /// `hasPending`.
    let id: UUID
    let operation: Operation
    /// The board's change count immediately after this delivery wrote it.
    /// Doubles as the test for "does the board still hold what this cleanup was
    /// written for".
    let changeCountAfterPaste: Int
    let task: Task<Void, Never>
  }

  private static var pending: Pending?

  // KNOWN LIMIT, raised by review three times and adjudicated three times, so
  // the reasoning is here rather than in a review thread nobody will find.
  //
  // If the process exits inside the 200 ms window, this task is destroyed and
  // the user's clipboard keeps our dictated payload instead of their own.
  //
  // THAT LOSS IS NOT NEW. There is no `applicationShouldTerminate` in this app
  // (swept: `AppDelegate` implements only
  // `applicationShouldTerminateAfterLastWindowClosed`), so `NSApp.terminate` runs
  // straight through to exit as one synchronous main-thread chain. Today's
  // INLINE `Task.sleep` in `deliver` is abandoned by that chain in exactly the
  // same way — a suspended task cannot interleave into it.
  //
  // WHAT DOES CHANGE IS LIKELIHOOD, and it is worth saying rather than claiming
  // strict equality: after this change the session has already finished when the
  // window opens, so the app looks idle and a user is marginally more likely to
  // quit inside it.
  //
  // Both proposed fixes are worse than the defect. A synchronous flush restores
  // BEFORE the delay expires, which can pull our payload off the board before the
  // target app has read the ⌘V we already posted — the wrong-text failure, via a
  // teardown hook. Deferring termination introduces an app that may not quit, in
  // an app that has never had a termination hook at all. A lost clipboard entry
  // is recoverable; neither of those is.
  //
  // What IS closed is the only newly-reachable route: an update relaunch, which
  // `UpdateCoordinator.installRefusedNow` now refuses while cleanup is pending.

  // MARK: Test seams
  //
  // Deliberately NOT `#if DEBUG`. A DEBUG-only declaration referenced from a
  // test breaks the RELEASE build, and a Debug-only local run cannot see it by
  // construction (tools-and-apps.md RULE: xcode-test-entrypoint). Three internal
  // statics cost nothing in the shipped binary and remove that whole class.

  /// Shortens the wait so a test does not sleep 200 ms per case. Nil in
  /// production, and nothing in `Sources/` ever assigns it.
  static var testDelayOverrideMs: Int?

  /// Awaits the currently-pending cleanup, so a test learns it is done from the
  /// subject rather than by sleeping and hoping
  /// (testing-philosophy.md RULE: never-guess-when-the-subject-is-finished).
  static func awaitPendingCleanup() async {
    await pending?.task.value
  }

  /// Drops any pending cleanup between cases. Cancels first, so an abandoned
  /// task cannot fire against the next case's board.
  static func resetPendingForTests() {
    pending?.task.cancel()
    pending = nil
  }

  /// Cancels pending cleanup and waits for that task to actually finish.
  ///
  /// The waiting is the point. Proving cleanup was ABANDONED means proving
  /// something did not happen, and the tempting way to do that is to sleep and
  /// look. A cancelled task still RUNS TO COMPLETION — it just returns early —
  /// so awaiting it is a real signal from the subject with no clock in it
  /// (testing-philosophy.md RULE: never-guess-when-the-subject-is-finished).
  static func cancelPendingAndAwait() async {
    guard let current = pending else { return }
    pending = nil
    current.task.cancel()
    await current.task.value
  }

  /// Whether cleanup is outstanding.
  ///
  /// Read by the update coordinator, which already refuses to install an update
  /// mid-dictation and now also refuses while cleanup is pending: a Sparkle
  /// relaunch inside the window would take the process down before the user's
  /// clipboard came back. Declining to *start* an install for 200 ms is a
  /// strictly smaller refusal than the one already shipping.
  public static var hasPending: Bool { pending != nil }

  /// The user's clipboard as it stood before OUR payloads began landing on it.
  ///
  /// Routes call this instead of `PasteService.saveClipboard()` so a delivery
  /// beginning while cleanup is outstanding cannot photograph our own previous
  /// payload and mistake it for the user's clipboard.
  static func snapshotForDelivery(from board: NSPasteboard = .general) -> ClipboardSnapshot {
    guard let current = pending else { return PasteService.saveClipboard(from: board) }

    guard board.changeCount == current.changeCountAfterPaste else {
      // The board moved: someone else owns it now, the pending value is stale,
      // and its cleanup must not fire either — it would overwrite whatever the
      // user just copied.
      current.task.cancel()
      pending = nil
      return PasteService.saveClipboard(from: board)
    }

    switch current.operation {
    case .restore(let snapshot):
      // Our payload is still on the board and a real user clipboard is being
      // held for it. THAT is the user's clipboard, not what the board shows.
      return snapshot

    case .legacyRewrite(let legacyText):
      // No user clipboard is held here — restore was off for that delivery. But
      // the board holds the REPAIRED payload and this delivery is about to
      // supersede the rewrite that would have replaced it, so photographing the
      // board would preserve exactly the text the rewrite exists to remove.
      // Inherit what the board WOULD have held had the rewrite run.
      return ClipboardSnapshot(
        items: [[.string: Data(legacyText.utf8)]],
        changeCount: board.changeCount)
    }
  }

  // MARK: - Taking the board over for a non-delivery write (#2465)

  /// The answer to a takeover request.
  ///
  /// **Two values on the granted case, because they answer two different questions and conflating
  /// them is the defect this API exists to avoid.** `payload` is what the user must get back;
  /// `baseline` is the number a change-count poll compares against. `snapshotForDelivery` returns a
  /// snapshot whose own `changeCount` is from when the DICTATION snapshot was taken, so using it as
  /// a copy baseline compares against a number from the past and the very first poll reads as
  /// "something changed".
  /// Not `Equatable`, because `ClipboardSnapshot` is not and making it so to satisfy a test would
  /// hand that test an oracle with the wrong shape: "the clipboard came back" means the ITEMS match
  /// and the change count deliberately does not.
  enum Takeover {
    /// The board is yours. Restore `payload` on every exit path; poll against `baseline`.
    ///
    /// **Nothing else will put the user's clipboard back once this is returned.** Any pending
    /// cleanup has been cancelled, which is the point — an armed restore would otherwise fire on
    /// top of yours — and it is also the obligation: an early return between here and the restore
    /// strands whatever is on the board.
    case granted(payload: ClipboardSnapshot, baseline: Int)
    /// The clipboard is larger than the caller's budget, so nothing was touched.
    ///
    /// **Pending cleanup is left ARMED on this path**, deliberately. Refusing must not damage the
    /// state we declined to take responsibility for, and a caller that gets this back has no
    /// restore obligation precisely because it was given nothing to restore.
    case clipboardTooLarge
  }

  /// Take the user's clipboard over for a write that is not a dictation delivery.
  ///
  /// Quick Add's clipboard fallback (#2465) posts a synthetic Copy at the frontmost app, reads what
  /// lands, and puts the board back. That is the same preservation problem `snapshotForDelivery`
  /// solves for a delivery, with two differences that make a bare snapshot wrong here:
  ///
  /// 1. **A pending operation must be CONSUMED, not merely read.** `snapshotForDelivery` leaves it
  ///    armed on the path where the board has not moved, because a delivery goes on to schedule its
  ///    own cleanup which supersedes it. This caller schedules nothing, so an armed restore survives
  ///    and fires on top of the board it just handed back.
  /// 2. **The baseline must be the board's CURRENT count**, not the snapshot's. See `Takeover`.
  ///
  /// - Parameter maximumBytes: the largest clipboard this caller is willing to hold in memory. The
  ///   budget is the CALLER's policy rather than this type's: the number belongs beside the feature
  ///   that decided how much risk one word is worth.
  static func beginTakeover(
    maximumBytes: Int,
    from board: NSPasteboard = .general
  ) -> Takeover {
    // **The payload and the baseline must describe the SAME MOMENT, and an earlier version sampled
    // them at two.** It read the payload, then took `board.changeCount` afterwards as the baseline.
    // A write landing between those two reads produced a stale payload paired with a baseline
    // saying nothing had changed since — so the caller would later restore that stale payload over
    // the interloper's write, believing it still owned the board. `saveClipboard` also iterates the
    // items, so a concurrent write can tear the payload itself.
    //
    // Fixed by bracketing: read the count, build the payload, read the count again, and accept only
    // when it did not move. That makes "the payload and the baseline agree" a checked fact rather
    // than an assumption about how fast two adjacent lines run.
    //
    // Bounded rather than looped forever: a board being written continuously is a board we should
    // not be taking over at all, and `clipboardTooLarge` is the honest answer for "we could not get
    // a clean picture of your clipboard, so we left it alone" — it is the refusal that promises the
    // caller nothing was touched, which is exactly what happened.
    //
    // Found by a refutation run against this file's class enumeration, on the CORRELATED-VALUE
    // ATOMICITY axis, which that enumeration did not have.
    var payload: ClipboardSnapshot?
    var baseline = 0
    for _ in 0..<Self.takeoverSnapshotAttempts {
      let before = board.changeCount
      let candidate = intendedPayload(from: board)
      guard board.changeCount == before else { continue }
      payload = candidate
      baseline = before
      break
    }
    guard let payload else { return .clipboardTooLarge }

    guard payloadBytes(payload) <= maximumBytes else { return .clipboardTooLarge }

    // Commit. Any pending operation is abandoned whether or not it was stale: a fresh one would fire
    // on top of our restore, a stale one would overwrite whatever the user copied, and the caller is
    // about to write to the board either way.
    if let current = pending {
      pending = nil
      current.task.cancel()
    }

    // The baseline is the count that was VERIFIED to describe this payload, never a fresh read
    // taken here — a fresh read would reintroduce the gap this method just closed.
    return .granted(payload: payload, baseline: baseline)
  }

  /// How many times to try for a payload and a change count that describe the same moment.
  ///
  /// Three rather than one because an ordinary clipboard manager writing once should not cost the
  /// user the feature, and rather than unbounded because a board being written continuously is a
  /// board we should not be taking over.
  private static let takeoverSnapshotAttempts = 3

  /// What the user's clipboard IS right now, for a caller about to overwrite it.
  ///
  /// **Pure: it reads `pending` and the board and mutates neither.** That is the whole difference
  /// from `snapshotForDelivery`, which cancels a stale pending operation as a side effect of being
  /// asked. The three cases are the same three, and they are deliberately NOT shared with that
  /// method: one is a query and the other is a step in a transaction, and collapsing them is how a
  /// refusal comes to have side effects.
  private static func intendedPayload(from board: NSPasteboard) -> ClipboardSnapshot {
    guard let current = pending, board.changeCount == current.changeCountAfterPaste else {
      // Either nothing is pending, or the board has moved on and the pending value is stale. In
      // both cases what is on the board now IS the user's clipboard.
      return PasteService.saveClipboard(from: board)
    }

    switch current.operation {
    case .restore(let snapshot):
      // Our own payload is still on the board and the real user clipboard is being held for it.
      // Photographing the board here is the loss this whole method exists to prevent.
      return snapshot

    case .legacyRewrite(let legacyText):
      // No user clipboard is held, but the board holds the CONTEXTUAL payload that the pending
      // rewrite exists to replace. Inherit what the board would have held had the rewrite run.
      return ClipboardSnapshot(
        items: [[.string: Data(legacyText.utf8)]],
        changeCount: board.changeCount)
    }
  }

  /// Total bytes across every representation of every item.
  ///
  /// **Every representation, because that is what restoration writes back.** Measuring only the
  /// string would let a snapshot carrying a large image through as "small", and the budget exists to
  /// bound what is held in memory rather than what is legible.
  private static func payloadBytes(_ snapshot: ClipboardSnapshot) -> Int {
    snapshot.items.reduce(0) { total, item in
      total + item.values.reduce(0) { $0 + $1.count }
    }
  }

  /// Hand the user's clipboard back after the target app has had time to read
  /// ours, without making the dictation wait for it.
  static func scheduleRestore(
    _ snapshot: ClipboardSnapshot,
    changeCountAfterPaste: Int,
    tier: PasteTier,
    on board: NSPasteboard = .general
  ) {
    schedule(
      operation: .restore(snapshot),
      changeCountAfterPaste: changeCountAfterPaste,
      tier: tier
    ) {
      PasteService.restoreClipboard(
        snapshot, changeCountAfterPaste: changeCountAfterPaste, on: board)
    }
  }

  /// Replace our contextual payload with the legacy one after the target app has
  /// had time to read the contextual one.
  ///
  /// A separate operation from the restore on purpose: the wait is shared, the
  /// body is not. Collapsing them would swap one behaviour for the other.
  static func scheduleLegacyRewrite(
    legacyText: String,
    submittedChangeCount: Int,
    tier: PasteTier,
    on board: NSPasteboard = .general
  ) {
    schedule(
      operation: .legacyRewrite(legacyText),
      changeCountAfterPaste: submittedChangeCount,
      tier: tier
    ) {
      // The same freshness question the restore asks, asked separately because
      // the POLICY ("should this be rewritten at all") was answered before the
      // wait and the FRESHNESS question can only be answered after it.
      guard
        clipboardUntouchedSinceSubmit(
          submitted: submittedChangeCount,
          current: board.changeCount)
      else { return false }
      PasteService.copyToClipboard(legacyText, to: board)
      return true
    }
  }

  // MARK: - Private

  /// - Parameter body: performs the cleanup and returns whether it applied.
  ///   `false` means a guard declined, which is a normal outcome.
  private static func schedule(
    operation: Operation,
    changeCountAfterPaste: Int,
    tier: PasteTier,
    body: @escaping @MainActor () -> Bool
  ) {
    let id = UUID()
    let label = operation.label

    let task = Task { @MainActor in
      // `do/catch { return }`, NOT `try?`. A cancelled wait must ABANDON this
      // cleanup, never fall through and perform it early — see the type doc.
      do {
        try await Task.sleep(
          for: .milliseconds(testDelayOverrideMs ?? TimingConstants.clipboardRestoreDelayMs))
      } catch {
        return
      }
      // Superseded while we slept: their cleanup owns the board now.
      guard pending?.id == id else { return }

      let applied = body()

      // Cleared on EVERY path that reaches here, including the one where the
      // guard declined. A slot left populated would be inherited by the next
      // delivery and would keep `hasPending` true, blocking update installs
      // indefinitely.
      finish(id)

      Task {
        await AppLogger.shared.log(
          "Clipboard cleanup: op=\(label), applied=\(applied), "
            + "delay=\(TimingConstants.clipboardRestoreDelayMs)ms, tier=\(tier.rawValue)",
          level: .info, category: "PipelineTiming"
        )
      }
    }

    // A newer cleanup supersedes an older one outright: only one can own the
    // board, and leaving the old task running would race it.
    pending?.task.cancel()
    pending = Pending(
      id: id,
      operation: operation,
      changeCountAfterPaste: changeCountAfterPaste,
      task: task)
  }

  private static func finish(_ id: UUID) {
    guard pending?.id == id else { return }
    pending = nil
  }
}
