import CoreGraphics
import EnviousWisprCore
import Foundation

// Sole owner of WHERE the overlay sits (#2292, chunk C2). No AppKit: it takes a
// `ScreenGeometry` value and returns a rect, so every rule below is assertable
// against invented screens — including a full-screen space and a short display,
// neither of which is convenient to produce on the dev machine.
//
// The rules are PORTED, not invented. Each carries the shipped site it came
// from so C4 can check them back against it.

struct OverlayPlacementState: Equatable {
  /// Where the pill is anchored, and on which screen.
  ///
  /// `.user` is reached only by a genuine drag. The shipped code infers that by
  /// comparing the outgoing panel's Y against the last origin it set
  /// (`RecordingOverlayPanel.swift:1518`) — an inference that exists only
  /// because the panel is destroyed between presentations and the fact has to
  /// survive the rebuild. With one retained window, `windowDidMove` reports it
  /// directly. The probe run on 2026-08-21 confirmed the callback fires and
  /// that a programmatic-move depth flag separates a user drag from an app
  /// move; `NSEvent.pressedMouseButtons` was measured useless for this and is
  /// deliberately not used.
  enum Anchor: Equatable {
    case automatic(OverlayPillPosition, ScreenID)
    case user(CGPoint, ScreenID)
  }

  private(set) var anchor: Anchor?

  /// Shipped default: `visibleFrame.maxY - 60` for Top
  /// (`RecordingOverlayPanel.swift:400`).
  static let topOffsetFromVisibleTop: CGFloat = 60
  /// Shipped clamp margin (`:425`).
  static let topClampMargin: CGFloat = 8

  // MARK: - Anchor transitions

  mutating func beginFresh(at position: OverlayPillPosition, screen: ScreenGeometry) {
    // A genuinely new presentation starts clean; an earlier drag does not carry
    // over. That matches the contract the settings copy already promises, and
    // the shipped `wasManuallyDragged = false` on the fresh branch (`:1532`).
    anchor = .automatic(position, screen.id)
  }

  mutating func userDidMove(to origin: CGPoint, screen: ScreenGeometry) {
    anchor = .user(origin, screen.id)
  }

  /// True when the pill is where the user put it, on this screen.
  func isUserAnchored(on screen: ScreenID) -> Bool {
    if case .user(_, let anchored) = anchor { return anchored == screen }
    return false
  }

  // MARK: - The frame

  /// The one place a frame is computed.
  ///
  /// **X is preserved on a continuing presentation.** The shipped path computes
  /// `x` unconditionally as `targetScreen.visibleFrame.midX - resolvedWidth / 2`
  /// (`RecordingOverlayPanel.swift:1484`) BEFORE it branches on whether the
  /// presentation is continuing, and only `y` is inherited (`:1508`). That is
  /// #2195: a pill dragged sideways snaps back to centre the moment its content
  /// changes. Here both axes travel together in `OverlayContinuity`, so the
  /// half-inheritance cannot be expressed.
  func frame(
    for size: CGSize, continuity: OverlayContinuity, environment screen: ScreenGeometry
  ) -> CGRect {
    let x: CGFloat
    let requestedY: CGFloat

    switch continuity {
    case .fresh(let position, _):
      x = screen.visibleFrame.midX - size.width / 2
      requestedY = Self.freshOriginY(for: position, on: screen)

    case .continuing(let currentFrame, _, let outgoingWasContentSized):
      x = currentFrame.origin.x
      switch anchorPosition {
      case .top:
        // Ported from `Self.inheritedTopOriginY` (`:1420-1426`): re-anchor a
        // content-sized outgoing panel by its TOP edge, a fixed-frame one by
        // its CENTRE.
        requestedY =
          outgoingWasContentSized
          ? currentFrame.maxY - size.height
          : currentFrame.midY - size.height / 2
      case .bottom:
        // Bottom content is `.bottom`-aligned (#1341) and the preview grows
        // upward from a fixed bottom edge, so the outgoing bottom origin already
        // IS the visible bottom in both geometries. Preserve it (`:1508`).
        requestedY = currentFrame.origin.y
      }
    }

    return CGRect(
      x: x, y: Self.clampedOriginY(requestedY: requestedY, height: size.height, on: screen),
      width: size.width, height: size.height)
  }

  /// Re-anchor after the active Space changed.
  ///
  /// Bottom only, and that is deliberate rather than an omission: Top is
  /// measured from `visibleFrame.maxY`, which does not move when a full-screen
  /// space appears, so Top needs no re-anchor. Bottom does, because
  /// `visibleFrame.minY` reserves Dock space this background app still sees
  /// even when the Dock is hidden behind another app's full-screen space
  /// (`RecordingOverlayPanel.swift:354-395`, measured 2026-07-17).
  ///
  /// A user-dragged pill is left alone: the user's position outranks our rule.
  func repositionedFrameForSpaceChange(
    currentFrame: CGRect, on screen: ScreenGeometry
  ) -> CGRect? {
    guard case .automatic(let position, let anchoredScreen) = anchor,
      position == .bottom, anchoredScreen == screen.id
    else { return nil }

    let requestedY = Self.freshOriginY(for: .bottom, on: screen)
    guard abs(requestedY - currentFrame.origin.y) > 0.5 else { return nil }
    return CGRect(
      x: currentFrame.origin.x,
      y: Self.clampedOriginY(requestedY: requestedY, height: currentFrame.height, on: screen),
      width: currentFrame.width, height: currentFrame.height)
  }

  // MARK: - Rules

  private var anchorPosition: OverlayPillPosition {
    if case .automatic(let position, _) = anchor { return position }
    // A user-anchored pill preserves its own origin on a continuing
    // presentation, so the Top/Bottom re-anchor rule never applies to it; the
    // value here only selects which continuing branch runs, and Bottom's
    // "preserve the origin" is the correct behaviour for a dragged pill.
    return .bottom
  }

  /// Ported from `computeRequestedY` (`RecordingOverlayPanel.swift:398-413`).
  static func freshOriginY(for position: OverlayPillPosition, on screen: ScreenGeometry)
    -> CGFloat
  {
    switch position {
    case .top:
      return screen.visibleFrame.maxY - topOffsetFromVisibleTop
    case .bottom:
      // `visibleFrame` is Dock-reserved space as this background app sees it and
      // does NOT shrink when a DIFFERENT app is in native full screen — measured
      // empirically 2026-07-17, leaving an ~85pt gap. Drop to the true screen
      // edge in that case only.
      return screen.hasFullScreenSpace ? screen.frame.minY : screen.visibleFrame.minY
    }
  }

  /// Ported from `clampedOriginY` (`:422-427`). #1060: keep the whole panel
  /// inside the visible frame, because positioning a tall pill by its bottom
  /// origin would push its top under the menu bar.
  static func clampedOriginY(requestedY: CGFloat, height: CGFloat, on screen: ScreenGeometry)
    -> CGFloat
  {
    min(requestedY, screen.visibleFrame.maxY - height - topClampMargin)
  }
}
