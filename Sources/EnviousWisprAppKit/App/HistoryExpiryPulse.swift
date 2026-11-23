import Foundation
import Observation

/// What the Escape Recovery expiry pulse needs from History's writer (#4586 N6): whether held-row
/// work remains, whether a sweep is due, the sweep, and dropping the cached disk state.
@MainActor
protocol HistoryExpiryPulseWriter: AnyObject {
  func pendingPulseHasWork() -> Bool
  func pendingSweepIsDue() -> Bool
  func sweepExpiredPending(now: Date) async
  func invalidateDiskState()
}

/// Redraws held Escape Recovery rows once a minute while one is live, and runs the follow-up
/// sweep (#2087). Its own owner since #4586 N6; `TranscriptCoordinator` owns it and is reached
/// only through `HistoryExpiryPulseWriter`.
@MainActor @Observable
final class HistoryExpiryPulse {
  /// Re-render pulse for pending Escape Recovery rows (#2087).
  ///
  /// This type has no clock, and Observation redraws on a STATE change — a
  /// remaining-time computed from `Date()` is not one. Without a pulse a row
  /// would keep showing whatever it said when something else last mutated
  /// state, and an expired row would stay on screen until an unrelated edit
  /// happened to refresh it. Reading this in a view is what subscribes it.
  ///
  /// Only runs while a live pending row exists, so the ordinary case — feature
  /// off, or no recovery held — has no timer at all.
  private(set) var expiryPulse: Int = 0

  private let pendingPulseInterval: Duration
  private let pendingPulseSleep: @Sendable (Duration) async -> Void
  private var pulseTask: Task<Void, Never>?
  /// The writer whose held rows this pulse redraws. Weak: the writer owns this pulse.
  @ObservationIgnored weak var writer: (any HistoryExpiryPulseWriter)?

  init(
    pendingPulseInterval: Duration, pendingPulseSleep: @escaping @Sendable (Duration) async -> Void
  ) {
    self.pendingPulseInterval = pendingPulseInterval
    self.pendingPulseSleep = pendingPulseSleep
  }

  // No `deinit` teardown: `deinit` is nonisolated and cannot touch main-actor
  // state, and none is needed — the loop holds `self` weakly, so once this
  // object goes away the next wake finds nothing and returns. Nothing is
  // retained in the meantime.

  func startPulseIfNeeded() {
    guard pulseTask == nil, let writer,
      writer.pendingPulseHasWork()
    else { return }
    pulseTask = Task { [weak self, pendingPulseInterval, pendingPulseSleep] in
      while !Task.isCancelled {
        await pendingPulseSleep(pendingPulseInterval)
        guard let self, let writer = self.writer, !Task.isCancelled else { return }
        // Bumped BEFORE the stop check, so the pulse that carries the last row
        // past its deadline is itself delivered — otherwise the final expiry
        // would stop the timer and never redraw, leaving the expired row on
        // screen until something unrelated moved.
        self.expiryPulse &+= 1
        // #2087: the pulse is where an expiry is DETECTED, so it is where the
        // file must go and the event must fire. Sweeping only on `load()` left
        // cleanup and telemetry waiting for the user to reopen History — which
        // for a row that aged out while they watched could be days, or never.
        //
        // Asks "can I see a lapsed row" rather than comparing the live count
        // before and after. The comparison version could never fire: both reads
        // happen after the wait, so they are always equal, and it only appeared
        // to work because the row sometimes expired BETWEEN them. A test that
        // removed the wall clock is what exposed it.
        if writer.pendingSweepIsDue() {
          await writer.sweepExpiredPending(now: Date())
        }
        // AFTER the sweep above, never before: this asks whether a countdown is
        // running or a file resisted removal, and the sweep is what settles the
        // second half. Stopping on the live count alone is what stranded a
        // failed removal, because the retry it was promised never came.
        if !writer.pendingPulseHasWork() {
          self.pulseTask = nil
          return
        }
      }
    }
  }

  private func stopPulseIfIdle() {
    guard let writer, !writer.pendingPulseHasWork() else { return }
    pulseTask?.cancel()
    pulseTask = nil
  }

  /// #2186: after an action that REMOVES pending files, re-read disk truth
  /// before deciding the pulse is idle.
  ///
  /// `liveOnDiskPendingCount` is a CACHE of the last sweep, and Keep, Delete and
  /// Delete All all change the directory it describes. Calling `stopPulseIfIdle`
  /// on the stale value means `pendingPulseHasWork` still sees the removed row,
  /// so the pulse never stops — a directory walk every minute for the life of
  /// the app, which is precisely the stranded-retry this file's own comments
  /// warn about, reintroduced through a cache those comments predate.
  ///
  /// A sweep rather than zeroing the count: zeroing is wrong whenever ANOTHER
  /// pending row is still counting down, and it would stop that row's timer.
  /// Only the directory knows. The sweep re-arms if work remains, so the stop
  /// below can then be trusted. Cloud review, P2.
  func refreshDiskStateThenStopIfIdle() {
    // SYNCHRONOUS first, and that is a contract rather than an optimisation:
    // `Keep stops the pulse once the last held row is gone` asserts the pulse is
    // gone the instant Keep returns. Making this purely async broke it — the
    // full lane caught it, this suite did not, because the new tests await the
    // refresh and the old one does not.
    //
    // The cache is INVALIDATED rather than trusted or preserved. It describes a
    // directory this removal just changed, so keeping it blocks the stop (the
    // round-2 P2), and believing its old value is what made it stale. Zeroing
    // can only stop the pulse EARLY; the refresh below re-arms within moments if
    // another row is still counting down, and only the directory can say.
    writer?.invalidateDiskState()
    stopPulseIfIdle()
    refreshTask = Task { [weak self] in
      await self?.writer?.sweepExpiredPending(now: Date())
      self?.stopPulseIfIdle()
    }
  }


  /// Held so a test can await the refresh rather than guess at a duration —
  /// a signal the subject itself fires, never a sleep or a yield count.
  private var refreshTask: Task<Void, Never>?

  #if DEBUG
    // periphery:ignore - test seam
    var hasPendingPulseForTesting: Bool { pulseTask != nil }

    /// Bumps the pulse the way the loop does, so a test can assert that reading
    /// the visible list actually subscribes to it — without driving the loop.
    // periphery:ignore - test seam
    func bumpExpiryPulseForTesting() {
      expiryPulse &+= 1
    }

    /// Awaits the post-removal disk refresh. Captured before awaiting because
    /// the task clears nothing but may be replaced by a later removal.
    // periphery:ignore - test seam
    func waitForRefreshForTesting() async {
      let running = refreshTask
      await running?.value
    }

    /// Awaits the pulse loop's own completion — a real signal, so a test never
    /// guesses how long the loop needs. Captured before awaiting because the
    /// loop nils the handle as it exits.
    // periphery:ignore - test seam
    func waitForPulseForTesting() async {
      let running = pulseTask
      await running?.value
    }

    /// The deadline behind `waitForPulseForTesting`. A loop that stopped
    /// honouring its own exit condition would otherwise spin forever and HANG
    /// the suite — no test name, no assertion, just a wedged run — which is
    /// worse than having no test. A test bounds its iterations and calls this,
    /// so the regression fails loudly instead.
    // periphery:ignore - test seam
    func cancelPulseForTesting() {
      pulseTask?.cancel()
      pulseTask = nil
    }

  #endif
}
