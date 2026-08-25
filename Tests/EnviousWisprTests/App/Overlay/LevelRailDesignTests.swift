import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// The second without-words design (#2376 Phase 4, C5).
///
/// **What this suite has to establish is that `.levelRail` is a DESIGN and not a
/// near-copy.** Phase 4's named likeliest regression is correct model data
/// rendered with the wrong visual treatment, and a new design that measures like
/// its neighbour is that regression arriving as a feature. So every row here is a
/// difference from something, or a bound it must respect.
///
/// **Product Outcome.** When these fail a user who picked one pill gets another
/// one, or gets a warning banner clipped off the bottom of it.
@MainActor
@Suite(.tags(.productOutcome))
struct LevelRailDesignTests {

  init() { _ = NSApplication.shared }

  // MARK: - It is genuinely a different pill

  @Test("the level rail measures like neither of its neighbours")
  func levelRailIsDistinctFromBothShippedDesigns() throws {
    let rail = RenderedPillHarness.recordingRootSize(design: .levelRail)
    let classic = RenderedPillHarness.recordingRootSize(design: .classic)
    let well = RenderedPillHarness.recordingRootSize(design: .readingWell)

    try #require(rail.width > 0 && rail.height > 0, "the level rail measured \(rail)")
    #expect(
      rail != classic,
      """
      the level rail measures \(rail) and the classic capsule \(classic) — the same. \
      A design that renders identically to its neighbour is this phase's named \
      regression shipped as a feature.
      """)
    #expect(rail != well, "the level rail measures the same as the reading well: \(rail)")
    // 288 since round 5: the hands-free badge is inline and the locked row
    // measured 279pt of content, so 260 clipped the one thing that says the
    // microphone is still open. Pinned rather than derived, deliberately — a pin
    // that reads `design.width` would agree with any future value.
    #expect(rail.width == 288, "the level rail is \(rail.width)pt wide, not the 288 it declares")
    #expect(rail.height == 92, "the level rail reserved \(rail.height)pt, not 92")
  }

  /// The clock is present in BOTH lock states, where the capsule hides it when
  /// locked. Read as GEOMETRY rather than as text, because the harness cannot see
  /// glyphs: the two designs' unlocked sizes must differ, and the rail's own two
  /// lock states must not.
  @Test("the level rail is the same size locked and unlocked")
  func lockNeutrality() {
    let unlocked = RenderedPillHarness.recordingRootSize(design: .levelRail, locked: false)
    let locked = RenderedPillHarness.recordingRootSize(design: .levelRail, locked: true)
    #expect(
      unlocked == locked,
      """
      the level rail measured \(unlocked) unlocked and \(locked) locked. Hands-free \
      is the mode that runs for minutes, so the clock stays — and a pill that \
      twitches when you double-press is the class of thing #2201 removed.
      """)
  }

  // MARK: - The notice budget it inherits

  /// **The assertion the design's 92 exists for.** The #1060 banner is the only
  /// thing that makes a without-words pill grow, and such a pill is handed a no-op
  /// growth callback — so if the content exceeds the reserved box it is clipped on
  /// screen with nothing reporting it.
  @Test(
    "the shipped in-panel notices fit the box the level rail reserves",
    arguments: [RecordingNoticeReason.approachingCap, .autoStopUnavailable])
  func inPanelNoticesFitTheReservedBox(reason: RecordingNoticeReason) throws {
    let budget = try #require(RecordingPillDesign.levelRail.reservedHeight)
    for locked in [false, true] {
      let height = try RenderedPillHarness.recordingContentHeight(
        design: .levelRail, locked: locked,
        notice: DictationNarrator.copy(for: reason),
        width: RecordingPillDesign.levelRail.width)
      #expect(
        height <= budget,
        """
        the \(reason) banner made the level rail \(height)pt tall (locked: \(locked)) \
        against the \(budget)pt box it reserves. It cannot grow — a without-words \
        design is handed a no-op growth callback — so the overflow is CLIPPED with \
        nothing reporting it. Shorten the copy or raise the reserved height; do not \
        raise this expectation.
        """)
    }
  }

  /// The paired case, so the budget row cannot pass by measuring nothing.
  @Test("a notice grows the level rail at all")
  func aNoticeGrowsTheRail() throws {
    let bare = try RenderedPillHarness.recordingContentHeight(
      design: .levelRail, width: RecordingPillDesign.levelRail.width)
    let withNotice = try RenderedPillHarness.recordingContentHeight(
      design: .levelRail, notice: DictationNarrator.copy(for: .approachingCap),
      width: RecordingPillDesign.levelRail.width)
    #expect(withNotice > bare, "a notice measured \(withNotice)pt against a bare \(bare)pt")
  }

  // MARK: - It cannot hold words, proven through the real gate

  /// **Driven through `OverlayRenderModel`, never through the leaf's
  /// `initialPreview:` seam.** That seam bypasses the `canHoldWords` gate
  /// entirely, so seeding it would measure the leaf's willingness to draw words
  /// rather than whether the gate let any through — which is the thing that makes
  /// this design wordless by construction rather than by policy.
  @Test("the level rail is handed no words even when a provider offers them")
  func theGateRefusesWordsForTheRail() {
    let model = OverlayRenderModel()
    var displayReads = 0
    var growthReports: [CGFloat] = []

    model.setRecordingProviders(
      audioLevel: { 0.4 },
      recordingElapsed: { 127 },
      livePreview: {
        displayReads += 1
        return .text("the quarterly numbers came in ahead of plan")
      },
      design: .levelRail,
      position: .top,
      onContentHeightChange: { growthReports.append($0) })

    #expect(model.livePreviewProvider() == .off, "the level rail was handed a live display")
    model.onContentHeightChange(123)

    #expect(displayReads == 0, "the live provider was read for a pill that shows no words")
    #expect(growthReports.isEmpty, "a pill that cannot grow reported a height to its window")
  }

  /// And it measures the same whether or not a provider was offered, which is the
  /// rendered consequence of the row above.
  @Test("offering the level rail words does not change what it draws")
  func wordsDoNotChangeTheRail() {
    let silent = RenderedPillHarness.recordingRootSize(design: .levelRail, display: .off)
    let offered = RenderedPillHarness.recordingRootSize(
      design: .levelRail,
      display: .text("the quarterly numbers came in ahead of plan and the board was pleased"))
    #expect(
      silent == offered,
      "the level rail measured \(silent) with no words and \(offered) with words offered")
  }

  // MARK: - It perturbed nothing

  /// The two shipped designs are byte-identical to what `RenderedPillFreezeTests`
  /// froze before this design existed. Asserted here as well as there because the
  /// frozen suite proves they did not move; this proves adding a CASE did not move
  /// them, which is the specific risk of widening a switch.
  @Test(
    "adding a design left the shipped two exactly as they were",
    arguments: [
      (RecordingPillDesign.classic, CGSize(width: 185, height: 92)),
      (RecordingPillDesign.readingWell, CGSize(width: 400, height: 34)),
    ])
  func shippedDesignsAreUnmoved(row: (RecordingPillDesign, CGSize)) {
    let measured = RenderedPillHarness.recordingRootSize(design: row.0)
    #expect(measured == row.1, "\(row.0) measured \(measured), frozen at \(row.1)")
  }

  /// The catalog's own geometry for the new design, so a wrong number is caught
  /// without rendering anything.
  @Test("the catalog gives the level rail its declared geometry")
  func catalogGeometry() throws {
    let definition = try #require(
      PillCatalog.entry(
        for: .recording(audioLevel: 0, design: .levelRail), id: RenderedPillHarness.id()
      ).definition)
    #expect(definition.requestedWidth == .fixed(288))
    #expect(definition.reservesFixedHeight == 92)
    #expect(definition.recordingDesign == .levelRail)
  }
}
