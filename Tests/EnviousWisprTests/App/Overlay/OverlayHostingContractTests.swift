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
/// **THE SPLIT BELOW IS DELIBERATE, and this branch has already paid for getting
/// it wrong once.** The cross-host comparisons read `presentedIDForTesting` and
/// `currentPresentationForTesting`, which live inside `#if DEBUG` on the
/// director, so they cannot exist in the Release lane — a Debug-only local run
/// cannot see that by construction, and the failure is a COMPILE break with zero
/// failure marks rather than a red test. The guard that matters most needs no
/// seam at all, so it stays outside and runs in both lanes.
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

    d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)

    #expect(host.presented.count == 1, "the fake was never asked to present")
    #expect(host.isShowing, "the fake accepted a presentation and then reported nothing showing")

    d.send(.pipeline(.hidden), actions: nil)

    #expect(host.hideCount == 1, "the fake was never asked to hide")
    #expect(!host.isShowing, "the fake was hidden and still reports a presentation showing")
  }
}

#if DEBUG
  /// The half that COMPARES the two hosts, and it needs the director's debug
  /// seams to do it. See the note on the suite above for why that confines it to
  /// the Debug lane rather than making it optional.
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

        d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)

        #expect(
          d.presentedIDForTesting != nil,
          "the \(name) host refused a presentation the other accepted")
        #expect(
          d.currentPresentationForTesting != nil,
          "the \(name) host left the reducer without an occupant after a success")
      }
    }

    @Test("both hosts release the slot when the overlay is hidden")
    func hidingClearsOnBothHosts() {
      defer { Self.closeRealHosts() }
      for (name, host) in Self.hosts() {
        let d = Self.director(on: host)
        d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)

        d.send(.pipeline(.hidden), actions: nil)

        #expect(d.presentedIDForTesting == nil, "the \(name) host still claims a presentation")
        #expect(
          d.currentPresentationForTesting == nil,
          "the \(name) host left an occupant behind after hiding")
      }
    }
  }
#endif
