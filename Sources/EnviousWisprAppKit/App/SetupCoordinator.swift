import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import Observation

/// Owns setup-orchestration concerns previously held directly on the former root state:
/// the Ollama setup service, the WhisperKit setup service, and the background
/// observation task that pre-loads WhisperKit when its setup state becomes ready.
///
/// Heart path does not consult this object. If setup services fail, dictation
/// still completes — the user just sees broken status in Settings tabs.
@MainActor
@Observable
final class SetupCoordinator {
  let ollamaSetup = OllamaSetupService()
  /// #1386 PR-2: injected, because its download/cancel/availability now come
  /// from the delivery layer, which is built beside this coordinator.
  let whisperKitSetup: WhisperKitSetupService

  @ObservationIgnored
  private var whisperKitPreloadTask: Task<Void, Never>?

  private let asrManager: any ASRManagerInterface
  private let preloadAction: @MainActor () async -> Void

  /// Reads WhisperKit setup readiness for the preload gate. Defaults to the owned
  /// `whisperKitSetup` service, so production behavior is unchanged. A unit test
  /// injects a reader that returns `.ready` to prove the parakeet backend guard —
  /// not the (test-unreachable) readiness gate — is what suppresses preload (#898).
  private let setupStateReader: @MainActor () -> WhisperKitSetupState

  /// #1386 PR-2: the ~/Documents phase of the multilingual migration. Injected
  /// (the coordinator that owns it is built beside this one) and fired from
  /// `startWhisperKitMigrationThenDetect()` once the app has UI, because this is
  /// the step that can raise a Files-and-Folders prompt. Defaults to a no-op.
  private let runDocumentsMigration: @MainActor () async -> Void

  init(
    asrManager: any ASRManagerInterface,
    whisperKitSetup: WhisperKitSetupService = WhisperKitSetupService(),
    setupStateReader: (@MainActor () -> WhisperKitSetupState)? = nil,
    runDocumentsMigration: @escaping @MainActor () async -> Void = {},
    preloadAction: @escaping @MainActor () async -> Void
  ) {
    self.asrManager = asrManager
    self.whisperKitSetup = whisperKitSetup
    self.runDocumentsMigration = runDocumentsMigration
    self.preloadAction = preloadAction
    // Bind the default reader inside init capturing the owned service as a local
    // (a default parameter value cannot reference `self`).
    let service = whisperKitSetup
    self.setupStateReader = setupStateReader ?? { service.setupState }
  }

  /// #1386 PR-2: the post-UI launch step for the multilingual engine, in order —
  /// migrate an existing ~/Documents copy, then read the resulting availability,
  /// then start watching for readiness. Sequenced so setup never reports on a
  /// half-migrated state, and called from `runDidFinishLaunching` so the
  /// Documents read (and any permission prompt) happens with the app on screen.
  func startWhisperKitMigrationThenDetect() {
    Task { [weak self] in
      guard let self else { return }
      await self.runDocumentsMigration()
      await self.whisperKitSetup.detectState()
      self.startPreloadObservation()
    }
  }

  /// Observe `whisperKitSetup.setupState` and invoke `preloadAction` when it becomes
  /// `.ready` and the active backend is WhisperKit. Cancels any prior observation
  /// task; safe to call repeatedly (e.g. on backend switch).
  func startPreloadObservation() {
    whisperKitPreloadTask?.cancel()
    whisperKitPreloadTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }

        // Exit immediately when WhisperKit isn't the active backend. Parakeet
        // users shouldn't pay CPU/memory cost warming a backend they never use.
        // This observer covers launch + a download-completing-while-already-on-
        // WhisperKit; warming AFTER a backend switch is owned by
        // `EngineCoordinator` (#1171), so this observer is no longer restarted on
        // a switch.
        guard self.asrManager.activeBackendType == .whisperKit else { return }

        let currentState = self.setupStateReader()
        if currentState == .ready {
          await self.preloadAction()
          return
        }

        await withCheckedContinuation { continuation in
          withObservationTracking {
            _ = self.whisperKitSetup.setupState
          } onChange: {
            continuation.resume()
          }
        }
      }
    }
  }
}
