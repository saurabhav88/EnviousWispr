import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 B3: every surface that recommends reads one policy (`SetupAdvice`).
///
/// **Product Outcome.** When this fails, a fresh install on a Mac without Apple Intelligence starts
/// with no AI polish (#1454), an existing user's polish engine changes on upgrade, Settings and
/// Transcribe a File disagree about which engine is "Recommended", or the language lock lands on a
/// language the engine cannot transcribe.
@MainActor
@Suite(.tags(.productOutcome))
struct SetupAdviceConsumerTests {
  private static func freshSuite() -> UserDefaults {
    let name = "ew.setup.advice.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  // MARK: - Fresh-install polish default (D1)

  @Test("a fresh install starts on the recommended polish provider")
  func freshInstallTakesTheRecommendation() {
    #expect(
      SettingsManager.defaultPolishProvider(
        providerKeyAbsent: true, everCompletedOnboarding: false, onboardingStateRaw: nil) == .egOne)
    #expect(SettingsManager(defaults: Self.freshSuite()).llmProvider == .egOne)
  }

  @Test(
    "an install that completed onboarding keeps the canonical default when no provider is stored")
  func completedInstallKeepsTheCanonicalDefault() {
    #expect(
      SettingsManager.defaultPolishProvider(
        providerKeyAbsent: true, everCompletedOnboarding: true, onboardingStateRaw: "completed")
        == .appleIntelligence)
    #expect(
      SettingsManager.defaultPolishProvider(
        providerKeyAbsent: true, everCompletedOnboarding: false, onboardingStateRaw: "completed")
        == .appleIntelligence)
    let suite = Self.freshSuite()
    suite.set(true, forKey: SettingsManager.onboardingEverCompletedKey)
    #expect(SettingsManager(defaults: suite).llmProvider == .appleIntelligence)
  }

  @Test("a stored provider is never replaced, including an explicit off and Apple Intelligence")
  func storedProvidersAreKept() {
    for stored in [LLMProvider.none, .appleIntelligence, .openAI, .s1Mini] {
      let suite = Self.freshSuite()
      suite.set(stored.rawValue, forKey: "llmProvider")
      #expect(SettingsManager(defaults: suite).llmProvider == stored, "\(stored) was replaced")
    }
  }

  @Test("an unreadable stored provider keeps the canonical default, not the fresh-install one")
  func unreadableStoredValueIsNotFresh() {
    let suite = Self.freshSuite()
    suite.set("a-provider-from-the-future", forKey: "llmProvider")
    #expect(SettingsManager(defaults: suite).llmProvider == .appleIntelligence)
  }

  /// D1 makes a fresh install's dictation default EG-1. That default must not count as "this user
  /// already used EG-1", or every new user would be seeded the full size (4.8 GB) on any Mac.
  @Test("a fresh install's EG-1 default does not count as prior EG-1 use")
  func freshDefaultIsNotPriorUse() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    #expect(settings.llmProvider == .egOne)
    settings.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: false, recommendation: .micro)
    #expect(settings.egOneSize == .micro, "the fresh default was read as an existing EG-1 user")
    let chosen = Self.freshSuite()
    chosen.set(LLMProvider.egOne.rawValue, forKey: "llmProvider")
    let existing = SettingsManager(defaults: chosen)
    existing.resolveEGOneSizeIfNeeded(hasEGOneInstallRecord: false, recommendation: .micro)
    #expect(existing.egOneSize == .full, "a stored EG-1 choice must still keep the full size")
  }

  // MARK: - One "Recommended" across surfaces

  @Test("the AI Polish list marks exactly the provider the recommender names")
  func recommendedPillFollowsTheRecommender() {
    let recommended = SetupAdvice.recommendedPolishProvider()
    #expect(PolishRailCatalog.all.filter(\.recommended).map(\.provider) == [recommended])
  }

  /// Transcribe a File's badges read the same calls; this pins what they return for the same
  /// inputs, using the engines' live language lists (`LanguageLockOptions.speechCapabilities`).
  @Test("the speech badge follows the language: Parakeet for English, Whisper for Japanese")
  func speechBadgeFollowsTheLanguage() {
    let english = SetupAdvice.recommendation(
      languageMode: .locked("en"), capabilities: LanguageLockOptions.speechCapabilities)
    let japanese = SetupAdvice.recommendation(
      languageMode: .locked("ja"), capabilities: LanguageLockOptions.speechCapabilities)
    #expect(english.speech == .parakeet)
    #expect(japanese.speech == .whisper)
  }

  @Test("the recommended EG-1 size is one of the shipped sizes")
  func recommendedSizeIsShipped() {
    #expect(EGOneSize.allCases.contains(SetupAdvice.recommendedEGOneSize(languageMode: .auto)))
  }
}
