import AppKit
import CoreGraphics
import EnviousWisprCore
import SwiftUI

/// Sole owner of the overlay's `NSPanel` (#2292, chunk C3).
///
/// **One panel for the app's lifetime, created lazily once and morphed
/// thereafter.** That single change is what removes the four compensating
/// mechanisms the shipped panel needs only because it destroys and rebuilds
/// itself on every panel-replacing transition: the inherited-frame plumbing that
/// carries Y across a rebuild, the drag-deferral that postpones work while the
/// user holds the panel, the parallel `OverlayNoticeState` channel whose own doc
/// comment says it exists so a notice can morph the live pill "WITHOUT tearing
/// the panel down", and the generation counters.
///
/// ## What the probe established, 2026-08-21
///
/// Measured on a disposable spike before any of this was written
/// (`docs/audits/2026-08-21-overlay-probe-results.md`), because keeping a window
/// alive that the shipped code closes is the one decision that could have sent
/// the design back:
///
/// - **One construction across 203 presentations**, including a size morph.
/// - Hidden with `orderOut`, the panel is absent from `NSApp`'s on-screen count,
///   absent from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` — the list
///   Mission Control and the screenshot path draw from — and absent from a real
///   screenshot taken while hidden.
/// - **Memory converges**: flat at 45.0 MB from cycle 126 through 200, a
///   one-time cost of ~2.7 MB. Ten cycles, which is what the plan specified,
///   could NOT have shown that — at ten the curve is still rising and
///   convergence is indistinguishable from a slow leak.
///
/// Two constraints came out of it and both are honoured here rather than
/// rediscovered later:
///
/// - **`occlusionState` is unreliable and is never read.** It reported
///   `.visible` while `isVisible == false` at five of nine samples, settling
///   only after an idle beat. A guard built on it would be a confident wrong
///   answer, not a flake.
/// - **Right after `orderOut` in a fast cycle the window server may still list
///   the window, at alpha 0.00.** Invisible, but present. Any test asserting
///   `onScreen == 0` immediately after hide will flake; assert absent OR alpha 0.
@MainActor
final class OverlayWindowHost: NSObject, NSWindowDelegate {

  /// `nil` until the first presentation. Never closed, never released.
  private var panel: NSPanel?
  private var placement = OverlayPlacementState()
  private let screens: () -> OverlayScreenResolver

  /// Whether the CURRENT occupant was sized from its content, which the Top
  /// continuing rule needs in order to choose top-edge versus centre
  /// re-anchoring.
  private var currentWasContentSized = false

  /// Non-zero while this object is moving the panel itself.
  ///
  /// **This is the `windowDidMove` discriminator, and it is not the one §11.3
  /// proposed.** The plan named `NSEvent.pressedMouseButtons`; the probe
  /// measured it reading **0 at every callback including the drag one**, so it
  /// cannot separate a user drag from a programmatic move and is deliberately
  /// not used. A depth counter around our own frame changes can, and the probe
  /// confirmed it: both programmatic moves flagged, the drag-induced callback
  /// not flagged.
  private var programmaticMoveDepth = 0

  #if DEBUG
    /// The #2292 acceptance metric: reads 1 after a full dictation exercising
    /// every transition.
    private(set) var panelConstructionCount = 0
  #endif

  init(screens: @escaping () -> OverlayScreenResolver = { .live }) {
    self.screens = screens
    super.init()
  }

  // MARK: - Presenting

  /// Show `view`, sized by `width`, morphing the existing panel rather than
  /// replacing it.
  ///
  /// `isFresh` distinguishes a genuinely new presentation from one continuing an
  /// existing on-screen pill. It is the caller's fact, not something to infer
  /// from whether a panel happens to exist: a panel retained but hidden is not
  /// a continuation.
  func present(
    _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
    position: OverlayPillPosition
  ) {
    guard let screen = screens().current() else { return }
    let panel = ensurePanel()

    let size = resolvedSize(for: view, width: width, fixedHeight: fixedHeight)
    let continuity: OverlayContinuity
    if isFresh || !panel.isVisible {
      placement.beginFresh(at: position, screen: screen)
      continuity = .fresh(position: position, screen: screen.id)
    } else {
      continuity = .continuing(
        currentFrame: panel.frame, anchoredScreen: screen.id,
        outgoingWasContentSized: currentWasContentSized)
    }

    view.frame = NSRect(origin: .zero, size: size)
    panel.contentView = view
    currentWasContentSized = width == .measured || fixedHeight == nil

    let frame = placement.frame(for: size, continuity: continuity, environment: screen)
    withProgrammaticMove { panel.setFrame(frame, display: true) }
    panel.orderFrontRegardless()
  }

  /// Resize the CURRENT occupant without treating it as a new presentation.
  /// Live Preview grows the pill mid-recording; the shipped path cannot do this
  /// without a rebuild, which is the whole reason the preview's size is fixed
  /// for a panel's lifetime today.
  func resizeCurrentPresentation(to size: CGSize) {
    guard let panel, panel.isVisible, let screen = screens().current() else { return }
    let frame = placement.frame(
      for: size,
      continuity: .continuing(
        currentFrame: panel.frame, anchoredScreen: screen.id,
        outgoingWasContentSized: currentWasContentSized),
      environment: screen)
    withProgrammaticMove { panel.setFrame(frame, display: true) }
  }

  /// **`orderOut`, never `close`.** Closing is what forces every rebuild, and
  /// `hide` is the only thing standing between a retained panel and a hidden
  /// window that still swallows clicks — the panel accepts events across its
  /// whole frame because it is drag-to-relocate.
  func hide() {
    panel?.orderOut(nil)
  }

  /// Re-anchor after the active Space changed. Bottom only, and never for a pill
  /// the user moved — both rules live in `OverlayPlacementState`.
  func repositionForActiveSpaceChange() {
    guard let panel, panel.isVisible, let screen = screens().current() else { return }
    guard
      let frame = placement.repositionedFrameForSpaceChange(
        currentFrame: panel.frame, on: screen)
    else { return }
    withProgrammaticMove { panel.setFrame(frame, display: true, animate: true) }
  }

  // MARK: - Window ownership

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    #if DEBUG
      panelConstructionCount += 1
    #endif
    // Configuration copied verbatim from `RecordingOverlayPanel.swift:1467-1479`
    // so this chunk changes the panel's LIFETIME and nothing about its identity.
    let p = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 185, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    p.isReleasedWhenClosed = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isMovableByWindowBackground = true
    p.hasShadow = true
    p.delegate = self
    panel = p
    return p
  }

  private func resolvedSize(for view: NSView, width: OverlayWidth, fixedHeight: CGFloat?)
    -> CGSize
  {
    // **`fittingSize` can be zero, and a zero-sized panel is an INVISIBLE pill
    // that reports success.** A plain `NSView` with no constraints returns
    // `.zero`, and so does a hosting view asked before layout. Found by a test
    // fixture rather than by review, which is the useful direction: the failure
    // is silent, so nothing would have reported it in production either.
    //
    // Fall back to the view's own frame, which is what a caller that sized its
    // view already means. Never to a literal default — a plausible number here
    // is exactly what `.measured` exists to forbid.
    let fitting = view.fittingSize
    let fallback = view.frame.size
    let measuredWidth = fitting.width > 0 ? fitting.width : fallback.width
    let measuredHeight = fitting.height > 0 ? fitting.height : fallback.height
    let w: CGFloat
    switch width {
    case .fixed(let value): w = value
    case .measured: w = measuredWidth
    }
    return CGSize(width: w, height: fixedHeight ?? measuredHeight)
  }

  private func withProgrammaticMove(_ body: () -> Void) {
    programmaticMoveDepth += 1
    body()
    programmaticMoveDepth -= 1
  }

  /// The user dragged the pill, so its position outranks our placement rules for
  /// the rest of this presentation.
  ///
  /// **With one retained window this is a direct observation.** The shipped code
  /// can only INFER it, by comparing the outgoing panel's Y against the last
  /// origin it set (`RecordingOverlayPanel.swift:1518`) — an inference that
  /// exists solely because the panel is destroyed between presentations and the
  /// fact has to survive the rebuild. Nothing survives a rebuild here, because
  /// there is no rebuild.
  nonisolated func windowDidMove(_ notification: Notification) {
    MainActor.assumeIsolated {
      guard programmaticMoveDepth == 0, let panel, let screen = screens().current() else { return }
      placement.userDidMove(to: panel.frame.origin, screen: screen)
    }
  }

  #if DEBUG
    var placementForTesting: OverlayPlacementState { placement }
    var panelForTesting: NSPanel? { panel }
    var isProgrammaticallyMovingForTesting: Bool { programmaticMoveDepth > 0 }
  #endif
}

/// How the host learns about screens.
///
/// A seam rather than a direct `NSScreen` read, so the host's geometry decisions
/// are exercisable against invented displays — a full-screen space, a second
/// monitor — none of which can be arranged from a unit test.
struct OverlayScreenResolver {
  let current: () -> ScreenGeometry?

  /// Mirrors the shipped target-screen resolution
  /// (`RecordingOverlayPanel.swift:1444-1449`): the screen under the pointer,
  /// then main, then the first attached.
  @MainActor
  static let live = OverlayScreenResolver {
    let target =
      NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main ?? NSScreen.screens.first
    guard let target else { return nil }
    return ScreenGeometry(
      id: ScreenID(rawValue: target.deviceDescription[.init("NSScreenNumber")] as? Int ?? 0),
      frame: target.frame,
      visibleFrame: target.visibleFrame,
      hasFullScreenSpace: OverlayScreenResolver.isFrontmostAppFullScreen(on: target))
  }

  /// #1341: `NSScreen.visibleFrame` does NOT shrink when a DIFFERENT app is in
  /// native full screen and the Dock is hidden from view — measured empirically
  /// 2026-07-17, leaving an ~85pt unused gap below the pill.
  ///
  /// **Ported verbatim from `RecordingOverlayPanel.swift:1571-1601`, not written
  /// from a description of it.** The first version of this method here was
  /// composed from memory and differed in two behaviour-changing ways: it
  /// omitted the `screen == NSScreen.main` guard, so it would have reported full
  /// screen on secondary displays where the shipped code never does, and it
  /// scanned `kAXWindowsAttribute` — every window — instead of
  /// `kAXFocusedWindowAttribute`. A behaviour change wearing a port's clothes.
  ///
  /// Untrusted for Accessibility this answers false and the pill keeps the
  /// Dock-safe position, which is the shipped fallback. The alternative is
  /// requesting Screen Recording, which is a product decision and not something
  /// to fold into a positioning fix.
  @MainActor
  private static func isFrontmostAppFullScreen(on screen: NSScreen) -> Bool {
    guard screen == NSScreen.main, AXIsProcessTrusted(),
      let frontApp = NSWorkspace.shared.frontmostApplication
    else { return false }
    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedWindow: AnyObject?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        == .success,
      let focusedWindow
    else { return false }
    // `AXUIElement` is a CFTypeRef-family type: neither `as!` nor `as?` performs
    // a real dynamic type check here (verified empirically — both silently
    // "succeed" on a wrong CF type instead of crashing or returning nil), so a
    // checked cast would only be misleading. `kAXFocusedWindowAttribute` is
    // documented to always yield an AXUIElement on `.success`; the subsequent
    // AX call is what actually fails gracefully if that contract is ever broken.
    // swift-format-ignore: NeverForceUnwrap
    let window = focusedWindow as! AXUIElement
    var fullScreenValue: AnyObject?
    guard
      AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreenValue)
        == .success
    else { return false }
    return (fullScreenValue as? Bool) ?? false
  }
}
