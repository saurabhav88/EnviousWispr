import SwiftUI
import EnviousWisprCore
import EnviousWisprStorage
import EnviousWisprPostProcessing
import EnviousWisprAudio
import EnviousWisprServices
import EnviousWisprASR
import EnviousWisprLLM
import EnviousWisprPipeline

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
    // Settings
    var settings = SettingsManager()

    // Sub-systems
    let permissions = PermissionsService()
    let audioCapture: any AudioCaptureInterface
    let asrManager: any ASRManagerInterface
    let transcriptStore = TranscriptStore()
    let keychainManager = KeychainManager()
    let hotkeyService = HotkeyService()
    let benchmark = BenchmarkSuite()
    let recordingOverlay = RecordingOverlayPanel()
    let ollamaSetup = OllamaSetupService()
    let whisperKitSetup = WhisperKitSetupService()
    let audioDeviceList = AudioDeviceList()

    /// Background task that observes WhisperKitSetupService.setupState and pre-loads the model when ready.
    private var whisperKitPreloadTask: Task<Void, Never>?

    // Pipelines — initialized after sub-systems
    let pipeline: TranscriptionPipeline
    let whisperKitPipeline: WhisperKitPipeline

    /// Forwards settings changes to pipelines and subsystems.
    private let settingsSync: PipelineSettingsSync

    /// Called when pipeline state changes — set by AppDelegate for icon updates.
    var onPipelineStateChange: ((PipelineState) -> Void)?

    // Transcript history — delegated to coordinator
    let transcriptCoordinator: TranscriptCoordinator
    var pendingNavigationSection: SettingsSection?

    /// True when recording is in hands-free (locked) mode via double-press.
    /// Read by the overlay to switch to the expanded lips visual.
    var isRecordingLocked: Bool = false

    // Feature #8: custom word management — delegated to coordinator
    let customWordsCoordinator = CustomWordsCoordinator()

    // Model discovery — delegated to coordinator
    let llmDiscovery: LLMModelDiscoveryCoordinator

    init() {
        // XPC audio service — default ON (Step 7). Audio capture runs in a separate XPC
        // service process for crash isolation. Escape hatch: `defaults write ... useXPCAudioService -bool false`
        // Read directly from UserDefaults because `settings` is not yet available (stored
        // properties must all be initialized before `self` is accessible).
        // NOTE: .bool(forKey:) returns false for absent keys — use object() ?? true pattern
        // so existing installs (no key written) get the new default.
        let useXPC = UserDefaults.standard.object(forKey: "useXPCAudioService") as? Bool ?? true
        if useXPC {
            audioCapture = AudioCaptureProxy()
        } else {
            audioCapture = AudioCaptureManager()
        }

        // Phase 5: XPC ASR service — default ON (Stage F). ASR inference runs in a separate
        // XPC service process for memory isolation. Escape hatch: `defaults write ... useXPCASRService -bool false`
        // NOTE: .bool(forKey:) returns false for absent keys — use object() ?? true pattern.
        let useXPCASR = UserDefaults.standard.object(forKey: "useXPCASRService") as? Bool ?? true
        if useXPCASR {
            asrManager = ASRManagerProxy()
        } else {
            asrManager = ASRManager()
        }

        transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
        llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: keychainManager)

        // Both pipeline properties must be initialized before `self` can be used.
        // WhisperKitBackend default is large-v3-turbo; reconfigured from settings below.
        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        whisperKitPipeline = WhisperKitPipeline(
            audioCapture: audioCapture,
            backend: WhisperKitBackend(),
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        // Initialize settingsSync and apply initial settings to both pipelines and audio capture
        settingsSync = PipelineSettingsSync(
            pipeline: pipeline,
            whisperKitPipeline: whisperKitPipeline,
            audioCapture: audioCapture,
            asrManager: asrManager,
            hotkeyService: hotkeyService,
            whisperKitSetup: whisperKitSetup
        )
        settingsSync.applyInitialSettings(settings, customWords: customWordsCoordinator.customWords)

        // Unified engine interruption handler — routes to whichever pipeline is actively recording.
        // Both pipelines share the same audioCapture instance. When the audio engine/XPC service
        // is interrupted, we must notify the pipeline that's currently recording, not the one
        // that happened to set onEngineInterrupted last.
        audioCapture.onEngineInterrupted = { [weak self] in
            guard let self else { return }
            if self.pipeline.state == .recording {
                self.pipeline.handleEngineInterruption()
            } else if self.whisperKitPipeline.state == .recording {
                self.whisperKitPipeline.handleEngineInterruption()
            }
            // Dismiss recording overlay if showing
            self.recordingOverlay.hide()
        }

        // Unified ASR service crash handler — routes to whichever pipeline is active.
        // Fires when the XPC ASR service dies mid-session (streaming or batch).
        asrManager.onServiceInterrupted = { [weak self] in
            guard let self else { return }
            let pState = self.pipeline.state
            let wkState = self.whisperKitPipeline.state
            Task { await AppLogger.shared.log(
                "[AppState] ASR onServiceInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
                level: .info, category: "XPC"
            ) }
            if pState == .loadingModel || pState == .recording || pState == .transcribing {
                self.pipeline.handleASRServiceInterruption()
            } else if wkState == .recording || wkState == .transcribing {
                self.whisperKitPipeline.handleASRServiceInterruption()
            }
            self.recordingOverlay.hide()
        }

        // Unified VAD auto-stop handler — routes to whichever pipeline is actively recording.
        // Fired by service-side VAD (XPC mode only). Same routing pattern as onEngineInterrupted.
        audioCapture.onVADAutoStop = { [weak self] in
            guard let self else { return }
            if self.pipeline.state == .recording {
                Task { await self.pipeline.stopAndTranscribe() }
            } else if self.whisperKitPipeline.state == .recording {
                Task { await self.whisperKitPipeline.stopAndTranscribe() }
            }
        }
        settingsSync.onNeedsPreloadObservation = { [weak self] in
            self?.startWhisperKitPreloadObservation()
        }

        // Wire custom words changes to pipeline sync
        customWordsCoordinator.onWordsChanged = { [weak self] words in
            guard let self else { return }
            self.pipeline.wordCorrection.customWords = words
            self.pipeline.llmPolish.customWords = words
            self.whisperKitPipeline.wordCorrection.customWords = words
            self.whisperKitPipeline.llmPolish.customWords = words
        }

        // Initialize logger
        Task {
            await AppLogger.shared.setLogLevel(settings.debugLogLevel)
            await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled)
        }

        // Sync WhisperKit setup service model variant
        whisperKitSetup.modelVariant = settings.whisperKitModel

        // Restore persisted backend selection (ASRManager defaults to .parakeet)
        if settings.selectedBackend != .parakeet {
            Task {
                await asrManager.switchBackend(to: settings.selectedBackend)
            }
        }

        // Wire settings change handler
        settings.onChange = { [weak self] key in
            guard let self else { return }
            self.settingsSync.handleSettingChanged(key, settings: self.settings)
        }

        // Wire pipeline state changes to overlay and icon
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(newState)
            // Hotkey management
            switch newState {
            case .recording:
                self.hotkeyService.registerCancelHotkey()
            case .loadingModel, .transcribing, .polishing, .error, .idle, .complete:
                self.isRecordingLocked = false
                self.hotkeyService.unregisterCancelHotkey()
            }
            // Intent-driven overlay — pipeline.overlayIntent maps state to the correct label
            self.recordingOverlay.show(
                intent: self.pipeline.overlayIntent,
                audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                isRecordingLocked: self.isRecordingLocked
            )
            if newState == .complete { self.transcriptCoordinator.load() }
        }

        // Wire WhisperKit pipeline state changes to overlay and icon
        whisperKitPipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            // Hotkey management
            switch newState {
            case .recording:
                self.hotkeyService.registerCancelHotkey()
            case .startingUp, .loadingModel, .transcribing, .polishing, .error, .idle, .ready, .complete:
                self.isRecordingLocked = false
                self.hotkeyService.unregisterCancelHotkey()
            }
            // Intent-driven overlay — pipeline.overlayIntent maps state to the correct label
            self.recordingOverlay.show(
                intent: self.whisperKitPipeline.overlayIntent,
                audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                isRecordingLocked: self.isRecordingLocked
            )
            if newState == .complete { self.transcriptCoordinator.load() }
        }

        // Wire hotkey callbacks
        hotkeyService.recordingMode = settings.recordingMode
        hotkeyService.cancelKeyCode = settings.cancelKeyCode
        hotkeyService.cancelModifiers = settings.cancelModifiers
        hotkeyService.toggleKeyCode = settings.toggleKeyCode
        hotkeyService.toggleModifiers = settings.toggleModifiers
        hotkeyService.onToggleRecording = { [weak self] in
            guard let self else { return }
            await self.toggleRecording()
        }
        hotkeyService.onStartRecording = { [weak self] in
            guard let self else { return }
            let isWhisperKit = self.asrManager.activeBackendType == .whisperKit
            let active = self.activePipeline

            if isWhisperKit {
                guard !self.whisperKitPipeline.state.isActive else { return }
                self.whisperKitPipeline.autoPasteToActiveApp = true
                self.whisperKitPipeline.autoCopyToClipboard = self.settings.autoCopyToClipboard
            } else {
                guard !self.pipelineState.isActive else { return }
                self.pipeline.autoPasteToActiveApp = true
                self.pipeline.autoCopyToClipboard = self.settings.autoCopyToClipboard
            }

            self.permissions.refreshAccessibilityStatus()
            if !self.permissions.hasAccessibilityPermission {
                if isWhisperKit {
                    self.whisperKitPipeline.autoPasteToActiveApp = false
                } else {
                    self.pipeline.autoPasteToActiveApp = false
                }
                self.permissions.restartMonitoringIfNeeded()
            }

            // Show recording overlay IMMEDIATELY for instant visual feedback.
            // The pipeline hasn't started yet, but the user needs to see the
            // overlay now — especially for double-press detection where they
            // need visual confirmation before tapping again.
            self.recordingOverlay.show(
                intent: .recording(audioLevel: 0),
                audioLevelProvider: { self.audioCapture.audioLevel },
                isRecordingLocked: false
            )

            await active.handle(event: .preWarm)
            guard !Task.isCancelled else {
                // PTT release arrived during preWarm — stop the engine that preWarm started
                self.audioCapture.abortPreWarm()
                self.recordingOverlay.show(intent: .hidden)
                return
            }
            await active.handle(event: .toggleRecording)

            if isWhisperKit {
                if case .error = self.whisperKitPipeline.state {
                    self.whisperKitPipeline.autoPasteToActiveApp = false
                }
            } else {
                if case .error = self.pipeline.state {
                    self.pipeline.autoPasteToActiveApp = false
                }
            }
        }
        hotkeyService.onStopRecording = { [weak self] in
            guard let self else { return }
            self.isRecordingLocked = false
            await self.activePipeline.handle(event: .requestStop)
            if self.asrManager.activeBackendType == .whisperKit {
                self.whisperKitPipeline.autoPasteToActiveApp = false
            } else {
                self.pipeline.autoPasteToActiveApp = false
            }
        }

        hotkeyService.onCancelRecording = { [weak self] in
            self?.isRecordingLocked = false
            await self?.cancelRecording()
        }

        hotkeyService.onIsProcessing = { [weak self] in
            guard let self else { return false }
            // Block during any state that means "still working on the last recording"
            if self.asrManager.activeBackendType == .whisperKit {
                let state = self.whisperKitPipeline.state
                return state == .transcribing || state == .polishing
            } else {
                let state = self.pipeline.state
                return state == .transcribing || state == .polishing
            }
        }

        hotkeyService.onLocked = { [weak self] in
            guard let self else { return }
            self.isRecordingLocked = true
            self.recordingOverlay.updateLockState(true)
            Task { await AppLogger.shared.log(
                "Hands-free mode activated — overlay expanding",
                level: .info, category: "AppState"
            ) }
        }

        // Pre-load WhisperKit model in background to eliminate cold-start delay.
        // Detect cached model state first (setupState starts as .checking), then observe for .ready.
        Task { [weak self] in
            await self?.whisperKitSetup.detectState()
            self?.startWhisperKitPreloadObservation()
        }

        // NOTE: hotkey registration is deferred to startHotkeyServiceIfEnabled(),
        // called from applicationDidFinishLaunching. Carbon RegisterEventHotKey
        // requires the NSApplication event loop to be running for event delivery.
    }

    /// Start the hotkey service. Must be called after the NSApplication event loop
    /// is running (e.g., from applicationDidFinishLaunching), because Carbon
    /// RegisterEventHotKey events are only delivered once the run loop is active.
    func startHotkeyServiceIfEnabled() {
        if settings.hotkeyEnabled {
            hotkeyService.start()
        }
    }

    /// Observe WhisperKitSetupService.setupState and pre-load the model when it becomes .ready.
    /// Uses withObservationTracking to react to @Observable property changes outside SwiftUI.
    private func startWhisperKitPreloadObservation() {
        whisperKitPreloadTask?.cancel()
        whisperKitPreloadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Check current state — if already .ready, trigger pre-load
                let currentState = self.whisperKitSetup.setupState
                if currentState == .ready {
                    await self.whisperKitPipeline.prepareBackendSilently()
                    return  // Model loaded — no need to keep observing
                }

                // Wait for the next change to setupState
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

    /// Active dictation pipeline — routes based on selected backend.
    var activePipeline: any DictationPipeline {
        asrManager.activeBackendType == .whisperKit ? whisperKitPipeline : pipeline
    }

    /// Convenience: current pipeline state.
    var pipelineState: PipelineState {
        pipeline.state
    }

    /// Convenience: the transcript from the latest recording.
    var activeTranscript: Transcript? {
        if let selected = transcriptCoordinator.selectedTranscriptID {
            return transcriptCoordinator.transcripts.first { $0.id == selected }
        }
        return pipeline.currentTranscript
    }

    /// Convenience: audio level for UI visualization.
    var audioLevel: Float {
        audioCapture.audioLevel
    }

    /// Human-readable model name for display.
    var activeModelName: String {
        settings.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
    }

    var activeLLMDisplayName: String {
        guard settings.llmProvider != .none else { return "LLM Deactivated" }
        let model = settings.llmProvider == .ollama ? settings.ollamaModel : settings.llmModel
        if model.isEmpty { return settings.llmProvider.displayName }
        // Use discoveredModels displayName if available, otherwise raw model ID
        if let info = llmDiscovery.discoveredModels.first(where: { $0.id == model }) {
            return info.displayName
        }
        return model
    }

    /// Model status text for sidebar display.
    var modelStatusText: String {
        if asrManager.activeBackendType == .whisperKit {
            switch whisperKitPipeline.state {
            case .loadingModel: return "Loading Model"
            case .recording: return "Recording"
            case .transcribing: return "Transcribing"
            case .polishing: return "Polishing"
            case .error: return "Error"
            default: break
            }
        } else {
            if pipelineState == .recording { return "Recording" }
            if pipelineState == .transcribing { return "Transcribing" }
            if pipelineState == .polishing { return "Polishing" }
            if case .error = pipelineState { return "Error" }
        }
        return asrManager.isModelLoaded ? "Loaded" : "Unloaded"
    }

    /// Toggle recording on/off (plain, no forced LLM).
    func toggleRecording() async {
        let active = activePipeline
        // Set auto-paste before toggle
        if active is WhisperKitPipeline {
            switch whisperKitPipeline.state {
            case .idle, .ready, .complete, .error:
                whisperKitPipeline.autoPasteToActiveApp = true
                permissions.refreshAccessibilityStatus()
                if !permissions.hasAccessibilityPermission {
                    whisperKitPipeline.autoPasteToActiveApp = false
                    permissions.restartMonitoringIfNeeded()
                }
            default: break
            }
        } else {
            switch pipeline.state {
            case .idle, .complete, .error:
                pipeline.autoPasteToActiveApp = true
                permissions.refreshAccessibilityStatus()
                if !permissions.hasAccessibilityPermission {
                    pipeline.autoPasteToActiveApp = false
                    permissions.restartMonitoringIfNeeded()
                }
            default: break
            }
        }

        await active.handle(event: .toggleRecording)

        // Clear auto-paste on completion/error
        if active is WhisperKitPipeline {
            if case .complete = whisperKitPipeline.state { whisperKitPipeline.autoPasteToActiveApp = false }
            if case .error = whisperKitPipeline.state { whisperKitPipeline.autoPasteToActiveApp = false }
        } else {
            if pipeline.state == .complete { pipeline.autoPasteToActiveApp = false }
            if case .error = pipeline.state { pipeline.autoPasteToActiveApp = false }
        }
    }

    /// Cancel an active recording, discarding all captured audio.
    func cancelRecording() async {
        isRecordingLocked = false
        recordingOverlay.hide()
        let isWhisperKit = asrManager.activeBackendType == .whisperKit
        if isWhisperKit {
            let wkState = whisperKitPipeline.state
            guard wkState == .recording || wkState == .loadingModel || wkState == .startingUp else { return }
            whisperKitPipeline.autoPasteToActiveApp = false
            await whisperKitPipeline.handle(event: .cancelRecording)
        } else {
            guard pipelineState == .recording else { return }
            pipeline.autoPasteToActiveApp = false
            await pipeline.cancelRecording()
        }
    }

    /// Polish an existing transcript with LLM. Stays in AppState as pipeline coordination forwarding.
    func polishTranscript(_ transcript: Transcript) async {
        if let updated = await pipeline.polishExistingTranscript(transcript) {
            if let idx = transcriptCoordinator.transcripts.firstIndex(where: { $0.id == updated.id }) {
                transcriptCoordinator.transcripts[idx] = updated
            }
        }
    }

    // Phase 5 B.1 validated 2026-03-16: batch round-trip 51-60ms across XPC.
    // Cold model load: 13,966ms. 3 warm back-to-back runs stable.
    // Test function in git history.
}
