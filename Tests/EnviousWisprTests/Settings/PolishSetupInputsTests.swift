import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4321. The EnviousMeet summary engine has its own setup monitor. When this is wrong, the
/// Summaries leave question warns about dictation's model (or stays quiet about the summary
/// engine), a key check for another provider counts for the summary engine, or a summary setting
/// change reaches the monitor late, so a leave question answers for a configuration already gone.
@MainActor
@Suite("EnviousMeet summary engine setup monitor inputs (#4321)", .tags(.productOutcome))
struct PolishSetupInputsTests {
  typealias World = PolishSetupLeaveGuardTests.World

  private static func settings() throws -> SettingsManager {
    let suite = try #require(TestDefaults.suite("ew-4321-inputs-\(UUID().uuidString)"))
    return SettingsManager(defaults: suite)
  }

  // MARK: - Which engine each scope reads

  @Test("each scope reads its own provider, model and Ollama model together")
  func scopesReadTheirOwnEngine() throws {
    let settings = try Self.settings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-dictation"
    settings.ollamaModel = "dictation-ollama"
    settings.meetingSummaryLLMProvider = .claude
    settings.meetingSummaryLLMModel = "claude-summary"
    settings.meetingSummaryOllamaModel = "summary-ollama"

    let dictation = PolishSetupEngineSelection(settings: settings, scope: .dictation)
    #expect(dictation.provider == .openAI)
    #expect(dictation.model == settings.effectiveLLMModel)
    #expect(dictation.ollamaModel == "dictation-ollama")

    let summary = PolishSetupEngineSelection(settings: settings, scope: .meetingSummary)
    #expect(summary.provider == .claude)
    #expect(summary.model == settings.effectiveMeetingSummaryLLMModel)
    #expect(summary.ollamaModel == "summary-ollama")

    // Ollama for summaries reads the summary Ollama field, never dictation's.
    settings.meetingSummaryLLMProvider = .ollama
    let ollama = PolishSetupEngineSelection(settings: settings, scope: .meetingSummary)
    #expect(ollama.provider == .ollama)
    #expect(ollama.model == "summary-ollama")
    #expect(ollama.ollamaModel == "summary-ollama")

    // An unmigrated summary choice is no engine.
    settings.meetingSummaryLLMProvider = nil
    #expect(
      PolishSetupEngineSelection(settings: settings, scope: .meetingSummary).provider == .none)
  }

  @Test("a key check counts for the summary engine only when it is about the summary provider")
  func summaryValidationIsMasked() throws {
    let settings = try Self.settings()
    settings.llmProvider = .openAI
    settings.meetingSummaryLLMProvider = .claude
    let summary = PolishSetupEngineSelection(settings: settings, scope: .meetingSummary)
    let dictation = PolishSetupEngineSelection(settings: settings, scope: .dictation)

    // About another provider: the summary engine sees nothing.
    let other = summary.validation(stateProvider: .openAI, state: .invalid("rejected"))
    #expect(other.provider == nil)
    #expect(other.state == .idle)
    // About the summary provider: passed through.
    let own = summary.validation(stateProvider: .claude, state: .invalid("rejected"))
    #expect(own.provider == .claude)
    #expect(own.state == .invalid("rejected"))
    // Dictation keeps today's pass-through whatever it is about.
    let passThrough = dictation.validation(stateProvider: .claude, state: .valid)
    #expect(passThrough.provider == .claude)
    #expect(passThrough.state == .valid)
  }

  // MARK: - Synchronous notifications through the production holder

  private static func monitor(_ world: World) -> PolishSetupMonitor {
    // Not started: only a synchronous notification reconciles it, so a missing one shows.
    PolishSetupMonitor(readInputs: { world.inputs }, reportPrompt: { _ in })
  }

  @Test("a summary setting reaches only the summary monitor; dictation's only dictation's")
  func settingChangesReachTheirOwnMonitor() {
    let dictationWorld = World()
    let summaryWorld = World()
    let dictation = Self.monitor(dictationWorld)
    let summary = Self.monitor(summaryWorld)
    let holder = PolishSetupMonitorHolder()
    holder.monitor = dictation
    holder.summaryMonitor = summary

    for key in [
      SettingsManager.SettingKey.meetingSummaryLLMProvider, .meetingSummaryLLMModel,
      .meetingSummaryOllamaModel,
    ] {
      let fresh = Self.monitor(summaryWorld)
      holder.summaryMonitor = fresh
      holder.settingChanged(key)
      #expect(fresh.currentEpisode != nil, "\(key) did not reach the summary monitor")
    }
    #expect(dictation.currentEpisode == nil, "a summary setting reached dictation's monitor")

    holder.summaryMonitor = summary
    for key in [SettingsManager.SettingKey.llmProvider, .llmModel, .ollamaModel] {
      let fresh = Self.monitor(dictationWorld)
      holder.monitor = fresh
      holder.settingChanged(key)
      #expect(fresh.currentEpisode != nil, "\(key) did not reach dictation's monitor")
    }
    #expect(summary.currentEpisode == nil, "a dictation setting reached the summary monitor")
  }

  @Test("onboarding and saved-key changes reach both monitors")
  func sharedChangesReachBoth() {
    let holder = PolishSetupMonitorHolder()
    let onboardingDictation = Self.monitor(World())
    let onboardingSummary = Self.monitor(World())
    holder.monitor = onboardingDictation
    holder.summaryMonitor = onboardingSummary
    holder.settingChanged(.onboardingState)
    #expect(onboardingDictation.currentEpisode != nil)
    #expect(onboardingSummary.currentEpisode != nil)

    let keyDictation = Self.monitor(World())
    let keySummary = Self.monitor(World())
    holder.monitor = keyDictation
    holder.summaryMonitor = keySummary
    holder.savedKeysChanged()
    #expect(keyDictation.currentEpisode != nil)
    #expect(keySummary.currentEpisode != nil)

    // An unrelated setting reaches neither.
    let quietDictation = Self.monitor(World())
    let quietSummary = Self.monitor(World())
    holder.monitor = quietDictation
    holder.summaryMonitor = quietSummary
    holder.settingChanged(.shareUsageMetrics)
    #expect(quietDictation.currentEpisode == nil)
    #expect(quietSummary.currentEpisode == nil)
  }

  // A user who picks another EG-1 size would see warnings for the old size until something else changed.
  @Test("an EG-1 size change reaches both monitors")
  func egOneSizeReachesBoth() {
    let holder = PolishSetupMonitorHolder()
    let dictation = Self.monitor(World())
    let summary = Self.monitor(World())
    holder.monitor = dictation
    holder.summaryMonitor = summary
    holder.settingChanged(.egOneSize)
    #expect(dictation.currentEpisode != nil, "dictation's monitor missed the size change")
    #expect(summary.currentEpisode != nil, "the summary monitor missed the size change")
  }

  @Test("a summary key that becomes saved ends the summary episode at once")
  func savedKeyRepairsTheSummaryEpisode() {
    let summaryWorld = World()
    let summary = Self.monitor(summaryWorld)
    let holder = PolishSetupMonitorHolder()
    holder.summaryMonitor = summary
    holder.savedKeysChanged()
    #expect(summary.promptSubject?.problem == .cloudKeyMissing(.openAI))
    summaryWorld.openAIKeySaved = true
    holder.savedKeysChanged()
    #expect(summary.promptSubject == nil)
    // Unknown (a failed Keychain read) is never "missing".
    summaryWorld.openAIKeySaved = nil
    holder.savedKeysChanged()
    #expect(summary.promptSubject == nil)
  }

}

/// #4321. A Drift Guard over the composition root's source, not evidence about what a user sees.
@MainActor
@Suite("Summary setup monitor composition (#4321)", .tags(.driftGuard))
struct PolishSetupCompositionTests {

  private static let bootstrapperPath = "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"

  /// A type-keyed `@Environment` has no default: a window that reads the summary monitor holder
  /// without its injection traps at runtime with every other test green (see
  /// `EnvironmentInjectionFreezeTests`). Read as source, like that guard.
  @Test("the Settings window root injects the summary monitor holder; the monitor is built once")
  func summaryHolderIsInjectedWhereSettingsIsHosted() throws {
    let source = try String(
      contentsOf: RepoRoot.url.appending(path: Self.bootstrapperPath), encoding: .utf8)
    try #require(source.count > 1000, "\(Self.bootstrapperPath) read \(source.count) bytes")
    let start = try #require(
      source.range(of: "UnifiedWindowView()"),
      "positive control failed: UnifiedWindowView() is not in the composition root")
    let rest = source[start.upperBound...]
    let blockEnd = rest.range(of: "\nprivate struct ") ?? rest.range(of: "\nstruct ")
    let block = blockEnd.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
    try #require(
      block.contains(".environment(b.polishSetup.monitor)"),
      "positive control failed: the Settings host does not inject dictation's monitor")
    #expect(block.contains(".environment(b.polishSetup.summary)"))
    #expect(source.components(separatedBy: "scope: .meetingSummary)").count - 1 == 1)
    #expect(source.contains("polishSetupMonitorHolder.summaryMonitor = summarySetupMonitor"))
    #expect(source.contains("polishSetup.start()"))
    #expect(source.contains("polishSetup.stop()"))
  }
}
