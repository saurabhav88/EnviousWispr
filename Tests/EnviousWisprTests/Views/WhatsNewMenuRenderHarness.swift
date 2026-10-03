import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Offscreen render of production menu content. Does not attach to the dev app
/// or prove popover anchoring, keyboard focus, pointer clicks or VoiceOver.
@MainActor
@Suite(.tags(.harnessContract))
struct WhatsNewMenuRenderHarness {
  private final class Notifier: UpdateNotifying {
    var onInstallTapped: (() -> Void)?
    func post(displayVersion: String) {}
    func activateTapRouting() {}
  }

  init() { _ = NSApplication.shared }

  @Test(
    "Render original full release descriptions at 750, 820 and 1300pt in light and dark",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_WHATS_NEW"] == "1"))
  func renderMenu() throws {
    let directory = RepoRoot.url.appending(path: "build/gift-render/run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let defaults = try #require(TestDefaults.suite("ew.giftRender.\(UUID().uuidString)"))
    defaults.set("0.0.0", forKey: WhatsNewConstants.lastSeenVersionDefaultsKey)
    let settings = SettingsManager(defaults: defaults)
    let coordinator = UpdateCoordinator(
      updaterController: nil, defaults: defaults, notifier: Notifier(), attendedCheck: {})
    let holder = UpdateCoordinatorHolder()
    holder.coordinator = coordinator
    let readDefaults = try #require(TestDefaults.suite("ew.giftRenderRead.\(UUID().uuidString)"))
    let readSettings = SettingsManager(defaults: readDefaults)
    #expect(settings.hasUnreadWhatsNew && !readSettings.hasUnreadWhatsNew)
    let entries = WhatsNewMenuPresentation.entries()
    #expect(entries.map(\.description) == WhatsNewContent.entries
      .filter { $0.version == "2.5.2" }.map(\.description))
    for width in [750, 820, 1300] {
      for dark in [false, true] {
        let content = VStack(alignment: .trailing, spacing: 12) {
          HStack(spacing: 12) {
            WhatsNewToolbarButton().environment(readSettings)
            WhatsNewToolbarButton()
          }
          WhatsNewMenuView(coordinator: coordinator, entries: entries)
        }
        .environment(settings)
        .environment(holder)
        .environment(\.settingsPR1Density, true)
        .frame(width: CGFloat(width), height: 600, alignment: .topTrailing)
        .background(Color.stWindowBg)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 600)
        let window = NSWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = directory.appending(path: "gift-\(width)-\(dark ? "dark" : "light").png")
        try png.write(to: url)
        print("RENDERED gift -> \(url.path)")
        window.contentView = nil
      }
    }
  }
}
