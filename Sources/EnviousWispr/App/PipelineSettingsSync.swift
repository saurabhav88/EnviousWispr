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
  private let pipeline: TranscriptionPipeline
  private let whisperKitPipeline: WhisperKitPipeline
  private let polishService: TranscriptPolishService
  private let audioCapture: any AudioCaptureInterface
  private let asrManager: any ASRManagerInterface
  private let hotkeyService: HotkeyService
  private let whisperKitSetup: WhisperKitSetupService

  /// Set by AppState so backend/model changes can retrigger preload observation
  /// without coupling this layer to AppState.
  var onNeedsPreloadObservation: (() -> Void)?

  /// Tracks the last evictable Ollama model for #295. Independent of
  /// `polishService.llmPolishStep` because SettingsManager's cascading didSet
  /// can corrupt a pre-snapshot read from the polish step.
  private var lastEvictableOllamaModel: String?

  init(
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    polishService: TranscriptPolishService,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    hotkeyService: HotkeyService,
    whisperKitSetup: WhisperKitSetupService
  ) {
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline
    self.polishService = polishService
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.hotkeyService = hotkeyService
    self.whisperKitSetup = whisperKitSetup
  }

  /// Seed live-mutable subsystems. Per-recording values are captured fresh
  /// at each `startRecording` and are not seeded here.
  func applyInitialSettings(_ settings: SettingsManager, customWords: [CustomWord]) {
    pipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    pipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    pipeline.wordCorrection.customWords = customWords
    pipeline.llmPolish.customWords = customWords
    whisperKitPipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    whisperKitPipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    whisperKitPipeline.wordCorrection.customWords = customWords
    whisperKitPipeline.llmPolish.customWords = customWords

    syncPolishServiceSettings(settings, customWords: customWords)

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
  }

  /// Handle a settings change by forwarding to the appropriate subsystem.
  func handleSettingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) {
    switch key {
    case .selectedBackend:
      // Don't switch backends while a pipeline is actively recording/transcribing
      let parakeetActive = pipeline.state.isActive
      let whisperKitActive = whisperKitPipeline.state.isActive
      if parakeetActive || whisperKitActive {
        Task {
          await AppLogger.shared.log(
            "Backend switch blocked — pipeline is active",
            level: .info, category: "PipelineSettingsSync"
          )
        }
        break
      }
      let backend = settings.selectedBackend
      // Issue #289: invalidate any stall-recovery token on either pipeline
      // so a deferred cleanup from a pre-switch stall doesn't tear down
      // the pipeline that's about to become active.
      pipeline.clearPendingStallRecovery()
      whisperKitPipeline.clearPendingStallRecovery()
      Task { [weak self] in
        await self?.asrManager.switchBackend(to: backend)
        SentryBreadcrumb.updateASRBackend(backend == .whisperKit ? "whisperkit" : "parakeet")
        if backend == .whisperKit {
          await self?.whisperKitSetup.detectState()
          self?.onNeedsPreloadObservation?()
        }
      }
    case .recordingMode:
      hotkeyService.recordingMode = settings.recordingMode
    case .llmProvider:
      // Live mirror to re-polish path; eviction fires for RAM management (#295).
      // Pipeline polish uses the frozen value from `DictationSessionConfig`.
      polishService.llmPolishStep.llmProvider = settings.llmProvider
      polishService.llmPolishStep.llmModel = resolvedModel(settings)
      reconcileOllamaEviction(settings: settings)
    case .llmModel:
      polishService.llmPolishStep.llmModel = resolvedModel(settings)
      if settings.llmProvider == .ollama {
        settings.ollamaModel = settings.llmModel
      }
      reconcileOllamaEviction(settings: settings)
    case .ollamaModel:
      if settings.llmProvider == .ollama {
        polishService.llmPolishStep.llmModel = settings.ollamaModel
      }
      reconcileOllamaEviction(settings: settings)
    case .hotkeyEnabled:
      if settings.hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
    case .environmentPreset:
      // Cascade into `vadSensitivity` for the next recording's snapshot.
      settings.vadSensitivity = settings.environmentPreset.vadSensitivity
    case .writingStylePreset, .customSystemPrompt:
      polishService.llmPolishStep.polishInstructions = settings.activePolishInstructions
      polishService.llmPolishStep.styleConfig = settings.activePolishStyleConfig
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
    case .wordCorrectionEnabled:
      pipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
      whisperKitPipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    case .fillerRemovalEnabled:
      pipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
      whisperKitPipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    case .isDebugModeEnabled:
      Task { await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled) }
    case .debugLogLevel:
      Task { await AppLogger.shared.setLogLevel(settings.debugLogLevel) }
    case .useExtendedThinking:
      polishService.llmPolishStep.useExtendedThinking = settings.useExtendedThinking
    case .selectedInputDeviceUID:
      // Rebuilds next recording's capture source; in-flight recordings unaffected.
      audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
    case .preferredInputDeviceIDOverride:
      audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
    case .noiseSuppression:
      // Runtime voice-processing toggling is unreliable — full engine rebuild.
      // Cancel active recording first to avoid corrupted state.
      if pipeline.state == .recording {
        Task { [weak self] in
          await self?.pipeline.cancelRecording()
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
    case .onboardingState, .hasCompletedOnboarding, .useXPCAudioService:
      break  // UI-only or cold flag.
    }
  }

  /// Re-polish settings. TODO: share `LLMPolishConfig` with the pipeline (#206 follow-up).
  private func syncPolishServiceSettings(_ settings: SettingsManager, customWords: [CustomWord]) {
    polishService.llmPolishStep.llmProvider = settings.llmProvider
    polishService.llmPolishStep.llmModel = resolvedModel(settings)
    polishService.llmPolishStep.polishInstructions = settings.activePolishInstructions
    polishService.llmPolishStep.styleConfig = settings.activePolishStyleConfig
    polishService.llmPolishStep.useExtendedThinking = settings.useExtendedThinking
    polishService.llmPolishStep.customWords = customWords
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
    let polishStep = polishService.llmPolishStep
    Task { [polishStep, pre] in
      await polishStep.evictPreviousOllamaModel(pre)
    }
  }

  /// True if either pipeline's frozen `DictationSessionConfig` targets the
  /// given Ollama model. Used by `reconcileOllamaEviction` to avoid evicting
  /// a model the in-flight polish still needs.
  private func isOllamaModelPinnedInFlight(_ model: String) -> Bool {
    for cfg in [pipeline.currentSessionConfig, whisperKitPipeline.currentSessionConfig] {
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
