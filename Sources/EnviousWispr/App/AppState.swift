import SwiftUI
import EnviousWisprCore
import EnviousWisprStorage
import EnviousWisprPostProcessing
import EnviousWisprAudio

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
    // Settings
    var settings = SettingsManager()

    // Sub-systems
    let permissions = PermissionsService()
    let audioCapture = AudioCaptureManager()
    let asrManager = ASRManager()
    let transcriptStore = TranscriptStore()
    let keychainManager = KeychainManager()
    let hotkeyService = HotkeyService()
    let benchmark = BenchmarkSuite()
    let recordingOverlay = RecordingOverlayPanel()
    let customWordsManager = CustomWordsManager()
    let ollamaSetup = OllamaSetupService()
    let whisperKitSetup = WhisperKitSetupService()

    // Audio device management
    var availableInputDevices: [AudioInputDevice] = []
    private var deviceMonitor: AudioDeviceMonitor?

    /// Background task that observes WhisperKitSetupService.setupState and pre-loads the model when ready.
    private var whisperKitPreloadTask: Task<Void, Never>?

    // Pipelines — initialized after sub-systems
    let pipeline: TranscriptionPipeline
    let whisperKitPipeline: WhisperKitPipeline

    /// Called when pipeline state changes — set by AppDelegate for icon updates.
    var onPipelineStateChange: ((PipelineState) -> Void)?

    /// Called when accessibility permission status changes — set by AppDelegate for icon updates.
    var onAccessibilityChange: (() -> Void)?

    // Accessibility monitoring
    private var accessibilityMonitorTask: Task<Void, Never>?

    // Transcript history
    var transcripts: [Transcript] = []
    private var loadTask: Task<Void, Never>?
    var searchQuery: String = ""
    var selectedTranscriptID: UUID?
    var pendingNavigationSection: SettingsSection?

    /// True when recording is in hands-free (locked) mode via double-press.
    /// Read by the overlay to switch to the expanded lips visual.
    var isRecordingLocked: Bool = false

    var filteredTranscripts: [Transcript] {
        guard !searchQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // Feature #8: custom word correction
    var customWords: [CustomWord] = []
    var customWordError: String?

    // Model discovery
    var discoveredModels: [LLMModelInfo] = []
    var isDiscoveringModels = false
    var keyValidationState: KeyValidationState = .idle

    enum KeyValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    init() {
        // Load custom words (nil = I/O failure, keep default empty array to prevent data loss)
        customWords = customWordsManager.load() ?? []

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
        pipeline.llmPolish.useExtendedThinking = settings.useExtendedThinking
        // Sync WhisperKit pipeline settings
        syncWhisperKitPipelineSettings()
        // Build engine with correct noise suppression config from the start.
        // This sets noiseSuppressionEnabled and configures anti-ducking if needed.
        if settings.noiseSuppression {
            audioCapture.buildEngine(noiseSuppression: true)
        } else {
            audioCapture.noiseSuppressionEnabled = false
        }
        audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
        audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
        syncTranscriptionOptions()

        // Enumerate input devices and monitor for changes
        refreshInputDevices()
        deviceMonitor = AudioDeviceMonitor { [weak self] in
            Task { @MainActor in
                self?.refreshInputDevices()
            }
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
        settings.onChange = { [weak self] key in self?.handleSettingChanged(key) }

        // Wire pipeline state changes to overlay and icon
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(newState)
            // Hotkey management
            switch newState {
            case .recording:
                self.hotkeyService.registerCancelHotkey()
            case .transcribing, .polishing, .error, .idle, .complete:
                self.isRecordingLocked = false
                self.hotkeyService.unregisterCancelHotkey()
            }
            // Intent-driven overlay — pipeline.overlayIntent maps state to the correct label
            self.recordingOverlay.show(
                intent: self.pipeline.overlayIntent,
                audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                isRecordingLocked: self.isRecordingLocked
            )
            if newState == .complete { self.loadTranscripts() }
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
            if newState == .complete { self.loadTranscripts() }
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
                self.restartAccessibilityMonitoringIfNeeded()
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

    private func handleSettingChanged(_ key: SettingsManager.SettingKey) {
        switch key {
        case .selectedBackend:
            // Don't switch backends while a pipeline is actively recording/transcribing
            let parakeetActive = pipelineState.isActive
            let whisperKitActive = whisperKitPipeline.state.isActive
            if parakeetActive || whisperKitActive {
                Task { await AppLogger.shared.log(
                    "Backend switch blocked — pipeline is active",
                    level: .info, category: "AppState"
                ) }
                break
            }
            let backend = settings.selectedBackend
            Task {
                await asrManager.switchBackend(to: backend)
                if backend == .whisperKit {
                    await whisperKitSetup.detectState()
                    // Re-observe setupState to pre-load model when ready
                    startWhisperKitPreloadObservation()
                }
            }
        case .whisperKitModel:
            let model = settings.whisperKitModel
            whisperKitSetup.modelVariant = model
            Task {
                await asrManager.updateWhisperKitModel(model)
                await whisperKitSetup.forceDetectState()
                // Re-observe setupState to pre-load new model variant when ready
                startWhisperKitPreloadObservation()
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
        case .vadSilenceTimeout:
            pipeline.vadSilenceTimeout = settings.vadSilenceTimeout
            whisperKitPipeline.vadSilenceTimeout = settings.vadSilenceTimeout
        case .environmentPreset:
            let sensitivity = settings.environmentPreset.vadSensitivity
            settings.vadSensitivity = sensitivity
        case .writingStylePreset:
            pipeline.llmPolish.polishInstructions = settings.activePolishInstructions
            whisperKitPipeline.llmPolish.polishInstructions = settings.activePolishInstructions
        case .vadSensitivity:
            pipeline.vadSensitivity = settings.vadSensitivity
            whisperKitPipeline.vadSensitivity = settings.vadSensitivity
        case .vadEnergyGate:
            pipeline.vadEnergyGate = settings.vadEnergyGate
            whisperKitPipeline.vadEnergyGate = settings.vadEnergyGate
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
            syncTranscriptionOptions()
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
                    self?.audioCapture.buildEngine(noiseSuppression: self?.settings.noiseSuppression ?? false)
                }
            } else {
                audioCapture.buildEngine(noiseSuppression: settings.noiseSuppression)
            }
        case .onboardingState, .hasCompletedOnboarding:
            break
        }
    }

    /// Sync shared transcription options (language, timestamps) to both pipelines.
    private func syncTranscriptionOptions() {
        var opts = TranscriptionOptions()
        // Parakeet is English-only; WhisperKit uses the user's selected language.
        // Pass the language to both pipelines — Parakeet ignores it, WhisperKit
        // passes it through to DecodingOptions.
        opts.language = settings.whisperKitLanguage
        pipeline.transcriptionOptions = opts
        whisperKitPipeline.transcriptionOptions = opts
    }

    /// Sync all user-facing settings to the WhisperKit pipeline.
    private func syncWhisperKitPipelineSettings() {
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
        whisperKitPipeline.vadAutoStop = settings.vadAutoStop
        whisperKitPipeline.vadSilenceTimeout = settings.vadSilenceTimeout
        whisperKitPipeline.vadSensitivity = settings.vadSensitivity
        whisperKitPipeline.vadEnergyGate = settings.vadEnergyGate
        whisperKitPipeline.modelUnloadPolicy = settings.modelUnloadPolicy
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

    /// Re-register Carbon hotkeys after a config change.
    private func reregisterHotkeys() {
        guard hotkeyService.isEnabled else { return }
        hotkeyService.stop()
        hotkeyService.start()
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
        if let selected = selectedTranscriptID {
            return transcripts.first { $0.id == selected }
        }
        return pipeline.currentTranscript
    }

    /// Convenience: audio level for UI visualization.
    var audioLevel: Float {
        audioCapture.audioLevel
    }

    /// Total transcript count for sidebar stats.
    var transcriptCount: Int { transcripts.count }

    /// Average processing speed across all transcripts (seconds).
    var averageProcessingSpeed: Double {
        let withTimes = transcripts.filter { $0.processingTime > 0 }
        guard !withTimes.isEmpty else { return 0 }
        return withTimes.map(\.processingTime).reduce(0, +) / Double(withTimes.count)
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
        if let info = discoveredModels.first(where: { $0.id == model }) {
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
                    restartAccessibilityMonitoringIfNeeded()
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
                    restartAccessibilityMonitoringIfNeeded()
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

    /// Check Accessibility permission on launch (no prompt, no polling side-effects).
    /// If Accessibility is denied on launch, reset any previous warning dismissal —
    /// the binary may have been rebuilt, invalidating the previous TCC grant.
    func refreshAccessibilityOnLaunch() {
        permissions.refreshAccessibilityStatus()
        if !permissions.accessibilityGranted {
            permissions.resetAccessibilityWarningDismissal()
        }
    }

    /// Start smart polling for Accessibility permission.
    ///
    /// Polls every `TimingConstants.accessibilityPollIntervalSec` seconds, but ONLY
    /// while `accessibilityGranted == false`. Once the user grants access the loop
    /// exits and the task completes. A new monitoring task is started automatically
    /// if permission is later revoked (detected via `restartAccessibilityMonitoringIfNeeded`).
    func startAccessibilityMonitoring() {
        // Already monitoring or already granted — no work needed.
        guard accessibilityMonitorTask == nil || accessibilityMonitorTask?.isCancelled == true else { return }
        guard !permissions.accessibilityGranted else { return }

        accessibilityMonitorTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(TimingConstants.accessibilityPollIntervalSec * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.permissions.refreshAccessibilityStatus()
                if self.permissions.accessibilityGranted {
                    // Fire the callback first so observers see consistent state
                    // (task still non-nil = monitoring was active). Nil it out
                    // after so restartAccessibilityMonitoringIfNeeded cannot
                    // observe the intermediate state where task is nil but
                    // accessibilityGranted hasn't propagated yet.
                    self.onAccessibilityChange?()
                    self.accessibilityMonitorTask = nil
                    return
                }
            }
        }
    }

    /// Restart accessibility monitoring if not already running and permission is missing.
    ///
    /// Call this after a failed paste attempt or after detecting that permission may
    /// have been revoked, to ensure the polling loop resumes.
    func restartAccessibilityMonitoringIfNeeded() {
        let taskDone = accessibilityMonitorTask == nil || accessibilityMonitorTask?.isCancelled == true
        guard taskDone && !permissions.accessibilityGranted else { return }
        startAccessibilityMonitoring()
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

    /// Polish an existing transcript with LLM.
    func polishTranscript(_ transcript: Transcript) async {
        if let updated = await pipeline.polishExistingTranscript(transcript) {
            if let idx = transcripts.firstIndex(where: { $0.id == updated.id }) {
                transcripts[idx] = updated
            }
        }
    }

    /// Delete a transcript.
    func deleteTranscript(_ transcript: Transcript) {
        do {
            try transcriptStore.delete(id: transcript.id)
            transcripts.removeAll { $0.id == transcript.id }
            if selectedTranscriptID == transcript.id {
                selectedTranscriptID = nil
            }
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to delete transcript: \(error)",
                level: .info, category: "AppState"
            ) }
        }
    }

    func deleteAllTranscripts() {
        do {
            try transcriptStore.deleteAll()
            transcripts.removeAll()
            selectedTranscriptID = nil
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to delete all transcripts: \(error)",
                level: .info, category: "AppState"
            ) }
        }
    }

    /// Load transcript history from disk asynchronously.
    func loadTranscripts() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                transcripts = try await transcriptStore.loadAll()
            } catch {
                await AppLogger.shared.log(
                    "Failed to load transcripts: \(error)",
                    level: .info, category: "AppState"
                )
            }
        }
    }

    // Feature #8: custom word management
    func addCustomWord(_ word: String) {
        do {
            try customWordsManager.add(canonical: word, to: &customWords)
            syncCustomWordsToPipelines()
            customWordError = nil
        } catch {
            customWordError = error.localizedDescription
        }
    }

    func removeCustomWord(_ id: UUID) {
        do {
            try customWordsManager.remove(id: id, from: &customWords)
            syncCustomWordsToPipelines()
            customWordError = nil
        } catch {
            customWordError = error.localizedDescription
        }
    }

    /// Convenience: remove by canonical string (used by legacy callers).
    func removeCustomWord(_ word: String) {
        guard let match = customWords.first(where: { $0.canonical == word }) else { return }
        removeCustomWord(match.id)
    }

    func updateCustomWord(_ word: CustomWord) {
        do {
            try customWordsManager.update(word: word, in: &customWords)
            syncCustomWordsToPipelines()
            customWordError = nil
        } catch {
            customWordError = error.localizedDescription
        }
    }

    private func syncCustomWordsToPipelines() {
        pipeline.wordCorrection.customWords = customWords
        whisperKitPipeline.wordCorrection.customWords = customWords
    }

    /// Validate an API key and discover available models for the given provider.
    func validateKeyAndDiscoverModels(provider: LLMProvider) async {
        keyValidationState = .validating
        isDiscoveringModels = true

        let apiKey: String
        if provider == .ollama || provider == .appleIntelligence {
            apiKey = ""
        } else {
            let keychainId = provider == .openAI ? KeychainManager.openAIKeyID : KeychainManager.geminiKeyID
            guard let key = try? keychainManager.retrieve(key: keychainId), !key.isEmpty else {
                keyValidationState = .invalid("No API key found")
                isDiscoveringModels = false
                return
            }
            apiKey = key
        }

        let discovery = LLMModelDiscovery()
        do {
            let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
            discoveredModels = models
            if provider != .appleIntelligence {
                cacheModels(models, for: provider)
            }
            keyValidationState = .valid

            if !models.contains(where: { $0.id == settings.llmModel && $0.isAvailable }) {
                if let firstAvailable = models.first(where: { $0.isAvailable }) {
                    settings.llmModel = firstAvailable.id
                    if provider == .ollama { settings.ollamaModel = firstAvailable.id }
                }
            }
        } catch LLMError.providerUnavailable {
            keyValidationState = .invalid(
                provider == .ollama
                    ? "Ollama is not running. Start it with: ollama serve"
                    : "Apple Intelligence not available on this system."
            )
            discoveredModels = []
        } catch let error as LLMError where error == .invalidAPIKey {
            keyValidationState = .invalid("Invalid API key")
            discoveredModels = []
        } catch {
            keyValidationState = .invalid(error.localizedDescription)
            discoveredModels = []
        }

        isDiscoveringModels = false
    }

    /// Load cached models from UserDefaults for the given provider.
    func loadCachedModels(for provider: LLMProvider) {
        let key = "cachedModels_\(provider.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let models = try? JSONDecoder().decode([LLMModelInfo].self, from: data) else {
            discoveredModels = []
            return
        }
        discoveredModels = models
    }

    private func cacheModels(_ models: [LLMModelInfo], for provider: LLMProvider) {
        let key = "cachedModels_\(provider.rawValue)"
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Refresh the list of available audio input devices.
    func refreshInputDevices() {
        availableInputDevices = AudioDeviceEnumerator.allInputDevices()
    }
}
