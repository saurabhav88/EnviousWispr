import EnviousWisprAppKit
import Foundation

// #2455 C4 (#2461): moved out of `RecordingPollingLifetimeTests` so the polling
// test that needs a REAL panel — and therefore lives in
// `EnviousWisprDesktopEffectsTests` — can share them instead of owning a second
// copy. Two copies of a cadence fake drift apart and nothing fails.

package enum PostHideOutcome: Equatable {
  case cancelled
  case repolled
}

/// `@unchecked Sendable` because the cadence closure it vends is `@Sendable` and
/// captures it. Safe in practice and in a way the compiler cannot see: every
/// caller drives it from the main actor, and the poll loop it feeds is itself
/// main-actor-bound. It was nested inside a `@MainActor` suite before it moved
/// here, which is why the capture compiled without this.
package final class ManualCadence: @unchecked Sendable {

  package init() {}
  private var gate: CheckedContinuation<Void, Never>?
  private var parkWaiter: CheckedContinuation<Void, Never>?
  private(set) var parks = 0

  /// **Which of the two things happened first after `hide()`.**
  ///
  /// Awaiting cancellation alone cannot fail FAST: a host that never releases
  /// its content simply never cancels, so the row hits its hang guard and
  /// reports a timeout instead of the poll that carried on. Racing the two
  /// outcomes reports whichever the code actually did, promptly, with no
  /// elapsed time involved either way.
  private var observingPostHide = false
  private var postHideOutcome: PostHideOutcome?
  private var postHideWaiter: CheckedContinuation<PostHideOutcome, Never>?

  package var cadence: RecordingPollCadence {
    RecordingPollCadence { [weak self] in
      guard let self else { return }
      await self.park()
    }
  }

  /// Called by the view's poll loop in place of its 50 ms wait.
  private func park() async {
    parks += 1
    // A park AFTER hide is the pill completing another poll.
    if observingPostHide { finishPostHide(.repolled) }
    // A waiter that asked BEFORE this park gets its answer now.
    parkWaiter?.resume()
    parkWaiter = nil
    await withTaskCancellationHandler {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        gate = c
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.releaseOnCancel() }
    }
  }

  private func releaseOnCancel() {
    finishPostHide(.cancelled)
    gate?.resume()
    gate = nil
  }

  /// Suspend until the view parks. Resolves immediately if it already has more
  /// parks than `count`.
  package func awaitPark(after count: Int) async {
    if parks > count { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      parkWaiter = c
    }
  }

  private func finishPostHide(_ outcome: PostHideOutcome) {
    guard postHideOutcome == nil else { return }
    postHideOutcome = outcome
    postHideWaiter?.resume(returning: outcome)
    postHideWaiter = nil
  }

  /// Start watching for whichever happens first once the host is hidden.
  package func beginPostHideObservation() {
    observingPostHide = true
  }

  package func awaitPostHideOutcome() async -> PostHideOutcome {
    if let postHideOutcome { return postHideOutcome }
    return await withCheckedContinuation { postHideWaiter = $0 }
  }

  /// Let the poll loop run one more iteration.
  package func advance() {
    gate?.resume()
    gate = nil
  }
}


package final class Counts {

  package init() {}
  package var audio = 0
  package var elapsed = 0
  package var preview = 0
  package var all: [Int] { [audio, elapsed, preview] }
}

