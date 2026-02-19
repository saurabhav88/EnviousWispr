import SwiftUI

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
    // Sub-systems
    let permissions = PermissionsService()
    let audioCapture = AudioCaptureManager()
    let asrManager = ASRManager()
    let transcriptStore = TranscriptStore()
    let keychainManager = KeychainManager()
    let hotkeyService = HotkeyService()
    let benchmark = BenchmarkSuite()
    let recordingOverlay = RecordingOverlayPanel()

    // Pipeline — initialized after sub-systems
    let pipeline: TranscriptionPipeline

    /// Called when pipeline state changes — set by AppDelegate for icon updates.
    var onPipelineStateChange: ((PipelineState) -> Void)?

    // Transcript history
    var transcripts: [Transcript] = []
    var searchQuery: String = ""
    var selectedTranscriptID: UUID?

    var filteredTranscripts: [Transcript] {
        guard !searchQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // Settings (persisted via UserDefaults)
    var selectedBackend: ASRBackendType {
        didSet {
            UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selectedBackend")
            Task { await asrManager.switchBackend(to: selectedBackend) }
        }
    }

    var whisperKitModel: String {
        didSet {
            UserDefaults.standard.set(whisperKitModel, forKey: "whisperKitModel")
            Task { await asrManager.updateWhisperKitModel(whisperKitModel) }
        }
    }

    var recordingMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode")
            hotkeyService.recordingMode = recordingMode
        }
    }

    var llmProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider")
            pipeline.llmProvider = llmProvider
        }
    }

    var llmModel: String {
        didSet {
            UserDefaults.standard.set(llmModel, forKey: "llmModel")
            pipeline.llmModel = llmModel
        }
    }

    var autoCopyToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard")
            pipeline.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    var hotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled")
            if hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
        }
    }

    var vadAutoStop: Bool {
        didSet {
            UserDefaults.standard.set(vadAutoStop, forKey: "vadAutoStop")
            pipeline.vadAutoStop = vadAutoStop
        }
    }

    var vadSilenceTimeout: Double {
        didSet {
            UserDefaults.standard.set(vadSilenceTimeout, forKey: "vadSilenceTimeout")
            pipeline.vadSilenceTimeout = vadSilenceTimeout
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

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
        // Load persisted settings
        let defaults = UserDefaults.standard
        selectedBackend = ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
        whisperKitModel = defaults.string(forKey: "whisperKitModel") ?? "large-v3"
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .pushToTalk
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .none
        llmModel = defaults.string(forKey: "llmModel") ?? "gpt-4o-mini"
        autoCopyToClipboard = defaults.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        hotkeyEnabled = defaults.object(forKey: "hotkeyEnabled") as? Bool ?? true
        vadAutoStop = defaults.object(forKey: "vadAutoStop") as? Bool ?? false
        vadSilenceTimeout = defaults.object(forKey: "vadSilenceTimeout") as? Double ?? 1.5
        hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? false
        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        pipeline.autoCopyToClipboard = autoCopyToClipboard
        pipeline.llmProvider = llmProvider
        pipeline.llmModel = llmModel
        pipeline.vadAutoStop = vadAutoStop
        pipeline.vadSilenceTimeout = vadSilenceTimeout
        // Wire pipeline state changes to overlay and icon
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(newState)
            switch newState {
            case .recording:
                self.recordingOverlay.show(audioLevelProvider: { [weak self] in
                    self?.audioCapture.audioLevel ?? 0
                })
            case .transcribing, .error, .idle:
                self.recordingOverlay.hide()
            case .complete, .polishing:
                break
            }
        }

        // Wire hotkey callbacks
        hotkeyService.recordingMode = recordingMode
        hotkeyService.onToggleRecording = { [weak self] in
            await self?.toggleRecording()
        }
        hotkeyService.onStartRecording = { [weak self] in
            guard let self, !self.pipelineState.isActive else { return }
            // Push-to-talk: paste directly into the active app after transcription
            self.pipeline.autoPasteToActiveApp = true
            await self.pipeline.startRecording()
        }
        hotkeyService.onStopRecording = { [weak self] in
            guard let self, self.pipelineState == .recording else { return }
            await self.pipeline.stopAndTranscribe()
            self.pipeline.autoPasteToActiveApp = false
            self.loadTranscripts()
        }

        if hotkeyEnabled {
            hotkeyService.start()
        }
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

    /// Toggle recording on/off.
    func toggleRecording() async {
        // Enable paste-to-active-app when starting a new recording
        // (push-to-talk sets this in its own callbacks, but toggle/UI buttons need it too)
        switch pipeline.state {
        case .idle, .complete, .error:
            pipeline.autoPasteToActiveApp = true
        default:
            break
        }

        await pipeline.toggleRecording()

        // Reset paste flag and reload transcripts when pipeline finishes
        if pipeline.state == .complete {
            pipeline.autoPasteToActiveApp = false
            loadTranscripts()
        } else if case .error = pipeline.state {
            pipeline.autoPasteToActiveApp = false
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
            print("Failed to delete transcript: \(error)")
        }
    }

    /// Load transcript history from disk.
    func loadTranscripts() {
        do {
            transcripts = try transcriptStore.loadAll()
        } catch {
            print("Failed to load transcripts: \(error)")
        }
    }

    /// Validate an API key and discover available models for the given provider.
    func validateKeyAndDiscoverModels(provider: LLMProvider) async {
        keyValidationState = .validating
        isDiscoveringModels = true

        let keychainId = provider == .openAI ? "openai-api-key" : "gemini-api-key"
        guard let apiKey = try? keychainManager.retrieve(key: keychainId), !apiKey.isEmpty else {
            keyValidationState = .invalid("No API key found")
            isDiscoveringModels = false
            return
        }

        let discovery = LLMModelDiscovery()
        do {
            let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
            discoveredModels = models
            cacheModels(models, for: provider)
            keyValidationState = .valid

            // Auto-select first available model if current selection is invalid
            if !models.contains(where: { $0.id == llmModel && $0.isAvailable }) {
                if let firstAvailable = models.first(where: { $0.isAvailable }) {
                    llmModel = firstAvailable.id
                }
            }
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
