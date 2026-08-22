import Foundation
import Testing

@testable import EnviousWisprAppKit

/// A director for tests that need one only as a DEPENDENCY (#2292, C4c).
///
/// **Headless: it resolves no screen, so `OverlayWindowHost.present` refuses
/// before it can build an `NSPanel`.** That refusal is a real production path —
/// no screen, or an unsizable presentation — not a stub, so these tests exercise
/// the same code every other caller does and simply never reach a window.
///
/// It matters because `NSApp` RETAINS an ordered-in window. Sixteen suites
/// construct an overlay purely to satisfy a constructor, and if each built a
/// real panel they would leave sixteen pills stacked on the developer's screen
/// for the life of the test process — which is exactly what happened when the
/// window suites first landed, until the founder sent a screenshot of 34 of them
/// over his terminal.
@MainActor
enum OverlayTestDouble {

  /// A director that can be handed to anything and never draws.
  static func headlessDirector() -> OverlayDirector {
    OverlayDirector(
      host: OverlayWindowHost(screens: { OverlayScreenResolver { nil } }),
      deliverEffect: { _ in },
      deliverAppAction: { _ in },
      // Announcements go nowhere: a test that has not asked for a screen has not
      // asked for VoiceOver either, and the real post reaches the system.
      announce: { _ in })
  }
}
