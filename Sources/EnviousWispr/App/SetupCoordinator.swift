import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import Observation

/// Owns setup-orchestration concerns previously held directly on AppState:
/// the Ollama setup service, the WhisperKit setup service, and the background
/// observation task that pre-loads WhisperKit when its setup state becomes ready.
///
/// Heart path does not consult this object. If setup services fail, dictation
/// still completes — the user just sees broken status in Settings tabs.
@MainActor
@Observable
final class SetupCoordinator {
  let ollamaSetup = OllamaSetupService()
  let whisperKitSetup = WhisperKitSetupService()

  @ObservationIgnored
  private var whisperKitPreloadTask: Task<Void, Never>?

  private let asrManager: any ASRManagerInterface
  private let preloadAction: @MainActor () async -> Void

  init(
    asrManager: any ASRManagerInterface,
    preloadAction: @escaping @MainActor () async -> Void
  ) {
    self.asrManager = asrManager
    self.preloadAction = preloadAction
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
        // Backend switches fire settingsSync.onNeedsPreloadObservation, which
        // restarts this observer; the re-entry sees the new activeBackendType.
        guard self.asrManager.activeBackendType == .whisperKit else { return }

        let currentState = self.whisperKitSetup.setupState
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
