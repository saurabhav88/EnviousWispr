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
    case stored(validation: Task<Void, Never>, revision: UInt64?)
    case failed(any Error, revision: UInt64?)
  }

  enum ClearOutcome {
    case cleared(revision: UInt64?)
    case failed(any Error, revision: UInt64?)
  }

  let keychainManager: KeychainManager
  let presence: SavedKeyPresence
  let discovery: LLMModelDiscoveryCoordinator
  var access: CredentialAccessLane = .live
  var emit: Emit = { provider, action, result in
    TelemetryService.shared.apiKeyChanged(provider: provider, action: action, result: result)
  }

  struct Admission {
    let turn: CredentialAccessLane.Turn
    let discovery: LLMModelDiscoveryCoordinator.CredentialAdmission
    let pendingID: UUID
  }

  /// Admit synchronously at the UI/door ingress, before a task can yield to a newer choice.
  func admit(
    _ provider: CredentialProvider, settings: SettingsManager?, surface: ProviderSetupSurface
  ) -> Admission {
    let pendingID = presence.beginMutation(for: provider.llmProvider)
    let turn = access.reserve()
    let discoveryAdmission = discovery.admitCredentialMutation(
      provider: provider.llmProvider, settings: settings, surface: surface)
    return Admission(turn: turn, discovery: discoveryAdmission, pendingID: pendingID)
  }

  /// Storage and shared-state publication are one ordered operation; validation is separate.
  func save(
    _ value: String, for provider: CredentialProvider, settings: SettingsManager,
    surface: ProviderSetupSurface,
    admission: Admission? = nil
  ) async -> SaveOutcome {
    let admitted = admission ?? admit(provider, settings: settings, surface: surface)
    return await access.run(turn: admitted.turn) {
      defer { presence.endMutation(admitted.pendingID) }
      let result = await CredentialIO.perform(.store(provider.keyID, value), using: keychainManager)
      switch result {
      case .failure(let error):
        credentialWriterLog.error(
          "Save key failed action=save keyID=\(provider.keyID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        emit(provider.llmProvider.rawValue, "save", "failure")
        // A failed store may have changed storage. Keep uncertainty, never an old verdict.
        presence.recordUncertain(provider.llmProvider)
        discovery.finishCredentialMutation(admitted.discovery, cleared: false, settings: settings)
        return .failed(error, revision: presence.revision(for: provider.llmProvider))
      case .success:
        emit(provider.llmProvider.rawValue, "save", "success")
        // Record THIS committed key before scheduling its validation (#3438).
        presence.recordSaved(provider.llmProvider)
        let revision = presence.revision(for: provider.llmProvider)
        let discovery = discovery
        let validation = Task {
          await discovery.validateSavedCredential(
            value, revision: revision, admission: admitted.discovery, settings: settings)
        }
        return .stored(validation: validation, revision: revision)
      }
    }
  }

  func clear(
    _ provider: CredentialProvider, settings: SettingsManager? = nil,
    surface: ProviderSetupSurface = .dictation,
    admission: Admission? = nil
  ) async -> ClearOutcome {
    let admitted = admission ?? admit(provider, settings: settings, surface: surface)
    return await access.run(turn: admitted.turn) {
      defer { presence.endMutation(admitted.pendingID) }
      let result = await CredentialIO.perform(.delete(provider.keyID), using: keychainManager)
      switch result {
      case .failure(let error):
        credentialWriterLog.error(
          "Clear key failed action=clear keyID=\(provider.keyID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        emit(provider.llmProvider.rawValue, "remove", "failure")
        presence.recordUncertain(provider.llmProvider)
        discovery.finishCredentialMutation(admitted.discovery, cleared: false, settings: settings)
        return .failed(error, revision: presence.revision(for: provider.llmProvider))
      case .success:
        emit(provider.llmProvider.rawValue, "remove", "success")
        presence.recordCleared(provider.llmProvider)
        discovery.finishCredentialMutation(admitted.discovery, cleared: true, settings: settings)
        return .cleared(revision: presence.revision(for: provider.llmProvider))
      }
    }
  }
}

/// #3776: serialize the whole credential transaction, including MainActor publication.
/// Holding this permit across awaits is deliberate: an actor hop alone is reentrant.
@MainActor
final class CredentialAccessLane {
  static let live = CredentialAccessLane()

  @MainActor
  final class Turn {
    fileprivate var ready = false
    fileprivate var continuation: CheckedContinuation<Void, Never>?
  }
  private var held = false
  private var waiters: [Turn] = []
  /// Observes the real queued transition; never changes admission or releases a permit.
  package var onQueuedForTesting: (@MainActor () -> Void)?

  /// Reserve before launching the owned operation task. Actor task launch order is not FIFO.
  func reserve() -> Turn {
    let turn = Turn()
    if held {
      waiters.append(turn)
      onQueuedForTesting?()
    } else {
      held = true
      turn.ready = true
    }
    return turn
  }

  func run<T>(turn: Turn, _ operation: @MainActor () async -> T) async -> T {
    await waitUntilReady(turn)
    defer { release() }
    // Admission owns completion even if the caller/view/connection has been cancelled.
    return await operation()
  }

  func run<T>(_ operation: @MainActor () async -> T) async -> T {
    let turn = reserve()
    return await run(turn: turn, operation)
  }

  // Keep the checked continuation in a non-generic function, matching the concrete FIFO
  // primitive rather than introducing the library/test back-deploy generic-frame mismatch.
  private func waitUntilReady(_ turn: Turn) async {
    if turn.ready == false {
      await withCheckedContinuation { turn.continuation = $0 }
    }
  }

  private func release() {
    guard waiters.isEmpty == false else { held = false; return }
    let next = waiters.removeFirst()
    next.ready = true
    next.continuation?.resume()
    next.continuation = nil
  }
}

/// One background bridge for the blocking storage APIs. Only Sendable values cross it;
/// screen state, discovery and telemetry stay on MainActor. No synchronous main-queue wait.
enum CredentialIO {
  enum Operation: Sendable {
    case store(String, String)
    case delete(String)
    case read(String)
  }
  private static let queue = DispatchQueue(label: "com.enviouswispr.credentials.io", qos: .userInitiated)

  static func perform(_ operation: Operation, using manager: KeychainManager) async -> Result<String?, any Error> {
    await withCheckedContinuation { continuation in
      queue.async {
        let result: Result<String?, any Error> = Result {
          switch operation {
          case .store(let key, let value): try manager.store(key: key, value: value); return nil
          case .delete(let key): try manager.delete(key: key); return nil
          case .read(let key): return try manager.retrieve(key: key)
          }
        }
        continuation.resume(returning: result)
      }
    }
  }
}
