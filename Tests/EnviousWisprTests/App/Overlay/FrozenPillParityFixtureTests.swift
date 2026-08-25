import CoreGraphics
import EnviousWisprCore
import Foundation
import Testing

/// Guards on the frozen oracle itself (#2375 Phase 3, chunk C0).
///
/// **Drift Guard, not Product Outcome.** These do not test the product; they
/// test that the oracle every later chunk is measured against is intact and
/// still usable. Declaring the class matters here more than usual: a suite that
/// looks like parity coverage and is really a fixture check is exactly the
/// arithmetic this repo's test inventory exists to expose.
///
/// The rename-neutrality check is the one that earns its place. C1b's proof is
/// that the renamed type's occurrence population is exactly the count measured
/// before the work began, and a fixture naming that type would enlarge it
/// silently — so the oracle would break the other proof that depends on it. The
/// plan calls for that check to be mechanical rather than intended.
///
/// **No sweep exclusion is needed, and an earlier draft of this file wrongly
/// asked for one.** Only ONE of the forbidden names is renamed by C1b, and a
/// guard's list is data rather than prose — so that single entry is assembled
/// from fragments at the point of use. The guard stays readable, C1b's sweep
/// stays a plain search with a zero-reference endpoint, and the plan needs no
/// permanent carve-out. The other entries are not renamed by C1b, so spelling
/// them costs nothing.
@Suite(.tags(.driftGuard))
struct FrozenPillParityFixtureTests {

  private static let fixturePath =
    "Tests/EnviousWisprTests/App/Overlay/FrozenPillParityFixture.swift"

  /// MIGRATION types the fixture must never name. Naming any of them either
  /// enlarges C1b's rename population or ties the oracle to the code under test.
  ///
  /// Deliberately NOT "every production type": the fixture legitimately names
  /// `OverlayReducer` in its provenance comment, and a list that does not forbid
  /// that name cannot support a claim that it forbids all of them.
  private static let forbidden = [
    // Assembled, not spelled: this is the one name C1b renames, and a literal
    // here would enlarge the very population C1b's sweep must drive to zero.
    "Overlay" + "Presentation",
    "PillDefinition",
    // Retired by C3b, and kept on this list deliberately. A forbidden name for a
    // type that no longer exists costs nothing and still stops the fixture
    // resurrecting it — removing it as dead would reopen the hole.
    "OverlayRecordingLayout",
    "RecordingPillDesign",
    "PillCatalog",
    "NoticeModel",
    "OverlayWidth",
    "OverlayExpiry",
    "OverlayAnnouncement",
  ]

  @Test("the frozen fixture names no forbidden migration type")
  func fixtureIsRenameNeutral() throws {
    let url = RepoRoot.url.appending(path: Self.fixturePath)
    let source = try String(contentsOf: url, encoding: .utf8)

    // Two-way control: a token that IS present, so an empty result cannot pass
    // for "nothing forbidden found" when the read itself failed.
    #expect(
      source.contains("FrozenRecordingCapability"),
      "positive control failed — the fixture source was not read")

    for name in Self.forbidden {
      #expect(
        source.contains(name) == false,
        "the frozen fixture names forbidden migration type \(name), which ties the oracle to the code under test or enlarges C1b's rename population"
      )
    }
  }

  @Test("every row has a distinct label")
  func labelsAreUnique() {
    let labels = FrozenPillParity.rows.map(\.label)
    #expect(Set(labels).count == labels.count, "duplicate labels make a row unaddressable")
  }

  /// The transcription's own floor. A row silently dropped during transcription
  /// is invisible to every later chunk, because a missing expectation cannot
  /// fail.
  @Test("the capture's full row set survived transcription")
  func rowCountIsFrozen() {
    #expect(FrozenPillParity.rows.count == 20)
    #expect(FrozenPillParity.recordingRows.count == 2)
  }

  /// `hidden` is the row that forced the catalog to return an ENTRY rather than
  /// a definition: no definition, and it still announces.
  ///
  /// **The announcement assertion is the point of this test**, not an extra.
  /// An earlier draft said "it still announces" in prose and checked only the
  /// absent definition — so it passed against a row frozen with `nil`, which is
  /// exactly what a fresh-reducer capture produces. A test whose name claims a
  /// property its assertions do not require is worse than no test, because it is
  /// cited as covering that property.
  @Test("hidden carries no definition and still announces the end of the dictation")
  func hiddenHasNoDefinitionAndStillAnnounces() throws {
    let row = try #require(FrozenPillParity.rows.first { $0.label == "hidden" })
    #expect(row.hasDefinition == false)
    #expect(row.width == nil)
    #expect(row.expiry == nil)
    #expect(
      row.announcement
        == FrozenAnnouncement(text: "Recording complete", isHighPriority: false),
      "the end of a dictation is spoken even though no pill is shown, which is the case that forced the catalog's return type to be an entry rather than a definition"
    )
  }

  /// Import status is the one presentation with no matching intent, so the
  /// shipped announcement switch has no arm for it. Asserted as nil rather than
  /// left out, because an omitted row proves nothing.
  @Test("import status announces nothing")
  func importStatusIsSilent() throws {
    let row = try #require(
      FrozenPillParity.rows.first { $0.label == "importStatus.featureRoute" })
    #expect(row.hasDefinition)
    #expect(row.announcement == nil)
  }

  /// **The duplicate, measured.** Both routes produce identical values in the
  /// base revision. This is what C2's de-duplication must preserve, and having
  /// it as a checked property means the agreement is a fact rather than a
  /// recollection.
  @Test("both Bluetooth routes are identical in the base revision")
  func bluetoothRoutesAgree() throws {
    let pipeline = try #require(
      FrozenPillParity.rows.first { $0.label == "bluetoothAwareness.pipelineRoute" })
    let feature = try #require(
      FrozenPillParity.rows.first { $0.label == "bluetoothAwareness.featureRoute" })

    #expect(pipeline.hasDefinition == feature.hasDefinition)
    #expect(pipeline.notice == feature.notice)
    #expect(pipeline.contentTag == feature.contentTag)
    #expect(pipeline.width == feature.width)
    #expect(pipeline.fixedHeight == feature.fixedHeight)
    #expect(pipeline.expiry == feature.expiry)
    #expect(pipeline.announcement == feature.announcement)
  }

  /// **The dead literal, measured.** The reducer answers 185/92 for a recording;
  /// the director substitutes 400/content-sized when words can be shown. If
  /// these two ever agree, the defect Phase 3 exists to close has already been
  /// closed by something else and this fixture is describing a tree that no
  /// longer exists.
  @Test("the reducer's recording width is the without-words answer only")
  func recordingGeometryDisagreesWithTheReducer() throws {
    let reducerRow = try #require(FrozenPillParity.rows.first { $0.label == "recording" })
    let withoutWords = try #require(
      FrozenPillParity.recordingRows.first { $0.capability == .withoutWords })
    let withWords = try #require(
      FrozenPillParity.recordingRows.first { $0.capability == .withWords })

    #expect(reducerRow.width == .fixed(withoutWords.effectiveWidth))
    #expect(reducerRow.fixedHeight == withoutWords.fixedHeight)

    #expect(
      withWords.effectiveWidth != withoutWords.effectiveWidth,
      "the two capability states must differ, or there is no substitution to close")
    #expect(withWords.fixedHeight == nil, "the with-words pill is content-sized")
    #expect(withWords.usesPreviewLayout != withoutWords.usesPreviewLayout)
  }

  /// The accessibility refusal draws one request's definition under another
  /// request's announcement. It is the only row where that is legitimate, and
  /// C2 has to reproduce it exactly.
  @Test("a refused accessibility toast draws the clipboard pill and keeps its own sentence")
  func accessibilityRefusalMixesTwoRequests() throws {
    let refused = try #require(
      FrozenPillParity.rows.first { $0.label == "accessibilityNotice.toastRefused" })
    let clipboard = try #require(
      FrozenPillParity.rows.first { $0.label == "clipboardFallback" })
    let shown = try #require(
      FrozenPillParity.rows.first { $0.label == "accessibilityNotice.toastShown" })

    #expect(refused.notice == clipboard.notice, "the drawn pill is the clipboard fallback")
    #expect(refused.hasDefinition == clipboard.hasDefinition)
    #expect(refused.contentTag == clipboard.contentTag)
    #expect(refused.fixedHeight == clipboard.fixedHeight)
    #expect(refused.width == clipboard.width)
    #expect(refused.expiry == clipboard.expiry)
    #expect(
      refused.announcement == shown.announcement,
      "the spoken sentence stays the accessibility one")
  }
}
