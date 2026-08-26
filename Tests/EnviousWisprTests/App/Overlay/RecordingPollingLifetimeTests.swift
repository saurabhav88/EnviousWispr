import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// A hidden recording pill stops polling (#2377 Phase 5, C5).
///
/// **The shutdown already ships and this suite is the PROBE for it.**
/// `OverlayWindowHost.hide()` sets `panel?.contentView = nil` precisely so the
/// recording leaf's poll and the capsule's `repeatForever` animation stop; a
/// retained panel that is merely ordered out keeps both running for the rest of
/// the session, invisibly. Nothing in the suite could see that either way, which
/// is exactly why it went unnoticed the first time — the window is correctly
/// hidden whether or not the content is released.
///
/// **No sleeps, and no elapsed time anywhere.** The poll's wait is a seam, so the
/// test learns the view has parked from a signal the VIEW sends and releases it
/// itself. A row that waited a while and then counted would be measuring the
/// machine.
@Suite(.tags(.productOutcome), .serialized)
@MainActor
struct RecordingPollingLifetimeTests {

  private enum PostHideOutcome: Equatable {
    case cancelled
    case repolled
  }

  /// A cadence the test drives, with the receipts the probe needs: it has PARKED,
  /// it may ADVANCE, it was CANCELLED, and — after `hide()` — which of
  /// cancellation and another poll came first.
  @MainActor
  private final class ManualCadence {
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

    var cadence: RecordingPollCadence {
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
    func awaitPark(after count: Int) async {
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
    func beginPostHideObservation() {
      observingPostHide = true
    }

    func awaitPostHideOutcome() async -> PostHideOutcome {
      if let postHideOutcome { return postHideOutcome }
      return await withCheckedContinuation { postHideWaiter = $0 }
    }

    /// Let the poll loop run one more iteration.
    func advance() {
      gate?.resume()
      gate = nil
    }
  }

  private final class Counts {
    var audio = 0
    var elapsed = 0
    var preview = 0
    var all: [Int] { [audio, elapsed, preview] }
  }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  /// The time limit is a final harness guard, not part of the proof. The row
  /// resolves from either cancellation or another completed poll, with no
  /// elapsed-time assertion.
  @Test("a hidden recording pill stops reading its providers", .timeLimit(.minutes(1)))
  func hidingTheHostStopsThePoll() async throws {
    let counts = Counts()
    let manual = ManualCadence()
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { Self.screen } })
    defer { host.hide() }

    let view = RecordingOverlayView(
      audioLevelProvider: {
        counts.audio += 1
        return 0.4
      },
      recordingElapsedProvider: {
        counts.elapsed += 1
        return 12
      },
      livePreviewProvider: {
        counts.preview += 1
        return .off
      },
      onContentHeightChange: { _ in },
      chrome: RecordingPillDesign.classic.chrome,
      isLocked: false,
      noticeText: nil,
      cadence: manual.cadence)

    let hosted = NSHostingView(rootView: AnyView(view))
    // Required, not ignored: a refused presentation would otherwise surface as an
    // unrelated hang-guard timeout rather than as the thing that went wrong.
    try #require(
      host.present(
        hosted, width: .fixed(RecordingPillDesign.classic.width),
        fixedHeight: RecordingPillDesign.classic.reservedHeight,
        isFresh: true, position: .top),
      "the recording pill never reached the host")

    // 1. The first poll runs immediately, then the loop parks.
    await manual.awaitPark(after: 0)
    let afterFirstPoll = counts.all
    #expect(
      afterFirstPoll == [1, 1, 1],
      "the first poll read \(afterFirstPoll), not one of each")

    // 2. THE NON-VACUOUS CONTROL. Without this, a row proving the counts stop
    //    would pass on a view that never polled at all.
    manual.advance()
    await manual.awaitPark(after: 1)
    let afterOneTick = counts.all
    #expect(
      afterOneTick == [2, 2, 2],
      "one advance moved the counts to \(afterOneTick), so the poll is not running")

    // 3. Take the content away — what `hide()` does in production — and push the
    //    loop at the same time. Whichever happens first is the answer: the wait
    //    is cancelled, or the pill completes another poll.
    manual.beginPostHideObservation()
    host.hide()
    manual.advance()

    let outcome = await manual.awaitPostHideOutcome()
    #expect(outcome == .cancelled, "the hidden pill completed another poll")

    // 4. And nothing was read on the way.
    #expect(
      counts.all == afterOneTick,
      "a hidden pill kept polling: \(afterOneTick) became \(counts.all)")
  }
}
