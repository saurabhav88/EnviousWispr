import AppKit
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #3850: a pill with a fixed width and a content height gets the height of its
/// WRAPPED text from the host's own measurement.
///
/// Until #3850 the host measured the #1891 advisory as one unwrapped line and
/// placed a 39-point window; the hosting view, as the window's content view,
/// then stretched the window to fit. That stretching was the launch crash loop,
/// and the view can no longer reach the window, so a wrong measurement now shows
/// as clipped text. The oracle is `RenderedPillHarness`, which builds its own
/// hosting view in its own window and proposes the width itself, so it does not
/// read the host's measurement or the root view's proposal.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayWrappedPillHeightTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  @Test("the hinted advisory window is as tall as its wrapped sentence")
  func hintedAdvisoryGetsItsWrappedHeight() throws {
    let hint = MultiInputAdvisoryHint(deviceName: "Scarlett 2i2 USB")
    let recorder = OverlayPanelCommandRecorder()
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { Self.screen } }, effects: recorder.makeEffects())
    defer { host.hide() }
    let director = OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      openMicrophoneSettings: {}, advisoryHint: { _ in hint },
      selections: { .shipped }, firstRenderSchedule: { $0() })

    let receipt = director.present(.advisory(reason: .zeroSignal))
    try #require(receipt != nil, "the overlay refused the advisory")
    let placed = try #require(
      recorder.commands.compactMap { command -> CGSize? in
        if case .setFrame(_, let frame, _, _) = command { return frame.size }
        return nil
      }.last,
      "the host never placed the advisory's window")

    let wrapped = RenderedPillHarness.rootSize(for: .advisory(reason: .zeroSignal, hint: hint))
    try #require(
      wrapped.width > 0 && wrapped.height > 0,
      "the harness measured \(wrapped), which is not a measurement")
    #expect(
      placed == wrapped,
      "the host placed the advisory at \(placed); its sentence wraps to \(wrapped) at its width")
  }
}
