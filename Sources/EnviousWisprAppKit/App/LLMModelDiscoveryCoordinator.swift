import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Manages LLM model discovery, API key validation, and model caching.
@MainActor @Observable
final class LLMModelDiscoveryCoordinator {
  var discoveredModels: [LLMModelInfo] = []
  var isDiscoveringModels = false
  var keyValidationState: KeyValidationState = .idle

  enum KeyValidationState: Equatable {
    case idle
    case validating
    case valid
    case invalid(String)
  }

  private let keychainManager: KeychainManager

  init(keychainManager: KeychainManager) {
    self.keychainManager = keychainManager
  }

  /// Reset discovery state (used when switching providers or clearing keys).
  func reset() {
    discoveredModels = []
    keyValidationState = .idle
  }

  /// Validate an API key and discover available models for the given provider.
  /// Pass `settings` to auto-correct model selection if the current model is unavailable.
  /// `source` (#1173) tags which user action drove the pass for telemetry; the
  /// six refresh / provider-switch call sites take the default.
  func validateKeyAndDiscoverModels(
    provider: LLMProvider, settings: SettingsManager,
    source: ApiKeyValidationSource = .modelDiscovery
  ) async {
    keyValidationState = .validating
    isDiscoveringModels = true

    let apiKey: String
    if provider == .ollama || provider == .appleIntelligence {
      apiKey = ""
    } else {
      let keychainId =
        provider == .openAI ? KeychainManager.openAIKeyID : KeychainManager.geminiKeyID
      guard let key = try? keychainManager.retrieve(key: keychainId), !key.isEmpty else {
        // Missing-key guard: no validation actually ran, so NO
        // `api_key.validation_completed` event (#1173).
        keyValidationState = .invalid("No API key found")
        isDiscoveringModels = false
        return
      }
      apiKey = key
    }

    let discovery = LLMModelDiscovery()
    do {
      let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
      discoveredModels = models
      if provider != .appleIntelligence {
        cacheModels(models, for: provider)
      }
      keyValidationState = .valid
      emitValidationCompleted(provider: provider, result: "valid", source: source)

      settings.applyDiscoveredModels(models, for: provider)
    } catch LLMError.providerUnavailable {
      keyValidationState = .invalid(
        provider == .ollama
          ? "Ollama is not running. Start it with: ollama serve"
          : "Apple Intelligence not available on this system."
      )
      discoveredModels = []
      emitValidationCompleted(provider: provider, result: "provider_unavailable", source: source)
    } catch let error as LLMError where error == .invalidAPIKey {
      keyValidationState = .invalid("Invalid API key")
      discoveredModels = []
      emitValidationCompleted(provider: provider, result: "invalid", source: source)
    } catch {
      keyValidationState = .invalid(error.localizedDescription)
      discoveredModels = []
      emitValidationCompleted(provider: provider, result: "error", source: source)
    }

    isDiscoveringModels = false
  }

  /// #1173: emit `api_key.validation_completed` for a terminal validation result.
  /// Provider identity only — never the key. Gated to OpenAI/Gemini (Codex r2):
  /// Ollama and Apple Intelligence are keyless local providers, so their
  /// discovery outcome is NOT an API-key validation and must stay out of the
  /// `api_key.*` metrics.
  private func emitValidationCompleted(
    provider: LLMProvider, result: String, source: ApiKeyValidationSource
  ) {
    guard provider == .openAI || provider == .gemini else { return }
    TelemetryService.shared.apiKeyValidationCompleted(
      provider: provider.rawValue, result: result, source: source.rawValue)
  }

  /// Load cached models from UserDefaults for the given provider.
  func loadCachedModels(for provider: LLMProvider) {
    let key = "cachedModels_\(provider.rawValue)"
    guard let data = UserDefaults.standard.data(forKey: key),
      let models = try? JSONDecoder().decode([LLMModelInfo].self, from: data)
    else {
      discoveredModels = []
      return
    }
    discoveredModels = models
  }

  private func cacheModels(_ models: [LLMModelInfo], for provider: LLMProvider) {
    let key = "cachedModels_\(provider.rawValue)"
    if let data = try? JSONEncoder().encode(models) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}
