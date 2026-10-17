import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprDesktopEffects
import Testing

@testable import EnviousWisprAppKit

/// #3850 (ENVIOUSWISPR-7F): the pill's SwiftUI view must never resize its window.
///
/// When the hosting view WAS the panel's content view, every window layout let it resize the
/// panel to its own idea of the pill's size (`NSHostingView.windowDidLayout` →
/// `updateAnimatedWindowSize`), away from the frame `OverlayWindowHost` placed. In English the
/// "Downloading Parakeet Ultra" pill settled at 289 x 51; in German it never settled, and AppKit
/// ended the loop with NSGenericException at launch on every German 2.5.4 update.
///
/// The test host runs in English, which is enough: the drift happens in every language, and the
/// drift is what the loop is made of. It needs a REAL panel, because the resize is AppKit's own
/// window layout acting on a real window, so it lives in this target.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayPanelSizeOwnershipTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  @Test("the download pill keeps the frame the host placed after the window lays out")
  func downloadPillKeepsTheHostsFrame() throws {
    var panels: [LiveOverlayPanelDriver] = []
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { Self.screen } },
      effects: DesktopOverlayEffects(
        makePanel: {
          let panel = LiveOverlayPanelDriver()
          panels.append(panel)
          return panel
        },
        workspace: LiveWorkspaceObserver()))
    defer { host.hide() }
    let director = OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })

    let receipt = director.present(
      .parakeetUpgrade(
        ParakeetUpgradePillModel(phase: .downloading(fraction: 0.4)), isStillWanted: { true }))
    try #require(receipt != nil, "the overlay refused the download pill")
    let panel = try #require(panels.first?.underlyingPanel, "no real panel was built")
    #expect(panel.isVisible, "the download pill never reached the screen")
    // The pill wraps at the message width with a content height (#3912), so the host's own
    // placement is the reference; the width is the catalog's.
    let placed = panel.frame.size
    #expect(
      placed.width == PillCatalog.messageWidth && placed.height > 0,
      "the host placed \(placed), not a \(PillCatalog.messageWidth)-wide pill")

    // The crash's own path, run now: a Core Animation commit flushes AppKit's
    // display cycle, which lays the window out and calls
    // `NSHostingView.windowDidLayout`. On the parent of #3850 this one call moves
    // the window to 289 x 51; `layoutIfNeeded` alone does not reach it.
    CATransaction.flush()

    #expect(
      panel.frame.size == placed,
      "the pill's view resized its window to \(panel.frame.size) after layout; the host placed \(placed)"
    )

    // A pill that grows (the live-preview recording pill) asks the HOST to resize,
    // and the view must follow the window down through the container.
    let grown = CGSize(width: PillCatalog.messageWidth, height: placed.height + 36)
    host.resizeCurrentPresentation(to: grown)
    CATransaction.flush()
    let view = try #require(panel.contentView?.subviews.first, "the pill's view left the panel")
    #expect(panel.frame.size == grown, "the host asked for \(grown); the window is \(panel.frame.size)")
    #expect(
      view.frame.size == grown,
      "the window grew to \(grown) and the pill's view stayed \(view.frame.size)")
  }
}
