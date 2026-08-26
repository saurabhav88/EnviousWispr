import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// The Appearance picker draws each pill instead of describing it (#2435).
///
/// **Product Outcome.** When these fail, a user picking a recording pill is
/// looking at the wrong picture, an empty box, or a preview that says nothing to
/// a screen reader — and picks by guessing, which is the failure the whole change
/// exists to remove.
///
/// **Every size assertion here is a RELATION between two measurements taken in
/// one process, never a frozen point value.** The 2026-08-25 lesson from #2376
/// Phase 4 is that an absolute rendered size is a reading of one Mac's font
/// metrics: the suite went Debug-green and CI-red on exactly that. Differences
/// and orderings survive a different machine; numbers do not.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingPillTileTests {

  init() { _ = NSApplication.shared }

  /// The tile as the settings page builds it, measured unconstrained so it
  /// reports what it ideally wants.
  private static func tileSize(_ design: RecordingPillDesign) -> CGSize {
    let tile = RecordingPillPreviewTile(
      design: design, isSelected: false, isEnabled: true, onSelect: {})
    let host = NSHostingView(rootView: AnyView(tile))
    let frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return host.fittingSize
  }

  /// **The oracle the tile did not write.** `RenderedPillHarness` measures the
  /// recording leaf directly, through the leaf's own height callback, with no
  /// tile involved. The sample display comes from the tile so both sides are
  /// looking at the same picture — that is the INPUT, not the thing under test.
  private static func leafHeight(_ design: RecordingPillDesign) throws -> CGFloat {
    try RenderedPillHarness.recordingContentHeight(
      design: design,
      display: RecordingPillPreviewTile.sampleDisplay(for: design),
      width: design.width)
  }

  // MARK: - The tile renders the real pill

  /// **The strong one: the tile's height tracks the LEAF's height exactly.**
  ///
  /// Stated as a difference so the tile's own padding cancels out of both sides.
  /// A tile that drew a placeholder, an empty box, or another design's chrome
  /// would have a height unrelated to what the leaf reports for itself, and no
  /// absolute constant is involved on either side.
  @Test(
    "each tile is as tall as the pill inside it",
    arguments: [RecordingPillDesign.levelRail, RecordingPillDesign.readingWell])
  func tileHeightTracksTheLeaf(design: RecordingPillDesign) throws {
    let baseline = RecordingPillDesign.classic

    let tileDelta = Self.tileSize(design).height - Self.tileSize(baseline).height
    let leafDelta = try Self.leafHeight(design) - Self.leafHeight(baseline)

    #expect(
      abs(tileDelta - leafDelta) < 0.5,
      """
      the \(design) tile is \(tileDelta)pt taller than the \(baseline) tile while the \
      PILLS differ by \(leafDelta)pt. The tile is not sized by the pill it contains, so \
      it is drawing something else.
      """)
  }

  /// **The two wordless designs are the same height, because they are the same
  /// chrome.** A tile that routed one of them through the reading well's layout
  /// would differ here, and the difference is what no static mock could catch.
  @Test("the two wordless pills give tiles of equal height")
  func wordlessTilesAgree() {
    let capsule = Self.tileSize(.classic).height
    let rail = Self.tileSize(.levelRail).height

    #expect(capsule > 0 && rail > 0, "measured \(capsule)/\(rail): nothing rendered, which is not a pass")
    #expect(
      abs(capsule - rail) < 0.5,
      "the capsule tile is \(capsule)pt and the level rail tile is \(rail)pt, so one of them is not the pill it claims")
  }

  /// **The first frame is already right, and this is the only row that can see
  /// it.**
  ///
  /// The reading well's words come from `initialPreview:`. Without that seed the
  /// well renders `.off` on its first layout pass, which is an EmptyView — the
  /// tile would then be SHORTER than a capsule tile rather than taller, and would
  /// visibly fill in a frame later. No size freeze would catch it; this ordering
  /// does, and it fails in the informative direction.
  @Test("the reading well tile already holds words on its first layout pass")
  func theReadingWellIsSeeded() {
    let well = Self.tileSize(.readingWell).height
    let capsule = Self.tileSize(.classic).height

    #expect(
      well > capsule,
      """
      the reading well tile is \(well)pt against a \(capsule)pt capsule tile. A seeded \
      well is TALLER; an unseeded one collapses to its header strip and fills in later. \
      `initialPreview:` is not reaching the leaf.
      """)
  }

  /// Each design asks for its own width, so no two tiles are interchangeable.
  @Test("no two tiles are the same width")
  func tileWidthsAreDistinct() {
    let widths = RecordingPillDesign.allCases.map { Self.tileSize($0).width }
    #expect(widths.allSatisfy { $0 > 0 }, "measured \(widths): nothing rendered")
    #expect(
      Set(widths).count == widths.count,
      "two tiles measured the same width \(widths), so the picker shows one design twice")
  }

  // MARK: - What a screen reader gets

  /// **The words that left the screen have to arrive somewhere, and the LABEL is
  /// the only channel a macOS user cannot switch off.**
  ///
  /// VoiceOver Utility's Verbosity pane sets hints and extra content to "Do
  /// Nothing", so a design that put the description in either could go silent on
  /// a real reader's machine. WCAG 1.1.1 asks for a text alternative serving an
  /// EQUIVALENT purpose, and once the tile is only a picture, the option's name
  /// alone does not serve it.
  ///
  /// **What this row does NOT prove, stated rather than discovered later:** the
  /// selected VALUE, the `.isSelected` TRAIT and DISABLED reporting are carried
  /// by modifiers on the tile, and a hosted SwiftUI view's accessibility tree is
  /// not readable from a test — measured 2026-08-25 and recorded in
  /// `RenderedPillHarness`. Those three are unchanged from the control this tile
  /// replaces and are confirmed by the VoiceOver pass in Live UAT.
  @Test("every tile announces its name and what it looks like", arguments: RecordingPillDesign.allCases)
  func theLabelCarriesNameAndDescription(design: RecordingPillDesign) {
    let label = RecordingPillPreviewTile.accessibilityLabel(for: design)

    #expect(
      label.contains(design.displayName),
      "the \(design) tile announces \"\(label)\", which does not name the option")
    #expect(
      label.contains(design.summary),
      """
      the \(design) tile announces \"\(label)\", which drops the description. That \
      description is no longer on screen, so a reader who cannot see the picture now \
      gets nothing about what this option looks like.
      """)
  }

  @Test("no two tiles announce the same thing")
  func labelsAreDistinct() {
    let labels = RecordingPillDesign.allCases.map {
      RecordingPillPreviewTile.accessibilityLabel(for: $0)
    }
    #expect(
      Set(labels).count == labels.count,
      "two tiles announce identically: \(labels)")
  }

  /// House style, swept over the surface that is now the ONLY place these strings
  /// are read (GR-NO-DASHES).
  @Test("no announced string carries a dash", arguments: RecordingPillDesign.allCases)
  func labelsCarryNoDashes(design: RecordingPillDesign) {
    let label = RecordingPillPreviewTile.accessibilityLabel(for: design)
    #expect(!label.contains("\u{2014}"), "em dash in: \(label)")
    #expect(!label.contains("\u{2013}"), "en dash in: \(label)")
  }

  /// The sample sentence is a real one, and the wordless designs get no words —
  /// which is what makes their tiles pictures of a capsule rather than of a well.
  @Test("only a design that can hold words is shown holding any", arguments: RecordingPillDesign.allCases)
  func onlyWordCapableDesignsAreShownWords(design: RecordingPillDesign) {
    switch RecordingPillPreviewTile.sampleDisplay(for: design) {
    case .text(let sentence):
      #expect(design.canHoldWords, "\(design) cannot hold words and is drawn holding \"\(sentence)\"")
      #expect(!sentence.isEmpty, "\(design) is drawn holding an empty sentence")
    case .off:
      #expect(!design.canHoldWords, "\(design) can hold words and is drawn empty, so its tile understates it")
    default:
      Issue.record("\(design) is sampled in a transient state, which is not an appearance")
    }
  }
}
