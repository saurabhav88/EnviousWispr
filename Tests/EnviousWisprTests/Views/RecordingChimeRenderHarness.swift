import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Renders the real Chimes page to PNG so a human can LOOK at it (#3385).
///
/// **Harness Contract. An instrument, not a test of the product**, and NOT a substitute for
/// Live UAT: no window chrome, no accessibility tree, no sound, no running app. It draws the
/// production `RecordingChimesContent` (the page `RecordingSoundsSettingsView` shows) with its
/// state passed in, at the shell's page widths, light and dark, idle, switched off, and
/// during dictation.
///
/// **Gated OFF by default**, so CI never renders and no geometry is frozen. Run it deliberately:
///
///     TEST_RUNNER_EW_RENDER_CHIMES=1 scripts/xcode-test.sh \
///       --filter EnviousWisprTests/RecordingChimeRenderHarness
///
/// PNGs land in a fresh `build/pr1-lane-d/chimes-render/run-*/` directory per run. A skipped run has
/// proven nothing.
@MainActor
@Suite(.tags(.harnessContract))
struct RecordingChimeRenderHarness {

  init() { _ = NSApplication.shared }

  static let runDirectory = RepoRoot.url.appending(
    path:
      "build/pr1-lane-d/chimes-render/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")

  private static func render(
    _ label: String, pageWidth: CGFloat, dark: Bool, playsChimes: Bool, dictating: Bool
  ) throws -> URL {
    let page = RecordingChimesContent(
      playsChimes: .constant(playsChimes),
      selected: .dustMote,
      isDictationActive: dictating,
      onSelect: { _ in },
      onPreview: { _ in }
    )
    // The app's Dictation tab host supplies the PR1 row density; render with it.
    .environment(\.settingsPR1Density, true)
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
    let url = runDirectory.appending(path: "chimes-\(label).png")
    #expect(
      !FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) rendered twice")
    try png.write(to: url)
    let decoded = try #require(
      NSBitmapImageRep(data: try Data(contentsOf: url)), "\(url.path) does not decode")
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0, "\(url.path) is empty")
    print(
      "RENDERED chimes \(label): page \(Int(size.width))x\(Int(size.height)) (content ideal \(ideal)) png \(decoded.pixelsWide)x\(decoded.pixelsHigh) grid columns \(RecordingChimeGrid.columns(forWidth: pageWidth - 2 * SettingsLayout.contentH)) -> \(url.path)"
    )
    window.contentView = nil
    return url
  }

  @Test(
    "render the Chimes page at the widths a user gets, idle, off and while dictating",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_CHIMES"] == "1"))
  func renderTheChimesPage() throws {
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
            "\(name)-on-idle-\(dark ? "dark" : "light")", pageWidth: width, dark: dark,
            playsChimes: true, dictating: false))
      }
    }
    let defaultWidth = AppearanceRenderHarness.pageWidth(window: 820)
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      made.append(
        try Self.render(
          "default-820-off-idle-\(scheme)", pageWidth: defaultWidth, dark: dark,
          playsChimes: false, dictating: false))
      made.append(
        try Self.render(
          "default-820-on-dictating-\(scheme)", pageWidth: defaultWidth, dark: dark,
          playsChimes: true, dictating: true))
    }
    #expect(made.count == 12, "rendered \(made.count) of 12 planned PNGs")
    #expect(Set(made).count == made.count, "two renders wrote one file")
  }
}
