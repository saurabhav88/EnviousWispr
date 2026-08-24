import AppKit
import CoreGraphics
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
/// ordering and `panelConstructionCount` are NOT here — the fake has no frame
/// and must not be encouraged to invent one. `OverlayWindowHostTests` owns those
/// and always will.
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
      host: host,       announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      deferFirstRender: { $0() })

    d.present(.warning(reason: .polishFailed))

    #expect(host.presented.count == 1, "the fake was never asked to present")
    #expect(host.isShowing, "the fake accepted a presentation and then reported nothing showing")

    d.dismissCurrent(.announced)

    #expect(host.hideCount == 1, "the fake was never asked to hide")
    #expect(!host.isShowing, "the fake was hidden and still reports a presentation showing")
  }
}

/// The half that COMPARES the two hosts.
///
/// **Release-visible since C6.** It needed the director's debug seams to do the
/// comparison, which confined it to the Debug lane; it now reads `renderModel`,
/// which is production surface, so both hosts are compared in both lanes.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayHostingParityTests {

  init() { _ = NSApplication.shared }

  private static var realHosts: [OverlayWindowHost] = []

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  /// Both hosts, behind the protocol, so a case is written ONCE and runs
  /// twice. A per-host copy is how the two definitions drift apart without
  /// anything failing.
  private static func hosts() -> [(name: String, host: any OverlayWindowHosting)] {
    let real = OverlayWindowHost(screens: { OverlayScreenResolver { screen } })
    realHosts.append(real)
    return [("real", real), ("windowless", WindowlessOverlayHost())]
  }

  private static func closeRealHosts() {
    for host in realHosts { host.hide() }
    realHosts.removeAll()
  }

  private static func director(on host: any OverlayWindowHosting) -> OverlayDirector {
    OverlayDirector(
      host: host,         announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      deferFirstRender: { $0() })
  }

  @Test("both hosts report a presentation they accepted")
  func presentationSucceedsOnBothHosts() {
    defer { Self.closeRealHosts() }
    for (name, host) in Self.hosts() {
      let d = Self.director(on: host)

      d.present(.warning(reason: .polishFailed))

      #expect(
        d.renderModel.presentation != nil,
        "the \(name) host refused a presentation the other accepted")
    }
  }

  @Test("both hosts release the slot when the overlay is hidden")
  func hidingClearsOnBothHosts() {
    defer { Self.closeRealHosts() }
    for (name, host) in Self.hosts() {
      let d = Self.director(on: host)
      d.present(.warning(reason: .polishFailed))

      d.dismissCurrent(.announced)

      #expect(
        d.renderModel.presentation == nil,
        "the \(name) host left a pill on screen after hiding")
    }
  }
}
