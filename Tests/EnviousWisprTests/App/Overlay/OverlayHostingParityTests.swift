import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

// #2455 C4 (#2461): STAYS in the unit target, and the chunk plan expected it to
// move.
//
// The plan's reason was "the unit target cannot both exclude DesktopEffects and
// compile a suite that uses it". Once the panel is injected, this suite does not
// use it: what it compares is two HOST implementations — `OverlayWindowHost`
// against `WindowlessOverlayHost` — and the `NSPanel` underneath was incidental to
// that comparison. It was also the thing that flashed on screen. With a recording
// driver the comparison is unchanged and nothing displays, so moving it would
// carry it across a boundary it no longer crosses.
//
// `OverlayRetainedWindowRealPanelTests` DOES construct the live driver, and that
// suite is why `EnviousWisprDesktopEffectsTests` exists.

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
    let real = OverlayWindowHost(
      screens: { OverlayScreenResolver { screen } }, effects: .recording())
    realHosts.append(real)
    return [("real", real), ("windowless", WindowlessOverlayHost())]
  }

  private static func closeRealHosts() {
    for host in realHosts { host.hide() }
    realHosts.removeAll()
  }

  private static func director(on host: any OverlayWindowHosting) -> OverlayDirector {
    OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      openMicrophoneSettings: {},
      selections: { .shipped },
      firstRenderSchedule: { $0() })
  }

  @Test("both hosts report a presentation they accepted")
  func presentationSucceedsOnBothHosts() {
    defer { Self.closeRealHosts() }
    for (name, host) in Self.hosts() {
      let d = Self.director(on: host)

      d.present(.warning(reason: .polishFailed))

      #expect(
        d.renderModel.state.presentation != nil,
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
        d.renderModel.state.presentation == nil,
        "the \(name) host left a pill on screen after hiding")
    }
  }
}
