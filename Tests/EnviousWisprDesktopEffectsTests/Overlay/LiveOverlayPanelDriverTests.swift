import AppKit
@testable import EnviousWisprAppKit
import EnviousWisprDesktopEffects
import Testing

/// What the REAL panel is built as (#2455 C4, issue #2461).
///
/// These assertions used to live in `OverlayWindowHostTests`, where they read
/// `panel.styleMask` off the host's panel. That worked only because the "fake"
/// was a real `NSPanel` — which is the defect this chunk removes. They belong
/// here: this is the only test target the dep-direction gate permits to construct a live driver, and construction is
/// the driver's business rather than the host's.
///
/// **These deliberately touch a real window**, which is why this target exists
/// and why it is the only one that may.
@MainActor
@Suite(.tags(.productOutcome))
struct LiveOverlayPanelDriverTests {

  init() { _ = NSApplication.shared }

  @Test("the live driver builds a borderless, non-activating panel")
  func styleMaskIsBorderlessNonActivating() {
    let driver = LiveOverlayPanelDriver()
    defer { driver.orderOut() }

    // The two flags this test is NAMED for. An earlier revision asserted the
    // frame size instead — a test that moved and lost the thing it was moved to
    // check, which is worse than not moving it.
    let panel = driver.underlyingPanel
    #expect(panel.styleMask.contains(.borderless))
    #expect(panel.styleMask.contains(.nonactivatingPanel))
  }

  /// Both flags matter and for different reasons, so they are asserted apart:
  /// `.borderless` is why the pill has no title bar, and `.nonactivatingPanel` is
  /// why showing it does not steal the keyboard from whatever the user is typing
  /// in. Losing the second one is the founder-visible focus bug this epic exists
  /// to prevent, and it would not change a single pixel.
  @Test("the live driver does not take focus when ordered front")
  func orderingFrontDoesNotActivate() {
    let driver = LiveOverlayPanelDriver()
    defer { driver.orderOut() }

    driver.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 185, height: 44))

    // Captured BEFORE, and compared against AFTER. The earlier form asserted
    // `NSApp.isActive == false || NSApp.keyWindow == nil`, which is true of a
    // headless test process whatever the panel does — it would have passed with
    // `.nonactivatingPanel` removed.
    let wasActive = NSApp.isActive
    let previousKeyWindow = NSApp.keyWindow

    driver.orderFrontRegardless()

    #expect(driver.isVisible)
    #expect(NSApp.isActive == wasActive, "ordering the pill front changed app activation")
    #expect(NSApp.keyWindow === previousKeyWindow, "the pill took key from another window")
    #expect(
      driver.underlyingPanel.isKeyWindow == false,
      "a non-activating panel must never become key")
  }

  @Test("configuration set through the protocol reaches the real panel")
  func configurationRoundTrips() {
    let driver = LiveOverlayPanelDriver()
    defer { driver.orderOut() }

    driver.level = .floating
    driver.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    driver.hasShadow = true
    driver.isOpaque = false
    driver.isReleasedWhenClosed = false

    #expect(driver.level == .floating)
    #expect(driver.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
    #expect(driver.hasShadow)
    #expect(driver.isOpaque == false)
    #expect(driver.isReleasedWhenClosed == false, "a released panel cannot be retained")
  }
}
