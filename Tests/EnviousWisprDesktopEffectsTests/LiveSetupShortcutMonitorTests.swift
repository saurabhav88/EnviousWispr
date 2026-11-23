import AppKit
import Testing

@testable import EnviousWisprDesktopEffects

@MainActor
@Suite("Setup shortcut monitor", .tags(.productOutcome))
struct LiveSetupShortcutMonitorTests {
  private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }

  @Test("Only handled events from the key Setup window are consumed")
  func routing() throws {
    _ = NSApplication.shared
    let window = KeyWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let other = KeyWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    func event(in window: NSWindow) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
          windowNumber: window.windowNumber, context: nil, characters: "a",
          charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }
    let ownEvent = try event(in: window)
    let otherEvent = try event(in: other)
    #expect(ownEvent.window === window)
    #expect(otherEvent.window === other)
    let consumed = LiveSetupShortcutMonitor.consumes(ownEvent, in: window, handling: { _ in true })
    #expect(consumed)
    #expect(
      LiveSetupShortcutMonitor.consumes(ownEvent, in: window, handling: { _ in false }) == false)
    #expect(
      LiveSetupShortcutMonitor.consumes(otherEvent, in: window, handling: { _ in true }) == false)
    #expect(LiveSetupShortcutMonitor.consumes(ownEvent, in: nil, handling: { _ in true }) == false)
  }
}
