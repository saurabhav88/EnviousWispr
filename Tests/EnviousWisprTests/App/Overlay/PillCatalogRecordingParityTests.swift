import CoreGraphics
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// **Table 1's recording rows, and the measurement that makes G3 legible**
/// (#2375 Phase 3, chunk C3a).
///
/// C0 froze the recording pill twice: once as an ordinary definition row, which
/// records what the REDUCER emitted, and once per capability state as a
/// `FrozenRecordingRow`, which records what the window was actually sized to.
/// Those two disagree for the with-words case — 185 against 400 — and that
/// disagreement IS the defect: two authorities for one geometry, the
/// correct-looking one ignored.
///
/// After C3a there is one authority. Both frozen recording rows must now come
/// from the definition itself.
@Suite(.tags(.productOutcome))
struct PillCatalogRecordingParityTests {

  /// Which design each frozen capability state resolves to under the shipped
  /// selections. Not hardcoded per row: `PillDesignSelections.shipped` is the
  /// pair the base revision produced, so the mapping is derived from the thing
  /// under test's own input rather than restated.
  private static func design(for capability: FrozenRecordingCapability) -> RecordingPillDesign {
    PillDesignSelections.shipped
      .resolve(capabilityHasWords: capability == .withWords)
      .design
  }

  @Test("both frozen recording geometries come from the definition alone")
  func recordingGeometryParity() throws {
    #expect(FrozenPillParity.recordingRows.count == 2, "the oracle lost a capability state")

    for row in FrozenPillParity.recordingRows {
      let design = Self.design(for: row.capability)
      let entry = PillCatalog.entry(
        for: .recording(audioLevel: 0, design: design), id: PresentationID())
      let definition = try #require(entry.definition, "\(row.capability) produced no definition")

      #expect(
        definition.requestedWidth == .fixed(row.effectiveWidth),
        "\(row.capability): the definition's own width is not the width the base revision sized to")
      #expect(
        definition.reservesFixedHeight == row.fixedHeight,
        "\(row.capability): the definition's own height is not what the base revision reserved")
      #expect(
        definition.recordingDesign?.canHoldWords == row.usesPreviewLayout,
        "\(row.capability): the leaf would be told the wrong thing about showing words")
    }
  }

  /// The dead literal, asserted as a difference rather than described.
  ///
  /// **This is the one row that would have passed before C3a and did not mean
  /// anything.** The reducer emitted 185 for both capability states; the director
  /// substituted 400 for one of them. A test reading the reducer saw 185 twice
  /// and agreed with itself.
  @Test("the two designs produce genuinely different geometry")
  func theTwoDesignsDiffer() throws {
    let classic = try #require(
      PillCatalog.entry(for: .recording(audioLevel: 0, design: .classic), id: PresentationID())
        .definition)
    let readingWell = try #require(
      PillCatalog.entry(
        for: .recording(audioLevel: 0, design: .readingWell), id: PresentationID()
      ).definition)

    let levelRail = try #require(
      PillCatalog.entry(for: .recording(audioLevel: 0, design: .levelRail), id: PresentationID())
        .definition)

    #expect(classic.requestedWidth == .fixed(185))
    #expect(readingWell.requestedWidth == .fixed(400))
    #expect(levelRail.requestedWidth == .fixed(260))
    #expect(classic.reservesFixedHeight == 92)
    #expect(readingWell.reservesFixedHeight == nil)
    // **The same 92 as the capsule, and that is inherited rather than repeated.**
    // It is the without-words NOTICE BUDGET: the #1060 banner is the only thing
    // that grows such a pill, and a design that cannot hold words is handed a
    // no-op growth callback, so anything over the reserved box is clipped in
    // silence.
    #expect(levelRail.reservesFixedHeight == 92)

    // **Every PAIR must differ, not just the original two.** Asserting only that
    // classic and readingWell disagree would stay green with a third design that
    // rendered as a copy of either — which is this phase's named regression
    // arriving as a feature.
    let widths = [classic, readingWell, levelRail].map(\.requestedWidth)
    #expect(Set(widths.map(String.init(describing:))).count == widths.count, "\(widths)")
  }

  /// The recording pill still announces, and still says the same sentence
  /// whichever design it wears — the design is a look, not a different event.
  @Test("both designs announce the frozen recording sentence")
  func recordingAnnouncementIsDesignIndependent() throws {
    let frozen = try #require(
      FrozenPillParity.rows.first { $0.label == "recording" }?.announcement,
      "the oracle lost the recording announcement")

    for design in RecordingPillDesign.allCases {
      let entry = PillCatalog.entry(
        for: .recording(audioLevel: 0, design: design), id: PresentationID())
      #expect(entry.announcement?.text == frozen.text, "\(design) said something else")
      #expect(
        entry.announcement?.isHighPriority == frozen.isHighPriority,
        "\(design) announced at the wrong priority")
    }
  }

  /// The frozen `recording` definition row, which is the classic design's.
  ///
  /// It is asserted here rather than in the main parity sweep because that sweep
  /// is keyed by request and this row needs a design argument the other sixteen
  /// do not have.
  @Test("the classic design reproduces the frozen recording definition row")
  func classicMatchesTheFrozenDefinitionRow() throws {
    let row = try #require(FrozenPillParity.rows.first { $0.label == "recording" })
    let entry = PillCatalog.entry(
      for: .recording(audioLevel: 0, design: .classic), id: PresentationID())
    let definition = try #require(entry.definition)

    #expect(row.hasDefinition)
    #expect(row.contentTag == "recording")
    #expect(row.notice == nil)
    #expect(definition.requestedWidth == .fixed(185))
    #expect(definition.reservesFixedHeight == row.fixedHeight)
    #expect(definition.expiry == .untilReplaced)
  }

  // MARK: - The selection seam

  /// `resolve` is fail-closed, and the fallback is a value rather than a promise.
  @Test("a selection that cannot hold words is substituted, and says so")
  func resolveIsFailClosed() {
    let bad = PillDesignSelections(withoutWords: .classic, withWords: .classic)

    let withWords = bad.resolve(capabilityHasWords: true)
    #expect(withWords.design == .readingWell, "a design that cannot hold words was accepted")
    #expect(withWords.substituted, "the substitution was silent")

    // The same bad pair is FINE without words: nothing is being dropped.
    let withoutWords = bad.resolve(capabilityHasWords: false)
    #expect(withoutWords.design == .classic)
    #expect(withoutWords.substituted == false, "an unnecessary substitution was reported")
  }

  /// The shipped pair never substitutes, in either state. If it ever does, the
  /// constant and the designs have drifted apart.
  @Test("the shipped selections resolve cleanly in both capability states")
  func shippedSelectionsNeverSubstitute() {
    for hasWords in [true, false] {
      let resolution = PillDesignSelections.shipped.resolve(capabilityHasWords: hasWords)
      #expect(
        resolution.substituted == false, "the shipped pair substituted at hasWords=\(hasWords)")
      #expect(resolution.design.canHoldWords == hasWords, "the shipped pair resolved the wrong way")
    }
  }

  /// **`canHoldWords` is what provider gating keys off, so it is pinned per
  /// design rather than inferred.** Reading it off the resolution would make this
  /// agree with itself.
  @Test("each design's word capability is what its name promises")
  func designCapabilities() {
    #expect(RecordingPillDesign.classic.canHoldWords == false)
    #expect(RecordingPillDesign.readingWell.canHoldWords)
    #expect(RecordingPillDesign.levelRail.canHoldWords == false)
    // Raised from 2 to 3 by #2376 C5, which added `.levelRail` WITH its frozen
    // geometry row below and its own suite. The tripwire is doing its job: it
    // fired, and the response was to add the rows a new design owes rather than
    // to widen the number.
    #expect(RecordingPillDesign.allCases.count == 3, "a design was added without a frozen row")
  }
}
