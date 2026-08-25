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

  /// **Two refusals must not share a sentence.** Telling a user whose engine
  /// cannot run here to switch a preview on is worse than saying nothing: it
  /// sends them to a control that will not help.
  @Test("the two unavailable causes give different reasons")
  func reasonsDifferByCause() throws {
    let off = try #require(
      RecordingPillAppearancePanel.reason(for: .previewOff, groupHoldsWords: true))
    let unsupported = try #require(
      RecordingPillAppearancePanel.reason(for: .engineUnsupported, groupHoldsWords: true))

    #expect(off != unsupported, "both causes give one sentence: \(off)")
    #expect(!off.isEmpty && !unsupported.isEmpty)
  }

  /// The paired negative: an ACTIVE group carries no reason at all, so the
  /// sentence appears exactly once in the rendered page rather than twice.
  @Test(
    "an applicable group is given no reason",
    arguments: [
      (PillWordsCapability.available, true),
      (.previewOff, false),
      (.engineUnsupported, false),
    ])
  func anApplicableGroupHasNoReason(row: (PillWordsCapability, Bool)) {
    #expect(
      RecordingPillAppearancePanel.reason(for: row.0, groupHoldsWords: row.1) == nil,
      """
      the \(row.1 ? "with-words" : "wordless") group is applicable at \(row.0) and \
      still carries a reason, so the page would explain a restriction that is not \
      in force.
      """)
  }

  /// And the INAPPLICABLE group always carries one, in every capability state.
  /// Without this, greying a group with no explanation would pass every row above.
  @Test(
    "an inapplicable group always says why",
    arguments: [
      (PillWordsCapability.available, false),
      (.previewOff, true),
      (.engineUnsupported, true),
    ])
  func anInapplicableGroupAlwaysSaysWhy(row: (PillWordsCapability, Bool)) {
    let reason = RecordingPillAppearancePanel.reason(for: row.0, groupHoldsWords: row.1)
    #expect(reason != nil, "a greyed group at \(row.0) explains nothing")
    #expect(reason?.isEmpty == false)
  }

  /// House style: no em or en dashes in anything a user reads.
  @Test("no user-facing string carries a dash")
  func copyCarriesNoDashes() {
    var strings = RecordingPillDesign.allCases.flatMap { [$0.displayName, $0.summary] }
    for capability in [PillWordsCapability.available, .previewOff, .engineUnsupported] {
      for holdsWords in [true, false] {
        if let r = RecordingPillAppearancePanel.reason(
          for: capability, groupHoldsWords: holdsWords)
        {
          strings.append(r)
        }
      }
    }
    for s in strings {
      #expect(!s.contains("\u{2014}"), "em dash in: \(s)")
      #expect(!s.contains("\u{2013}"), "en dash in: \(s)")
    }
  }

  // MARK: - Choosing writes one group and only one

  @Test("choosing a design writes its own group and leaves the other alone")
  func choosingWritesOneGroup() {
    let m = Self.model(.previewOff)
    let otherBefore = m.selection(holdingWords: true)

    m.choose(.levelRail, holdingWords: false)

    #expect(m.selection(holdingWords: false) == .levelRail)
    #expect(
      m.selection(holdingWords: true) == otherBefore,
      "choosing a wordless design changed the with-words group's selection")
  }

  /// Every design carries a name and a sentence, so a design added later cannot
  /// render as a blank card.
  @Test("every design has copy", arguments: RecordingPillDesign.allCases)
  func everyDesignHasCopy(design: RecordingPillDesign) {
    #expect(!design.displayName.isEmpty, "\(design) has no name")
    #expect(!design.summary.isEmpty, "\(design) has no description")
  }

  @Test("no two designs share a name")
  func namesAreDistinct() {
    let names = RecordingPillDesign.allCases.map(\.displayName)
    #expect(Set(names).count == names.count, "two designs share a card title: \(names)")
  }
}
