import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Forwards live-mutable settings changes. Per-recording values are frozen
/// via `DictationSessionConfig` at `startRecording` and do not flow here —
/// see #195 plan for the full frozen/live classification.
@MainActor
final class PipelineSettingsSync {
  private let kernelDriver: KernelDictationDriver
  private let whisperKitKernelDriver: KernelDictationDriver
  private let audioCapture: any AudioCaptureInterface
  private let asrManager: any ASRManagerInterface
  private let hotkeyService: HotkeyService
  private let whisperKitSetup: WhisperKitSetupService

  /// Set by `EnviousWisprApp.init()` so backend/model changes can retrigger
  /// preload observation without coupling this layer to the composition root.
  var onNeedsPreloadObservation: (() -> Void)?

  /// #1063 PR2 — true while the crash-recovery limb is replaying behind the pill.
  /// A backend switch then would unload/reset the model mid-recovery, throwing the
  /// in-flight transcribe and (one-attempt) deleting the spool — data loss. Set by
  /// the composition root to `RecoveryCoordinator.isRecovering`; default no-recovery.
  var isRecovering: () -> Bool = { false }

  /// Tracks the last evictable Ollama model for #295. Independent of the
  /// kernel's polish step because SettingsManager's cascading didSet can
  /// corrupt a pre-snapshot read from the polish step.
  private var lastEvictableOllamaModel: String?

  init(
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    hotkeyService: HotkeyService,
    whisperKitSetup: WhisperKitSetupService
  ) {
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.hotkeyService = hotkeyService
    self.whisperKitSetup = whisperKitSetup
  }

  /// Seed live-mutable subsystems. Per-recording values are captured fresh
  /// at each `startRecording` and are not seeded here.
  ///
  /// Custom words are NOT seeded here — `CustomWordsPropagator` (registered
  /// in the former root state init) owns that fanout. See Phase D (#496).
  func applyInitialSettings(_ settings: SettingsManager) {
    kernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    kernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    kernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
    whisperKitKernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    whisperKitKernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    whisperKitKernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled

    if settings.noiseSuppression {
      audioCapture.buildEngine(noiseSuppression: true)
    } else {
      audioCapture.noiseSuppressionEnabled = false
    }
    audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
    audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
    audioCapture.warmEnginePolicy = settings.warmEnginePolicy
    audioCapture.configureVAD(
      autoStop: settings.vadAutoStop,
      silenceTimeout: settings.vadSilenceTimeout,
      sensitivity: settings.vadSensitivity,
      energyGate: settings.vadEnergyGate
    )

    // #295: seed eviction tracker. No initial eviction on app launch.
    lastEvictableOllamaModel = OllamaConnector.effectiveOllamaModel(
      provider: settings.llmProvider, model: resolvedModel(settings)
    )

    // #728: AppLogger defaults to debug=off / level=.info. Sync the persisted
    // values at launch so the file handle opens (or stays closed) according
    // to the user's saved preference instead of requiring a toggle off-then-on.
    // Capture values upfront so the unstructured Task is not racing settings
    // mutation. Level is set first so the file-open log line in `setDebugMode`
    // is not filtered out when the saved level is more permissive than .info.
    let logLevel = settings.debugLogLevel
    let debugEnabled = settings.isDebugModeEnabled
    Task {
      await AppLogger.shared.setLogLevel(logLevel)
      await AppLogger.shared.setDebugMode(debugEnabled)
    }
  }

  /// Handle a settings change by forwarding to the appropriate subsystem.
  func handleSettingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) {
    switch key {
    case .selectedBackend:
      // Don't switch backends while a pipeline is actively recording/transcribing,
      // OR while crash recovery is replaying on the shared engine (#1063 PR2) — a
      // switch would unload/reset the model mid-recovery and lose the spool.
      // Like the pre-existing active-pipeline case, the switch is DROPPED (not
      // queued): the persisted `selectedBackend` and the active engine can disagree
      // until the next change/relaunch. Recovery is short (seconds), so the window
      // is brief; a general deferred-apply mechanism is PR3 hardening (Codex r6 P2).
      let parakeetActive = kernelDriver.state.isActive
      let whisperKitActive = whisperKitKernelDriver.state.isActive
      if parakeetActive || whisperKitActive || isRecovering() {
        Task {
          await AppLogger.shared.log(
            "Backend switch blocked — pipeline active or recovery in progress",
            level: .info, category: "PipelineSettingsSync"
          )
        }
        break
      }
      let backend = settings.selectedBackend
      Task { [weak self] in
        await self?.asrManager.switchBackend(to: backend)
        SentryBreadcrumb.updateASRBackend(backend == .whisperKit ? "whisperkit" : "parakeet")
        if backend == .whisperKit {
          await self?.whisperKitSetup.detectState()
          self?.onNeedsPreloadObservation?()
        } else {
          // #879 — warm the newly-active Parakeet engine on swap so the first
          // press after switching is instant. Without this, swapping to
          // Parakeet leaves it cold until the first press (only launch warmed
          // it, and only if it was the launch-selected backend). Idempotent +
          // single-flighted; no-op if already loaded. WhisperKit warms via the
          // observation path above.
          await self?.kernelDriver.ensureEngineWarm(reason: .engineSwap)
        }
      }
    case .recordingMode:
      hotkeyService.recordingMode = settings.recordingMode
    case .llmProvider:
      // Eviction fires for RAM management (#295). Pipeline polish uses the
      // frozen value from `DictationSessionConfig`; live steps are seeded per
      // recording, so nothing to mirror here since #1106 removed re-polish.
      reconcileOllamaEviction(settings: settings)
    case .llmModel:
      if settings.llmProvider == .ollama {
        settings.ollamaModel = settings.llmModel
      }
      reconcileOllamaEviction(settings: settings)
    case .ollamaModel:
      reconcileOllamaEviction(settings: settings)
    case .hotkeyEnabled:
      if settings.hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
    case .cancelKeyCode:
      hotkeyService.cancelKeyCode = settings.cancelKeyCode
    case .cancelModifiers:
      hotkeyService.cancelModifiers = settings.cancelModifiers
    case .toggleKeyCode:
      hotkeyService.toggleKeyCode = settings.toggleKeyCode
      reregisterHotkeys()
    case .toggleModifiers:
      hotkeyService.toggleModifiers = settings.toggleModifiers
      reregisterHotkeys()
    case .pushToTalkKeyCode, .pushToTalkModifiers:
      // PTT mirrors toggle — single hotkey, mode determines behavior. No separate registration needed.
      break
    case .modelUnloadPolicy:
      // Frozen per recording; cancel idle timer live when switched to .never.
      if settings.modelUnloadPolicy == .never {
        asrManager.cancelIdleTimer()
      }
    case .emojiFormatterEnabled:
      kernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
      whisperKitKernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
    case .wordCorrectionEnabled:
      kernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
      whisperKitKernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    case .fillerRemovalEnabled:
      kernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
      whisperKitKernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    case .isDebugModeEnabled:
      Task { await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled) }
    case .debugLogLevel:
      Task { await AppLogger.shared.setLogLevel(settings.debugLogLevel) }
    case .useExtendedThinking:
      break  // Frozen per recording; see `DictationSessionConfig`. (Re-polish mirror removed #1106.)
    case .selectedInputDeviceUID:
      // Rebuilds next recording's capture source; in-flight recordings unaffected.
      audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
    case .preferredInputDeviceIDOverride:
      audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
    case .noiseSuppression:
      // Runtime voice-processing toggling is unreliable — full engine rebuild.
      // Cancel active recording first to avoid corrupted state.
      if kernelDriver.state == .recording {
        Task { [weak self] in
          await self?.kernelDriver.cancelRecording()
          self?.audioCapture.buildEngine(noiseSuppression: settings.noiseSuppression)
        }
      } else {
        audioCapture.buildEngine(noiseSuppression: settings.noiseSuppression)
      }
    case .warmEnginePolicy:
      audioCapture.warmEnginePolicy = settings.warmEnginePolicy
    case .autoCopyToClipboard, .vadAutoStop, .vadSilenceTimeout, .vadSensitivity,
      .vadEnergyGate, .restoreClipboardAfterPaste, .languageMode, .useStreamingASR:
      break  // Frozen per recording; see `DictationSessionConfig`.
    case .whisperKitLanguage:
      break  // Deprecated — legacy migration only (SettingsManager:460-484).
    case .onboardingState, .hasCompletedOnboarding, .useXPCAudioService,
      .contactsSyncOnLaunchEnabled:
      break  // UI-only or cold flag.
    case .crashRecoveryEnabled:
      break  // #1063: read by the recovery wiring at capture start, not the live pipeline.
    case .appearance:
      break  // UI-only; applied to NSApp.appearance by the app shell (#1047).
    }
  }

  /// Resolve the effective LLM model ID for the current provider.
  /// Apple Intelligence has a fixed model; Ollama uses its own model field.
  private func resolvedModel(_ settings: SettingsManager) -> String {
    switch settings.llmProvider {
    case .appleIntelligence: return "apple-intelligence"
    case .ollama: return settings.ollamaModel
    default: return settings.llmModel
    }
  }

  // MARK: - Ollama eviction on swap (#295)

  /// Fires best-effort unload when the tracked previous Ollama model differs
  /// from the new one. Also coalesces cascading .llmModel → .ollamaModel fires.
  private func reconcileOllamaEviction(settings: SettingsManager) {
    let new = OllamaConnector.effectiveOllamaModel(
      provider: settings.llmProvider, model: resolvedModel(settings)
    )
    let pre = lastEvictableOllamaModel
    guard let pre, pre != new else {
      lastEvictableOllamaModel = new
      return
    }
    // Phase B: if either pipeline has frozen `pre` into its in-flight
    // session via `DictationSessionConfig`, the upcoming polish call is
    // pinned to that model. Evicting now would cold-swap the active
    // recording's polish. Defer by leaving `lastEvictableOllamaModel` at
    // `pre`; the next setting change re-evaluates.
    if isOllamaModelPinnedInFlight(pre) { return }
    lastEvictableOllamaModel = new
    // #1106: eviction is a stateless server-unload by model NAME
    // (`OllamaConnector.evictModel`), so it routes through the live kernel's
    // polish step (where the Ollama models actually load) rather than the
    // deleted re-polish step. Any `LLMPolishStep` instance works.
    let polishStep = kernelDriver.llmPolish
    Task { [polishStep, pre] in
      await polishStep.evictPreviousOllamaModel(pre)
    }
  }

  /// Retry a deferred Ollama eviction after an in-flight session ends.
  /// Called from the pipeline state-change side-effect path when either
  /// pipeline transitions to a terminal state. Idempotent: no-op if nothing
  /// is pending.
  func retryDeferredOllamaEviction(settings: SettingsManager) {
    reconcileOllamaEviction(settings: settings)
  }

  /// True if either pipeline's frozen `DictationSessionConfig` targets the
  /// given Ollama model. Used by `reconcileOllamaEviction` to avoid evicting
  /// a model the in-flight polish still needs.
  private func isOllamaModelPinnedInFlight(_ model: String) -> Bool {
    for cfg in [kernelDriver.currentSessionConfig, whisperKitKernelDriver.currentSessionConfig] {
      guard let cfg else { continue }
      if cfg.llmProvider == .ollama && cfg.llmModel == model {
        return true
      }
    }
    return false
  }

  /// Re-register Carbon hotkeys after a config change.
  private func reregisterHotkeys() {
    guard hotkeyService.isEnabled else { return }
    hotkeyService.stop()
    hotkeyService.start()
  }
}
