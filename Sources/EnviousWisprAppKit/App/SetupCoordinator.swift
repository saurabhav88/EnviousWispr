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

  @ObservationIgnored
  private var whisperKitMigrationTask: Task<Void, Never>?

  /// #1918: the settings-pane-scoped poll and the app-activation probe for
  /// Ollama status. Both nil when no pane is watching.
  @ObservationIgnored
  private var ollamaStatusPollTask: Task<Void, Never>?
  @ObservationIgnored
  private var ollamaActivationProbeTask: Task<Void, Never>?

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

  /// #1918 test seams. Default to the real Ollama probe and a real 15s delay,
  /// so production behavior is unchanged; a unit test injects both to make
  /// polling deterministic without real time or a real daemon.
  private let ollamaStatusProbe: @MainActor (String) async -> Void
  private let ollamaPollDelay: @MainActor () async throws -> Void

  init(
    asrManager: any ASRManagerInterface,
    whisperKitSetup: WhisperKitSetupService,
    setupStateReader: (@MainActor () -> WhisperKitSetupState)? = nil,
    runDocumentsMigration: @escaping @MainActor () async -> Void = {},
    preloadAction: @escaping @MainActor () async -> Void,
    ollamaStatusProbe: (@MainActor (String) async -> Void)? = nil,
    ollamaPollDelay: @escaping @MainActor () async throws -> Void = {
      try await Task.sleep(for: .seconds(15))
    }
  ) {
    self.asrManager = asrManager
    self.whisperKitSetup = whisperKitSetup
    self.runDocumentsMigration = runDocumentsMigration
    self.preloadAction = preloadAction
    self.ollamaPollDelay = ollamaPollDelay
    // Bind the default readers inside init capturing the owned services as
    // locals (a default parameter value cannot reference `self`).
    let service = whisperKitSetup
    self.setupStateReader = setupStateReader ?? { service.setupState }
    let ollama = ollamaSetup
    self.ollamaStatusProbe =
      ollamaStatusProbe ?? { trigger in await ollama.detectState(trigger: trigger) }
  }

  /// #1386 PR-2: the post-UI launch step for the multilingual engine, in order —
  /// migrate an existing ~/Documents copy, then read the resulting availability,
  /// then start watching for readiness. Sequenced so setup never reports on a
  /// half-migrated state, and called from `runDidFinishLaunching` so the
  /// Documents read (and any permission prompt) happens with the app on screen.
  func startWhisperKitMigrationThenDetect() {
    whisperKitMigrationTask = Task { [weak self] in
      // `Task.cancel()` only sets a flag; a closure cancelled before entry
      // still runs until its first cancellation check. This is that check.
      guard !Task.isCancelled, let self else { return }
      await self.runDocumentsMigration()
      guard !Task.isCancelled else { return }
      await self.whisperKitSetup.detectState()
      guard !Task.isCancelled else { return }
      self.startPreloadObservation()
    }
  }

  /// Start the settings-pane-scoped poll for Ollama status, called from
  /// `AIPolishSettingsView.onAppear`/`.onChange(llmProvider)`. Idempotent:
  /// cancels-before-restart, mirroring `startPreloadObservation()`'s own
  /// precedent for the sibling WhisperKit observer.
  func startOllamaStatusWatch() {
    ollamaStatusPollTask?.cancel()
    ollamaStatusPollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await self.ollamaPollDelay()
        guard !Task.isCancelled else { return }
        if self.ollamaSetup.setupState.allowsSilentBackgroundRefresh {
          await self.ollamaStatusProbe("visible_poll")
        }
      }
    }
  }

  /// Stop the visible-pane poll AND the activation probe — closing/leaving
  /// the pane must fully stop the watch, not just the poll half of it.
  func stopOllamaStatusWatch() {
    ollamaStatusPollTask?.cancel()
    ollamaStatusPollTask = nil
    ollamaActivationProbeTask?.cancel()
    ollamaActivationProbeTask = nil
  }

  /// Called from `AppLifecycleCoordinator.runDidBecomeActive()`. Self-gated
  /// no-op unless a pane is currently watching, so a background/foreground
  /// cycle with no Settings pane open costs nothing.
  func applicationDidBecomeActive() {
    guard ollamaStatusPollTask != nil else { return }
    ollamaActivationProbeTask?.cancel()
    ollamaActivationProbeTask = Task { [weak self] in
      // `Task.cancel()` only sets a flag; a closure cancelled before entry
      // still runs until its first cancellation check. This is that check.
      guard !Task.isCancelled, let self else { return }
      guard self.ollamaSetup.setupState.allowsSilentBackgroundRefresh else { return }
      await self.ollamaStatusProbe("app_active")
    }
  }

  /// Cancel every task this coordinator owns: the Ollama poll, the Ollama
  /// activation probe, the WhisperKit preload observer, and the WhisperKit
  /// migration task.
  func cleanup() {
    ollamaStatusPollTask?.cancel()
    ollamaStatusPollTask = nil
    ollamaActivationProbeTask?.cancel()
    ollamaActivationProbeTask = nil
    whisperKitPreloadTask?.cancel()
    whisperKitPreloadTask = nil
    whisperKitMigrationTask?.cancel()
    whisperKitMigrationTask = nil
    ollamaSetup.cleanup()
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
