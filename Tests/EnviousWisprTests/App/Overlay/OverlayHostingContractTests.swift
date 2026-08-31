import AppKit
import CoreGraphics
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// The contract BOTH `OverlayWindowHosting` implementations must satisfy
/// (#2292, C7).
///
/// **A fake is only useful while it still means the same thing as the real
/// one.** `WindowlessOverlayHost` exists so sixteen suites can observe a
/// successful presentation without a window, and the whole value of that
/// disappears the day it answers differently from `OverlayWindowHost` for the
/// same request. A protocol change produces a compile error; a SEMANTIC drift
/// produces nothing at all, which is what this suite is for.
///
/// Scoped to what both can honestly claim: a presentation succeeds, a hide takes
/// it down, and the director's own view of the world follows. Geometry, window
/// ordering and the panel construction count are NOT here — the fake has no
/// frame and must not be encouraged to invent one. `OverlayWindowHostTests`
/// owns those and always will.
///
/// **The split below used to be a LANE split and is now only a subject split.**
/// The cross-host comparisons read `presentedIDForTesting` and
/// `currentPresentationForTesting`, which lived inside `#if DEBUG` on the
/// director, so the whole comparing half was Debug-only — and a Debug-only local
/// run cannot see that by construction, because the failure is a COMPILE break
/// with zero failure marks rather than a red test. C6 deleted those seams; both
/// halves now read the render model and both lanes execute them.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayHostingContractTests {

  init() { _ = NSApplication.shared }

  /// **The specific drift that would matter most, and it runs in BOTH lanes.**
  ///
  /// The fake replaced a stub that got its silence by refusing, so the one way
  /// it could silently regress is by starting to refuse again — which would look
  /// exactly like the twenty blank assertions the C7 rollback produced, and for
  /// the same reason.
  ///
  /// Asserted entirely on the fake's OWN record, which is why no debug seam is
  /// involved: `send` is production API, and a host that was asked to present
  /// and says it is showing has accepted. That is the whole claim.
  @Test("the windowless host accepts every presentation it is asked for")
  func theFakeNeverRefuses() {
    let host = WindowlessOverlayHost()
    let d = OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      openMicrophoneSettings: {},
      selections: { .shipped },
      firstRenderSchedule: { $0() })

    d.present(.warning(reason: .polishFailed))

    #expect(host.presented.count == 1, "the fake was never asked to present")
    #expect(host.isShowing, "the fake accepted a presentation and then reported nothing showing")

    d.dismissCurrent(.announced)

    #expect(host.hideCount == 1, "the fake was never asked to hide")
    #expect(!host.isShowing, "the fake was hidden and still reports a presentation showing")
  }
}
