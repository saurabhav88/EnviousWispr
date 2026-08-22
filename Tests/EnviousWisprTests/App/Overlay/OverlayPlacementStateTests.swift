import CoreGraphics
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2292 chunk C2. Where the pill sits.
///
/// **Product Outcome:** when one of these fails the user sees the pill jump —
/// sideways after they dragged it (#2195), under the menu bar (#1060), or into
/// an ~85pt gap above the screen edge when another app is in full screen
/// (#1341).
///
/// No AppKit. `ScreenGeometry` is a value, so a full-screen space, a short
/// display and a multi-screen setup are all reachable from a plain unit test
/// rather than requiring the dev machine to be arranged a particular way.
@Suite(.tags(.productOutcome))
struct OverlayPlacementStateTests {

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  private static let fullScreened = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860),
    hasFullScreenSpace: true)

  // MARK: - #2195: the horizontal axis

  /// **The bug, stated as a test.** The shipped path computes `x` as
  /// `visibleFrame.midX - width / 2` unconditionally
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`), before it branches on continuity, and
  /// inherits only `y`. So a pill the user dragged left snaps back to
  /// centre the instant its content changes — recording to polishing, for
  /// instance, which happens in every single dictation.
  ///
  /// Swept over every size pair rather than one, because the defect is exactly a
  /// dependence on the incoming WIDTH: a same-width transition hides it.
  @Test(
    "a continuing presentation preserves BOTH coordinates, at every size pair",
    arguments: [
      (CGSize(width: 185, height: 92), CGSize(width: 185, height: 92)),
      (CGSize(width: 185, height: 92), CGSize(width: 120, height: 64)),
      (CGSize(width: 120, height: 64), CGSize(width: 320, height: 120)),
      (CGSize(width: 320, height: 120), CGSize(width: 185, height: 44)),
      (CGSize(width: 260, height: 44), CGSize(width: 260, height: 44)),
    ])
  func continuingPreservesBothAxes(pair: (from: CGSize, to: CGSize)) {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .bottom, screen: Self.screen)

    // Where the pill actually is: dragged well away from centre.
    let live = CGRect(
      x: 120, y: Self.screen.visibleFrame.minY, width: pair.from.width, height: pair.from.height)

    let next = placement.frame(
      for: pair.to,
      continuity: .continuing(
        currentFrame: live, anchoredScreen: Self.screen.id, outgoingWasContentSized: true),
      environment: Self.screen)

    #expect(
      next.origin.x == live.origin.x,
      "x was recentred on a continuing presentation — this is #2195")
    #expect(next.origin.y == live.origin.y, "y was not preserved on a Bottom continuation")
  }

  /// Paired case: a FRESH presentation must still centre, or the guard above is
  /// satisfied by placement that never centres anything.
  @Test("a fresh presentation is centred")
  func freshIsCentred() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .bottom, screen: Self.screen)
    let f = placement.frame(
      for: CGSize(width: 185, height: 44),
      continuity: .fresh(position: .bottom, screen: Self.screen.id),
      environment: Self.screen)
    #expect(f.origin.x == Self.screen.visibleFrame.midX - 92.5)
  }

  // MARK: - #1341: the Bottom full-screen rule

  @Test("Bottom sits on the Dock-safe edge normally, and on the true screen edge in full screen")
  func bottomDropsToTheTrueEdgeInFullScreen() {
    #expect(OverlayPlacementState.freshOriginY(for: .bottom, on: Self.screen) == 85)
    // `visibleFrame` does NOT shrink when another app is full-screen — measured
    // 2026-07-17 — so without this rule the pill floats ~85pt above the edge.
    #expect(OverlayPlacementState.freshOriginY(for: .bottom, on: Self.fullScreened) == 0)
  }

  @Test("Top is measured from the visible top and is unaffected by a full-screen space")
  func topIsUnaffectedByFullScreen() {
    let expected = Self.screen.visibleFrame.maxY - 60
    #expect(OverlayPlacementState.freshOriginY(for: .top, on: Self.screen) == expected)
    #expect(OverlayPlacementState.freshOriginY(for: .top, on: Self.fullScreened) == expected)
  }

  // MARK: - #1060: the clamp

  @Test("a tall pill is clamped so its top never goes under the menu bar")
  func tallPillIsClamped() {
    let vf = Self.screen.visibleFrame
    // Requested flush with the visible top, but 200pt tall: unclamped, its top
    // would sit 200pt above the visible frame.
    let clamped = OverlayPlacementState.clampedOriginY(
      requestedY: vf.maxY - 60, height: 200, on: Self.screen)
    #expect(clamped == vf.maxY - 200 - 8)
    #expect(clamped + 200 <= vf.maxY, "the pill's top escaped the visible frame")
  }

  @Test("a short pill is not moved by the clamp")
  func shortPillIsUntouched() {
    // The paired case: a clamp that always fires would satisfy the test above.
    let vf = Self.screen.visibleFrame
    #expect(
      OverlayPlacementState.clampedOriginY(requestedY: vf.minY, height: 44, on: Self.screen)
        == vf.minY)
  }

  // MARK: - The Top continuation rule

  @Test("Top re-anchors a content-sized outgoing pill by its top edge")
  func topContentSizedReanchorsByTopEdge() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .top, screen: Self.screen)
    let live = CGRect(x: 400, y: 700, width: 185, height: 44)

    let next = placement.frame(
      for: CGSize(width: 185, height: 92),
      continuity: .continuing(
        currentFrame: live, anchoredScreen: Self.screen.id, outgoingWasContentSized: true),
      environment: Self.screen)

    #expect(next.maxY == live.maxY, "the top edge moved on a content-sized Top continuation")
  }

  @Test("Top re-anchors a fixed-frame outgoing pill by its centre")
  func topFixedFrameReanchorsByCentre() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .top, screen: Self.screen)
    let live = CGRect(x: 400, y: 700, width: 185, height: 92)

    let next = placement.frame(
      for: CGSize(width: 185, height: 44),
      continuity: .continuing(
        currentFrame: live, anchoredScreen: Self.screen.id, outgoingWasContentSized: false),
      environment: Self.screen)

    #expect(next.midY == live.midY, "the centre moved on a fixed-frame Top continuation")
  }

  // MARK: - Space change

  @Test("a Bottom pill re-anchors when a full-screen space appears")
  func bottomRepositionsOnSpaceChange() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .bottom, screen: Self.screen)
    let live = CGRect(x: 300, y: 85, width: 185, height: 44)

    let moved = placement.repositionedFrameForSpaceChange(
      currentFrame: live, on: Self.fullScreened)

    #expect(moved?.origin.y == 0)
    // Shipped that site RECENTRES on this path. An earlier version of this test
    // asserted the x was preserved, which encoded my own invented behaviour
    // rather than the shipped rule. It is not the #2195 defect: this path runs
    // only for an `.automatic` anchor, which is centred by definition, and it
    // returns early for a pill the user moved.
    #expect(moved?.origin.x == Self.fullScreened.visibleFrame.midX - 92.5)
  }

  @Test("a Top pill does not re-anchor on a space change")
  func topDoesNotRepositionOnSpaceChange() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .top, screen: Self.screen)
    let live = CGRect(x: 300, y: 800, width: 185, height: 44)
    #expect(
      placement.repositionedFrameForSpaceChange(currentFrame: live, on: Self.fullScreened) == nil)
  }

  @Test("a pill the user dragged is never moved by a space change")
  func userDraggedPillSurvivesASpaceChange() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .bottom, screen: Self.screen)
    placement.userDidMove(to: CGPoint(x: 300, y: 400), screen: Self.screen)
    let live = CGRect(x: 300, y: 400, width: 185, height: 44)

    #expect(
      placement.repositionedFrameForSpaceChange(currentFrame: live, on: Self.fullScreened) == nil,
      "the user's own position was overridden by our re-anchor rule")
    #expect(placement.isUserAnchored(on: Self.screen.id))
  }

  /// **Inverted after review.** An earlier version asserted a different screen
  /// was ignored, which would have stranded the pill on the old display.
  /// Shipped that site re-resolves the target screen every time — mouse-
  /// containing, then main, then first — and re-anchors onto it.
  @Test("a Bottom pill follows the resolved target screen")
  func spaceChangeFollowsTheTargetScreen() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .bottom, screen: Self.screen)
    let other = ScreenGeometry(
      id: ScreenID(rawValue: 2),
      frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 1512, y: 85, width: 1920, height: 960))
    let live = CGRect(x: 300, y: 85, width: 185, height: 44)

    let moved = placement.repositionedFrameForSpaceChange(currentFrame: live, on: other)

    #expect(moved?.origin.x == other.visibleFrame.midX - 92.5, "the pill was stranded")
    #expect(moved?.origin.y == 85)
  }

  @Test("a dragged Top pill keeps its Top edge for re-anchoring")
  func draggedPillKeepsItsEdge() {
    // The anchor used to drop the edge, so a dragged TOP pill fell through to
    // the Bottom continuing rule and stopped re-anchoring by top edge or centre.
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .top, screen: Self.screen)
    placement.userDidMove(to: CGPoint(x: 300, y: 700), screen: Self.screen)
    let live = CGRect(x: 300, y: 700, width: 185, height: 44)

    let next = placement.frame(
      for: CGSize(width: 185, height: 92),
      continuity: .continuing(
        currentFrame: live, anchoredScreen: Self.screen.id, outgoingWasContentSized: true),
      environment: Self.screen)

    // Top rule, content-sized: preserve the TOP edge. The Bottom rule would have
    // preserved the bottom origin instead, moving the pill down by 48 points.
    #expect(next.maxY == live.maxY)
    #expect(next.origin.x == live.origin.x)
  }

  /// Ownership must transfer even when the frame does NOT move — two displays
  /// with identical coordinates expose it precisely because the geometry check
  /// returns nil, so nothing moves and the anchor silently keeps naming the old
  /// screen. Cloud review found it; the earlier version returned a frame for the
  /// new screen while still anchored to the old one.
  @Test("a space change takes ownership of the resolved screen even when nothing moves")
  func spaceChangeTakesScreenOwnershipWithoutMoving() {
    var placement = OverlayPlacementState()
    placement.beginFresh(at: .bottom, screen: Self.screen)
    let twin = ScreenGeometry(
      id: ScreenID(rawValue: 7),
      frame: Self.screen.frame, visibleFrame: Self.screen.visibleFrame)
    let live = CGRect(
      x: Self.screen.visibleFrame.midX - 92.5, y: 85, width: 185, height: 44)

    #expect(
      placement.repositionedFrameForSpaceChange(currentFrame: live, on: twin) == nil,
      "identical geometry should not move the pill")
    // Assert the ANCHOR, not a round-trip through `userDidMove`. The first
    // version of this test did the latter, which asserts only that
    // `userDidMove` stores the screen it is handed — trivially true, and true
    // on the broken code too. A vacuous guard written while fixing a vacuity
    // finding, which is the shape this repo keeps recording.
    #expect(
      placement.anchor == .automatic(.bottom, ScreenID(rawValue: 7)),
      "the anchor never transferred to the resolved screen")
  }
}
