import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4473 (plan §3.1.1 S4, S5, S12): the EG-1 size preference and the recommendation.
///
/// When this fails, a user gets the wrong model: someone who used EG-1 before sizes existed is
/// moved to a smaller model without asking, a new user on an 8 GB Mac is started on a model
/// their Mac cannot hold, a size the user picked is forgotten on relaunch, or the size changes
/// by itself when they change language or polish engine. Encounter: the first launch of a
/// build with sizes, and every launch after. Owner: plan #4473 P5.
@MainActor
@Suite("The EG-1 size preference is set once, by the user's history or the Mac, and then stays (#4473)", .tags(.productOutcome))
struct EGOneSizePreferenceTests {
  private static func freshSuite() -> UserDefaults {
    let name = "ew.eg1.size.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  nonisolated static let gib: UInt64 = 1 << 30

  struct Tier: Sendable, CustomTestStringConvertible {
    let bytes: UInt64
    let language: LanguageMode
    let expected: EGOneSize
    var testDescription: String { "\(bytes) bytes, \(language) -> \(expected)" }
  }

  /// The founder's rule: 8 GB Micro (Mini for a language that is not English), 16 to 24 GB
  /// Mini, 32 GB and more the full size. Written out with the values on each side of a step.
  nonisolated static let tiers = [
    Tier(bytes: 8 * gib, language: .auto, expected: .micro),
    Tier(bytes: 8 * gib, language: .locked("en"), expected: .micro),
    Tier(bytes: 8 * gib, language: .locked("en-GB"), expected: .micro),
    Tier(bytes: 8 * gib, language: .locked("de"), expected: .mini),
    Tier(bytes: 16 * gib - 1, language: .auto, expected: .micro),
    Tier(bytes: 16 * gib - 1, language: .locked("hi"), expected: .mini),
    Tier(bytes: 16 * gib, language: .auto, expected: .mini),
    Tier(bytes: 18 * gib, language: .locked("en"), expected: .mini),
    Tier(bytes: 24 * gib, language: .locked("de"), expected: .mini),
    Tier(bytes: 32 * gib - 1, language: .auto, expected: .mini),
    Tier(bytes: 32 * gib, language: .auto, expected: .full),
    Tier(bytes: 32 * gib, language: .locked("de"), expected: .full),
    Tier(bytes: 128 * gib, language: .locked("en"), expected: .full),
  ]

  /// #4528 B3: the advice now comes from the Setup recommender and its bundled rules; this
  /// hand-written founder table stays the independent expectation.
  @Test("the recommendation follows installed memory and the dictation language", arguments: tiers)
  func recommendation(_ tier: Tier) throws {
    let profile = MacProfile(
      memoryGiB: Int(tier.bytes / Self.gib), chipName: nil, macOSMajor: 26,
      appleIntelligence: .unavailable, macLanguages: [], freeDiskBytes: nil)
    let advice = SetupRecommender.recommend(
      profile: profile, rules: try SetupRules.bundled(), languageMode: tier.language,
      capabilities: .polishOnly)
    #expect(advice.polishPrimary == "eg1.\(tier.expected.rawValue)")
  }

  @Test("a new user with no EG-1 history starts on the recommendation, and it is saved")
  func noHistoryTakesTheRecommendation() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    #expect(settings.egOneSize == nil)
    #expect(suite.object(forKey: "egOneSize") == nil, "loading writes nothing")
    var changed: [SettingsManager.SettingKey] = []
    settings.onChange = { changed.append($0) }
    settings.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: false, recommendation: .micro)
    #expect(settings.egOneSize == .micro)
    #expect(suite.string(forKey: "egOneSize") == "micro")
    #expect(changed == [.egOneSize])
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == "egOneSize" }.count == 1)
  }

  enum Surface: CaseIterable, Sendable { case dictation, fileImport, meetingSummary }

  @Test(
    "a user who already chose EG-1 on any surface continues on the full size, whatever the Mac",
    arguments: Surface.allCases)
  func anExistingSelectionMeansFull(_ surface: Surface) {
    let settings = SettingsManager(defaults: Self.freshSuite())
    switch surface {
    case .dictation: settings.llmProvider = .egOne
    case .fileImport: settings.fileImportLLMProvider = .egOne
    case .meetingSummary: settings.meetingSummaryLLMProvider = .egOne
    }
    settings.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: false, recommendation: .micro)
    #expect(settings.egOneSize == .full)
  }

  @Test("an EG-1 install record alone means the full size; polish switched off with no record does not")
  func anInstallRecordMeansFull() {
    let installed = SettingsManager(defaults: Self.freshSuite())
    installed.llmProvider = .none
    installed.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: true, recommendation: .micro)
    #expect(installed.egOneSize == .full)

    // EG-1 was chosen once and polish is now off; nothing is installed. No history remains.
    let off = SettingsManager(defaults: Self.freshSuite())
    off.llmProvider = .egOne
    off.llmProvider = .none
    #expect(off.lastLLMProvider == .egOne)
    off.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: false, recommendation: .mini)
    #expect(off.egOneSize == .mini)
  }

  @Test("a stored size is kept on every later launch, against history and against the Mac")
  func aKnownSizeIsKept() {
    let suite = Self.freshSuite()
    suite.set("micro", forKey: "egOneSize")
    let settings = SettingsManager(defaults: suite)
    settings.llmProvider = .egOne
    #expect(settings.egOneSize == .micro)
    var changed: [SettingsManager.SettingKey] = []
    settings.onChange = { changed.append($0) }
    settings.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: true, recommendation: .full)
    #expect(settings.egOneSize == .micro)
    #expect(changed.isEmpty)

    // Resolved once, then relaunched with a different Mac answer: unchanged.
    let fresh = Self.freshSuite()
    SettingsManager(defaults: fresh).resolveEGOneSizeIfNeeded(
      hasEGOneInstallRecord: false, recommendation: .mini)
    let relaunched = SettingsManager(defaults: fresh)
    #expect(relaunched.egOneSize == .mini)
    relaunched.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: true, recommendation: .full)
    #expect(relaunched.egOneSize == .mini && fresh.string(forKey: "egOneSize") == "mini")
  }

  @Test("a stored value this build does not know becomes the recommendation, even with EG-1 history")
  func anUnknownValueBecomesTheRecommendation() {
    let suite = Self.freshSuite()
    suite.set("giant", forKey: "egOneSize")
    let settings = SettingsManager(defaults: suite)
    settings.llmProvider = .egOne
    #expect(settings.egOneSize == nil)
    #expect(suite.string(forKey: "egOneSize") == "giant", "loading does not erase it")
    settings.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: true, recommendation: .mini)
    #expect(settings.egOneSize == .mini && suite.string(forKey: "egOneSize") == "mini")

    #expect(
      EGOneSizeResolution.resolve(stored: .unknown, hasPriorEGOneUse: true, recommendation: .micro)
        == .micro)
    #expect(
      EGOneSizeResolution.resolve(
        stored: .known(.mini), hasPriorEGOneUse: true, recommendation: .micro) == .mini)
    #expect(
      EGOneSizeResolution.resolve(stored: .absent, hasPriorEGOneUse: true, recommendation: .micro)
        == .full)
    #expect(
      EGOneSizeResolution.resolve(stored: .absent, hasPriorEGOneUse: false, recommendation: .micro)
        == .micro)
  }

  @Test("after it is set, a language change, a polish engine change and onboarding do not change the size")
  func nothingElseMovesIt() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: false, recommendation: .micro)
    var changed: [SettingsManager.SettingKey] = []
    settings.onChange = { changed.append($0) }
    settings.languageMode = .locked("de")
    settings.languageMode = .auto
    settings.llmProvider = .egOne
    settings.llmProvider = .s1Mini
    settings.llmProvider = .egOne
    settings.fileImportLLMProvider = .egOne
    settings.meetingSummaryLLMProvider = .egOne
    settings.onboardingState = .completed
    #expect(settings.egOneSize == .micro)
    #expect(suite.string(forKey: "egOneSize") == "micro")
    #expect(!changed.contains(.egOneSize))
    #expect(SettingsManager(defaults: suite).egOneSize == .micro)
  }
}
