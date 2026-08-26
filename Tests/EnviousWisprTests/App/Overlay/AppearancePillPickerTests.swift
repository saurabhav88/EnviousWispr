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
  /// means the next cause is swept by every case here on the day it is added.
  @Test("no two refusals give the same reason")
  func refusalsAreDistinguishable() throws {
    let refusals = PillWordsCapability.allCases.filter { !$0.hasWords }
    #expect(refusals.count >= 2, "control: there is more than one way to be refused")

    var sentences: [PillWordsCapability: String] = [:]
    for cause in refusals {
      let sentence = try #require(
        RecordingPillAppearancePanel.reason(for: cause, groupHoldsWords: true),
        "\(cause) greys the with-words group and explains nothing")
      #expect(!sentence.isEmpty)
      sentences[cause] = sentence
    }

    #expect(
      Set(sentences.values).count == refusals.count,
      """
      \(refusals.count) causes share \(Set(sentences.values).count) sentences, so at \
      least one user is told the wrong thing about why their designs are greyed: \
      \(sentences)
      """)
  }

  /// **One property replacing two row tables, and it is a closed question: a group
  /// carries a reason EXACTLY when it is inapplicable.** The applicable group must
  /// carry none, so the sentence appears once on the page rather than twice; the
  /// inapplicable one must always carry one, so nothing is greyed in silence.
  /// Written as an if-and-only-if over the full cross-product because the two
  /// halves were separate hand-written tables that could each be extended without
  /// the other.
  @Test(
    "a group explains itself exactly when it is inapplicable",
    arguments: PillWordsCapability.allCases, [true, false])
  func onlyTheInapplicableGroupCarriesAReason(
    capability: PillWordsCapability, groupHoldsWords: Bool
  ) {
    // The with-words group applies when words are available; the wordless group
    // applies when they are not. So applicability IS this equality.
    let isApplicable = (groupHoldsWords == capability.hasWords)
    let reason = RecordingPillAppearancePanel.reason(
      for: capability, groupHoldsWords: groupHoldsWords)

    if isApplicable {
      #expect(
        reason == nil,
        """
        the \(groupHoldsWords ? "with-words" : "wordless") group applies at \
        \(capability) and still explains a restriction that is not in force: \(reason!)
        """)
    } else {
      #expect(
        reason != nil,
        "the \(groupHoldsWords ? "with-words" : "wordless") group is greyed at \(capability) and says nothing")
      #expect(reason?.isEmpty == false, "\(capability) explains itself with an empty string")
    }
  }

  /// House style: no em or en dashes in anything a user reads. Swept over the
  /// authority for the same reason as above.
  @Test("no user-facing string carries a dash")
  func copyCarriesNoDashes() {
    var strings = RecordingPillDesign.allCases.flatMap { [$0.displayName, $0.summary] }
    for capability in PillWordsCapability.allCases {
      for holdsWords in [true, false] {
        if let r = RecordingPillAppearancePanel.reason(
          for: capability, groupHoldsWords: holdsWords)
        {
          strings.append(r)
        }
      }
    }
    #expect(strings.count > RecordingPillDesign.allCases.count, "control: reasons were collected")
    for s in strings {
      #expect(!s.contains("\u{2014}"), "em dash in: \(s)")
      #expect(!s.contains("\u{2013}"), "en dash in: \(s)")
    }
  }

  /// **THE PAGE MUST BE INVALIDATED, not merely able to compute the right answer
  /// if something else happens to ask it again** (cloud review round 4).
  ///
  /// Every other input to `wordsCapability` is settings-backed, so a page reading
  /// it registers a dependency and refreshes on its own. Model-removal
  /// suppression is the exception: a private field on a coordinator that is not
  /// `@Observable`, which the capability's guard returns on BEFORE any settings
  /// read. During a drain the page therefore depends on nothing at all, and the
  /// end of the drain cannot invalidate it — the removal sentence stays over
  /// designs that are available again.
  ///
  /// Asserted with `withObservationTracking`, the mechanism SwiftUI itself uses,
  /// so this fails if `wordsCapability` ever stops consuming the generation. That
  /// discard in its body reads like tidying and IS the registration.
  ///
  /// Lives here rather than beside the coordinator because this suite already
  /// builds a model with its own defaults suite; the capability suite has a
  /// coordinator rig and no settings rig, and a second fixture for a state one
  /// already stages is the cost worth not paying.
  @Test("a reader of the capability is invalidated when the coordinator announces")
  func aCapabilityReaderIsInvalidated() {
    let model = Self.model(.available)

    // A reference box because `onChange` is `@Sendable`. It fires synchronously on
    // the mutating thread, which here is the main actor throughout.
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking {
      _ = model.wordsCapability
    } onChange: {
      flag.fired = true
    }

    #expect(!flag.fired, "control: nothing has changed yet")
    model.capabilityDidChange()
    #expect(
      flag.fired,
      """
      a reader of wordsCapability was not invalidated by an announced change, so \
      the Appearance page renders whatever it computed last and corrects itself \
      only on an unrelated redraw.
      """)
  }

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

  // MARK: - The current state stays unmistakable (#2435)

  /// **Product Outcome, and the reason the approved group titles are honest.**
  ///
  /// "Live Preview off" and "Live Preview on" name a CONDITION — the pills you get
  /// when the setting is that way. Read instead as a claim about the CURRENT
  /// state they would be false at `engineUnsupported` and `modelBeingRemoved`,
  /// where the setting is on and the pills are still out of reach. What makes the
  /// condition reading the one a user actually gets is that exactly one group
  /// shows the filled dot and the other prints its own reason. Both are therefore
  /// requirements, and this is the row that holds them.
  ///
  /// **It links the two surfaces rather than re-deriving either.** The dot reads
  /// `isActive`; the greyed line reads `reason(for:groupHoldsWords:)`. That they
  /// each behave correctly is asserted above; that they AGREE, in every
  /// capability state, is what this asserts and nothing else does.
  @Test(
    "exactly one group is marked in use, and it is the one with nothing to explain",
    arguments: PillWordsCapability.allCases)
  func theDotAndTheReasonAgree(capability: PillWordsCapability) throws {
    let active = [true, false].filter {
      RecordingPillAppearancePanel.isActive(capability, groupHoldsWords: $0)
    }

    #expect(
      active.count == 1,
      """
      \(capability) marks \(active.count) groups in use. The dot is the only thing on \
      the page carrying the CURRENT state, so zero leaves a user unable to tell which \
      pills they have and two tells them both.
      """)
    let live = try #require(active.first)

    #expect(
      RecordingPillAppearancePanel.reason(for: capability, groupHoldsWords: live) == nil,
      "\(capability) marks a group in use and still explains why it is not")
    #expect(
      RecordingPillAppearancePanel.reason(for: capability, groupHoldsWords: !live)?.isEmpty
        == false,
      """
      \(capability) greys a group without saying why. The title says only which \
      CONDITION that group belongs to, so with no reason beside it there is nothing on \
      the page that names what is actually wrong.
      """)
  }
}
