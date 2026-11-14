import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import EnviousWisprServices

@MainActor
struct HistoryPolishChoices {
  let settings: SettingsManager
  let monitor: PolishSetupMonitorHolder
  let runtime: LocalPolishRuntimeSet
  let availability: AIAvailabilityCoordinator
  let setup: SetupCoordinator
  let discovery: LLMModelDiscoveryCoordinator
  let savedKeys: SavedKeyPresence
  let ollamaRemoteness: @MainActor (String) -> Bool?

  func available(for surface: HistoryRepolishRunner.Surface) -> [HistoryPolishChoice] {
    let memory: CloudModelMemory
    let active: LLMProvider
    let currentModel: String
    switch surface {
    case .dictation:
      memory = settings.dictationCloudModelMemory
      active = settings.llmProvider
      currentModel = settings.effectiveLLMModel
    case .transcript:
      memory = settings.fileImportLLMProvider == nil
        ? settings.dictationCloudModelMemory : settings.fileImportCloudModelMemory
      active = settings.effectiveFileImportLLMProvider
      currentModel = settings.effectiveFileImportLLMModel
    case .summary:
      memory = settings.meetingSummaryCloudModelMemory
      active = settings.effectiveMeetingSummaryLLMProvider
      currentModel = settings.effectiveMeetingSummaryLLMModel
    }
    let size = settings.preferredEGOneSize
    return LLMProvider.allCases.flatMap { provider -> [HistoryPolishChoice] in
      guard provider != .none else { return [] }
      let models: [String]
      if provider == .ollama {
        models = setup.ollamaSetup.downloadedModels.map(\.exactName)
      } else {
        let model = provider == active ? currentModel
          : LLMProvider.localModel(for: provider, ollamaModel: "") ?? memory.model(for: provider) ?? ""
        models = model.isEmpty ? [] : [model]
      }
      return models.compactMap { model in
        let remote = provider == .ollama ? ollamaRemoteness(model) : nil
        if surface == .summary,
          case .notForSummaries = MeetingSummary.capability(
            provider, model: model, ollamaModelIsRemote: remote)
        { return nil }
        guard isReady(provider, model: model, surface: surface, size: size) else { return nil }
        return HistoryPolishChoice(
          provider: provider, model: model, egOneSize: provider == .egOne ? size : nil,
          sendsTextOffMac: TranscribeFileView.isCloud(provider, ollamaModelIsRemote: remote))
      }
    }
  }

  private func isReady(
    _ provider: LLMProvider, model: String, surface: HistoryRepolishRunner.Surface, size: EGOneSize
  ) -> Bool {
    guard !savedKeys.hasPendingMutation(for: provider) else { return false }
    let facts = PolishSetupFacts.live(
      localPolishRuntimes: runtime, egOneSize: size, aiAvailability: availability, setup: setup,
      validationProvider: discovery.stateProvider, cloudValidation: discovery.keyValidationState,
      openAIKeySaved: savedKeys.savedFlag(for: .openAI),
      geminiKeySaved: savedKeys.savedFlag(for: .gemini),
      claudeKeySaved: savedKeys.savedFlag(for: .claude),
      savedKeyPresence: savedKeys, cloudVerdicts: discovery.cloudVerdicts,
      ollamaModel: provider == .ollama ? model : "",
      selectedCloudModel: PolishSetupMonitor.usesCloudKey(provider) ? model : nil,
      cloudModelEvidence: discovery.cloudModelObservations)
    let gate = FileImportPolishGate.readiness(
      provider: provider, facts: facts, hasUnsavedKeyDraft: false)
    if surface == .transcript {
      return gate.isReady && (!PolishSetupMonitor.usesCloudKey(provider)
        || PolishSetupReadiness.cloudModelReadiness(provider, facts: facts) == .noProblem)
    }
    // Ollama can offer every installed model; the monitor's readiness only has the default.
    if provider == .ollama { return gate.isReady }
    if surface == .dictation, let monitor = monitor.monitor {
      return monitor.readiness(for: provider) == .noProblem
    }
    if surface == .summary, let monitor = monitor.summaryMonitor {
      return monitor.readiness(for: provider) == .noProblem
    }
    return PolishSetupReadiness.evaluate(provider: provider, facts: facts) == .noProblem
  }
}
