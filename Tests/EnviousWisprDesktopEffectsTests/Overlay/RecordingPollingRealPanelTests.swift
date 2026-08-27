import AppKit
@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprDesktopEffects
import SwiftUI
import Testing

/// #2455 C4 (#2461): moved out of `EnviousWisprTests`.
///
/// **This test depends on REAL AppKit view-hierarchy teardown.** `hide()` sets
/// `contentView = nil`, and what cancels `RecordingOverlayView`'s polling `.task`
/// is AppKit removing the view from a real window. A recording driver cannot
/// reproduce that: nothing was ever in a view hierarchy, so nothing is torn out of
/// one. The host's own comment said as much — "the shipped panel got this for free
/// by being destroyed".
///
/// It is therefore a real-panel test, and it was only ever passing in the unit
/// target because the double was a real `NSPanel`. That is this chunk's whole
/// subject, so it moves rather than being weakened.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingPollingRealPanelTests {

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

 @Test("a hidden recording pill stops reading its providers", .timeLimit(.minutes(1)))
  func hidingTheHostStopsThePoll() async throws {
    let counts = Counts()
    let manual = ManualCadence()
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { Self.screen } }, effects: DesktopOverlayEffects(
        makePanel: { LiveOverlayPanelDriver() }, workspace: LiveWorkspaceObserver()))
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
