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
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`) — an inference that exists only
  /// because the panel is destroyed between presentations and the fact has to
  /// survive the rebuild. With one retained window, `windowDidMove` reports it
  /// directly. The probe run on 2026-08-21 confirmed the callback fires and
  /// that a programmatic-move depth flag separates a user drag from an app
  /// move; `NSEvent.pressedMouseButtons` was measured useless for this and is
  /// deliberately not used.
  enum Anchor: Equatable {
    case automatic(OverlayPillPosition, ScreenID)
    /// Carries the edge the pill was created with. The first version dropped it,
    /// so a dragged pill lost its Top/Bottom provenance and every continuing
    /// transition fell through to the Bottom rule — silently changing how a
    /// dragged Top pill re-anchors. Cloud review found it.
    case user(CGPoint, OverlayPillPosition, ScreenID)
  }

  private(set) var anchor: Anchor?

  /// Shipped default: `visibleFrame.maxY - 60` for Top
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`).
  static let topOffsetFromVisibleTop: CGFloat = 60
  /// Shipped clamp margin.
  static let topClampMargin: CGFloat = 8

  // MARK: - Anchor transitions

  mutating func beginFresh(at position: OverlayPillPosition, screen: ScreenGeometry) {
    // A genuinely new presentation starts clean; an earlier drag does not carry
    // over. That matches the contract the settings copy already promises, and
    // the shipped `wasManuallyDragged = false` on the fresh branch.
    anchor = .automatic(position, screen.id)
  }

  mutating func userDidMove(to origin: CGPoint, screen: ScreenGeometry) {
    anchor = .user(origin, anchorPosition, screen.id)
  }

  /// True when the pill is where the user put it, on this screen.
  func isUserAnchored(on screen: ScreenID) -> Bool {
    if case .user(_, _, let anchored) = anchor { return anchored == screen }
    return false
  }

  // MARK: - The frame

  /// The one place a frame is computed.
  ///
  /// **X is preserved on a continuing presentation.** The shipped path computes
  /// `x` unconditionally as `targetScreen.visibleFrame.midX - resolvedWidth / 2`
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`) BEFORE it branches on whether the
  /// presentation is continuing, and only `y` is inherited. That is
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

    case .continuing(let currentFrame, let anchoredScreen, let outgoingWasContentSized):
      // **X is preserved for a DRAGGED pill and recomputed for an automatic
      // one, and the anchor kind is the only thing that can tell them apart.**
      //
      // Preserving it unconditionally, which the first version did, fixes #2195
      // and creates its mirror: an automatically centred 185-point recording
      // pill becoming a 280-point warning keeps its LEFT EDGE, so the pill
      // visibly slides sideways on every width-changing transition. The shipped
      // path recomputed X unconditionally and had the opposite half of the bug.
      //
      // `anchoredScreen` was being discarded here. It is exactly the fact the
      // decision needs: a user anchor belongs to the screen it was made on.
      x =
        isUserAnchored(on: anchoredScreen)
        ? currentFrame.origin.x
        : screen.visibleFrame.midX - size.width / 2
      switch anchorPosition {
      case .top:
        // Ported from `origin/main`'s `RecordingOverlayPanel.inheritedTopOriginY`:
        // re-anchor a
        // content-sized outgoing panel by its TOP edge, a fixed-frame one by
        // its CENTRE.
        requestedY =
          outgoingWasContentSized
          ? currentFrame.maxY - size.height
          : currentFrame.midY - size.height / 2
      case .bottom:
        // Bottom content is `.bottom`-aligned (#1341) and the preview grows
        // upward from a fixed bottom edge, so the outgoing bottom origin already
        // IS the visible bottom in both geometries. Preserve it.
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
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`, measured 2026-07-17).
  ///
  /// A user-dragged pill is left alone: the user's position outranks our rule.
  /// `screen` is the CURRENT target screen the caller resolved, not the screen
  /// the pill was anchored to. Shipped that site re-resolves the target every
  /// time (mouse-containing screen, then main, then first) and re-anchors onto
  /// it, so a Space change that also moves the pill's context moves the pill.
  /// The first version rejected a different screen, which would have stranded
  /// the pill on the old one.
  mutating func repositionedFrameForSpaceChange(
    currentFrame: CGRect, on screen: ScreenGeometry
  ) -> CGRect? {
    guard case .automatic(let position, _) = anchor, position == .bottom else { return nil }
    // **Take ownership of the resolved screen even when the frame does not
    // move.** The earlier version returned a frame for the new screen while the
    // anchor still named the old one, so `isUserAnchored(on:)` and every later
    // decision keyed on the stale id. Two displays with identical coordinates
    // expose it precisely BECAUSE the geometry check returns nil — nothing
    // moves, and the ownership silently never transfers.
    anchor = .automatic(position, screen.id)

    // Shipped that site recentres X here rather than preserving it. That is NOT the
    // #2195 defect wearing a different hat: this path only ever runs for an
    // `.automatic` anchor, which is centred by definition, and the guard above
    // returns early for a pill the user moved. Preserving X, as the first
    // version did, is indistinguishable on the same screen and WRONG when the
    // target screen changed.
    let x = screen.visibleFrame.midX - currentFrame.width / 2
    let requestedY = Self.freshOriginY(for: .bottom, on: screen)
    let y = Self.clampedOriginY(
      requestedY: requestedY, height: currentFrame.height, on: screen)
    guard abs(x - currentFrame.origin.x) > 0.5 || abs(y - currentFrame.origin.y) > 0.5 else {
      return nil
    }
    return CGRect(x: x, y: y, width: currentFrame.width, height: currentFrame.height)
  }

  // MARK: - Rules

  /// The edge this pill was created with, whether or not the user has since
  /// moved it. The first version returned `.bottom` for a `.user` anchor on the
  /// argument that a dragged pill preserves its own origin anyway — which is
  /// true of the BOTTOM branch and false of the Top one, where a dragged Top
  /// pill would have stopped re-anchoring by top-edge or centre. That is the
  /// shape of argument this repo keeps recording: correct about the case in
  /// front of you, silently wrong about its twin.
  private var anchorPosition: OverlayPillPosition {
    switch anchor {
    case .automatic(let position, _): return position
    case .user(_, let position, _): return position
    case nil: return .bottom
    }
  }

  /// Ported from `origin/main`'s `RecordingOverlayPanel.computeRequestedY`.
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

  /// Ported from `origin/main`'s `RecordingOverlayPanel.clampedOriginY`.
  /// #1060: keep the whole panel
  /// inside the visible frame, because positioning a tall pill by its bottom
  /// origin would push its top under the menu bar.
  static func clampedOriginY(requestedY: CGFloat, height: CGFloat, on screen: ScreenGeometry)
    -> CGFloat
  {
    min(requestedY, screen.visibleFrame.maxY - height - topClampMargin)
  }
}

// MARK: - Screens and geometry

/// A screen's stable identity, so placement can say "the same screen" without
/// holding an `NSScreen` and without AppKit being present in a test.
struct ScreenID: Hashable, Sendable {
  let rawValue: Int
  init(rawValue: Int) { self.rawValue = rawValue }
}

/// Everything placement needs to know about a screen. A value, so the geometry
/// rules are exercisable against invented screens — including the ones that are
/// awkward to obtain on the dev machine, such as a display whose `visibleFrame`
/// is inset by a notch or by a full-screen space.
struct ScreenGeometry: Equatable, Sendable {
  let id: ScreenID
  /// Full display bounds.
  let frame: CGRect
  /// Bounds excluding menu bar and Dock.
  let visibleFrame: CGRect
  /// True when the screen currently shows a full-screen space, which is the
  /// condition the Bottom rule keys off.
  let hasFullScreenSpace: Bool

  init(id: ScreenID, frame: CGRect, visibleFrame: CGRect, hasFullScreenSpace: Bool = false) {
    self.id = id
    self.frame = frame
    self.visibleFrame = visibleFrame
    self.hasFullScreenSpace = hasFullScreenSpace
  }
}

/// Whether a presentation is arriving into an empty slot or replacing a live one.
///
/// **`continuing` carries the COMPLETE current frame, both axes.** That is the
/// whole of the #2195 fix: the shipped path inherits only `y` and always
/// recentres `x`, so a pill the user dragged horizontally jumps back to centre
/// the moment its content changes. A single value carrying the whole rect makes
/// the half-inheritance unrepresentable rather than merely discouraged.
enum OverlayContinuity: Equatable, Sendable {
  case fresh(position: OverlayPillPosition, screen: ScreenID)
  /// `outgoingWasContentSized` is required, not optional: the shipped Top rule
  /// re-anchors a content-sized outgoing panel by its TOP edge and a
  /// fixed-frame one by its CENTRE, and getting that wrong moves the pill
  /// vertically on an ordinary recording-to-polishing hand-off.
  case continuing(
    currentFrame: CGRect, anchoredScreen: ScreenID, outgoingWasContentSized: Bool)
}

