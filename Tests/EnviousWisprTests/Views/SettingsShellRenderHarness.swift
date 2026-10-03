import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Renders the Settings frame's pieces to PNG so a human can LOOK at them (#3385).
///
/// **Harness Contract. An instrument, not a test of the product**, and NOT a substitute for
/// Live UAT. It draws production components: `SidebarNavRow` (the PR1 sidebar column, laid
/// out as the shell lays it out: group headings and rows in a 200pt card padded 8pt, and a
/// sheet of row states, hover forced through the render-only `hoverOverride`, which proves the
/// paint and not pointer delivery), `DictionarySettingsHeading` at the shell's page widths,
/// and `SettingsContentView` around a sentinel to show nothing sits above a page's content.
/// The sidebar column is composed here because the real one needs the whole window's services;
/// its rows and headings are the production row and group strings.
///
/// **Gated OFF by default.** Run it deliberately:
///
///     TEST_RUNNER_EW_RENDER_SETTINGS_SHELL=1 scripts/xcode-test.sh \
///       --filter EnviousWisprTests/SettingsShellRenderHarness
///
/// PNGs land in a fresh `build/settings-shell-render/run-*/` directory per run.
@MainActor
@Suite(.tags(.harnessContract))
struct SettingsShellRenderHarness {

  init() { _ = NSApplication.shared }

  static let runDirectory = RepoRoot.url.appending(
    path:
      "build/settings-shell-render/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
  )

  private static func render(_ label: String, width: CGFloat, dark: Bool, _ content: some View)
    throws -> URL
  {
    let host = NSHostingView(rootView: AnyView(content.frame(width: width)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let ideal = host.fittingSize
    let size = CGSize(width: width, height: max(ideal.height, 120))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds), "no bitmap rep")
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]), "no PNG encoding")
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let url = runDirectory.appending(path: "shell-\(label)-\(dark ? "dark" : "light").png")
    #expect(
      !FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) rendered twice")
    try png.write(to: url)
    let decoded = try #require(
      NSBitmapImageRep(data: try Data(contentsOf: url)), "\(url.path) does not decode")
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0, "\(url.path) is empty")
    print(
      "RENDERED shell \(label)-\(dark ? "dark" : "light"): \(Int(size.width))x\(Int(size.height)) (ideal \(ideal)) png \(decoded.pixelsWide)x\(decoded.pixelsHigh) -> \(url.path)"
    )
    window.contentView = nil
    return url
  }

  static func row(
    _ section: SettingsSection, selected: Bool,
    activity: SettingsShellCopy.SidebarActivity = .none, hover: Bool? = nil
  ) -> some View {
    SidebarNavRow(
      label: section.label, isSelected: selected, activity: activity, hoverOverride: hover
    ) {
      Image(systemName: section.icon)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(selected ? .white : .stAccent)
    } action: {
    }
  }

  /// The PR1 sidebar column: four groups, Dictation Settings selected, Dictionary busy.
  static var sidebarColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(SettingsGroup.allCases.enumerated()), id: \.offset) { index, group in
        if index > 0 { Divider().padding(.vertical, 6) }
        Text(group.heading)
          .font(.stSectionHeader).tracking(0.6).foregroundStyle(.stTextSecondary)
          .padding(.horizontal, 10).padding(.bottom, 3)
        ForEach(group.sections) { section in
          row(
            section, selected: section == .dictation,
            activity: section == .wordCorrection ? .dictionaryEnrichment : .none)
        }
      }
    }
    .padding(8)
    .background(Color.stSidebarBg)
  }

  /// Every row state the sidebar can show, one row each.
  static var stateSheet: some View {
    VStack(alignment: .leading, spacing: 6) {
      row(.history, selected: false)
      row(.dictation, selected: true)
      row(.wordCorrection, selected: false, activity: .dictionaryEnrichment)
      row(.wordCorrection, selected: true, activity: .dictionaryEnrichment)
      row(.transcribeFile, selected: false, activity: .fileImport)
      row(.transcribeFile, selected: true, activity: .fileImport)
      row(.keybinds, selected: false, hover: true)
      row(.dictation, selected: true, hover: true)
    }
    .padding(8)
    .background(Color.stSidebarBg)
  }

  static func dictionary(enabled: Bool) -> some View {
    DictionarySettingsHeading(isEnabled: .constant(enabled))
      .padding(.top, SettingsLayout.contentTop)
      .padding(.horizontal, SettingsLayout.contentH)
      .padding(.bottom, SettingsLayout.contentBottom)
      .background(Color.stPageBg)
  }

  static var sentinelPage: some View {
    SettingsContentView {
      Text(verbatim: "FIRST CONTENT")
        .font(.stSectionHeader)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Color.red.opacity(0.25))
    }
    .frame(height: 160)
  }

  @Test(
    "render the sidebar, the Dictionary heading and a header-less page",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_SETTINGS_SHELL"] == "1"))
  func renderTheShell() throws {
    var made: [URL] = []
    for dark in [false, true] {
      made.append(try Self.render("sidebar-column", width: 200, dark: dark, Self.sidebarColumn))
      made.append(try Self.render("sidebar-states", width: 200, dark: dark, Self.stateSheet))
      for (name, page) in [
        ("min-750", AppearanceRenderHarness.pageWidth(window: 750)),
        ("default-820", AppearanceRenderHarness.pageWidth(window: 820)),
        ("wide-1300", AppearanceRenderHarness.pageWidth(window: 1300)),
        ("stress-380", 380),
      ] {
        made.append(
          try Self.render(
            "dictionary-on-\(name)", width: page, dark: dark, Self.dictionary(enabled: true)))
      }
      made.append(
        try Self.render(
          "dictionary-off-default-820", width: AppearanceRenderHarness.pageWidth(window: 820),
          dark: dark, Self.dictionary(enabled: false)))
      made.append(
        try Self.render(
          "content-first-min-750", width: AppearanceRenderHarness.pageWidth(window: 750),
          dark: dark,
          Self.sentinelPage))
      made.append(
        try Self.render(
          "content-first-wide-1300", width: AppearanceRenderHarness.pageWidth(window: 1300),
          dark: dark, Self.sentinelPage))
    }
    #expect(made.count == 18, "rendered \(made.count) of 18 planned PNGs")
    #expect(Set(made).count == made.count, "two renders wrote one file")
  }
}
