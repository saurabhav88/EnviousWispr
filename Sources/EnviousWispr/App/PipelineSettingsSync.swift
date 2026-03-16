import Foundation
import EnviousWisprCore
import EnviousWisprAudio
import EnviousWisprASR
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices

/// Forwards settings changes to pipelines and subsystems.
/// Single responsibility: settings propagation. No business logic.
@MainActor
final class PipelineSettingsSync {
    private let pipeline: TranscriptionPipeline
    private let whisperKitPipeline: WhisperKitPipeline
    private let audioCapture: any AudioCaptureInterface
    private let asrManager: ASRManager
    private let hotkeyService: HotkeyService
    private let whisperKitSetup: WhisperKitSetupService

    /// Called when backend/model changes require WhisperKit preload re-observation.
    /// Set by AppState — keeps preload observation ownership in AppState.
    var onNeedsPreloadObservation: (() -> Void)?

    init(
        pipeline: TranscriptionPipeline,
        whisperKitPipeline: WhisperKitPipeline,
        audioCapture: any AudioCaptureInterface,
        asrManager: ASRManager,
        hotkeyService: HotkeyService,
        whisperKitSetup: WhisperKitSetupService
    ) {
        self.pipeline = pipeline
        self.whisperKitPipeline = whisperKitPipeline
        self.audioCapture = audioCapture
        self.asrManager = asrManager
        self.hotkeyService = hotkeyService
        self.whisperKitSetup = whisperKitSetup
    }

    /// Apply initial settings to both pipelines and audio capture. Called once from AppState.init.
    func applyInitialSettings(_ settings: SettingsManager, customWords: [CustomWord]) {
        // Parakeet pipeline
        pipeline.autoCopyToClipboard = settings.autoCopyToClipboard
        pipeline.llmPolish.llmProvider = settings.llmProvider
        pipeline.llmPolish.llmModel = settings.llmModel
        if settings.llmProvider == .ollama {
            pipeline.llmPolish.llmModel = settings.ollamaModel
        }
        pipeline.vadAutoStop = settings.vadAutoStop
        pipeline.vadSilenceTimeout = settings.vadSilenceTimeout
        pipeline.vadSensitivity = settings.vadSensitivity
        pipeline.vadEnergyGate = settings.vadEnergyGate
        pipeline.modelUnloadPolicy = settings.modelUnloadPolicy
        pipeline.restoreClipboardAfterPaste = settings.restoreClipboardAfterPaste
        pipeline.llmPolish.polishInstructions = settings.activePolishInstructions
        pipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
        pipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
        pipeline.wordCorrection.customWords = customWords
        pipeline.llmPolish.customWords = customWords
        pipeline.llmPolish.useExtendedThinking = settings.useExtendedThinking

        // WhisperKit pipeline
        syncWhisperKitPipelineSettings(settings, customWords: customWords)

        // Audio capture
        if settings.noiseSuppression {
            audioCapture.buildEngine(noiseSuppression: true)
        } else {
            audioCapture.noiseSuppressionEnabled = false
        }
        audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
        audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride

        // VAD config to audio capture (used by XPC service-side VAD)
        audioCapture.configureVAD(
            autoStop: settings.vadAutoStop,
            silenceTimeout: settings.vadSilenceTimeout,
            sensitivity: settings.vadSensitivity,
            energyGate: settings.vadEnergyGate
        )

        // Transcription options (language)
        syncTranscriptionOptions(settings)
    }

    /// Handle a settings change by forwarding to the appropriate subsystem.
    func handleSettingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) {
        switch key {
        case .selectedBackend:
            // Don't switch backends while a pipeline is actively recording/transcribing
            let parakeetActive = pipeline.state.isActive
            let whisperKitActive = whisperKitPipeline.state.isActive
            if parakeetActive || whisperKitActive {
                Task { await AppLogger.shared.log(
                    "Backend switch blocked — pipeline is active",
                    level: .info, category: "PipelineSettingsSync"
                ) }
                break
            }
            let backend = settings.selectedBackend
            Task { [weak self] in
                await self?.asrManager.switchBackend(to: backend)
                if backend == .whisperKit {
                    await self?.whisperKitSetup.detectState()
                    self?.onNeedsPreloadObservation?()
                }
            }
        case .whisperKitModel:
            let model = settings.whisperKitModel
            whisperKitSetup.modelVariant = model
            Task { [weak self] in
                await self?.asrManager.updateWhisperKitModel(model)
                await self?.whisperKitSetup.forceDetectState()
                self?.onNeedsPreloadObservation?()
            }
        case .recordingMode:
            hotkeyService.recordingMode = settings.recordingMode
        case .llmProvider:
            pipeline.llmPolish.llmProvider = settings.llmProvider
            whisperKitPipeline.llmPolish.llmProvider = settings.llmProvider
        case .llmModel:
            pipeline.llmPolish.llmModel = settings.llmModel
            whisperKitPipeline.llmPolish.llmModel = settings.llmModel
            if settings.llmProvider == .ollama {
                settings.ollamaModel = settings.llmModel
            }
        case .ollamaModel:
            if settings.llmProvider == .ollama {
                pipeline.llmPolish.llmModel = settings.ollamaModel
                whisperKitPipeline.llmPolish.llmModel = settings.ollamaModel
            }
        case .autoCopyToClipboard:
            pipeline.autoCopyToClipboard = settings.autoCopyToClipboard
            whisperKitPipeline.autoCopyToClipboard = settings.autoCopyToClipboard
        case .hotkeyEnabled:
            if settings.hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
        case .vadAutoStop:
            pipeline.vadAutoStop = settings.vadAutoStop
            whisperKitPipeline.vadAutoStop = settings.vadAutoStop
            audioCapture.configureVAD(
                autoStop: settings.vadAutoStop,
                silenceTimeout: settings.vadSilenceTimeout,
                sensitivity: settings.vadSensitivity,
                energyGate: settings.vadEnergyGate
            )
        case .vadSilenceTimeout:
            pipeline.vadSilenceTimeout = settings.vadSilenceTimeout
            whisperKitPipeline.vadSilenceTimeout = settings.vadSilenceTimeout
            audioCapture.configureVAD(
                autoStop: settings.vadAutoStop,
                silenceTimeout: settings.vadSilenceTimeout,
                sensitivity: settings.vadSensitivity,
                energyGate: settings.vadEnergyGate
            )
        case .environmentPreset:
            let sensitivity = settings.environmentPreset.vadSensitivity
            settings.vadSensitivity = sensitivity
        case .writingStylePreset:
            pipeline.llmPolish.polishInstructions = settings.activePolishInstructions
            whisperKitPipeline.llmPolish.polishInstructions = settings.activePolishInstructions
        case .vadSensitivity:
            pipeline.vadSensitivity = settings.vadSensitivity
            whisperKitPipeline.vadSensitivity = settings.vadSensitivity
            audioCapture.configureVAD(
                autoStop: settings.vadAutoStop,
                silenceTimeout: settings.vadSilenceTimeout,
                sensitivity: settings.vadSensitivity,
                energyGate: settings.vadEnergyGate
            )
        case .vadEnergyGate:
            pipeline.vadEnergyGate = settings.vadEnergyGate
            whisperKitPipeline.vadEnergyGate = settings.vadEnergyGate
            audioCapture.configureVAD(
                autoStop: settings.vadAutoStop,
                silenceTimeout: settings.vadSilenceTimeout,
                sensitivity: settings.vadSensitivity,
                energyGate: settings.vadEnergyGate
            )
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
            pipeline.modelUnloadPolicy = settings.modelUnloadPolicy
            whisperKitPipeline.modelUnloadPolicy = settings.modelUnloadPolicy
            if settings.modelUnloadPolicy == .never {
                asrManager.cancelIdleTimer()
            }
        case .restoreClipboardAfterPaste:
            pipeline.restoreClipboardAfterPaste = settings.restoreClipboardAfterPaste
            whisperKitPipeline.restoreClipboardAfterPaste = settings.restoreClipboardAfterPaste
        case .customSystemPrompt:
            pipeline.llmPolish.polishInstructions = settings.activePolishInstructions
            whisperKitPipeline.llmPolish.polishInstructions = settings.activePolishInstructions
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
            pipeline.llmPolish.useExtendedThinking = settings.useExtendedThinking
            whisperKitPipeline.llmPolish.useExtendedThinking = settings.useExtendedThinking
        case .whisperKitLanguage:
            syncTranscriptionOptions(settings)
        case .selectedInputDeviceUID:
            audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
        case .preferredInputDeviceIDOverride:
            audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
        case .noiseSuppression:
            // Full engine rebuild — runtime toggling of voice processing is unreliable.
            // Cancel any active recording first to avoid corrupted state.
            if pipeline.state == .recording {
                Task { [weak self] in
                    await self?.pipeline.cancelRecording()
                    self?.audioCapture.buildEngine(noiseSuppression: settings.noiseSuppression)
                }
            } else {
                audioCapture.buildEngine(noiseSuppression: settings.noiseSuppression)
            }
        case .onboardingState, .hasCompletedOnboarding:
            break
        case .useXPCAudioService:
            // Cold flag — requires app restart. No live propagation needed.
            break
        }
    }

    /// Sync shared transcription options (language, timestamps) to both pipelines.
    private func syncTranscriptionOptions(_ settings: SettingsManager) {
        var opts = TranscriptionOptions()
        // Parakeet is English-only; WhisperKit uses the user's selected language.
        // Pass the language to both pipelines — Parakeet ignores it, WhisperKit
        // passes it through to DecodingOptions.
        opts.language = settings.whisperKitLanguage
        pipeline.transcriptionOptions = opts
        whisperKitPipeline.transcriptionOptions = opts
    }

    /// Sync all user-facing settings to the WhisperKit pipeline.
    private func syncWhisperKitPipelineSettings(_ settings: SettingsManager, customWords: [CustomWord]) {
        whisperKitPipeline.autoCopyToClipboard = settings.autoCopyToClipboard
        whisperKitPipeline.restoreClipboardAfterPaste = settings.restoreClipboardAfterPaste
        whisperKitPipeline.llmPolish.llmProvider = settings.llmProvider
        whisperKitPipeline.llmPolish.llmModel = settings.llmModel
        if settings.llmProvider == .ollama {
            whisperKitPipeline.llmPolish.llmModel = settings.ollamaModel
        }
        whisperKitPipeline.llmPolish.polishInstructions = settings.activePolishInstructions
        whisperKitPipeline.llmPolish.useExtendedThinking = settings.useExtendedThinking
        whisperKitPipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
        whisperKitPipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
        whisperKitPipeline.wordCorrection.customWords = customWords
        whisperKitPipeline.llmPolish.customWords = customWords
        whisperKitPipeline.vadAutoStop = settings.vadAutoStop
        whisperKitPipeline.vadSilenceTimeout = settings.vadSilenceTimeout
        whisperKitPipeline.vadSensitivity = settings.vadSensitivity
        whisperKitPipeline.vadEnergyGate = settings.vadEnergyGate
        whisperKitPipeline.modelUnloadPolicy = settings.modelUnloadPolicy
    }

    /// Re-register Carbon hotkeys after a config change.
    private func reregisterHotkeys() {
        guard hotkeyService.isEnabled else { return }
        hotkeyService.stop()
        hotkeyService.start()
    }
}
