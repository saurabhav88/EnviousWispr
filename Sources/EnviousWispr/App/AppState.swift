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

    // Pipeline — initialized after sub-systems
    let pipeline: TranscriptionPipeline

    /// Called when pipeline state changes — set by AppDelegate for icon updates.
    var onPipelineStateChange: ((PipelineState) -> Void)?

    // Transcript history
    var transcripts: [Transcript] = []
    private var loadTask: Task<Void, Never>?
    var searchQuery: String = ""
    var selectedTranscriptID: UUID?

    var filteredTranscripts: [Transcript] {
        guard !searchQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // Feature #8: custom word correction
    var customWords: [String] = []

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
        pipeline.wordCorrection.customWords = customWords

        // Initialize logger
        Task {
            await AppLogger.shared.setLogLevel(settings.debugLogLevel)
            await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled)
        }

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
                    audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                    modeLabel: self.settings.recordingMode.shortLabel
                )
            case .transcribing, .error, .idle:
                self.hotkeyService.unregisterCancelHotkey()
                self.recordingOverlay.hide()
            case .complete:
                self.hotkeyService.unregisterCancelHotkey()
                self.loadTranscripts()
            case .polishing:
                self.hotkeyService.unregisterCancelHotkey()
            }
        }

        // Wire hotkey callbacks
        hotkeyService.recordingMode = settings.recordingMode
        hotkeyService.cancelKeyCode = settings.cancelKeyCode
        hotkeyService.cancelModifiers = settings.cancelModifiers
        hotkeyService.toggleKeyCode = settings.toggleKeyCode
        hotkeyService.toggleModifiers = settings.toggleModifiers
        hotkeyService.pushToTalkKeyCode = settings.pushToTalkKeyCode
        hotkeyService.pushToTalkModifiers = settings.pushToTalkModifiers
        hotkeyService.onToggleRecording = { [weak self] in
            guard let self else { return }
            await self.toggleRecording()
        }
        hotkeyService.onStartRecording = { [weak self] in
            guard let self, !self.pipelineState.isActive else { return }
            self.pipeline.autoPasteToActiveApp = true
            await self.pipeline.startRecording()
        }
        hotkeyService.onStopRecording = { [weak self] in
            guard let self, self.pipelineState == .recording else { return }
            await self.pipeline.stopAndTranscribe()
            self.pipeline.autoPasteToActiveApp = false
        }

        hotkeyService.onCancelRecording = { [weak self] in
            await self?.cancelRecording()
        }

        if settings.hotkeyEnabled {
            hotkeyService.start()
        }
    }

    private func handleSettingChanged(_ key: SettingsManager.SettingKey) {
        switch key {
        case .selectedBackend:
            Task { await asrManager.switchBackend(to: settings.selectedBackend) }
        case .whisperKitModel:
            Task { await asrManager.updateWhisperKitModel(settings.whisperKitModel) }
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
        case .pushToTalkKeyCode:
            hotkeyService.pushToTalkKeyCode = settings.pushToTalkKeyCode
            reregisterHotkeys()
        case .pushToTalkModifiers:
            hotkeyService.pushToTalkModifiers = settings.pushToTalkModifiers
            reregisterHotkeys()
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
        case .isDebugModeEnabled:
            Task { await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled) }
        case .debugLogLevel:
            Task { await AppLogger.shared.setLogLevel(settings.debugLogLevel) }
        case .hasCompletedOnboarding:
            break
        }
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

    /// Cancel an active recording, discarding all captured audio.
    func cancelRecording() async {
        guard pipelineState == .recording else { return }
        pipeline.autoPasteToActiveApp = false
        pipeline.cancelRecording()
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
        try? customWordStore.add(word, to: &customWords)
        pipeline.wordCorrection.customWords = customWords
    }

    func removeCustomWord(_ word: String) {
        try? customWordStore.remove(word, from: &customWords)
        pipeline.wordCorrection.customWords = customWords
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
}
