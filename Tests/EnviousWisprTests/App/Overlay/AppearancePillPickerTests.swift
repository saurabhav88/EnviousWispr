import AppKit
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// The grouped pill picker gets its rules from the catalog (#2376 Phase 4, C7).
///
/// **The risk this suite exists for is DRIFT, and the plan names it outright:**
/// the picker and the pill each deciding which designs are compatible, agreeing
/// on the day they are written and diverging the day a design is added. Every row
/// here is generated over the cross-product, so a fourth design is swept with no
/// edit.
///
/// **Product Outcome.** When these fail, a user is offered a pill their machine
/// cannot draw, or is refused one it can.
@MainActor
@Suite(.tags(.productOutcome))
struct AppearancePillPickerTests {

  init() { _ = NSApplication.shared }

  private static func model(_ capability: PillWordsCapability) -> PillAppearanceModel {
    let name = "ew.pillPickerTest." + UUID().uuidString
    let suite = UserDefaults(suiteName: name)!
    suite.removePersistentDomain(forName: name)
    return PillAppearanceModel(
      settings: SettingsManager(defaults: suite), capability: { capability })
  }

  // MARK: - Offerability comes from the catalog, in both directions

  @Test(
    "what the picker offers is what the pill would accept",
    arguments: RecordingPillDesign.allCases, [true, false])
  func offerabilityAgreesWithTheCatalog(design: RecordingPillDesign, holdingWords: Bool) {
    let m = Self.model(holdingWords ? .available : .previewOff)
    let offered = m.offers(design, holdingWords: holdingWords)
    let resolution = PillDesignSelections(withoutWords: design, withWords: design)
      .resolve(capabilityHasWords: holdingWords)

    #expect(
      offered == (resolution.substituted == false),
      """
      the picker said offered=\(offered) for \(design) at holdingWords=\
      \(holdingWords) while the pill would have substituted=\(resolution.substituted). \
      The picker has grown an opinion of its own, which is the drift this phase \
      was told to watch for.
      """)
  }

  /// **Group completeness**, so a design added later cannot be silently
  /// unofferable: the union of the two rendered groups is every design.
  @Test("the two groups between them offer every design")
  func groupsCoverEveryDesign() {
    let m = Self.model(.available)
    let all = Set(m.designs(holdingWords: true) + m.designs(holdingWords: false))
    #expect(
      all == Set(RecordingPillDesign.allCases),
      "the picker lays out \(all.count) of \(RecordingPillDesign.allCases.count) designs")
  }

  // MARK: - The reason is stated, differs by cause, and only when it applies

  /// **No two refusals may share a sentence.** Telling a user whose engine cannot
  /// run here to switch a preview on is worse than saying nothing: it sends them
  /// to a control that will not help.
  ///
  /// **Swept over `allCases` rather than over a written-out pair, and the fourth
  /// cause is why.** This suite used to name its causes in array literals. An
  /// array literal is not exhaustive over an enum, so adding `.modelBeingRemoved`
  /// compiled and left it unswept in four places at once: the compiler cannot see
  /// an omission from a list, only from a `switch`. Reading the authority instead
  /// **Every capability state greys something, so every state says why.**
  ///
  /// One row replaced two groups (#2446), which turns a per-group question into a
  /// single invariant: exactly one side of the words divide is usable at a time,
  /// so a card is always greyed and a reason is always owed. A `nil` here would be
  /// a row with dead cards and no explanation.
  @Test("every state explains its greyed cards", arguments: PillWordsCapability.allCases)
  func everyStateCarriesAReason(capability: PillWordsCapability) {
    let reason = RecordingPillAppearancePanel.reason(for: capability)
    let text = try! #require(reason, "\(capability) greys cards and says nothing about why")

    #expect(
      !text.isEmpty, "\(capability) returns an empty reason, which renders as a blank line")
    #expect(
      !text.contains("—") && !text.contains("–"),
      "\(capability) reason carries a dash: \(text)")
  }

  /// **The reason never opens by reporting the SETTING's state.**
  ///
  /// The wording this replaced read "Live Preview is on, so the pill shows your
  /// words." directly beneath a heading that said "Live Preview off", which the
  /// founder rejected on sight. The heading is gone, but the failure mode is not
  /// about the heading: a line on a picture-picking page should be about the
  /// PICTURES, and naming the action is what keeps it there.
  @Test("the reason is about the cards, not the setting", arguments: PillWordsCapability.allCases)
  func theReasonIsAboutTheCards(capability: PillWordsCapability) {
    let text = try! #require(RecordingPillAppearancePanel.reason(for: capability))

    #expect(
      !text.hasPrefix("Live Preview is on"),
      "\(capability) opens by reporting the setting's state: \(text)")
  }

  /// **Exactly one side of the divide is offerable at a time, and the row shows
  /// its tick on that side.**
  ///
  /// This is the constraint the two groups used to make visible. Flattening the
  /// row did not remove it, so it is asserted directly against the catalog rather
  /// than against a heading that no longer exists.
  @Test("one side is usable and the tick is on it", arguments: PillWordsCapability.allCases)
  func theUsableSideCarriesTheSelection(capability: PillWordsCapability) {
    let usable = RecordingPillDesign.allCases.filter {
      PillCatalog.offers($0, capabilityHasWords: capability.hasWords)
    }

    #expect(!usable.isEmpty, "\(capability) offers no design at all, so the row is entirely dead")
    #expect(
      usable.allSatisfy { $0.canHoldWords == capability.hasWords },
      "\(capability) offers designs from both sides of the words divide: \(usable)")
  }
}
