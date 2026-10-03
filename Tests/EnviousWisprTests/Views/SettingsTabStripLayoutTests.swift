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

  static func paint(width: CGFloat, selected: DictationTab) throws -> NSBitmapImageRep {
    let root = SettingsTabStrip(items: items(german: false), selection: .constant(selected))
      .frame(width: width).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: .aqua)
    host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
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
