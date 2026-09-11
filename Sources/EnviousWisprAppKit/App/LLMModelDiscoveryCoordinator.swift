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

  /// #2772 chunk 3: WHICH provider `discoveredModels` and `keyValidationState` describe,
  /// or `nil` when nothing has been loaded or validated.
  ///
  /// One coordinator serves two surfaces now. Dictation's polisher and the file import's
  /// polisher can be different providers, and a reader that takes these two fields at face
  /// value gets whichever surface last drove them: open AI Polish with a valid Gemini key,
  /// switch to Transcribe a File with OpenAI selected and no key at all, and the OpenAI
  /// pane reads "Key valid". Before the split that could not happen, because the only
  /// writer reset on every provider change.
  ///
  /// Deliberately ONE field for BOTH values rather than one each: they are written together
  /// on every path below, and two trackers is how they would come to disagree about who
  /// they describe. `loadCachedModels` is the one place they could separate, so it clears
  /// the validation state when the provider changes.
  private(set) var stateProvider: LLMProvider? {
    didSet {
      guard stateProvider != oldValue else { return }
      discoveredModels = []
      keyValidationState = .idle
    }
  }

  /// Which discovery request the published state belongs to.
  ///
  /// `stateProvider` alone did NOT enforce its own contract, and the comment above claimed
  /// it did. `validateKeyAndDiscoverModels` stamps the provider before its `await` and
  /// publishes after it, so an OpenAI request that finishes AFTER the user switched to
  /// Gemini overwrote Gemini's models and verdict while `stateProvider` still read
  /// `.gemini` — the wrong answer wearing the right label, which is worse than no label.
  /// Found by Codex. Every path that changes what the state is ABOUT bumps this, and a
  /// completion that does not match its own generation publishes nothing.
  private var discoveryGeneration = 0

  /// Changing providers clears the previous provider's catalog and verdict. Same-provider
  /// assignment preserves them.
  ///
  /// **Async attribution additionally requires generation invalidation and guarded
  /// completion; this observer does not replace those protections.** An earlier version of
  /// this note claimed the observer closed the late-completion case too, which it does not:
  /// a stale request that has already passed this point is stopped by
  /// `discoveryGeneration`, not by anything here. Narrowed by Codex.
  ///
  /// `didSet` rather than a helper method because assignment is the ONLY way to change this
  /// field, and Swift runs `didSet` on every one of them, including any added later.

  enum KeyValidationState: Equatable {
    case idle
    case validating
    case valid
    case invalid(String)
  }

  private let keychainManager: KeychainManager

  /// Where the per-provider model cache lives.
  ///
  /// Injectable because the shared preference store on a real machine already holds this
  /// user's OpenAI catalog, so a test asserting an EMPTY list after a cache load passes or
  /// fails on what happens to be on disk rather than on the code. Production takes the
  /// default and is unchanged. Found by Codex.
  private let cacheDefaults: UserDefaults

  init(keychainManager: KeychainManager, cacheDefaults: UserDefaults = .standard) {
    self.keychainManager = keychainManager
    self.cacheDefaults = cacheDefaults
  }

  /// Abandon any request still in flight, and clear the markers it was going to resolve.
  ///
  /// The second half is the part round 2 caught. A bumped generation makes the old
  /// completion return early, which is correct and leaves `.validating` and the spinner
  /// standing with nothing left that can ever clear them: the gate said "Checking that
  /// engine" forever. A verdict already REACHED is left alone; only a pending one is
  /// dropped, because it is the only one whose author has been dismissed.
  private func invalidateInFlightDiscovery() {
    discoveryGeneration += 1
    isDiscoveringModels = false
    if keyValidationState == .validating { keyValidationState = .idle }
  }

  /// Reset discovery state (used when switching providers or clearing keys).
  func reset() {
    // Invalidate pending work before clearing ownership.
    // The explicit payload clears below also enforce reset when ownership is ALREADY nil,
    // because the owner observer ignores equal assignments. Not redundant. Found by Codex.
    invalidateInFlightDiscovery()
    stateProvider = nil
    discoveredModels = []
    keyValidationState = .idle
  }

  /// Validate an API key and discover available models for the given provider.
  /// Pass `settings` to auto-correct model selection if the current model is unavailable.
  /// `source` (#1173) tags which user action drove the pass for telemetry; the
  /// six refresh / provider-switch call sites take the default.
  /// `surface` says WHOSE model fields a repair may rewrite (#2772 chunk 3). Discovery run
  /// from the Transcribe a File wizard must repair the import's model, never dictation's:
  /// the two can be on different providers, and before the split there was only one pair of
  /// fields for a result to land in.
  func validateKeyAndDiscoverModels(
    provider: LLMProvider, settings: SettingsManager,
    surface: ProviderSetupSurface = .dictation,
    source: ApiKeyValidationSource = .modelDiscovery
  ) async {
    discoveryGeneration += 1
    let generation = discoveryGeneration
    // The surface's OWNERSHIP MODE at the moment the request was made. A discovery started
    // while the import had its own provider must not repair DICTATION's model because the
    // user pressed "Use dictation's polish settings" while it was in flight, even though the
    // provider still matches. Found by Codex.
    let importOverrideAtStart = settings.fileImportLLMProvider
    // Owner first. Until this request publishes, the previous provider's catalog must not
    // be sitting under this provider's name — and the synchronous missing-key return below
    // would have left it there permanently. `didSet` clears it on a real owner change and
    // leaves a same-provider refresh's list on screen, which is what a refresh should look
    // like. Found by Codex.
    stateProvider = provider
    keyValidationState = .validating
    isDiscoveringModels = true
    // Lowered by whoever raised it, and only if nothing newer has raised it since. An
    // unconditional clear on the way out of a SUPERSEDED request turns off the spinner a
    // live one is still showing.
    defer { if discoveryGeneration == generation { isDiscoveringModels = false } }

    let apiKey: String
    if provider == .ollama || provider == .appleIntelligence {
      apiKey = ""
    } else {
      let keychainId: String
      switch provider {
      case .openAI: keychainId = KeychainManager.openAIKeyID
      case .gemini: keychainId = KeychainManager.geminiKeyID
      case .claude: keychainId = KeychainManager.claudeKeyID
      // #2651: enumerated rather than `default:`. These providers hold no API
      // key, so there is no id to look up and the guard below reports the
      // missing key that is correctly absent. A NEW key-carrying provider
      // reaching a `default:` here would have got `""` and reported "No API
      // key found" forever, with no compiler complaint.
      case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: keychainId = ""
      }
      guard let key = try? keychainManager.retrieve(key: keychainId), !key.isEmpty else {
        // Missing-key guard: no validation actually ran, so NO
        // `api_key.validation_completed` event (#1173).
        keyValidationState = .invalid("No API key found")
        return
      }
      apiKey = key
    }

    let discovery = LLMModelDiscovery()
    do {
      let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
      guard discoveryGeneration == generation else { return }
      discoveredModels = models
      if provider != .appleIntelligence {
        cacheModels(models, for: provider)
      }
      keyValidationState = .valid
      emitValidationCompleted(
        provider: provider, result: "valid", source: source,
        modelCount: models.count,
        discoveryOutcome: models.isEmpty ? "zero_models" : "models_found")

      switch surface {
      case .dictation:
        settings.applyDiscoveredModels(models, for: provider)
      case .fileImport:
        guard settings.fileImportLLMProvider == importOverrideAtStart else { break }
        settings.applyDiscoveredModelsForFileImport(models, for: provider)
      }
    } catch LLMError.providerUnavailable {
      guard discoveryGeneration == generation else { return }
      keyValidationState = .invalid(
        provider == .ollama
          ? "Ollama is not running. Start it with: ollama serve"
          : "Apple Intelligence not available on this system."
      )
      discoveredModels = []
      emitValidationCompleted(provider: provider, result: "provider_unavailable", source: source)
    } catch let error as LLMError where error == .invalidAPIKey {
      guard discoveryGeneration == generation else { return }
      keyValidationState = .invalid("Invalid API key")
      discoveredModels = []
      emitValidationCompleted(provider: provider, result: "invalid", source: source)
    } catch {
      guard discoveryGeneration == generation else { return }
      keyValidationState = .invalid(error.localizedDescription)
      discoveredModels = []
      emitValidationCompleted(provider: provider, result: "error", source: source)
    }
  }

  /// #1173: emit `api_key.validation_completed` for a terminal validation result.
  /// Provider identity only — never the key. Gated to real cloud BYOK providers
  /// (Codex r2; widened to include Claude, issue #158): Ollama and Apple
  /// Intelligence are keyless local providers, so their discovery outcome is
  /// NOT an API-key validation and must stay out of the `api_key.*` metrics.
  private func emitValidationCompleted(
    provider: LLMProvider, result: String, source: ApiKeyValidationSource,
    modelCount: Int? = nil, discoveryOutcome: String? = nil
  ) {
    guard provider == .openAI || provider == .gemini || provider == .claude else { return }
    TelemetryService.shared.apiKeyValidationCompleted(
      provider: provider.rawValue, result: result, source: source.rawValue,
      modelCount: modelCount, discoveryOutcome: discoveryOutcome)
  }

  /// Load cached models from UserDefaults for the given provider.
  func loadCachedModels(for provider: LLMProvider) {
    // #2772 chunk 3: a cache load says nothing about whether THIS provider's key works, so
    // a validation verdict earned by a different provider must not survive the switch.
    // A cache load is a new owner of the published state, so an in-flight discovery must not
    // land on top of it — and dismissing that request is what leaves a pending verdict with
    // no author, which `invalidateInFlightDiscovery` clears. The owner change itself clears
    // a DIFFERENT provider's models and verdict through `stateProvider`'s `didSet`.
    invalidateInFlightDiscovery()
    stateProvider = provider
    let key = "cachedModels_\(provider.rawValue)"
    guard let data = cacheDefaults.data(forKey: key),
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
      cacheDefaults.set(data, forKey: key)
    }
  }
}
