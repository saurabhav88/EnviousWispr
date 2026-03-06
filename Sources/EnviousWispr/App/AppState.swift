import SwiftUI

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
    let customWordStore = CustomWordStore()
    let ollamaSetup = OllamaSetupService()
    let whisperKitSetup = WhisperKitSetupService()

    // Audio device management
    var availableInputDevices: [AudioInputDevice] = []
    private var deviceMonitor: AudioDeviceMonitor?

    // Pipeline — initialized after sub-systems
    let pipeline: TranscriptionPipeline

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

    var filteredTranscripts: [Transcript] {
        guard !searchQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // Feature #8: custom word correction
    var customWords: [String] = []
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
        // Load custom words
        customWords = (try? customWordStore.load()) ?? []

        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
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
        syncWhisperKitDecodingConfig()

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

        // Wire settings change handler
        settings.onChange = { [weak self] key in self?.handleSettingChanged(key) }

        // Wire pipeline state changes to overlay and icon
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(newState)
            switch newState {
            case .recording:
                self.hotkeyService.registerCancelHotkey()
                self.recordingOverlay.show(
                    audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 }
                )
            case .transcribing:
                self.hotkeyService.unregisterCancelHotkey()
                // Recording overlay stays visible — will transition to polishing
            case .polishing:
                self.hotkeyService.unregisterCancelHotkey()
                self.recordingOverlay.showPolishing()
            case .error, .idle:
                self.hotkeyService.unregisterCancelHotkey()
                self.recordingOverlay.hide()
            case .complete:
                self.hotkeyService.unregisterCancelHotkey()
                self.recordingOverlay.hide()
                self.loadTranscripts()
            }
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
            guard let self, !self.pipelineState.isActive else { return }
            self.pipeline.autoPasteToActiveApp = true
            self.pipeline.autoCopyToClipboard = self.settings.autoCopyToClipboard
            self.permissions.refreshAccessibilityStatus()
            if !self.permissions.hasAccessibilityPermission {
                self.pipeline.autoPasteToActiveApp = false
                self.restartAccessibilityMonitoringIfNeeded()
            }
            await self.pipeline.preWarmAudioInput()
            await self.pipeline.startRecording()
            if case .error = self.pipeline.state {
                self.pipeline.autoPasteToActiveApp = false
            }
        }
        hotkeyService.onStopRecording = { [weak self] in
            guard let self else { return }
            await self.pipeline.requestStop()
            self.pipeline.autoPasteToActiveApp = false
        }

        hotkeyService.onCancelRecording = { [weak self] in
            await self?.cancelRecording()
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
            let backend = settings.selectedBackend
            Task {
                await asrManager.switchBackend(to: backend)
                if backend == .whisperKit {
                    await whisperKitSetup.detectState()
                }
            }
        case .whisperKitModel:
            let model = settings.whisperKitModel
            whisperKitSetup.modelVariant = model
            Task {
                await asrManager.updateWhisperKitModel(model)
                await whisperKitSetup.forceDetectState()
            }
        case .recordingMode:
            hotkeyService.recordingMode = settings.recordingMode
        case .llmProvider:
            pipeline.llmPolish.llmProvider = settings.llmProvider
        case .llmModel:
            pipeline.llmPolish.llmModel = settings.llmModel
            if settings.llmProvider == .ollama {
                settings.ollamaModel = settings.llmModel
            }
        case .ollamaModel:
            if settings.llmProvider == .ollama {
                pipeline.llmPolish.llmModel = settings.ollamaModel
            }
        case .autoCopyToClipboard:
            pipeline.autoCopyToClipboard = settings.autoCopyToClipboard
        case .hotkeyEnabled:
            if settings.hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
        case .vadAutoStop:
            pipeline.vadAutoStop = settings.vadAutoStop
        case .vadSilenceTimeout:
            pipeline.vadSilenceTimeout = settings.vadSilenceTimeout
        case .environmentPreset:
            let sensitivity = settings.environmentPreset.vadSensitivity
            settings.vadSensitivity = sensitivity
        case .writingStylePreset:
            pipeline.llmPolish.polishInstructions = settings.activePolishInstructions
        case .vadSensitivity:
            pipeline.vadSensitivity = settings.vadSensitivity
        case .vadEnergyGate:
            pipeline.vadEnergyGate = settings.vadEnergyGate
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
            if settings.modelUnloadPolicy == .never {
                asrManager.cancelIdleTimer()
            }
        case .restoreClipboardAfterPaste:
            pipeline.restoreClipboardAfterPaste = settings.restoreClipboardAfterPaste
        case .customSystemPrompt:
            pipeline.llmPolish.polishInstructions = settings.activePolishInstructions
        case .wordCorrectionEnabled:
            pipeline.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
        case .fillerRemovalEnabled:
            pipeline.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
        case .isDebugModeEnabled:
            Task { await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled) }
        case .debugLogLevel:
            Task { await AppLogger.shared.setLogLevel(settings.debugLogLevel) }
        case .useExtendedThinking:
            pipeline.llmPolish.useExtendedThinking = settings.useExtendedThinking
        case .whisperKitTemperature, .whisperKitCompressionThreshold,
             .whisperKitLogProbThreshold, .whisperKitNoSpeechThreshold:
            syncWhisperKitDecodingConfig()
        case .whisperKitLanguageAutoDetect:
            syncTranscriptionOptions()
            syncWhisperKitDecodingConfig()
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

    /// Sync shared transcription options (language, timestamps) to the pipeline.
    private func syncTranscriptionOptions() {
        var opts = TranscriptionOptions()
        opts.language = settings.whisperKitLanguageAutoDetect ? nil : "en"
        pipeline.transcriptionOptions = opts
    }

    /// Sync WhisperKit-specific decoding config to its backend.
    private func syncWhisperKitDecodingConfig() {
        let config = WhisperKitDecodingConfig(
            temperature: settings.whisperKitTemperature,
            compressionRatioThreshold: settings.whisperKitCompressionThreshold,
            logProbThreshold: settings.whisperKitLogProbThreshold,
            noSpeechThreshold: settings.whisperKitNoSpeechThreshold
        )
        Task { await asrManager.updateWhisperKitDecodingConfig(config) }
    }

    /// Re-register Carbon hotkeys after a config change.
    private func reregisterHotkeys() {
        guard hotkeyService.isEnabled else { return }
        hotkeyService.stop()
        hotkeyService.start()
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
        if pipelineState == .recording { return "Recording" }
        if pipelineState == .transcribing { return "Transcribing" }
        if pipelineState == .polishing { return "Polishing" }
        if case .error = pipelineState { return "Error" }
        return asrManager.isModelLoaded ? "Loaded" : "Unloaded"
    }

    /// Toggle recording on/off (plain, no forced LLM).
    func toggleRecording() async {
        switch pipeline.state {
        case .idle, .complete, .error:
            pipeline.autoPasteToActiveApp = true
            permissions.refreshAccessibilityStatus()
            if !permissions.hasAccessibilityPermission {
                pipeline.autoPasteToActiveApp = false
                restartAccessibilityMonitoringIfNeeded()
            }
        default:
            break
        }

        await pipeline.toggleRecording()

        if pipeline.state == .complete {
            pipeline.autoPasteToActiveApp = false
        } else if case .error = pipeline.state {
            pipeline.autoPasteToActiveApp = false
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
        guard pipelineState == .recording else { return }
        // Immediately hide the overlay before any async suspension. If show()
        // queued a deferred createPanel via DispatchQueue.main.async, the
        // generation counter increment here prevents it from executing after we
        // return. Without this, there is a window where cancelRecording() awaits
        // pipeline.cancelRecording() and the deferred createPanel fires first,
        // leaving a visible panel even though state transitions to .idle.
        recordingOverlay.hide()
        pipeline.autoPasteToActiveApp = false
        await pipeline.cancelRecording()
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
            try customWordStore.add(word, to: &customWords)
            pipeline.wordCorrection.customWords = customWords
            customWordError = nil
        } catch {
            customWordError = error.localizedDescription
        }
    }

    func removeCustomWord(_ word: String) {
        do {
            try customWordStore.remove(word, from: &customWords)
            pipeline.wordCorrection.customWords = customWords
            customWordError = nil
        } catch {
            customWordError = error.localizedDescription
        }
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
