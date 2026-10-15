import EnviousWisprCore
import EnviousWisprServices

/// One surface's polish provider and models, read and written: the AI Polish screen (both
/// surfaces) and the dev control door call this, so seeding, overriding and following have
/// one owner (#2772 chunk 3 policy; moved out of `ProviderSetup` by #3765 PR-C).
@MainActor
enum PolishSettings {
  static func provider(on surface: ProviderSetupSurface, in settings: SettingsManager)
    -> LLMProvider
  {
    switch surface {
    case .dictation: return settings.llmProvider
    case .fileImport: return settings.effectiveFileImportLLMProvider
    }
  }

  static func cloudModel(on surface: ProviderSetupSurface, in settings: SettingsManager)
    -> String
  {
    switch surface {
    case .dictation: return settings.llmModel
    case .fileImport:
      return settings.fileImportLLMProvider == nil
        ? settings.llmModel : settings.fileImportLLMModel
    }
  }

  static func ollamaModel(on surface: ProviderSetupSurface, in settings: SettingsManager)
    -> String
  {
    switch surface {
    case .dictation: return settings.ollamaModel
    case .fileImport:
      return settings.fileImportLLMProvider == nil
        ? settings.ollamaModel : settings.fileImportOllamaModel
    }
  }

  /// Writing the provider. An import write becomes an OVERRIDE, seeded first, per chunk 2:
  /// a pick that equals dictation's engine is still a pick.
  static func setProvider(
    _ newValue: LLMProvider, on surface: ProviderSetupSurface, in settings: SettingsManager
  ) {
    switch surface {
    case .dictation: settings.llmProvider = newValue
    case .fileImport:
      settings.seedFileImportPolishModelsIfNeeded()
      settings.fileImportLLMProvider = newValue
    }
  }

  /// Writing the cloud model. On the import surface this also creates the override, because
  /// editing the MODEL is choosing just as much as editing the provider is.
  static func setCloudModel(
    _ newValue: String, on surface: ProviderSetupSurface, in settings: SettingsManager
  ) {
    switch surface {
    case .dictation: settings.llmModel = newValue
    case .fileImport:
      settings.seedFileImportPolishModelsIfNeeded()
      if settings.fileImportLLMProvider == nil {
        settings.fileImportLLMProvider = settings.llmProvider
      }
      settings.fileImportLLMModel = newValue
    }
  }
}
