import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the twelve chime cards reflow to at most four columns. **When this fails, a narrow
/// window cuts off readable text, a wide one grows a fifth column, cards in
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

  @Test("up to four columns, fewer when readable content needs the room")
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
    #expect(RecordingChimeGrid.columns(forWidth: 508 - 2 * SettingsLayout.contentH) == 2)
  }

  struct Frames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
      value.merge(nextValue()) { $1 }
    }
  }

  @MainActor final class Box { var frames: [String: CGRect] = [:] }

  static func cardFrames(
    width: CGFloat, selected: RecordingSoundPairing, previewEnabled: Bool = true, german: Bool = false
  )
    -> [String: CGRect]
  {
    let box = Box()
    let grid = RecordingChimeGrid {
      ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
        RecordingChimeCard(
          pairing: pairing, isSelected: pairing == selected, isPreviewEnabled: previewEnabled,
          onSelect: {}, onPreview: {}, text: german ? Self.germanText(pairing) : nil
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

  /// Founder 2026-10-03: "are the soundwaves just made up or actually accurate". They are read
  /// from the bundled WAVs: every pairing's files exist and carry sound, two different chimes
  /// draw different shapes, and a missing file draws silence rather than an invented shape.
  @Test("each chime strip is read from its own bundled start and stop sounds")
  func waveformsComeFromTheSounds() {
    for pairing in RecordingSoundPairing.allCases {
      for moment in ["start", "stop"] {
        let bars = RecordingChimeWaveform.envelope(name: "\(pairing.rawValue)_\(moment)", bars: 20)
        #expect(bars.count == 20)
        #expect(bars.contains { $0 > 0 }, "\(pairing.rawValue)_\(moment) read as silence")
      }
    }
    #expect(
      RecordingChimeWaveform.heights(for: .whisperTick)
        != RecordingChimeWaveform.heights(for: .softHush))
    #expect(RecordingChimeWaveform.envelope(name: "no_such_chime", bars: 8) == Array(repeating: 0, count: 8))
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

  @Test("natural text and footer fit without extra rows; Play and Select have disjoint effective regions")
  func textAndHitRegionsFit() throws {
    for width in Self.gridWidths.dropFirst() {
      let frames = Self.cardFrames(width: width, selected: .whisperTick)
      for pairing in RecordingSoundPairing.allCases {
        let card = try #require(frames[pairing.rawValue])
        let content = RecordingChimeCard(pairing: pairing, isSelected: true,
          isPreviewEnabled: true, onSelect: {}, onPreview: {})
        let headerHeight = PillSettingsLayoutTests.fitting(content.header, width: card.width).height
        let footerHeight = PillSettingsLayoutTests.fitting(content.footer, width: card.width).height
        // Independent native Text measurements at the required readable columns,
        // rather than accepting a taller branch merely because it measures itself.
        let side = card.width >= 150
        let nameWidth = card.width - (side ? 52 : 48)
        let descriptionWidth = card.width - (side ? 52 : 8)
        let nameHeight = PillSettingsLayoutTests.fitting(
          Text(RecordingChimeCatalog.name(for: pairing)).font(.stRowLabel)
            .fixedSize(horizontal: false, vertical: true), width: nameWidth).height
        let descriptionHeight = PillSettingsLayoutTests.fitting(
          Text(RecordingChimeCatalog.description(for: pairing)).font(.stRowHelper)
            .fixedSize(horizontal: false, vertical: true), width: descriptionWidth).height
        let expectedHeader = side ? max(44, nameHeight + 2 + descriptionHeight) + 4
          : max(44, nameHeight) + 4 + descriptionHeight + 4
        #expect(abs(headerHeight - expectedHeader) < 1, "header stacked when text could fit beside Play")
        let needed = headerHeight + 4 + footerHeight
        #expect(card.height + 0.5 >= needed)
        // The row's longest sibling sets its height, not an extra reserved row.
        let row = frames.values.filter { abs($0.minY - card.minY) < 0.5 }
        let natural = RecordingSoundPairing.allCases.compactMap { other -> CGFloat? in
          guard let frame = frames[other.rawValue], abs(frame.minY - card.minY) < 0.5 else { return nil }
          let view = RecordingChimeCard(pairing: other, isSelected: false,
            isPreviewEnabled: true, onSelect: {}, onPreview: {})
          return PillSettingsLayoutTests.fitting(view.header, width: frame.width).height + 4
            + PillSettingsLayoutTests.fitting(view.footer, width: frame.width).height
        }.max() ?? 0
        #expect(row.allSatisfy { abs($0.height - natural) < 1 }, "row has an unexplained vertical gap")
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
        print("ChimeFit \(pairing.rawValue) card=\(card) naturalHeaderHeight=\(headerHeight) naturalFooterHeight=\(footerHeight) needed=\(needed) rowNaturalHeight=\(natural) play=44x44 select=L-shaped overlap=\(overlap) uncovered=\(missing) contained=\(card.maxX <= width + 0.5)")
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

  // The host's Bundle.main is English, so German catalog names/badge are literal fixtures.
  static let germanNames = ["Staubflöckchen", "Samtflüstern", "Leises Okay", "Flüstertick",
    "Runder Kiesel", "Papierklopfen", "Sanftes Säuseln", "Tiefes Nicken", "Wolkenplopp",
    "Samttipp", "Satin-Schimmer", "Luftfunkeln"]

  static func germanText(_ pairing: RecordingSoundPairing) -> RecordingChimeCard.TextContent {
    let index = RecordingSoundPairing.allCases.firstIndex(of: pairing)!
    return .init(name: germanNames[index], description: germanDescriptions[index], inUse: "IN VERWENDUNG")
  }

  static let germanDescriptions = [
    "Leises, gefiltertes Rauschen ohne Tonhöhe.", "Zwei eng beieinanderliegende Töne, sanft und warm.",
    "Gleiche Tonhöhe beim Starten und Stoppen, ganz schlicht.", "Ein kaum hörbares Ticken.",
    "Rund und weich.", "Ein leises Klopfen wie auf Papier.", "Ein langsames Verklingen wie ein Atemzug.",
    "Tief, warm und gemächlich.", "Ein leises Ploppen wie ein Luftstoß durch einen Filter.",
    "Ein leises, kurzes Klopfen.", "Ein sanfter Wechsel zwischen zwei Tönen.",
    "Ein klarer, luftiger Klang."]

  @Test("columns leave room for the widest whole name beside Play and a one-line badge")
  func localizedCardWidths() {
    for german in [false, true] {
      let names = german ? Self.germanNames : RecordingSoundPairing.allCases.map { RecordingChimeCatalog.name(for: $0) }
      // Independent native measurements of the shipping 14pt semibold labels.
      let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
      let widestName = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
      let badge = ((german ? "IN VERWENDUNG" : "IN USE") as NSString).size(withAttributes: [.font: font]).width
      let required = max(widestName + 44 + 8, badge + 16 + 4 + 12 + 8)
      for window: CGFloat in [750, 820, 1300] {
        let width = AppearanceRenderHarness.pageWidth(window: window) - 2 * SettingsLayout.contentH
        let columns = RecordingChimeGrid.columns(forWidth: width)
        let cardWidth = (width - CGFloat(columns - 1) * 12) / CGFloat(columns)
        print("Chime localized window=\(window) de=\(german) columns=\(columns) card=\(cardWidth) needed=\(required)")
        #expect(cardWidth >= required, "whole names and badge need \(required), got \(cardWidth)")
        let frames = Self.cardFrames(width: width, selected: .whisperTick, german: german)
        #expect(frames.count == 12)
        #expect(frames.values.allSatisfy { $0.width >= required && $0.maxX <= width + 0.5 })
        #expect(Set(frames.values.map { ($0.minX * 2).rounded() }).count == columns)
        for pairing in RecordingSoundPairing.allCases {
          let view = RecordingChimeCard(pairing: pairing, isSelected: true, isPreviewEnabled: true,
            onSelect: {}, onPreview: {}, text: german ? Self.germanText(pairing) : nil)
          let footer = PillSettingsLayoutTests.fitting(view.footer, width: cardWidth)
          #expect(footer.width <= cardWidth + 0.5)
          let name = PillSettingsLayoutTests.fitting(view.cardName, width: cardWidth - 52)
          let nameIdeal = NSHostingView(rootView: view.cardName).fittingSize
          #expect(abs(name.height - nameIdeal.height) < 1, "every whole name fits beside Play")
          let badgeSize = PillSettingsLayoutTests.fitting(view.inUseBadge, width: cardWidth - 8)
          let badgeIdeal = NSHostingView(rootView: view.inUseBadge).fittingSize
          #expect(abs(badgeSize.height - badgeIdeal.height) < 1, "badge stays on one line")
          #expect(badgeSize.width <= cardWidth - 8 + 0.5)
        }
      }
    }
  }

}
