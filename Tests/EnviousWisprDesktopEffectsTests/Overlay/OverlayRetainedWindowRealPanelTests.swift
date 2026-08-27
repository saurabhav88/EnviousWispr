import AppKit
@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprDesktopEffects
import Testing

// #2455 C4 (#2461): moved out of `EnviousWisprTests`.
//
// This suite DELIBERATELY drives a real `NSPanel` — that is its entire value, and
// it is exactly why it cannot live in the unit target any more. `EnviousWisprTests`
// is not permitted by `check-dependency-direction.sh` to import
// `EnviousWisprDesktopEffects`. Xcode would let it — the gate is what does not.
//
// The chunk plan named only `OverlayHostingParityTests` as needing to move. This
// suite was found by grepping for the live factory after that one was handled.

/// The unit target's pure recorder proves the host issues the right COMMANDS; it says
/// nothing about what a real `NSPanel` does in response to them, because the
/// pure recorder is not a window at all. This suite injects
/// `LiveOverlayPanelDriver` itself — the identical driver production uses —
/// so the panel under test is exactly what ships.
///
/// **Show / hide / show, asserting identity across all three, not just the
/// last one.** A host that rebuilt on hide would still show correctly the
/// second time; only comparing the SAME `ObjectIdentifier` across the full
/// cycle catches that.
///
/// **`willCloseNotification`, not just final visibility.** `isVisible == false`
/// is what BOTH `orderOut` and `close` leave behind on a panel with
/// `isReleasedWhenClosed = false` — the earlier mutation control found exactly
/// this (`compensatingMechanismsStayGone`'s sibling test up the file). The
/// notification is the only observation that tells them apart without reading
/// private host state.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayRetainedWindowRealPanelTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  @Test("a real panel survives show, hide, show with identity intact")
  func showHideShowRetainsTheRealPanel() throws {
    // **A CAPTURING factory, not `firstView.window`.** Reading the panel off
    // the attached view can only see the panel that ended up attached — it is
    // blind to an extra real panel constructed and then discarded before or
    // instead of that one. Wrapping `.live` itself, so every panel it
    // constructs is genuinely production configuration, is what lets
    // `constructedPanels.count == 1` prove there was only ever ONE.
    var constructedPanels: [LiveOverlayPanelDriver] = []
    let capturingEffects = DesktopOverlayEffects(
      makePanel: {
        let panel = LiveOverlayPanelDriver()
        constructedPanels.append(panel)
        return panel
      },
      workspace: LiveWorkspaceObserver())
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { Self.screen } }, effects: capturingEffects)

    nonisolated(unsafe) var closed = false
    var closeToken: NSObjectProtocol?
    defer { closeToken.map(NotificationCenter.default.removeObserver) }

    let firstView = NSView(frame: NSRect(x: 0, y: 0, width: 185, height: 44))
    #expect(
      host.present(
        firstView, width: .fixed(185), fixedHeight: nil, isFresh: true, position: .bottom)
    )
    #expect(constructedPanels.count == 1, "the first presentation built more than one panel")
    let panel = try #require(constructedPanels.first)
    #expect(
      firstView.window === panel.underlyingPanel,
      "the view attached to a DIFFERENT panel than was built")
    closeToken = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: panel.underlyingPanel, queue: nil
    ) { _ in closed = true }
    defer { host.hide() }

    #expect(panel.isVisible, "show did not put the panel on screen")
    #expect(panel.contentView === firstView, "show did not attach the content view")

    host.hide()
    #expect(panel.isVisible == false, "hide left the panel on screen")
    #expect(panel.contentView == nil, "hide left the previous content attached")

    let secondView = NSView(frame: NSRect(x: 0, y: 0, width: 185, height: 44))
    #expect(
      host.present(
        secondView, width: .fixed(185), fixedHeight: nil, isFresh: true, position: .bottom)
    )
    #expect(
      constructedPanels.count == 1,
      "showing after a hide built a SECOND real panel — the window is not retained")
    let secondPanel = try #require(secondView.window)

    #expect(
      ObjectIdentifier(secondPanel) == ObjectIdentifier(panel.underlyingPanel),
      "show after hide built a NEW panel — the window is not retained")
    #expect(secondPanel.isVisible, "the second show did not put the panel back on screen")
    #expect(secondPanel.contentView === secondView, "the second show kept the old content view")
    #expect(
      closed == false,
      "the panel was CLOSED at some point in show/hide/show — orderOut never posts this")
  }
}
