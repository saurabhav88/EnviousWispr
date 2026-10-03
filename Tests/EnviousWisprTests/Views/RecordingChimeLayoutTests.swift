import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the twelve chime cards reflow to at most four columns. **When this fails, a narrow
/// window loses the four-column overview or cuts off readable text, a wide one grows a fifth column, cards in
/// a row come out different sizes, or picking a chime resizes its card and moves both buttons.**
/// Production views hosted here: `RecordingChimeGrid` laying out the real `RecordingChimeCard`s,
/// each wrapped only in a background probe that reports its frame.
///
/// Relations between measurements in one process; the printed sizes are this Mac's. Limits:
/// plain buttons are not NSViews and hosted views expose no accessibility tree, so the two
/// buttons' own rectangles and presses are final Live UAT; the cards' frames are measured.
@MainActor
@Suite("Recording chime layout (#3385)", .tags(.productOutcome))
struct RecordingChimeLayoutTests {

  init() { _ = NSApplication.shared }

  /// Grid widths: the shell's page widths (508, 578, 1058, stress 380) less the page's
  /// two `SettingsLayout.contentH` margins.
  static let gridWidths: [CGFloat] = [380, 508, 578, 1058].map { $0 - 2 * SettingsLayout.contentH }

  @Test("four columns at required widths, with a fallback below the supported window")
  func columnCeiling() {
    for width in Self.gridWidths + [1400, 2400] {
      let columns = RecordingChimeGrid.columns(forWidth: width)
      let card =
        (width - RecordingChimeGrid.spacing * CGFloat(columns - 1)) / CGFloat(columns)
      print("ChimeGrid width=\(width) columns=\(columns) card=\(card)")
      #expect(columns >= 1 && columns <= RecordingChimeGrid.maxColumns)
      #expect(columns == 1 || card >= RecordingChimeGrid.minimumCardWidth, "\(width): \(card)")
    }
    #expect(RecordingChimeGrid.columns(forWidth: 1058 - 2 * SettingsLayout.contentH) == 4)
    #expect(RecordingChimeGrid.columns(forWidth: 508 - 2 * SettingsLayout.contentH) == 4)
  }

  struct Frames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
      value.merge(nextValue()) { $1 }
    }
  }

  @MainActor final class Box { var frames: [String: CGRect] = [:] }

  static func cardFrames(
    width: CGFloat, selected: RecordingSoundPairing, previewEnabled: Bool = true
  )
    -> [String: CGRect]
  {
    let box = Box()
    let grid = RecordingChimeGrid {
      ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
        RecordingChimeCard(
          pairing: pairing, isSelected: pairing == selected, isPreviewEnabled: previewEnabled,
          onSelect: {}, onPreview: {}
        )
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: Frames.self, value: [pairing.rawValue: proxy.frame(in: .named("grid"))])
          })
      }
    }
    .frame(width: width)
    .fixedSize(horizontal: false, vertical: true)
    .coordinateSpace(name: "grid")
    .onPreferenceChange(Frames.self) { value in MainActor.assumeIsolated { box.frames = value } }
    let host = NSHostingView(rootView: AnyView(grid))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 1400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.contentView = nil
    return box.frames
  }

  @Test("all twelve cards lay out in equal columns, each row one height")
  func cardsFillTheirColumns() {
    for width in Self.gridWidths {
      let frames = Self.cardFrames(width: width, selected: .whisperTick)
      let columns = Set(frames.values.map { ($0.minX * 2).rounded() }).count
      let widths = Set(frames.values.map { ($0.width * 2).rounded() })
      print(
        "ChimeCards width=\(width) columns=\(columns) frames=\(frames.sorted { $0.key < $1.key })")
      #expect(frames.count == 12, "\(width): \(frames.count) cards measured")
      #expect(
        columns == RecordingChimeGrid.columns(forWidth: width), "\(width): \(columns) columns")
      #expect(widths.count == 1, "\(width): card widths \(widths)")
      #expect(frames.values.allSatisfy { $0.maxX <= width + 0.5 }, "a card overflows \(width)")
      let rows = Dictionary(grouping: frames.values) { ($0.minY * 2).rounded() }
      for (_, row) in rows {
        #expect(
          Set(row.map { ($0.height * 2).rounded() }).count == 1, "\(width): a row's heights differ")
      }
      #expect(frames.values.allSatisfy { $0.height > 40 && $0.height < 300 }, "\(width): \(frames)")
    }
  }

  @Test("picking a chime, or disabling Preview, moves and resizes nothing")
  func selectionIsGeometryFree() {
    for width in Self.gridWidths {
      let base = Self.cardFrames(width: width, selected: .whisperTick)
      let other = Self.cardFrames(width: width, selected: .airGlint)
      let busy = Self.cardFrames(width: width, selected: .whisperTick, previewEnabled: false)
      #expect(base.count == 12)
      #expect(base == other, "\(width): selection moved a card")
      #expect(base == busy, "\(width): disabling Preview moved a card")
    }
  }

  @Test("full-width 14pt names and captions fit; Play and Select have disjoint effective regions")
  func textAndHitRegionsFit() throws {
    for width in Self.gridWidths.dropFirst() {
      let frames = Self.cardFrames(width: width, selected: .whisperTick)
      for pairing in RecordingSoundPairing.allCases {
        let card = try #require(frames[pairing.rawValue])
        let text = VStack(alignment: .leading, spacing: 2) {
          Text(RecordingChimeCatalog.name(for: pairing)).font(.stRowLabel)
          Text(RecordingChimeCatalog.description(for: pairing)).font(.stRowHelper)
        }.fixedSize(horizontal: false, vertical: true)
        let textHeight = PillSettingsLayoutTests.fitting(text, width: card.width - 8).height
        #expect(card.height >= 44 + textHeight + 18 + 16)
        let rect = CGRect(origin: .zero, size: card.size)
        let select = RecordingChimeSelectRegion().path(in: rect)
        // Independent rectangle oracle, sampling interiors, edges left to native Live UAT.
        var overlap = 0
        var missing = 0
        for y in stride(from: CGFloat(0.5), to: card.height, by: 1) {
          for x in stride(from: CGFloat(0.5), to: card.width, by: 1) {
            let play = x < 44 && y < 44
            let chooses = select.contains(CGPoint(x: x, y: y))
            if play && chooses { overlap += 1 }
            if !play && !chooses { missing += 1 }
          }
        }
        print("ChimeFit \(pairing.rawValue) card=\(card) textWidth=\(card.width - 8) fullTextHeight=\(textHeight) play=44x44 select=L-shaped overlap=\(overlap) uncovered=\(missing) contained=\(card.maxX <= width + 0.5)")
        #expect(overlap == 0 && missing == 0)
      }
    }
  }

  /// The page builds the switch inline; this hosts the same component with the same modifiers.
  @Test("the master switch stays the size of its track")
  func toggleIsBounded() {
    let toggle = Toggle("", isOn: .constant(true))
      .labelsHidden()
      .toggleStyle(BrandedToggleStyle())
      .fixedSize()
    let host = NSHostingView(rootView: AnyView(toggle))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    print("ChimeToggle size=\(size)")
    #expect(size.width > 20 && size.width < 80 && size.height > 0)
  }
}
