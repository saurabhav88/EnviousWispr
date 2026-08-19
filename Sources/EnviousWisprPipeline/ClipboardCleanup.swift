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
