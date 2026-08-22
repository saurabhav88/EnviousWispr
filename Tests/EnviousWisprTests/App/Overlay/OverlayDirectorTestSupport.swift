import Foundation
import Testing

@testable import EnviousWisprAppKit

/// A director for tests that need one only as a DEPENDENCY (#2292, C4c).
///
/// **Windowless because it uses a fake HOST, not because presentation fails.**
/// It matters because `NSApp` RETAINS an ordered-in window. Sixteen suites
/// construct an overlay purely to satisfy a constructor, and if each built a
/// real panel they would leave sixteen pills stacked on the developer's screen
/// for the life of the test process — which is exactly what happened when the
/// window suites first landed, until the founder sent a screenshot of 34 of them
/// over his terminal.
///
/// **The first version got that silence the wrong way** (#2292, C7). It resolved
/// NO SCREEN, so `OverlayWindowHost.present` refused — borrowing a production
/// failure path as a stub. Five suites then asserted on overlay state that only
/// existed because a refused presentation used to leave its owner behind, and
/// the moment that rollback was fixed all twenty of those assertions went blank.
/// A stub built on a failure path is testing the failure, and it fails silently
/// the day the failure is corrected.
///
/// `WindowlessOverlayHost` succeeds instead, so these suites observe the overlay
/// they always meant to. Geometry, ordering and the panel count stay with the
/// real host and its own suite; this one cannot answer a question about a frame
/// and does not pretend to.
@MainActor
enum OverlayTestDouble {

  /// A director that can be handed to anything and never draws.
  static func headlessDirector() -> OverlayDirector {
    OverlayDirector(
      host: WindowlessOverlayHost(),
      deliverEffect: { _ in },
      deliverAppAction: { _ in },
      // Announcements go nowhere: a test that has not asked for a screen has not
      // asked for VoiceOver either, and the real post reaches the system.
      announce: { _ in })
  }

  /// The same director, with its fake host in hand for a test that needs to
  /// assert on what the host was ASKED for.
  static func headlessDirectorWithHost() -> (OverlayDirector, WindowlessOverlayHost) {
    let host = WindowlessOverlayHost()
    return (
      OverlayDirector(
        host: host, deliverEffect: { _ in }, deliverAppAction: { _ in }, announce: { _ in }),
      host
    )
  }
}
