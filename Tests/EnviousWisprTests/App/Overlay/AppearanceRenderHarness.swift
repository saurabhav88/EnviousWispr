import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Renders the real Appearance page to PNG so a human can LOOK at it (#2435), and since #3385
/// the Recording Pill tab the pill controls moved to.
///
/// **Harness Contract. It asserts almost nothing and is not a test of the
/// product** — it is an instrument, and it exists because this page's whole
/// subject is PAINT, which every other instrument here is blind to.
/// `NSHostingView.fittingSize` measures layout; `RenderedPillHarness` records
/// that it cannot see icon, colour, corner shape or `scaleEffect`. A flat level
/// meter, a pill drawn at the wrong size, a clipped theme title and a capsule
/// frozen at the wrong opacity are all invisible to every size assertion in this
/// target — and three of those four actually happened on this change.
///
/// **It is NOT a substitute for Live UAT and must never be cited as one.** It
/// renders SwiftUI views in a test process: no window server chrome, no real
/// scroll interaction, no accessibility tree, no running app. What it does give,
/// on a machine where the screen is LOCKED and no input can be driven, is a true
/// picture of what the layout code produces at a given width — which is the half
/// of a design review that does not need a person clicking.
///
/// **Gated OFF by default**, so CI never renders and no absolute geometry is ever
/// frozen. Run it deliberately:
///
///     TEST_RUNNER_EW_RENDER_APPEARANCE=1 scripts/xcode-test.sh \
///       --filter EnviousWisprTests/AppearanceRenderHarness
///
/// PNGs land in a fresh `build/appearance-render/run-*/` directory per run. A skipped receipt is not a passed
/// receipt: when this row is skipped it has proven nothing at all.
@MainActor
@Suite(.tags(.harnessContract))
struct AppearanceRenderHarness {

  init() { _ = NSApplication.shared }

  private static func model(_ capability: PillWordsCapability) -> (SettingsManager, PillAppearanceModel) {
    let name = "ew.appearanceRender." + UUID().uuidString
    let suite = TestDefaults.suite(name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)
    return (settings, PillAppearanceModel(settings: settings, capability: { capability }))
  }

  /// The two production pages this harness draws (#3385: the pill controls moved from
  /// Appearance to the Recording Pill tab, so both are rendered).
  enum Page: String { case appearance, pill }

  /// The page host's width for a window width, with the current shell: the window minus three
  /// `SettingsLayout.windowFrameInset` gutters and the 200pt sidebar. 750 gives 508, the 820
  /// default 578, 1300 gives 1058. That is the PAGE, before `SettingsContentView`'s own
  /// `SettingsLayout.contentH` margins; rows, cards and previews are narrower again.
  ///
  /// #3385: corrects the old note here ("the 820pt default leaves ~530 inside after the
  /// sidebar and insets"), which was the content width after the margins, not the page.
  static func pageWidth(window: CGFloat) -> CGFloat {
    window - 3 * SettingsLayout.windowFrameInset - 200
  }

  /// One fresh directory per run, so a PNG left by an earlier run can never pass as this one's.
  static let runDirectory = RepoRoot.url.appending(
    path: "build/appearance-render/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")

  /// Render one page at one width and scheme to a PNG; returns the PNG's URL after proving it
  /// decodes to a nonzero bitmap.
  ///
  /// The page header is suppressed explicitly (the shell injects it, not the page), the Pill
  /// page gets a harmless navigation closure, and Appearance's language and relaunch are never
  /// touched: the page only READS the preference and relaunches on a user's confirmation.
  @discardableResult
  private static func render(
    _ page: Page, label: String, pageWidth: CGFloat, dark: Bool,
    capability: PillWordsCapability = .available
  ) throws -> URL {
    let (settings, pill) = model(capability)
    let content: AnyView =
      switch page {
      case .appearance: AnyView(AppearanceSettingsView())
      case .pill: AnyView(PillSettingsView())
      }
    let root = content
      .environment(settings)
      .environment(pill)
      .environment(\.settingsPageSection, nil)
      .environment(\.settingsNavigate, { _ in })
      .frame(width: pageWidth)

    let host = NSHostingView(rootView: AnyView(root))
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
      host.bitmapImageRepForCachingDisplay(in: host.bounds),
      "the host produced no bitmap rep, so this render proved nothing")
    host.cacheDisplay(in: host.bounds, to: rep)

    let png = try #require(
      rep.representation(using: .png, properties: [:]),
      "the bitmap did not encode to PNG")

    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let url = runDirectory.appending(path: "\(page.rawValue)-\(label).png")
    #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) rendered twice")
    try png.write(to: url)

    let decoded = try #require(
      NSBitmapImageRep(data: try Data(contentsOf: url)), "\(url.path) does not decode")
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0, "\(url.path) is empty")
    print(
      "RENDERED \(page.rawValue) \(label): page \(Int(size.width))x\(Int(size.height)) (content ideal \(ideal)) png \(decoded.pixelsWide)x\(decoded.pixelsHigh) -> \(url.path)"
    )
    window.contentView = nil
    return url
  }

  @Test(
    "render the Appearance and Recording Pill pages at the widths a user actually gets",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_APPEARANCE"] == "1"))
  func renderBothPages() throws {
    // 750: the minimum window. 820: the shipped default. 1300: a wide window, where the
    //      pill cards sit side by side.
    // 380: a stress page deliberately narrower than any window gives, which is the only case
    //      that shows how a card and a row fall back when there is no room.
    let widths: [(String, CGFloat)] = [
      ("min-750", Self.pageWidth(window: 750)),
      ("default-820", Self.pageWidth(window: 820)),
      ("wide-1300", Self.pageWidth(window: 1300)),
      ("stress-380", 380),
    ]
    #expect(widths.map(\.1).prefix(3) == [508, 578, 1058], "the shell's page widths moved")
    var made: [URL] = []
    for page in [Page.appearance, .pill] {
      for (name, width) in widths {
        for dark in [false, true] {
          made.append(
            try Self.render(page, label: "\(name)-\(dark ? "dark" : "light")", pageWidth: width, dark: dark))
        }
      }
    }
    // The states no other render reaches, at the minimum window.
    for (state, capability) in [
      ("preview-off", PillWordsCapability.previewOff),
      ("engine-unsupported", .engineUnsupported),
      ("model-being-removed", .modelBeingRemoved),
    ] {
      made.append(
        try Self.render(
          .pill, label: "\(state)-min-750-light", pageWidth: Self.pageWidth(window: 750), dark: false,
          capability: capability))
    }
    #expect(made.count == 19, "rendered \(made.count) of 19 planned PNGs")
    #expect(Set(made).count == made.count, "two renders wrote one file")
  }
}
