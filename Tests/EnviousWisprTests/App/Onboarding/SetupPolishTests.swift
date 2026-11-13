import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 D3a (plan M77): AI polish's cards, selection and availability in Setup.
///
/// **Product Outcome.** When this fails, the AI polish screen offers Apple Intelligence on a Mac
/// that cannot run it, re-orders the recommender's cards, preselects one model while the button
/// commits another, offers S1-mini for a language it is not offered for, or leaves an EG-1 size
/// unselectable on a small Mac. Expected orders and labels are written by hand from the approved
/// mockup's `polishPlan`; the payload is the recommender's own output for a fixed Mac.
@MainActor
@Suite(.tags(.productOutcome))
struct SetupPolishTests {
  nonisolated static let caps = SpeechLanguageCapabilities(parakeet: ["en", "de"], whisper: nil)

  nonisolated static func held(
    memory: Int, afm: AppleIntelligenceSetupState, language: LanguageMode = .auto
  ) -> OnboardingRecommended {
    let profile = MacProfile(
      memoryGiB: memory, chipName: nil, macOSMajor: 26, appleIntelligence: afm,
      macLanguages: ["en-US"], freeDiskBytes: nil)
    return OnboardingLiveMapping.recommended(
      SetupRecommender.recommend(
        profile: profile, rules: SetupRules.builtIn, languageMode: language,
        capabilities: caps))
  }

  struct Arrangement: Sendable, CustomTestStringConvertible {
    let memory: Int
    let afm: AppleIntelligenceSetupState
    let language: LanguageMode
    let cards: [String]
    let labels: [SetupRecommendation.Label]
    let preselected: String
    var testDescription: String { "\(memory) GB, \(afm), \(language)" }
  }

  /// Every Apple Intelligence state, and the 8 GB English/non-English and 16/32 GB rows.
  nonisolated static let arrangements: [Arrangement] = [
    Arrangement(
      memory: 16, afm: .available, language: .auto, cards: ["appleIntelligence", "eg1.mini"],
      labels: [.easiestWayToStart, .recommendedBestResults], preselected: "eg1.mini"),
    Arrangement(
      memory: 16, afm: .turnedOff, language: .auto, cards: ["eg1.mini", "eg1.full"],
      labels: [.recommendedForYourMac, .evenBetterResults], preselected: "eg1.mini"),
    Arrangement(
      memory: 16, afm: .needsNewerMacOS, language: .auto, cards: ["eg1.mini", "eg1.full"],
      labels: [.recommendedForYourMac, .evenBetterResults], preselected: "eg1.mini"),
    Arrangement(
      memory: 16, afm: .gettingReady, language: .auto, cards: ["eg1.mini", "eg1.full"],
      labels: [.recommendedForYourMac, .evenBetterResults], preselected: "eg1.mini"),
    Arrangement(
      memory: 16, afm: .unavailable, language: .auto, cards: ["eg1.mini", "eg1.full"],
      labels: [.recommendedForYourMac, .evenBetterResults], preselected: "eg1.mini"),
    Arrangement(
      memory: 8, afm: .unavailable, language: .auto, cards: ["eg1.micro", "eg1.mini"],
      labels: [.recommendedForYourMac, .evenBetterResults], preselected: "eg1.micro"),
    Arrangement(
      memory: 8, afm: .unavailable, language: .locked("de"), cards: ["eg1.mini", "eg1.micro"],
      labels: [.recommendedForYourMac, .smallerDownload], preselected: "eg1.mini"),
    Arrangement(
      memory: 32, afm: .unavailable, language: .auto, cards: ["eg1.full", "eg1.mini"],
      labels: [.recommendedForYourMac, .smallerDownload], preselected: "eg1.full"),
  ]

  @Test(
    "the held cards keep the recommender's order, labels and preselection", arguments: arrangements)
  func cardsFollowTheRecommendation(_ a: Arrangement) throws {
    let held = Self.held(memory: a.memory, afm: a.afm, language: a.language)
    #expect(held.polishCards.map(\.model) == a.cards)
    #expect(held.polishCards.map(\.label) == a.labels)
    #expect(held.appleIntelligence == a.afm)
    #expect(held.polish == a.preselected, "the flow's default differs from the preselected card")
    let shown = SetupPolish.pickDisplayed(
      draft: nil, committed: nil, recommended: held, language: a.language)
    #expect(shown == a.preselected, "the screen preselected another card than the recommender")
    #expect(!held.polishCards.map(\.model).contains("s1mini"), "S1-mini became a recommended card")
  }

  @Test("selection: a draft or committed pick shows while it can be chosen; See all EG-1 picks survive the return")
  func displayedSelection() throws {
    let afm = Self.held(memory: 16, afm: .available)
    // Draft wins on both screens.
    #expect(
      SetupPolish.pickDisplayed(
        draft: "appleIntelligence", committed: "eg1.mini", recommended: afm, language: .auto)
        == "appleIntelligence")
    // An EG-1 size picked under See all survives the return to the cards (mockup `hideAll`);
    // an S1-mini pick falls back to the preselected card.
    #expect(
      SetupPolish.pickDisplayed(draft: "eg1.full", committed: nil, recommended: afm, language: .auto)
        == "eg1.full")
    #expect(
      SetupPolish.pickDisplayed(draft: "s1mini", committed: nil, recommended: afm, language: .auto)
        == "eg1.mini")
    #expect(
      SetupPolish.pickDisplayed(draft: nil, committed: "s1mini", recommended: afm, language: .auto)
        == "eg1.mini")
    #expect(
      SetupPolish.seeAllDisplayed(draft: "eg1.full", committed: nil, recommended: afm, language: .auto)
        == "eg1.full")
    // A committed Apple Intelligence pick on a Mac where it stopped being available.
    let off = Self.held(memory: 16, afm: .turnedOff)
    #expect(
      SetupPolish.seeAllDisplayed(
        draft: nil, committed: "appleIntelligence", recommended: off, language: .auto)
        == "eg1.mini", "an unavailable model stayed selected")
    // Skip and cloud are not local selections.
    #expect(
      SetupPolish.seeAllDisplayed(
        draft: nil, committed: OnboardingChoices.polishOff, recommended: off, language: .auto)
        == "eg1.mini")
  }

  @Test(
    "every EG-1 size can be chosen on every Mac; Apple Intelligence and S1-mini follow their rules")
  func selectability() {
    for afm in AppleIntelligenceSetupState.allCases {
      for size in EGOneSize.allCases {
        #expect(
          SetupPolish.isSelectable(
            SetupPolish.id(of: size), appleIntelligence: afm, language: .auto))
      }
      #expect(
        SetupPolish.isSelectable("appleIntelligence", appleIntelligence: afm, language: .auto)
          == (afm == .available), "\(afm)")
    }
    #expect(SetupPolish.isSelectable("s1mini", appleIntelligence: .unavailable, language: .auto))
    #expect(
      SetupPolish.isSelectable(
        "s1mini", appleIntelligence: .unavailable, language: .locked("en-GB")))
    #expect(
      !SetupPolish.isSelectable("s1mini", appleIntelligence: .unavailable, language: .locked("de")))
    for other in [OnboardingChoices.polishOff, OnboardingChoices.polishCloud, "eg1.huge"] {
      #expect(!SetupPolish.isSelectable(other, appleIntelligence: .available, language: .auto))
    }
  }

  @Test("names come from the owners and S1-mini keeps its licence credit")
  func namesAndCredit() {
    #expect(SetupPolish.name("eg1.full") == EGOneSizeCardCopy.title(.full))
    #expect(SetupPolish.name("eg1.micro") == EGOneSizeCardCopy.title(.micro))
    #expect(SetupPolish.name("appleIntelligence") == LLMProvider.appleIntelligence.displayName)
    #expect(SetupPolish.name("s1mini") == LLMProvider.s1Mini.displayName)
    #expect(SetupPolish.s1MiniLine(supported: true).contains("Superwhisper"))
    #expect(SetupPolish.s1MiniLine(supported: false).contains("Superwhisper"))
    #expect(SetupPolish.egOneOrder == [.full, .mini, .micro])
    #expect(SetupPolish.introPoints.count == 6)
  }

  @Test("an unknown Apple Intelligence state claims no diagnosis")
  func unknownSaysNothingAboutWhy() {
    let line = SetupPolish.appleIntelligenceLine(.unavailable)
    for claim in ["macOS", "support", "Settings", "turn"] {
      #expect(!line.localizedCaseInsensitiveContains(claim), "\(claim)")
    }
  }

  @Test("each See all EG-1 tile carries a two- or three-word reason (founder)")
  func tileReasonsAreShort() {
    for size in EGOneSize.allCases {
      let words = SetupPolish.tileReason(size).split(separator: " ").count
      #expect((2...3).contains(words), "\(size): \(SetupPolish.tileReason(size))")
    }
  }
}
