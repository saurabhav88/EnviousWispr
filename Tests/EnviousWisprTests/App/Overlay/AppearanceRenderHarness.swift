import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Renders the real Appearance page to PNG so a human can LOOK at it (#2435).
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
/// PNGs land in `build/appearance-render/`. A skipped receipt is not a passed
/// receipt: when this row is skipped it has proven nothing at all.
@MainActor
@Suite(.tags(.harnessContract))
struct AppearanceRenderHarness {

  init() { _ = NSApplication.shared }

  private static func model(_ capability: PillWordsCapability) -> (SettingsManager, PillAppearanceModel) {
    let name = "ew.appearanceRender." + UUID().uuidString
    let suite = UserDefaults(suiteName: name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)
    return (settings, PillAppearanceModel(settings: settings, capability: { capability }))
  }

  /// Render one width to a PNG and return the size it actually took.
  ///
  /// **The width is the CONTENT area, not the window.** The settings window's
  /// 820pt default leaves ~530 inside after the sidebar and insets; the wide case
  /// is what ~1300 leaves. Passing a window width here would measure a page that
  /// does not exist.
  @discardableResult
  private static func render(
    _ label: String, contentWidth: CGFloat, capability: PillWordsCapability = .available
  ) throws -> CGSize {
    let (settings, pill) = model(capability)
    let page = AppearanceSettingsView()
      .environment(settings)
      .environment(pill)
      .frame(width: contentWidth)

    let host = NSHostingView(rootView: AnyView(page))
    let ideal = host.fittingSize
    let size = CGSize(width: contentWidth, height: max(ideal.height, 400))
    host.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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

    let dir = RepoRoot.url.appending(path: "build/appearance-render")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "appearance-\(label).png")
    try png.write(to: url)

    print("RENDERED \(label): \(Int(size.width))x\(Int(size.height)) -> \(url.path)")
    return size
  }

  @Test(
    "render the Appearance page at the widths a user actually gets",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_APPEARANCE"] == "1"))
  func renderTheAppearancePage() throws {
    // 530: the content area at the shipped 820pt default window.
    // 1010: roughly what a ~1300pt window leaves, where both groups sit side by side.
    // 380: deliberately narrower than one reading-well tile, which is the only
    //      case that can show whether the horizontal scroll fallback is chosen.
    try Self.render("default-530", contentWidth: 530)
    try Self.render("wide-1010", contentWidth: 1010)
    try Self.render("narrow-380", contentWidth: 380)
    // The greyed group, which no other render reaches.
    try Self.render("preview-off-530", contentWidth: 530, capability: .previewOff)
  }
}
