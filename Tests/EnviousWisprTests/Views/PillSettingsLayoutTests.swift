import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Recording Pill tab's design cards now carry a visible name and short line under
/// the picture. **When this fails, the cards in one row come out different heights, a card
/// changes size when it is picked, a caption is cut off, or the grid stops reflowing and
/// squeezes three cards into a narrow window.** Production views hosted here: the real
/// `RecordingPillPreviewTile` and `RecordingPillAppearancePanel`.
///
/// Every assertion is a relation between measurements taken in this process; no font metric of
/// this Mac is frozen. Limits: hosted views expose no accessibility tree and plain buttons are
/// not NSViews, so presses, hover and VoiceOver are final Live UAT; German wrapping is checked
/// by eye at 750pt in that pass.
@MainActor
@Suite("Recording Pill settings layout (#3385)", .tags(.productOutcome))
struct PillSettingsLayoutTests {

  init() { _ = NSApplication.shared }

  /// Card widths a user gets: the grid's 270pt minimum, a middle card, and a single
  /// full-width card at the 750pt window.
  static let cardWidths: [CGFloat] = [270, 340, 460]

  /// The card's padding (12 each side), tick slot (18) and caption spacing (8).
  static let captionInset: CGFloat = 12 * 2 + 18 + 8

  static func fitting(_ view: some View, width: CGFloat) -> CGSize {
    let root = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
    let host = NSHostingView(rootView: AnyView(root))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    window.contentView = nil
    return size
  }

  static func tile(_ design: RecordingPillDesign, selected: Bool) -> RecordingPillPreviewTile {
    RecordingPillPreviewTile(design: design, isSelected: selected, isEnabled: true, onSelect: {})
  }

  @Test("every card in a row is one size, picked or not, at every width")
  func equalCardsAtEveryWidth() {
    for width in Self.cardWidths {
      var sizes: [String: CGSize] = [:]
      for design in RecordingPillDesign.allCases {
        for selected in [false, true] {
          sizes["\(design.rawValue)-\(selected ? "selected" : "unselected")"] = Self.fitting(
            Self.tile(design, selected: selected), width: width)
        }
      }
      print("PillCards width=\(width) \(sizes.sorted { $0.key < $1.key })")
      let heights = Set(sizes.values.map(\.height))
      #expect(sizes.values.allSatisfy { $0.height > 0 }, "a card measured nothing at \(width)")
      #expect(heights.count == 1, "cards differ in height at \(width): \(sizes)")
      #expect(
        sizes.values.allSatisfy { abs($0.width - width) < 0.5 },
        "a card is wider or narrower than its \(width)pt slot: \(sizes)")
    }
  }

  @Test("the card holds its picture and the tallest caption without cutting either")
  func captionFitsInsideTheCard() throws {
    for width in Self.cardWidths {
      let card = Self.fitting(Self.tile(.levelRail, selected: false), width: width).height
      let captionWidth = width - Self.captionInset
      let captions = RecordingPillDesign.allCases.map {
        Self.fitting(
          RecordingPillPreviewTile.captionText(for: $0, highlighted: false), width: captionWidth
        ).height
      }
      let tallest = try #require(captions.max())
      let needed = 12 + RecordingPillPreviewTile.thumbnailSize.height + 10 + tallest + 12
      print("PillCaption card=\(width) caption=\(captionWidth) heights=\(captions) card=\(card)")
      #expect(captions.allSatisfy { $0 > 0 }, "a caption measured nothing")
      #expect(
        card + 0.5 >= needed, "card \(card) < picture + tallest caption \(needed) at \(width)")
      #expect(card - needed < 1, "card \(card) reserves more than it holds (\(needed)) at \(width)")
    }
    // Wrapping, not truncation: a narrower card is never shorter than a wider one.
    let narrow = Self.fitting(Self.tile(.readingWell, selected: false), width: 270).height
    let wide = Self.fitting(Self.tile(.readingWell, selected: false), width: 460).height
    #expect(narrow >= wide, "a 270pt card is \(narrow) tall and a 460pt one \(wide)")
  }

  @Test("the grid reflows: a wide page lays the cards side by side")
  func gridReflows() {
    func panelHeight(_ width: CGFloat) -> CGFloat {
      let name = "ew.pillLayout." + UUID().uuidString
      let suite = TestDefaults.suite(name)!
      suite.removePersistentDomain(forName: name)
      let settings = SettingsManager(defaults: suite)
      let model = PillAppearanceModel(settings: settings, capability: { .available })
      return Self.fitting(
        RecordingPillAppearancePanel().environment(settings).environment(model), width: width
      ).height
    }
    let single = panelHeight(460)
    let wide = panelHeight(1010)
    print("PillPanel width=460 height=\(single) width=1010 height=\(wide)")
    #expect(single > 0 && wide > 0)
    #expect(wide < single, "the panel is as tall at 1010 (\(wide)) as at 460 (\(single))")
  }
  /// The page builds the picker inline, so this hosts the same component with the same two
  /// options and the same `.fixedSize()`; the page's own picker is in the rendered PNGs.
  @Test("the Top / Bottom picker stays compact beside its row title")
  func positionPickerIsCompact() {
    let picker = BrandedSegmentedPicker(
      options: [
        ("Top", "arrow.up.to.line", OverlayPillPosition.top),
        ("Bottom", "arrow.down.to.line", OverlayPillPosition.bottom),
      ],
      selection: .constant(OverlayPillPosition.top)
    )
    .fixedSize()
    let host = NSHostingView(rootView: AnyView(picker))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    print("PillPositionPicker size=\(size)")
    #expect(size.width > 60 && size.height > 0)
    #expect(size.width < 460 / 2, "the picker takes \(size.width) of a 460pt row")
  }
}
