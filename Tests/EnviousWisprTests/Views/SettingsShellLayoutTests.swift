import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Settings frame without page headers. **When this fails, a sidebar label is cut
/// off or changes size when selected or busy, the Dictionary heading row clips at a narrow
/// window, or a page draws something above its own first section again.** Production views
/// hosted here: `SidebarNavRow`, `DictionarySettingsHeading` and `SettingsContentView`, each
/// wrapped only in a background probe that reports its frame.
///
/// Relations only; printed sizes are this Mac's. Limits: plain buttons are not NSViews and
/// there is no accessibility tree, so hover delivery, presses and spoken values are final Live
/// UAT (the values themselves are pinned in `SettingsShellEnglishTests`).
@MainActor
@Suite("Settings shell layout (#3385)", .tags(.productOutcome))
struct SettingsShellLayoutTests {

  init() { _ = NSApplication.shared }

  /// The sidebar card is 200pt; its list pads 8pt each side.
  static let sidebarRowWidth: CGFloat = 200 - 2 * 8

  struct Frames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
      value.merge(nextValue()) { $1 }
    }
  }

  @MainActor final class Box { var frames: [String: CGRect] = [:] }

  static func probe(_ key: String) -> some View {
    GeometryReader { proxy in
      Color.clear.preference(key: Frames.self, value: [key: proxy.frame(in: .named("host"))])
    }
  }

  static func frames(width: CGFloat, _ content: some View) -> [String: CGRect] {
    let box = Box()
    let root =
      content
      .frame(width: width)
      .fixedSize(horizontal: false, vertical: true)
      .coordinateSpace(name: "host")
      .onPreferenceChange(Frames.self) { value in MainActor.assumeIsolated { box.frames = value } }
    let host = NSHostingView(rootView: AnyView(root))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.contentView = nil
    return box.frames
  }

  static func row(
    _ section: SettingsPage, selected: Bool, activity: SettingsShellCopy.SidebarActivity = .none
  ) -> some View {
    SidebarNavRow(label: section.label, isSelected: selected, activity: activity) {
      Image(systemName: section.icon).font(.system(size: 15, weight: .medium))
    } action: {
    }
  }

  @Test(
    "every sidebar row fills its width, shows its whole label, and keeps its size when selected or busy"
  )
  func sidebarRows() throws {
    var heights: [String: CGFloat] = [:]
    for section in SettingsPage.allCases {
      let variants: [(String, Bool, SettingsShellCopy.SidebarActivity)] = [
        ("rest", false, .none), ("selected", true, .none),
        ("busy", false, .fileImport), ("selectedBusy", true, .dictionaryEnrichment),
      ]
      var sizes: [String: CGRect] = [:]
      for (name, selected, activity) in variants {
        let frames = Self.frames(
          width: Self.sidebarRowWidth,
          Self.row(section, selected: selected, activity: activity).background(Self.probe("row")))
        sizes[name] = try #require(frames["row"], "\(section) \(name) measured nothing")
      }
      print(
        "SidebarRow \(section.rawValue) label=\(section.label) \(sizes.sorted { $0.key < $1.key })")
      let rest = try #require(sizes["rest"])
      #expect(abs(rest.width - Self.sidebarRowWidth) < 0.5, "\(section) row is \(rest.width) wide")
      #expect(rest.height > 20 && rest.height < 80, "\(section) row is \(rest.height) tall")
      for (name, frame) in sizes {
        #expect(
          frame.size == rest.size, "\(section) \(name) is \(frame.size), at rest \(rest.size)")
      }
      // At the tightest width a resting row fits on one line, a busy row must still fit on
      // one line: the dot's slot is reserved at rest, so it cannot rewrap the label.
      let tightest = NSHostingView(rootView: Self.row(section, selected: false)).fittingSize.width
      var tightHeights: [String: CGFloat] = [:]
      for (name, activity) in [
        ("rest", SettingsShellCopy.SidebarActivity.none), ("busy", .fileImport),
      ] {
        let frames = Self.frames(
          width: tightest,
          Self.row(section, selected: false, activity: activity).background(Self.probe("row")))
        tightHeights[name] = try #require(
          frames["row"], "\(section) \(name) at \(tightest) measured nothing"
        ).height
      }
      #expect(
        tightHeights["busy"] == tightHeights["rest"],
        "\(section) rewraps when busy at \(tightest): \(tightHeights)")
      heights[section.rawValue] = rest.height
    }
    // A label too long for one line wraps (a taller row), it is never squeezed below 14pt.
    let shortest = try #require(heights.values.min())
    #expect(heights.values.allSatisfy { $0 >= shortest })
    print("SidebarRowHeights \(heights.sorted { $0.key < $1.key })")
  }

  @Test("the gift is an icon-sized target with its full name for hover and VoiceOver")
  func iconOnlyGiftFits() throws {
    let defaults = try #require(TestDefaults.suite("ew.iconGift.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    let holder = UpdateCoordinatorHolder()
    let host = NSHostingView(
      rootView: WhatsNewToolbarButton()
        .environment(settings).environment(holder))
    let width = host.fittingSize.width
    print("GiftButton width=\(width)")
    // A caption beside the icon would add ~150pt; an icon-only pill is ~36pt.
    #expect(width >= 28 && width <= 60)
  }

  /// Content widths inside the page margins for the shell's page widths.
  static let contentWidths: [CGFloat] = [380, 508, 578, 1058].map {
    $0 - 2 * SettingsLayout.contentH
  }

  @Test("the Dictionary heading row fits every width, taller rather than clipped when narrow")
  func dictionaryHeading() throws {
    var heights: [CGFloat] = []
    for width in Self.contentWidths {
      let frames = Self.frames(
        width: width,
        DictionarySettingsHeading(isEnabled: .constant(true)).background(Self.probe("heading")))
      let frame = try #require(frames["heading"], "no heading frame at \(width)")
      print("DictionaryHeading width=\(width) frame=\(frame)")
      #expect(frame.height > 40, "\(width): \(frame.height)")
      #expect(frame.maxX <= width + 0.5, "\(width): the heading overflows to \(frame.maxX)")
      heights.append(frame.height)
    }
    #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 }, "\(heights)")
    // At the wide window the heading, the switch and its name share one line, so the whole
    // heading is two text lines tall; narrower, the short line wraps (and, narrower still than
    // any window allows, the control drops under the heading) rather than clipping.
    let wide = try #require(heights.last)
    let narrow = try #require(heights.first)
    #expect(wide < 64, "the Enable control is not on the heading line at the wide window: \(wide)")
    #expect(narrow > wide, "the narrow heading did not reflow: \(narrow) vs \(wide)")
    let off = try #require(
      Self.frames(
        width: Self.contentWidths[2],
        DictionarySettingsHeading(isEnabled: .constant(false)).background(Self.probe("heading"))
      )["heading"])
    #expect(abs(off.height - heights[2]) < 0.5, "turning Dictionary off resized its heading")
  }

  @Test("a page's own content is the first thing in the shared container")
  func contentIsFirst() throws {
    for width: CGFloat in [508, 1058] {
      let frames = Self.frames(
        width: width,
        SettingsContentView {
          Color.red.frame(height: 12).background(Self.probe("sentinel"))
        }
        .frame(height: 300))
      let sentinel = try #require(frames["sentinel"], "no sentinel at \(width)")
      print("ContentSentinel width=\(width) frame=\(sentinel)")
      #expect(
        abs(sentinel.minY - SettingsLayout.contentTop) < 0.5,
        "something sits above the content: \(sentinel)")
      #expect(abs(sentinel.minX - SettingsLayout.contentH) < 0.5)
      #expect(abs(sentinel.width - (width - 2 * SettingsLayout.contentH)) < 0.5)
    }
  }
}
