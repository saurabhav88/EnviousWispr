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
    activeTakeover = nil
    supersededTakeovers.removeAll()
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
  ///
  /// **Includes an active takeover since #2465.** A Sparkle relaunch during one takes the process
  /// down while the user's clipboard is held in memory by a caller that has already written to the
  /// board, which loses it exactly the way the 200 ms window this property was created for does.
  public static var hasPending: Bool { pending != nil || activeTakeover != nil }

  // MARK: - The takeover, and why it has to be visible to delivery (#2465)

  /// A clipboard transaction that is NOT a dictation delivery, currently in flight.
  ///
  /// **This exists because the fallback and a dictation are two owners of one board, and only one
  /// of them used to be visible.** The takeover cleared `pending` and registered nothing, so a
  /// delivery beginning during the fallback's wait — which awaits, releasing the main actor — saw
  /// an idle `ClipboardCleanup` and photographed a board mid-transaction. Two failures follow, and
  /// the second is the one this codebase is built to prevent: Quick Add reads the DICTATION's
  /// payload as the target app's Copy response, and then its restore pulls that payload off the
  /// board before the target app has read the paste we already posted. That is the wrong-text
  /// failure, reached through a limb.
  ///
  /// **Heart and limbs decides who yields.** Dictation is the heart and must never wait for Quick
  /// Add, so delivery takes the board and the takeover ABANDONS: it inherits nothing, restores
  /// nothing, and refuses.
  private struct ActiveTakeover {
    let id: UUID
    /// The user's real clipboard, held so a delivery starting mid-takeover inherits IT rather than
    /// photographing whatever the board holds at that instant.
    let payload: ClipboardSnapshot
  }

  private static var activeTakeover: ActiveTakeover?
  /// Tokens whose takeover was taken over. Read by the holder after each await.
  private static var supersededTakeovers: Set<UUID> = []

  /// Whether the delivery path claimed the board while this takeover was in flight.
  ///
  /// **Check after EVERY await.** Between two awaits the main actor is free and a dictation can run
  /// to a paste.
  static func wasSuperseded(_ token: UUID) -> Bool { supersededTakeovers.contains(token) }

  /// Tell an in-flight takeover that a dictation delivery is claiming the board.
  ///
  /// **`snapshotForDelivery` is NOT called on every delivery, which is the hole this closes.** It
  /// runs only when `restoreClipboardAfterPaste` is on; with the setting OFF a delivery writes the
  /// board and schedules a legacy rewrite without ever asking this type anything. A takeover in
  /// flight would then never learn it had lost the board, and would restore over a payload the
  /// target app had not read yet — the same wrong-text failure, reached through a setting.
  ///
  /// Called by `snapshotForDelivery` itself, so the restore-on path needs no second call, and
  /// called directly by the restore-off path.
  /// Public because a delivery writer lives in AppKit too: Escape Recovery's Undo pastes through
  /// `PasteService` directly rather than through the cascade. The visibility follows the CALL GRAPH
  /// rather than the layer, which is what stops the one writer outside this module from being the
  /// one that is invisible.
  public static func deliveryClaimsBoard() {
    guard let takeover = activeTakeover else { return }
    supersededTakeovers.insert(takeover.id)
    activeTakeover = nil
  }

  /// Release a takeover that finished on its own terms.
  static func endTakeover(_ token: UUID) {
    if activeTakeover?.id == token { activeTakeover = nil }
    supersededTakeovers.remove(token)
  }

  /// The user's clipboard as it stood before OUR payloads began landing on it.
  ///
  /// Routes call this instead of `PasteService.saveClipboard()` so a delivery
  /// beginning while cleanup is outstanding cannot photograph our own previous
  /// payload and mistake it for the user's clipboard.
  static func snapshotForDelivery(from board: NSPasteboard = .general) -> ClipboardSnapshot {
    // **A NON-DELIVERY transaction is in flight, and the heart does not wait for a limb (#2465).**
    // Quick Add's clipboard fallback holds the board across awaits, so a dictation can reach its
    // paste in the middle of one. The board right now may hold the target app's Copy response or
    // nothing meaningful, and photographing it would hand the user that instead of their clipboard.
    //
    // So delivery INHERITS the user's clipboard from the takeover, exactly as it inherits from a
    // pending restore, and the takeover is marked superseded: it will abandon rather than restore
    // over the payload this delivery is about to write. Checked FIRST because a takeover has
    // already cancelled any `pending`, so there is nothing below to find.
    if let payload = activeTakeover?.payload {
      deliveryClaimsBoard()
      return payload
    }

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
    /// `token` identifies THIS takeover. Hand it back to `endTakeover`, and check
    /// `wasSuperseded(_:)` after every await — a dictation delivery starting while you hold the
    /// board takes it from you, and continuing after that would put your restore on top of a
    /// payload the target app has not read yet.
    /// `inheritedPending` says the takeover CONSUMED a pending dictation cleanup, so the board may
    /// be holding our own payload right now. A caller that restores only when the board moved would
    /// strand it; a caller that always restores writes the user's clipboard for no reason.
    case granted(
      payload: ClipboardSnapshot, baseline: Int, token: UUID, inheritedPending: Bool)
    /// The clipboard is larger than the caller's budget, so nothing was touched.
    ///
    /// **Pending cleanup is left ARMED on this path**, deliberately. Refusing must not damage the
    /// state we declined to take responsibility for, and a caller that gets this back has no
    /// restore obligation precisely because it was given nothing to restore.
    case clipboardTooLarge
    /// Another takeover already holds the board.
    ///
    /// **Its own case rather than reusing `clipboardTooLarge`, because that one carries a SENTENCE.**
    /// The caller maps refusals to user-facing copy, and "your clipboard is too large to be kept
    /// safe" would be a confident lie about a state that has nothing to do with size. Unreachable in
    /// production, which is not a reason to answer it wrongly.
    case alreadyInFlight
    /// The board would not hold still long enough to be photographed with a matching change count.
    ///
    /// **Its own case for the same reason as the one above, and by the same mistake.** This path
    /// used to fall through to `clipboardTooLarge`, so a user whose clipboard held four characters
    /// and a busy clipboard manager was told their clipboard was too large to keep safe. A refusal
    /// that carries a SENTENCE cannot be reused as a general "no".
    case boardTooBusy
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
  /// - Parameter maximumBytes: the largest clipboard this caller is willing to READ. The budget is
  ///   the CALLER's policy rather than this type's: the number belongs beside the feature that
  ///   decided how much risk one word is worth.
  ///
  ///   **It bounds the branch that reads the BOARD, and only that one.** The other two branches
  ///   return a value already held in memory — a pending restore's snapshot, or a pending legacy
  ///   rewrite's text — where bounding saves nothing and refusing would decline to hand back a
  ///   clipboard we are holding either way. Said explicitly because the parameter's name invites
  ///   the wider reading, and a test used to depend on it.
  static func beginTakeover(
    maximumBytes: Int,
    from board: NSPasteboard = .general
  ) -> Takeover {
    // **A second takeover REFUSES rather than replacing the first.** Overwriting `activeTakeover`
    // would leave the first token unmarked, so its owner would pass `wasSuperseded`, fail to clear
    // the newer takeover because the ids differ, and restore over work it does not own.
    //
    // Production cannot reach this today — both doors sit behind one `isAcquiring` flag in
    // `QuickAddWiring` — and that is exactly why the primitive has to say no rather than rely on it.
    // A guard one layer up in another module is a convention; this is the contract. Refusing rather
    // than choosing is what `tools-and-apps.md` asks of anything that ACTS on a shared resource.
    guard activeTakeover == nil else { return .alreadyInFlight }

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
    // **Recorded before the pending operation is consumed, and only when it would actually be
    // INHERITED.** `pending != nil` alone is the wrong test: a pending cleanup whose board has
    // already moved is STALE, and `intendedPayload` correctly snapshots the current user clipboard
    // instead of the held one. Reporting `true` there tells the caller our own payload is on the
    // board when the user's is, so it restores for no reason — writing their clipboard and costing
    // a history entry, which is precisely what the caller's no-write path exists to avoid.
    //
    // The condition is the same freshness test `intendedPayload` applies one function down, and it
    // is duplicated rather than shared deliberately: they answer for the SAME instant, and a helper
    // that both called would be read twice with a gap between. Found by cloud review on PR #2472.
    let inheritedPending = pending.map { board.changeCount == $0.changeCountAfterPaste } ?? false

    var payload: ClipboardSnapshot?
    var baseline = 0
    for _ in 0..<Self.takeoverSnapshotAttempts {
      let before = board.changeCount
      // The budget is passed DOWN so it bounds what we touch, not just what we keep. Nil here means
      // the clipboard exceeded it and nothing usable was captured.
      guard let candidate = intendedPayload(from: board, maximumBytes: maximumBytes) else {
        // This one IS the budget: the snapshot refused because the bytes exceeded it.
        return .clipboardTooLarge
      }
      guard board.changeCount == before else { continue }
      payload = candidate
      baseline = before
      break
    }
    // Distinct from the budget refusal: the attempts ran out because the board kept MOVING, which
    // says nothing about its size.
    guard let payload else { return .boardTooBusy }

    // Commit. Any pending operation is abandoned whether or not it was stale: a fresh one would fire
    // on top of our restore, a stale one would overwrite whatever the user copied, and the caller is
    // about to write to the board either way.
    if let current = pending {
      pending = nil
      current.task.cancel()
    }

    // Registered BEFORE returning, so a delivery starting one line later can already see it. The
    // window between granting and registering would otherwise be the very race this closes.
    let token = UUID()
    activeTakeover = ActiveTakeover(id: token, payload: payload)

    // The baseline is the count that was VERIFIED to describe this payload, never a fresh read
    // taken here — a fresh read would reintroduce the gap this method just closed.
    return .granted(
      payload: payload, baseline: baseline, token: token, inheritedPending: inheritedPending)
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
  ///
  /// **Takes the budget rather than being measured afterwards.** Only the board-reading branch can
  /// exceed it: the other two return values we are already holding in memory, so there is nothing
  /// to bound and nothing to refuse.
  private static func intendedPayload(
    from board: NSPasteboard,
    maximumBytes: Int
  ) -> ClipboardSnapshot? {
    guard let current = pending, board.changeCount == current.changeCountAfterPaste else {
      // Either nothing is pending, or the board has moved on and the pending value is stale. In
      // both cases what is on the board now IS the user's clipboard — and it is the one branch that
      // materializes anything, so it is the one the budget applies to.
      return PasteService.boundedSaveClipboard(from: board, maximumBytes: maximumBytes)
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
