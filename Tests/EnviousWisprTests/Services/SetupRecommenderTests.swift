import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4528 B1: the first-run Setup recommendation, read from the bundled rules.
///
/// **Product Outcome.** When this fails, a new user is recommended a polish model their Mac cannot
/// hold comfortably, a speech engine that cannot hear their language, Apple Intelligence on a Mac
/// where it cannot run (#1454), or cards in the wrong order with the wrong label.
///
/// Expectations are written out by hand from the approved plan §3.2 and the mockup's `polishPlan`
/// (Main.baseline-before-audit.html:613-620); none is computed by the recommender. The EG-1 tiers
/// are additionally checked against the shipped `EGOneSizeRecommendation`, an independent
/// implementation of the same founder rule, until B3 retires it.
@Suite(.tags(.productOutcome))
struct SetupRecommenderTests {
  /// A fixed capability fixture: Parakeet speaks a European set, Whisper speaks those plus Hindi
  /// and Japanese. Independent of the engines' live tables so the rules are tested, not the tables.
  static let caps = SpeechLanguageCapabilities(
    parakeet: ["en", "de", "fr", "es", "it", "nl", "pt", "pl"],
    whisper: ["en", "de", "fr", "es", "it", "nl", "pt", "pl", "hi", "ja"])

  static func profile(
    memory: Int, afm: AppleIntelligenceSetupState = .unavailable, languages: [String] = ["en-US"],
    macOS: Int = 26
  ) -> MacProfile {
    MacProfile(
      memoryGiB: memory, chipName: nil, macOSMajor: macOS, appleIntelligence: afm,
      macLanguages: languages, freeDiskBytes: nil)
  }

  static func advice(
    _ profile: MacProfile, _ mode: LanguageMode = .auto
  ) throws -> SetupRecommendation {
    SetupRecommender.recommend(
      profile: profile, rules: try SetupRules.bundled(), languageMode: mode, capabilities: caps)
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let memory: Int
    let mode: LanguageMode
    let afm: AppleIntelligenceSetupState
    let primary: String
    let second: String
    let secondLabel: SetupRecommendation.Label
    var testDescription: String { "\(memory) GiB, \(mode), AFM \(afm) -> \(primary) + \(second)" }
  }

  /// Every production polish row and each threshold neighbour, plus the interacting cases.
  static let cases: [Case] = [
    // 8 GB, AFM not offered: Micro recommended, Mini as the "even better" neighbour.
    Case(
      memory: 8, mode: .auto, afm: .unavailable, primary: "eg1.micro", second: "eg1.mini",
      secondLabel: .evenBetterResults),
    // 8 GB locked German: Mini (the size rule), and the neighbour steps DOWN to Micro on a small Mac.
    Case(
      memory: 8, mode: .locked("de"), afm: .unavailable, primary: "eg1.mini", second: "eg1.micro",
      secondLabel: .smallerDownload),
    // English locked behaves like Auto.
    Case(
      memory: 8, mode: .locked("en-GB"), afm: .turnedOff, primary: "eg1.micro", second: "eg1.mini",
      secondLabel: .evenBetterResults),
    // Just below 16.
    Case(
      memory: 15, mode: .auto, afm: .needsNewerMacOS, primary: "eg1.micro", second: "eg1.mini",
      secondLabel: .evenBetterResults),
    // At 16: Mini, and the neighbour steps UP to full on a Mac with 16 GB or more.
    Case(
      memory: 16, mode: .auto, afm: .unavailable, primary: "eg1.mini", second: "eg1.full",
      secondLabel: .evenBetterResults),
    Case(
      memory: 24, mode: .locked("de"), afm: .gettingReady, primary: "eg1.mini", second: "eg1.full",
      secondLabel: .evenBetterResults),
    // Just below 32.
    Case(
      memory: 31, mode: .auto, afm: .unavailable, primary: "eg1.mini", second: "eg1.full",
      secondLabel: .evenBetterResults),
    // At 32: full, neighbour Mini as the smaller download.
    Case(
      memory: 32, mode: .auto, afm: .unavailable, primary: "eg1.full", second: "eg1.mini",
      secondLabel: .smallerDownload),
    Case(
      memory: 128, mode: .locked("de"), afm: .unavailable, primary: "eg1.full", second: "eg1.mini",
      secondLabel: .smallerDownload),
  ]

  @Test(
    "Apple Intelligence not offered: the recommended size first, its neighbour second",
    arguments: cases)
  func cardsWithoutAppleIntelligence(_ c: Case) throws {
    let a = try Self.advice(Self.profile(memory: c.memory, afm: c.afm), c.mode)
    #expect(a.polishPrimary == c.primary)
    #expect(a.polishCards.map(\.model) == [c.primary, c.second])
    #expect(a.polishCards.map(\.label) == [.recommendedForYourMac, c.secondLabel])
    #expect(a.polishCards.map(\.preselected) == [true, false])
  }

  @Test(
    "Apple Intelligence available: it comes first as the easiest start, the EG-1 size is preselected"
  )
  func cardsWithAppleIntelligence() throws {
    let a = try Self.advice(Self.profile(memory: 16, afm: .available))
    #expect(a.polishCards.map(\.model) == ["appleIntelligence", "eg1.mini"])
    #expect(a.polishCards.map(\.label) == [.easiestWayToStart, .recommendedBestResults])
    #expect(a.polishCards.map(\.preselected) == [false, true])
    #expect(a.appleIntelligence == .available)
  }

  /// Only "available" puts Apple Intelligence on a card; every other state keeps it off the two
  /// cards (it still appears in See all with its reason).
  @Test(
    "only an available Apple Intelligence reaches the two cards",
    arguments: [
      AppleIntelligenceSetupState.turnedOff, .needsNewerMacOS, .gettingReady, .unavailable,
    ])
  func appleIntelligenceOffTheCards(state: AppleIntelligenceSetupState) throws {
    let a = try Self.advice(Self.profile(memory: 16, afm: state))
    #expect(!a.polishCards.contains { $0.model == "appleIntelligence" })
    #expect(a.appleIntelligence == state)
  }

  /// Parity with the shipped size rule over its own boundary table (EGOneSizePreferenceTests).
  @Test(
    "the recommended EG-1 size matches the shipped size rule",
    arguments: EGOneSizePreferenceTests.tiers)
  func parityWithTheShippedSizeRule(_ tier: EGOneSizePreferenceTests.Tier) throws {
    let memory = Int(tier.bytes / (1 << 30))
    let a = try Self.advice(Self.profile(memory: memory), tier.language)
    #expect(a.polishPrimary == "eg1.\(tier.expected.rawValue)")
  }

  @Test("Auto stays Auto; the Mac's language is suggested when an engine speaks it")
  func autoStaysAuto() throws {
    let french = try Self.advice(Self.profile(memory: 16, languages: ["fr-CA", "en-US"]))
    #expect(french.languageMode == .auto)
    #expect(french.suggestedLanguage == "fr")
    #expect(french.speech == .parakeet)
  }

  @Test("a Hindi Mac under Auto is recommended Whisper, which speaks Hindi")
  func hindiMacGetsWhisper() throws {
    let a = try Self.advice(Self.profile(memory: 16, languages: ["hi-IN"]))
    #expect(a.suggestedLanguage == "hi")
    #expect(a.speech == .whisper)
    // Auto still counts as English for the polish size (the shipped rule), so 16 GB stays Mini.
    #expect(a.polishPrimary == "eg1.mini")
  }

  @Test("a locked language decides the speech engine, whatever the Mac's language")
  func lockedLanguageDecidesSpeech() throws {
    let a = try Self.advice(Self.profile(memory: 16, languages: ["de-DE"]), .locked("ja"))
    #expect(a.speech == .whisper)
    #expect(a.languageMode == .locked("ja"))
    let b = try Self.advice(Self.profile(memory: 16, languages: ["hi-IN"]), .locked("de"))
    #expect(b.speech == .parakeet)
  }

  @Test("a Mac language no engine speaks is not suggested, and speech falls back to English rules")
  func unsupportedMacLanguage() throws {
    let a = try Self.advice(Self.profile(memory: 16, languages: ["xx-YY"]))
    #expect(a.suggestedLanguage == nil)
    #expect(a.speech == .parakeet)
  }

  @Test("an unknown chip and an empty language list still produce full advice")
  func unknownInputsStillAnswer() throws {
    let profile = MacProfile(
      memoryGiB: 8, chipName: nil, macOSMajor: 15, appleIntelligence: .needsNewerMacOS,
      macLanguages: [], freeDiskBytes: nil)
    let a = try Self.advice(profile)
    #expect(a.suggestedLanguage == nil)
    #expect(a.polishPrimary == "eg1.micro")
    #expect(a.polishCards.count == 2)
  }

  @Test("downloads run side by side from 16 GB, one after the other below")
  func parallelDownloadsThreshold() throws {
    #expect(try Self.advice(Self.profile(memory: 15)).parallelDownloads == false)
    #expect(try Self.advice(Self.profile(memory: 16)).parallelDownloads == true)
  }

  @Test("advice carries the rules revision it came from")
  func carriesRevision() throws {
    let a = try Self.advice(Self.profile(memory: 16))
    #expect(a.rulesRevision == 1)
    #expect(a.rulesVersion == "2026.11.12")
  }

  /// G3: re-ranking registered models is a rules edit, with no Swift change.
  @Test("a rules file that re-ranks registered models changes the advice")
  func reRankingIsARulesEdit() throws {
    let edited = SetupRules.builtInJSON.replacingOccurrences(
      of: #"{"when": {"memoryAtLeastGiB": 16}, "pick": "eg1.mini"}"#,
      with: #"{"when": {"memoryAtLeastGiB": 16}, "pick": "eg1.full"}"#)
    #expect(edited != SetupRules.builtInJSON, "the fixture edit did not apply")
    let rules = try SetupRules.validated(from: Data(edited.utf8))
    let a = SetupRecommender.recommend(
      profile: Self.profile(memory: 16), rules: rules, languageMode: .auto, capabilities: Self.caps)
    #expect(a.polishPrimary == "eg1.full")
  }
}
