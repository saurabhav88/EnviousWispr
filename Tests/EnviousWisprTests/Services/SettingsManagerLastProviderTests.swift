import AppKit
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1285 — the AI Polish on/off toggle remembers the last real engine so turning
/// polish back on restores it. `lastLLMProvider` is the memory: seeded in init,
/// maintained in the `llmProvider` didSet, never set to `.none`. Every test uses
/// an ephemeral suite so nothing touches the real store.
@MainActor
@Suite("SettingsManager lastLLMProvider (#1285)")
struct SettingsManagerLastProviderTests {
  init() { _ = NSApplication.shared }  // @MainActor AppKit-touching SUT (swift-patterns)

  private static func freshSuite() -> UserDefaults {
    let name = "ew.lastProviderTest." + UUID().uuidString
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  // MARK: - Seeding

  @Test("upgrade: an existing engine with no remembered value seeds from that engine")
  func seedsFromExistingProvider() {
    let suite = Self.freshSuite()
    suite.set(LLMProvider.openAI.rawValue, forKey: "llmProvider")
    // No "lastLLMProvider" key present — the pre-#1285 upgrade case.
    let settings = SettingsManager(defaults: suite)
    #expect(settings.lastLLMProvider == .openAI)
  }

  @Test("an already-remembered engine is honored over the current engine")
  func honorsStoredValue() {
    let suite = Self.freshSuite()
    suite.set(LLMProvider.ollama.rawValue, forKey: "llmProvider")
    suite.set(LLMProvider.gemini.rawValue, forKey: "lastLLMProvider")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.lastLLMProvider == .gemini)
  }

  @Test("polish already off with no memory seeds the default engine, never .none")
  func seedsDefaultWhenOff() {
    let suite = Self.freshSuite()
    suite.set(LLMProvider.none.rawValue, forKey: "llmProvider")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.lastLLMProvider == SettingsDefaultValues.lastLLMProvider)
    #expect(settings.lastLLMProvider != .none)
  }

  @Test("an unparseable stored memory falls back to the current engine")
  func unparseableFallsBack() {
    let suite = Self.freshSuite()
    suite.set(LLMProvider.gemini.rawValue, forKey: "llmProvider")
    suite.set("not-a-provider", forKey: "lastLLMProvider")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.lastLLMProvider == .gemini)
  }

  // MARK: - Maintenance (didSet)

  @Test("switching to a real engine updates the memory")
  func realEngineUpdatesMemory() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.llmProvider = .gemini
    #expect(settings.lastLLMProvider == .gemini)
    settings.llmProvider = .ollama
    #expect(settings.lastLLMProvider == .ollama)
  }

  @Test("turning polish off does NOT overwrite the remembered engine")
  func offDoesNotOverwriteMemory() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.llmProvider = .openAI
    settings.llmProvider = .none
    #expect(settings.lastLLMProvider == .openAI)
  }

  // MARK: - Toggle restore round trip (the view's on/off contract)

  @Test("off then on restores the previously selected engine")
  func offThenOnRestores() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.llmProvider = .ollama
    // Toggle off.
    settings.llmProvider = .none
    #expect(settings.llmProvider == .none)
    // Toggle on → the view restores lastLLMProvider (guarding .none → default).
    settings.llmProvider =
      settings.lastLLMProvider == .none ? .appleIntelligence : settings.lastLLMProvider
    #expect(settings.llmProvider == .ollama)
  }

  @Test("memory survives a reload after being turned off")
  func memorySurvivesReloadWhileOff() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.llmProvider = .openAI
    settings.llmProvider = .none  // user turns polish off, then quits
    // Relaunch: provider is off, but the remembered engine persists.
    let reloaded = SettingsManager(defaults: suite)
    #expect(reloaded.llmProvider == .none)
    #expect(reloaded.lastLLMProvider == .openAI)
  }
}
