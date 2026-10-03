import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: when this fails, a person cannot see/read/reach every Dictation tab.
/// Measures production buttons in the production Layout, and the complete strip's
/// height/paint. Offscreen SwiftUI hosts do not expose the app's AX/focus tree;
/// the offline navigator fixtures and Claude's live check cover that boundary.
@MainActor
@Suite("Settings tab strip wrapping", .tags(.productOutcome))
struct SettingsTabStripLayoutTests {
  init() { _ = NSApplication.shared }

  // Lane C drafts supplied by the founder. Explicit resources are necessary:
  // an environment locale cannot translate Strings already resolved by a host.
  static let germanDraft = [
    "Engine", "Mikrofon & Medien", "Live-Vorschau", "Aufnahmeanzeige", "Signaltöne", "Zwischenablage",
  ]

  static func items(german: Bool) -> [SettingsTabItem<DictationTab>] {
    DictationTab.allCases.enumerated().map { index, tab in
      SettingsTabItem(id: tab, icon: tab.icon,
        label: german ? LocalizedStringResource(stringLiteral: germanDraft[index]) : tab.label)
    }
  }

  @Test("six whole tabs stay contained and nonoverlapping, wrapping only when needed")
  func wholeTabsWrapNaturally() throws {
    for german in [false, true] {
      // Actual host widths plus the independently supplied live-window bounds.
      for width: CGFloat in [468, 476, 487, 538, 546, 1018, 1026] {
        let measured = try Self.measure(width: width, german: german)
        try #require(measured.frames.count == 6)
        let rows = Set(measured.frames.values.map { Int($0.minY.rounded()) })
        #expect(rows.count == (width >= 1000 ? 1 : 2), "rows=\(rows) at \(width), German draft=\(german)")
        for (index, tab) in DictationTab.allCases.enumerated() {
          let frame = try #require(measured.frames[tab])
          let ideal = measured.ideals[index]
          #expect(frame.width >= ideal.width - 0.5, "\(tab) squeezed from \(ideal) to \(frame)")
          #expect(frame.height >= ideal.height - 0.5)
          #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5)
          #expect(frame.minY >= -0.5 && frame.maxY <= measured.height + 0.5)
          print("TAB \(german ? "German-DRAFT" : "English") width=\(width) \(tab) frame=\(frame) ideal=\(ideal) row=\(Int(frame.minY.rounded())) contained=true")
          for other in DictationTab.allCases.dropFirst(index + 1) {
            let otherFrame = try #require(measured.frames[other])
            let intersection = frame.intersection(otherFrame)
            #expect(intersection.isNull || intersection.width < 0.5 || intersection.height < 0.5)
          }
        }
        // Numeric floor protects readable native 14pt text and full padded targets.
        #expect(measured.height >= 52 && measured.height <= 110)
        let stripHeight = try SettingsDestinationTests.stripHeight(width: width, parentHeight: 400)
        #expect(abs(stripHeight - measured.height) < 0.5, "complete strip and measured cells diverged")
      }
    }
  }

  @Test("wrapped height follows row count and ignores surplus parent height")
  func heightIndependentOfParent() throws {
    for width: CGFloat in [468, 476, 487, 538, 546, 1018, 1026] {
      let short = try SettingsDestinationTests.stripHeight(width: width, parentHeight: 400)
      let tall = try SettingsDestinationTests.stripHeight(width: width, parentHeight: 900)
      #expect(abs(short - tall) < 0.5)
      #expect(short > (width >= 1000 ? 45 : 95) && short < (width >= 1000 ? 60 : 115))
      print("STRIP width=\(width) parent=400/900 height=\(short)/\(tall)")
    }
  }

  @Test("the selected underline follows the chosen tab on either row")
  func selectedUnderlineFollowsSelection() throws {
    let frames = try Self.measure(width: 476, german: false).frames
    for selected in DictationTab.allCases {
      let rep = try Self.paint(width: 476, selected: selected)
      for tab in DictationTab.allCases {
        let frame = try #require(frames[tab])
        let scale = CGFloat(rep.pixelsWide) / 476
        let x = Int(frame.midX * scale)
        let y = Int((frame.maxY - 1.5) * scale)
        let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        let accent = color.blueComponent > color.greenComponent + 0.15
          && color.redComponent > color.greenComponent + 0.10
        #expect(accent == (tab == selected), "\(selected): underline at \(tab) is \(color)")
      }
    }
  }

  @Test("separators appear only inside rows, never at row starts or endings")
  func separatorsStayInsideRows() throws {
    // Independent expected boundaries: three plus three at the narrow widths;
    // all six on one row at 1300. No production neighbour predicate is copied.
    for (window, width): (Int, CGFloat) in [(750, 468), (820, 538), (1300, 1018)] {
      let interior: Set<DictationTab> = window == 1300
        ? [.engine, .microphone, .livePreview, .pill, .chimes]
        : [.engine, .microphone, .pill, .chimes]
      let starts: [DictationTab] = window == 1300 ? [.engine] : [.engine, .pill]
      for german in [false, true] {
        let measured = try Self.measure(width: width, german: german)
        for dark in [false, true] {
          let rep = try Self.paint(width: width, selected: .engine, german: german, dark: dark)
          let control = try Self.paintContainer(width: width, height: measured.height, dark: dark)
          let scale = CGFloat(rep.pixelsWide) / width
          for tab in DictationTab.allCases {
            let frame = try #require(measured.frames[tab])
            let x = frame.maxX - 0.5
            // 15pt is inside the separator but above glyph/text. The control
            // paints only the unchanged container, so its curved edge cannot
            // be mistaken for a separator (different y samples could do that).
            let painted = try Self.pixelDifference(rep, control: control,
              x: x, y: frame.minY + 15, scale: scale)
            #expect((painted > 0.01) == interior.contains(tab),
              "window=\(window) German-DRAFT=\(german) dark=\(dark) trailing \(tab) difference=\(painted)")
            print("SEPARATOR window=\(window) strip=\(width) German-DRAFT=\(german) dark=\(dark) tab=\(tab) frame=\(frame) interior=\(interior.contains(tab)) paintDelta=\(painted)")
          }
          for tab in starts {
            let frame = try #require(measured.frames[tab])
            #expect(abs(frame.minX) < 0.5, "row start must be at the strip edge")
            let painted = try Self.pixelDifference(rep, control: control,
              x: frame.minX + 0.5, y: frame.minY + 15, scale: scale)
            #expect(painted < 0.01, "row start \(tab) has separator paint: \(painted)")
            print("SEPARATOR-ROW-START window=\(window) German-DRAFT=\(german) dark=\(dark) tab=\(tab) frame=\(frame) paintDelta=\(painted)")
          }
        }
      }
    }
  }

  static func pixelDifference(
    _ rep: NSBitmapImageRep, control: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: CGFloat
  ) throws -> CGFloat {
    let sample = try #require(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
    let reference = try #require(control.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
    return max(abs(sample.redComponent - reference.redComponent),
      abs(sample.greenComponent - reference.greenComponent), abs(sample.blueComponent - reference.blueComponent))
  }

  struct Measurement { let frames: [DictationTab: CGRect]; let ideals: [CGSize]; let height: CGFloat }
  final class Box { var frames: [DictationTab: CGRect] = [:] }
  struct FramesKey: PreferenceKey {
    static let defaultValue: [DictationTab: CGRect] = [:]
    static func reduce(value: inout [DictationTab: CGRect], nextValue: () -> [DictationTab: CGRect]) {
      value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
  }

  static func measure(width: CGFloat, german: Bool) throws -> Measurement {
    let box = Box()
    let items = items(german: german)
    let ideals = items.map { item in
      NSHostingView(rootView: SettingsTabButton(item: item, isSelected: false, action: {})).fittingSize
    }
    let root = SettingsTabWrappingLayout {
      ForEach(items) { item in
        SettingsTabButton(item: item, isSelected: item.id == .engine, action: {})
          .background(GeometryReader { proxy in
            Color.clear.preference(key: FramesKey.self,
              value: [item.id: proxy.frame(in: .named("tabs"))])
          })
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: width)
    .coordinateSpace(name: "tabs")
    .onPreferenceChange(FramesKey.self) { value in
      MainActor.assumeIsolated { box.frames = value }
    }
    let host = NSHostingView(rootView: root)
    let height = host.fittingSize.height
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    defer { window.contentView = nil }
    try #require(box.frames.count == 6, "every production button must report its frame")
    return Measurement(frames: box.frames, ideals: ideals, height: height)
  }

  static func paint(
    width: CGFloat, selected: DictationTab, german: Bool = false, dark: Bool = false
  ) throws -> NSBitmapImageRep {
    let root = SettingsTabStrip(items: items(german: german), selection: .constant(selected))
      .frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
    return try bitmap(root, dark: dark)
  }

  /// Same native card paint, without tabs/separators. An independent empty
  /// control, never the production row predicate or a disabled assertion.
  static func paintContainer(width: CGFloat, height: CGFloat, dark: Bool) throws -> NSBitmapImageRep {
    let root = Color.stSectionBg
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      }
      .environment(\.colorScheme, dark ? .dark : .light)
    return try bitmap(root, dark: dark)
  }

  static func bitmap<Content: View>(_ root: Content, dark: Bool) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep
  }
}
