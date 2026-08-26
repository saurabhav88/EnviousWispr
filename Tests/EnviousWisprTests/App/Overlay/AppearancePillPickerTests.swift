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
    let all = Set(PillCatalog.designs(holdingWords: true) + PillCatalog.designs(holdingWords: false))
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
  /// **A state explains itself EXACTLY when something in it is greyed.**
  ///
  /// Coupling the pill choice to Live Preview (founder, 2026-08-26) means a tap
  /// now produces whatever state the design needs, so nothing is greyed in the two
  /// states the switch controls — and a line there would be instructing the user to
  /// do by hand what the tap already does. The other two are not about the switch,
  /// stay greyed, and still owe a reason.
  ///
  /// Both directions asserted, so a future change that greys a card without
  /// explaining it fails here, and so does one that leaves an orphaned sentence
  /// under a row where everything is selectable.
  @Test("a state explains itself exactly when it greys something",
        arguments: PillWordsCapability.allCases)
  func reasonAppearsExactlyWhenSomethingIsGreyed(capability: PillWordsCapability) throws {
    let reason = RecordingPillAppearancePanel.reason(for: capability)
    let switchCanFixIt = capability == .available || capability == .previewOff

    if switchCanFixIt {
      #expect(
        reason == nil,
        """
        \(capability) shows "\(reason ?? "")" while every card is selectable. Picking a \
        design sets the switch itself, so this sentence tells the user to go and do what \
        the tap already did.
        """)
    } else {
      let text = try #require(reason, "\(capability) greys a card and says nothing about why")
      #expect(!text.isEmpty, "\(capability) returns an empty reason, which renders as a blank line")
      #expect(
        !text.contains("—") && !text.contains("–"),
        "\(capability) reason carries a dash: \(text)")
    }
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
    // **Only the states that still HAVE a reason.** This used to require one from
    // every state; coupling the pill choice to Live Preview removed the two the
    // switch controls, and a `#require` here then aborted the whole run rather
    // than reporting a result — which is why the sibling above now uses a
    // throwing require.
    guard let text = RecordingPillAppearancePanel.reason(for: capability) else { return }

    #expect(
      !text.hasPrefix("Live Preview is on"),
      "\(capability) opens by reporting the setting's state: \(text)")
    #expect(
      !text.lowercased().contains("turn on live preview")
        && !text.lowercased().contains("turn off live preview"),
      """
      \(capability) tells the user to flip Live Preview by hand: "\(text)". Tapping a \
      design does that now, so an instruction to go and do it is stale copy.
      """)
  }

  /// **A wordless design is ALWAYS pickable; a words-capable one needs words to be
  /// possible here.**
  ///
  /// This replaces "exactly one side is offerable at a time", which was true while
  /// the capability GATED the choice. It now FOLLOWS the choice, so the only
  /// remaining bar is whether the machine can produce words at all — something no
  /// tap can change. Asserted per state so the two cases the switch cannot fix
  /// stay closed.
  @Test("a tap can reach any design the machine can actually run",
        arguments: PillWordsCapability.allCases)
  func couplingOpensEverythingTheMachineCanDo(capability: PillWordsCapability) {
    let model = Self.model(capability)

    for design in RecordingPillDesign.allCases where !design.canHoldWords {
      #expect(
        model.offersCoupled(design, capability: capability),
        """
        \(design) is greyed at \(capability), but turning Live Preview OFF always works, \
        so no state can put a wordless design out of reach.
        """)
    }

    let wordsArePossible = capability == .available || capability == .previewOff
    for design in RecordingPillDesign.allCases where design.canHoldWords {
      #expect(
        model.offersCoupled(design, capability: capability) == wordsArePossible,
        """
        \(design) offerability at \(capability) does not match whether words are possible \
        there. A tap sets the switch, but it cannot install an engine or finish a removal.
        """)
    }
  }
}
