import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Renders the real Clipboard page to PNG so a human can LOOK at it (#3385).
///
/// **Harness Contract. An instrument, not a test of the product**, and NOT a substitute for
/// Live UAT: no window chrome, no accessibility tree, no clipboard, no running app. It draws the
/// production `ClipboardSettingsView` with an isolated `SettingsManager` (pages have no header
/// since #3385), at the shell's page widths, light and dark, with the switch values each render
/// names. Those values are fixtures, not claims about shipping defaults.
///
/// **Gated OFF by default**, so CI never renders and no geometry is frozen. Run it deliberately:
///
///     TEST_RUNNER_EW_RENDER_CLIPBOARD=1 scripts/xcode-test.sh \
///       --filter EnviousWisprTests/ClipboardSettingsRenderHarness
///
/// PNGs land in a fresh `build/clipboard-render/run-*/` directory per run. A skipped run has
/// proven nothing.
@MainActor
@Suite(.tags(.harnessContract))
struct ClipboardSettingsRenderHarness {

  init() { _ = NSApplication.shared }

  static let runDirectory = RepoRoot.url.appending(
    path:
      "build/clipboard-render/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
  )

  /// Auto-copy, Restore, Smart insertion, Quick Add.
  typealias Values = (Bool, Bool, Bool, Bool)

  private static func render(_ label: String, pageWidth: CGFloat, dark: Bool, values: Values)
    throws -> URL
  {
    let name = "ew.clipboardRender." + UUID().uuidString
    let suite = TestDefaults.suite(name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)
    settings.autoCopyToClipboard = values.0
    settings.restoreClipboardAfterPaste = values.1
    settings.smartInsertion = values.2
    settings.quickAddClipboardFallback = values.3

    let page = ClipboardSettingsView()
      .environment(settings)
      .frame(width: pageWidth)
    let host = NSHostingView(rootView: AnyView(page))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let ideal = host.fittingSize
    let size = CGSize(width: pageWidth, height: max(ideal.height, 400))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let rep = try #require(
      host.bitmapImageRepForCachingDisplay(in: host.bounds), "the host produced no bitmap rep")
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]), "no PNG encoding")

    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let url = runDirectory.appending(path: "clipboard-\(label).png")
    #expect(
      !FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) rendered twice")
    try png.write(to: url)
    let decoded = try #require(
      NSBitmapImageRep(data: try Data(contentsOf: url)), "\(url.path) does not decode")
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0, "\(url.path) is empty")
    print(
      "RENDERED clipboard \(label): page \(Int(size.width))x\(Int(size.height)) (content ideal \(ideal)) card \(Int(pageWidth - 2 * SettingsLayout.contentH)) row \(Int(pageWidth - 2 * SettingsLayout.contentH - 2 * SettingsLayout.rowPaddingH)) png \(decoded.pixelsWide)x\(decoded.pixelsHigh) -> \(url.path)"
    )
    window.contentView = nil
    return url
  }

  @Test(
    "render the Clipboard page at the widths a user gets, all on, all off and mixed",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_CLIPBOARD"] == "1"))
  func renderTheClipboardPage() throws {
    let widths: [(String, CGFloat)] = [
      ("min-750", AppearanceRenderHarness.pageWidth(window: 750)),
      ("default-820", AppearanceRenderHarness.pageWidth(window: 820)),
      ("wide-1300", AppearanceRenderHarness.pageWidth(window: 1300)),
      ("stress-380", 380),
    ]
    #expect(widths.map(\.1).prefix(3) == [508, 578, 1058], "the shell's page widths moved")
    var made: [URL] = []
    for (name, width) in widths {
      for dark in [false, true] {
        made.append(
          try Self.render(
            "\(name)-all-on-\(dark ? "dark" : "light")", pageWidth: width, dark: dark,
            values: (true, true, true, true)))
      }
    }
    let defaultWidth = AppearanceRenderHarness.pageWidth(window: 820)
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      made.append(
        try Self.render(
          "default-820-all-off-\(scheme)", pageWidth: defaultWidth, dark: dark,
          values: (false, false, false, false)))
      made.append(
        try Self.render(
          "default-820-mixed-\(scheme)", pageWidth: defaultWidth, dark: dark,
          values: (true, false, true, false)))
    }
    #expect(made.count == 12, "rendered \(made.count) of 12 planned PNGs")
    #expect(Set(made).count == made.count, "two renders wrote one file")
  }
}
