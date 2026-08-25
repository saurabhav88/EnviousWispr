import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// What every pill measures on `main` at `e062ab4d`, before Phase 4 moves a line
/// (#2376 C1).
///
/// **Every number here was RUN and TRANSCRIBED, never computed from the code it
/// freezes.** A table derived from the implementation agrees with every future
/// version of that implementation, which is the one thing a freeze must not do.
/// The capture that produced them is in the commit message; re-take them by
/// printing `RenderedPillHarness.rootSize` per row rather than by reading the
/// views.
///
/// **A Drift Guard, deliberately, and not a Product Outcome test.** When a row
/// here fails the user sees nothing yet — it says WE changed our own rendering,
/// which is exactly what Phase 4 does on purpose in some chunks and must not do
/// by accident in others. The sentence "when this fails the user sees ___" has
/// no ending, so it is not product coverage and is not counted as any.
@MainActor
@Suite(.tags(.driftGuard))
struct RenderedPillFreezeTests {

  init() { _ = NSApplication.shared }

  // MARK: - The frozen table

  /// Sizes of the routed content, measured 2026-08-25 on `e062ab4d`.
  ///
  /// Read `RenderedPillHarness`'s own doc for what a row means: it is the
  /// content at the width the definition asks for, which is not the window's
  /// size, and it is blind to paint.
  nonisolated static let frozenNotices:
    [(label: String, request: PillCatalogRequest, width: CGFloat, height: CGFloat)] = [
      ("processing.transcribing", .processing(phase: .transcribing), 151.5, 44),
      ("clipboardFallback", .clipboardFallback, 226.5, 44),
      ("accessibilityToast", .accessibilityToast, 332.5, 43),
      ("warning.polishFailed", .warning(reason: .polishFailed), 231, 37),
      ("error.asrFailed", .error(reason: .asrFailed), 239, 38),
      // The one row whose width is a PROPOSAL rather than an ideal, because it
      // is the one pill asking for a fixed width and a content height. At its
      // real 360 it wraps to 68pt; unproposed it reports 927 x 39, a single
      // unwrapped line — which is the reading two earlier capture rounds took
      // and the reason the harness proposes a width at all.
      ("advisory.zeroSignal", .advisory(reason: .zeroSignal), 360, 68),
      ("interruption.deviceRemoved", .interruption(reason: .deviceRemoved), 225.5, 44),
      ("cachingModel", .cachingModel(engineLabel: "Parakeet"), 259.5, 51),
      ("engineReady", .engineReady, 213, 40),
      ("recoveringLastRecording", .recoveringLastRecording, 352, 51),
      ("recoverySucceeded", .recoverySucceeded, 245, 51),
      ("importStatus", .importStatus(message: "Imported 12 words"), 170, 38),
    ]

  @Test(
    "every notice pill renders exactly what it rendered before Phase 4",
    arguments: RenderedPillFreezeTests.frozenNotices)
  func noticeRowsAreFrozen(
    row: (label: String, request: PillCatalogRequest, width: CGFloat, height: CGFloat)
  ) throws {
    let size = RenderedPillHarness.rootSize(for: row.request)
    // The instrument control comes FIRST and is a `#require`: a hosting view
    // measured before layout reports `.zero`, and a table of zeroes would freeze
    // perfectly for ever.
    try #require(
      size.width > 0 && size.height > 0,
      "\(row.label) measured \(size) — the harness returned nothing, which is not a pass")
    #expect(
      size.width == row.width && size.height == row.height,
      """
      \(row.label) measured \(size.width) x \(size.height), frozen at \
      \(row.width) x \(row.height). Either this pill is routed through a different \
      leaf now, or its treatment changed. Phase 4 changes where a leaf's WORDS come \
      from and must not change what any of them draws.
      """)
  }

  // MARK: - The instrument's own controls

  /// **An empty slot must be distinguishable from every pill**, or a harness
  /// that silently measured nothing would agree with a table of the right shape.
  @Test("an empty slot measures nothing, and nothing measures like a pill")
  func emptySlotIsDistinguishable() {
    let empty = RenderedPillHarness.rootSize(for: nil as PillDefinition?)
    #expect(empty == .zero, "an empty slot measured \(empty)")
    for row in Self.frozenNotices {
      #expect(
        !(row.width == empty.width && row.height == empty.height),
        "\(row.label) is frozen at the empty-slot size, so its row proves nothing")
    }
  }

  /// **The four notification severities must not all measure the same.** They
  /// share one leaf and one model shape and differ only in style, so a harness
  /// returning one number for everything would pass every row above while seeing
  /// nothing. `.interruption` swaps an SF Symbol for the distress lips and its
  /// own background, and `.advisory` wraps where the others do not.
  @Test("the notification severities are told apart by the instrument")
  func severitiesAreDiscriminated() {
    let sizes = [
      RenderedPillHarness.rootSize(for: .warning(reason: .polishFailed)),
      RenderedPillHarness.rootSize(for: .error(reason: .asrFailed)),
      RenderedPillHarness.rootSize(for: .advisory(reason: .zeroSignal)),
      RenderedPillHarness.rootSize(for: .interruption(reason: .deviceRemoved)),
    ]
    #expect(
      Set(sizes.map { "\($0.width)x\($0.height)" }).count == sizes.count,
      """
      two or more notification severities measured identically: \(sizes). This \
      instrument cannot tell them apart, so every frozen row above is a claim it \
      cannot support.
      """)
  }

  /// Reconciles this instrument against a number pinned independently, by a
  /// different rig, before this suite existed. A disagreement here indicts the
  /// harness rather than the app.
  @Test("the classic capsule measures what its own suite already pins")
  func classicAgreesWithTheIndependentPin() throws {
    let contentHeight = try RenderedPillHarness.recordingContentHeight(
      design: .classic, width: 185)
    #expect(
      contentHeight == 44,
      """
      the capsule's content measured \(contentHeight)pt, against the 44pt \
      `RecordingOverlayPreviewChromeTests.capsuleHeightIsPinned` has pinned since \
      #2202. Two rigs disagreeing about one pill means one of them is wrong, and \
      this is the newer one.
      """)
  }

  // MARK: - Recording pills

  nonisolated static let frozenRecording:
    [(label: String, design: RecordingPillDesign, locked: Bool, width: CGFloat, height: CGFloat)] =
      [
        ("classic.unlocked", .classic, false, 185, 92),
        ("classic.locked", .classic, true, 185, 92),
        ("readingWell.unlocked", .readingWell, false, 400, 34),
        ("readingWell.locked", .readingWell, true, 400, 34),
      ]

  @Test(
    "every recording pill renders exactly what it rendered before Phase 4",
    arguments: RenderedPillFreezeTests.frozenRecording)
  func recordingRowsAreFrozen(
    row: (
      label: String, design: RecordingPillDesign, locked: Bool, width: CGFloat, height: CGFloat
    )
  ) throws {
    let size = RenderedPillHarness.recordingRootSize(design: row.design, locked: row.locked)
    try #require(size.width > 0 && size.height > 0, "\(row.label) measured \(size)")
    #expect(
      size.width == row.width && size.height == row.height,
      "\(row.label) measured \(size.width) x \(size.height), frozen at \(row.width) x \(row.height)"
    )
  }

  /// The reading well earns its height a line at a time, and that growth is the
  /// feature. Frozen as a specific measurement rather than as "taller", because
  /// "taller" also passes if it grows to the wrong size.
  @Test("the reading well grows for words, and by exactly as much as it did")
  func readingWellGrowsForWords() {
    let words = RenderedPillHarness.recordingRootSize(
      design: .readingWell,
      display: .text("the quarterly numbers came in ahead of plan and the board was pleased"))
    #expect(words.width == 400 && words.height == 99, "the reading well measured \(words)")
  }

  // MARK: - The measurement nobody had taken

  /// **The classic pill's reserved box has ZERO headroom for its own longest
  /// notice, and that is measured rather than asserted.**
  ///
  /// The #1060 banner is the only thing that makes a without-words pill grow.
  /// The root frames such a pill to `RecordingPillDesign.reservedHeight`, and a
  /// without-words design is handed a no-op growth callback by
  /// `OverlayRenderModel`, so nothing in production and nothing in this tree
  /// could previously observe the content exceeding the box.
  ///
  /// Measured 2026-08-25: `approachingCap` fills the 92-point box EXACTLY, and
  /// `autoStopUnavailable` uses 78. A three-line sentence measures 120 and would
  /// be silently cut off. So this is not a defect today and is one word of copy
  /// away from being one — which is precisely why the budget is pinned here
  /// rather than left as a number in a doc comment.
  @Test(
    "the shipped in-panel notices fit the box the classic pill reserves",
    arguments: [RecordingNoticeReason.approachingCap, .autoStopUnavailable])
  func inPanelNoticesFitTheReservedBox(reason: RecordingNoticeReason) throws {
    let budget = try #require(RecordingPillDesign.classic.reservedHeight)
    for locked in [false, true] {
      let height = try RenderedPillHarness.recordingContentHeight(
        design: .classic, locked: locked,
        notice: DictationNarrator.copy(for: reason), width: RecordingPillDesign.classic.width)
      #expect(
        height <= budget,
        """
        the \(reason) banner made the capsule \(height)pt tall (locked: \(locked)) \
        against the \(budget)pt box the classic design reserves. The pill cannot \
        grow — a without-words design is handed a no-op growth callback — so the \
        overflow is CLIPPED on screen with nothing reporting it. Shorten the copy \
        or raise the reserved height; do not raise this expectation.
        """)
    }
  }

  /// The paired case, so the row above cannot pass by measuring nothing. A
  /// notice must make the pill genuinely taller than a bare one.
  @Test("a notice is what makes the capsule grow at all")
  func aNoticeGrowsTheCapsule() throws {
    let bare = try RenderedPillHarness.recordingContentHeight(
      design: .classic, width: 185)
    let withNotice = try RenderedPillHarness.recordingContentHeight(
      design: .classic,
      notice: DictationNarrator.copy(for: .approachingCap), width: 185)
    #expect(
      withNotice > bare,
      "a notice measured \(withNotice)pt against a bare \(bare)pt — the banner never rendered")
  }
}
