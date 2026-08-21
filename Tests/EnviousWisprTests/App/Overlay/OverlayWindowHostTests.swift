import AppKit
import CoreGraphics
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2292 chunk C3. The retained window.
///
/// **Product Outcome.** When these fail the user sees the pill flicker as it is
/// destroyed and rebuilt (#930), jump sideways after they dragged it (#2195), or
/// a hidden window keeps swallowing clicks over an empty patch of screen.
///
/// These touch AppKit, so they build a real `NSPanel` — that is the point. The
/// probe on 2026-08-21 established what a retained panel costs
/// (`docs/audits/2026-08-21-overlay-probe-results.md`); this suite establishes
/// that OUR host retains exactly one and places it correctly. Screens are faked
/// so geometry is deterministic and a full-screen space is reachable, neither of
/// which a test can arrange on a real display.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayWindowHostTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  private static func host() -> OverlayWindowHost {
    OverlayWindowHost(screens: { OverlayScreenResolver { screen } })
  }

  private static func view(width: CGFloat, height: CGFloat) -> NSView {
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    v.setFrameSize(NSSize(width: width, height: height))
    return v
  }

  /// **The headline metric of the whole change.** The shipped panel destroys and
  /// rebuilds itself on every panel-replacing transition, and four compensating
  /// mechanisms exist only because of that.
  @Test("one panel is constructed however many presentations arrive")
  func onePanelForEveryPresentation() {
    let h = Self.host()
    for i in 0..<12 {
      h.present(
        Self.view(width: 185 + CGFloat(i), height: 44), width: .fixed(185 + CGFloat(i)),
        fixedHeight: nil, isFresh: i == 0, position: .bottom)
    }
    h.hide()
    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: true,
      position: .bottom)

    #expect(h.panelConstructionCount == 1)
  }

  /// #2195 end to end through the host, not just through the placement value.
  @Test("a continuing presentation keeps the pill where the user dragged it")
  func continuingKeepsTheDraggedPosition() throws {
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)

    // The user drags it well left of centre. `windowDidMove` is how the host
    // learns; there is no rebuild for the fact to survive.
    panel.setFrameOrigin(NSPoint(x: 120, y: 85))
    h.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: false,
      position: .bottom)

    #expect(panel.frame.origin.x == 120, "the pill snapped back to centre — this is #2195")
  }

  /// The paired case: a genuinely FRESH presentation must still centre, or the
  /// guard above is satisfied by a host that never centres anything.
  @Test("a fresh presentation is centred even after a drag")
  func freshRecentresAfterADrag() throws {
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)
    panel.setFrameOrigin(NSPoint(x: 120, y: 85))
    h.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
    h.hide()

    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)

    // Within a point, not exact: **AppKit aligns a window frame to whole
    // points**, so a placement value of 663.5 lands at 663.0. The value type is
    // right and the window is right; an exact float comparison against the
    // unrounded computation is what was wrong. Half a point is tight enough that
    // a pill left at 120 still fails this.
    #expect(abs(panel.frame.origin.x - (Self.screen.visibleFrame.midX - 92.5)) <= 0.5)
  }

  /// **A programmatic move is not a drag**, and telling them apart is what makes
  /// anchor promotion safe. The probe measured `NSEvent.pressedMouseButtons`
  /// reading 0 even mid-drag, so the depth flag is the only working
  /// discriminator and this is its guard.
  @Test("the host's own frame changes never count as a user drag")
  func programmaticMovesAreNotDrags() {
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    // Every present/resize/reposition below moves the panel, and each fires
    // `windowDidMove` for real.
    h.resizeCurrentPresentation(to: CGSize(width: 240, height: 60))
    h.repositionForActiveSpaceChange()
    h.present(
      Self.view(width: 300, height: 60), width: .fixed(300), fixedHeight: nil, isFresh: false,
      position: .bottom)

    #expect(
      h.placementForTesting.isUserAnchored(on: Self.screen.id) == false,
      "the host mistook its own frame change for the user dragging the pill")
  }

  @Test("a real drag does count")
  func aRealDragCounts() throws {
    // Paired with the case above: a host that never promotes would pass it.
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)
    panel.setFrameOrigin(NSPoint(x: 400, y: 300))
    h.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

    #expect(h.placementForTesting.isUserAnchored(on: Self.screen.id))
  }

  /// `orderOut`, never `close`. Closing is what forces the rebuild.
  @Test("hiding orders the panel out and keeps it alive")
  func hideOrdersOutWithoutClosing() throws {
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)
    #expect(panel.isVisible)

    h.hide()

    #expect(panel.isVisible == false, "a hidden panel still on screen swallows clicks")
    #expect(h.panelForTesting === panel, "hiding released the panel — it must be retained")
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    #expect(h.panelConstructionCount == 1, "showing after a hide rebuilt the panel")
  }

  /// **`hide()` must ORDER OUT, and a mutation control is what proved this test
  /// was needed.** Substituting `close()` for `orderOut` left all eight cases
  /// green: with `isReleasedWhenClosed = false` a closed panel is still alive,
  /// still the same instance, still `isVisible == false`, and the construction
  /// count is unchanged — every assertion the suite had. The distinction that
  /// matters is not observable through any of them.
  ///
  /// `close()` posts `willCloseNotification`; `orderOut` does not. Observing the
  /// notification needs no production seam and no text matching, so it holds
  /// whatever the method is called. The C5 freeze assertion (zero `.close()`
  /// calls in the overlay module) is a second, structural protection — but it
  /// does not exist yet, and deferring to it would have left the central claim
  /// of this change unguarded for two chunks.
  @Test("hiding never closes the window")
  func hideNeverCloses() throws {
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)

    nonisolated(unsafe) var closed = false
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: panel, queue: nil
    ) { _ in closed = true }
    defer { NotificationCenter.default.removeObserver(token) }

    h.hide()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    h.hide()

    #expect(
      closed == false,
      "the panel was CLOSED rather than ordered out — every rebuild this change removes comes from that")
  }

  /// A `.measured` width must come from the view, and no default may stand in
  /// for it. Escape Recovery's real width is computed from text metrics, so a
  /// literal there would look plausible and silently disagree with the pill.
  @Test("a measured width is taken from the view, not from a default")
  func measuredWidthComesFromTheView() throws {
    let h = Self.host()
    h.present(
      Self.view(width: 271, height: 58), width: .measured, fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)
    #expect(panel.frame.width == 271)
  }

  /// The #1060 reserved interaction frame survives the migration. It is NOT
  /// universal — only the non-preview recording pill asks for it — so the host
  /// must honour a fixed height when given one and measure when not.
  @Test("a fixed height is honoured and overrides the view's own")
  func fixedHeightIsHonoured() throws {
    let h = Self.host()
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .bottom)
    let panel = try #require(h.panelForTesting)
    #expect(panel.frame.height == 92)
  }
}
