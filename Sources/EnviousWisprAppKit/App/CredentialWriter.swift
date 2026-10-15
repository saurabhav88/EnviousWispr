import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import OSLog

/// The three cloud polish providers whose API keys the app stores, each with the fixed
/// KeychainManager id it is stored under. No other id or storage location can be named.
enum CredentialProvider: CaseIterable, Sendable {
  case openAI
  case gemini
  case claude

  init?(_ provider: LLMProvider) {
    switch provider {
    case .openAI: self = .openAI
    case .gemini: self = .gemini
    case .claude: self = .claude
    // Enumerated, not `default:`: a new provider has to decide here whether it stores a key.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return nil
    }
  }

  var llmProvider: LLMProvider {
    switch self {
    case .openAI: return .openAI
    case .gemini: return .gemini
    case .claude: return .claude
    }
  }

  var keyID: String {
    switch self {
    case .openAI: return KeychainManager.openAIKeyID
    case .gemini: return KeychainManager.geminiKeyID
    case .claude: return KeychainManager.claudeKeyID
    }
  }
}

/// Unified log for Save/Clear key failures.
/// The user-facing badge intentionally omits the raw OSStatus (#724), so this
/// log keeps the numeric code observable for support and Sentry triage. Never
/// log the key value itself.
///
/// #2772 chunk 1: moved from `AIPolishSettingsView.swift` into `ProviderSetup.swift` with its
/// only two callers; #3765 moved it here with them.
private let credentialWriterLog = Logger(
  subsystem: "com.enviouswispr.app", category: "AIPolishSettings")

/// #3765: storing or clearing one provider's API key, and everything that follows from it
/// outside the screen: the `api_key.changed` event, what `SavedKeyPresence` records, and the
/// key check (save) or discovery reset (clear). The AI Polish screen and the dev control door
/// both call this, so the credential effects have one owner; the screen keeps its draft,
/// reveal state and Saved/Failed badge.
@MainActor
struct CredentialWriter {
  /// `TelemetryService.apiKeyChanged(provider:action:result:)`.
  typealias Emit = @MainActor (_ provider: String, _ action: String, _ result: String) -> Void

  enum SaveOutcome {
    /// The store accepted the key. `validation` is the key check it started; the store
    /// succeeding says nothing about how that check ends.
    case stored(validation: Task<Void, Never>)
    case failed(any Error)
  }

  enum ClearOutcome {
    case cleared
    case failed(any Error)
  }

  let keychainManager: KeychainManager
  let presence: SavedKeyPresence
  let discovery: LLMModelDiscoveryCoordinator
  var emit: Emit = { provider, action, result in
    TelemetryService.shared.apiKeyChanged(provider: provider, action: action, result: result)
  }

  /// Store `value` for `provider`, then record it and start the key check that Save starts.
  /// The store runs synchronously on the main actor, exactly as the screen always ran it;
  /// moving Keychain work off the main actor is #3776 (founder 2026-10-15).
  /// The provider label is the `LLMProvider.rawValue` vocabulary `api_key.validation_completed`
  /// uses, so both events group by the same provider (#1173). Never the key value.
  func save(
    _ value: String, for provider: CredentialProvider, settings: SettingsManager,
    surface: ProviderSetupSurface
  ) -> SaveOutcome {
    do {
      try keychainManager.store(key: provider.keyID, value: value)
    } catch {
      credentialWriterLog.error(
        "Save key failed action=save keyID=\(provider.keyID, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      emit(provider.llmProvider.rawValue, "save", "failure")
      // A failed store may or may not have changed what is stored; say unknown and
      // drop any verdict about the previous key rather than guess (#3438).
      presence.recordUncertain(provider.llmProvider)
      return .failed(error)
    }
    emit(provider.llmProvider.rawValue, "save", "success")
    // Before the check below starts, so its verdict is tied to THIS key (#3438).
    presence.recordSaved(provider.llmProvider)
    let discovery = discovery
    let validation = Task {
      await discovery.validateKeyAndDiscoverModels(
        provider: provider.llmProvider, settings: settings, surface: surface, source: .save)
    }
    return .stored(validation: validation)
  }

  /// Delete `provider`'s stored key, then record the clear and reset discovery.
  func clear(_ provider: CredentialProvider) -> ClearOutcome {
    do {
      try keychainManager.delete(key: provider.keyID)
    } catch {
      credentialWriterLog.error(
        "Clear key failed action=clear keyID=\(provider.keyID, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      emit(provider.llmProvider.rawValue, "remove", "failure")
      presence.recordUncertain(provider.llmProvider)
      return .failed(error)
    }
    emit(provider.llmProvider.rawValue, "remove", "success")
    presence.recordCleared(provider.llmProvider)
    discovery.reset()
    return .cleared
  }
}
