import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport

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


  /// A one-shot latch: the subject announces, the test suspends until it has.
  ///
  /// Signalling BEFORE anyone waits is the ordinary case here rather than an edge
  /// case, so it latches instead of requiring a waiter to already be present.
  @MainActor
  private final class Latch {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
      guard !fired else { return }
      fired = true
      waiter?.resume()
      waiter = nil
    }

    func wait() async {
      if fired { return }
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiter = c }
    }
  }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  /// The time limit is a final harness guard, not part of the proof. The row
  /// resolves from either cancellation or another completed poll, with no
  /// elapsed-time assertion.

  // MARK: - The still cadence (#2435)

  /// **Product Outcome.** The Appearance picker draws three recording pills as
  /// PICTURES. On `.live` each would read its providers twenty times a second for
  /// as long as the settings window is open, so a page that shows what a pill
  /// looks like would cost more than showing one.
  ///
  /// **This row proves the FIRST READ still happens and is the LAST one.** The
  /// count is taken at the moment the loop parks, which the pill's own provider
  /// announces — no elapsed time, and no inference that a subject is finished.
  ///
  /// The non-vacuous control is the row above: with a cadence the test can
  /// advance, the very same counters move. A subject that never polled at all
  /// would fail there.
  @Test("a still recording pill reads its providers once, then parks", .timeLimit(.minutes(1)))
  func aStillPillReadsOnceThenParks() async throws {
    let counts = Counts()
    let parked = Latch()
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { Self.screen } }, effects: .recording())
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
        // LAST of the three reads in the loop body, so the latch fires with the
        // whole first poll complete rather than part-way through it.
        parked.signal()
        return .off
      },
      onContentHeightChange: { _ in },
      chrome: RecordingPillDesign.classic.chrome,
      isLocked: false,
      noticeText: nil,
      cadence: .still)

    let hosted = NSHostingView(rootView: AnyView(view))
    try #require(
      host.present(
        hosted, width: .fixed(RecordingPillDesign.classic.width),
        fixedHeight: RecordingPillDesign.classic.reservedHeight,
        isFresh: true, position: .top),
      "the still pill never reached the host")

    await parked.wait()
    #expect(
      counts.all == [1, 1, 1],
      """
      a still pill read \(counts.all) on its first poll, not one of each. \
      `.still` suppresses REPEATED reads; the first one is what seeds the frame.
      """)
  }

  /// **The other half of `.still`, and the failure it guards is a LEAK.** A park
  /// that outlives its view keeps the pill's task alive for the rest of the
  /// session with nothing on screen — the same defect the first row proves for
  /// the live cadence, one layer down, asserted on the cadence VALUE so it holds
  /// however that value is used.
  ///
  /// **The park must NOT return while its task is uncancelled — and the earlier
  /// version of this row could not see that, which a mutation run proved rather
  /// than suggested.**
  ///
  /// It read `Task.isCancelled` on the far side of the wait and required `true`.
  /// Against a `.still` mutated to `continuation.finish()` — a cadence that parks
  /// for nothing and returns at once — the row still PASSED, because the mutant's
  /// wait suspends just long enough for the main actor to run the test's own
  /// `cancel()` first. So `isCancelled` was true, the assertion held, and the
  /// guard was decorative. Written after its fix against already-correct code, it
  /// was indistinguishable from a row that cannot fail.
  ///
  /// **The discriminating property is the one the earlier row assumed: does the
  /// wait return while nothing has cancelled it.** So this never cancels at all
  /// for that half. `Task.yield()` hands the main actor over repeatedly — a
  /// SCHEDULING barrier, not elapsed time, so it is not the guess-when-the-subject-
  /// is-finished shape and adds no real-time dependence. A correct park cannot
  /// return across any number of yields; the mutant returns on the first.
  ///
  /// The cancellation half is kept as the second arm, so the row still proves the
  /// park RELEASES rather than merely never returning — a `wait` that hangs
  /// forever would satisfy arm one alone.
  @Test("a still cadence parks until cancelled, and only until cancelled", .timeLimit(.minutes(1)))
  func stillParksUntilCancelled() async {
    final class Flag: @unchecked Sendable { var returned = false }

    // ARM 1: uncancelled, it must not come back.
    let flag = Flag()
    let entered = Latch()
    let parked = Task { @MainActor in
      entered.signal()
      await RecordingPollCadence.still.wait()
      flag.returned = true
    }
    await entered.wait()
    for _ in 0..<32 { await Task.yield() }

    #expect(
      !flag.returned,
      """
      the still cadence returned with nothing cancelling it, so it does not park at all \
      and every pill using it polls exactly as fast as the loop can run.
      """)

    // ARM 2: and it does come back once cancelled, or a park that simply hangs
    // forever would satisfy arm one.
    parked.cancel()
    await parked.value
    #expect(
      flag.returned,
      "the still cadence did not release on cancellation, so its task outlives the view")
  }
}
