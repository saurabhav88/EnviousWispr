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
    let soundManager = SoundManager()
    let recordingOverlay = RecordingOverlayPanel()

    // Pipeline — initialized after sub-systems
    private(set) var pipeline: TranscriptionPipeline!

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

    var audioCuesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioCuesEnabled, forKey: "audioCuesEnabled")
            soundManager.isEnabled = audioCuesEnabled
        }
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
        audioCuesEnabled = defaults.object(forKey: "audioCuesEnabled") as? Bool ?? true
        soundManager.isEnabled = audioCuesEnabled

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

        // Wire pipeline state changes to overlay + sounds
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .recording:
                self.soundManager.playStartSound()
                self.recordingOverlay.show(audioLevelProvider: { [weak self] in
                    self?.audioCapture.audioLevel ?? 0
                })
            case .transcribing:
                self.soundManager.playStopSound()
                self.recordingOverlay.hide()
            case .complete:
                self.soundManager.playCompleteSound()
            case .error:
                self.soundManager.playErrorSound()
                self.recordingOverlay.hide()
            case .idle:
                self.recordingOverlay.hide()
            case .polishing:
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
        await pipeline.toggleRecording()
        if pipeline.state == .complete {
            loadTranscripts()
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
        try? transcriptStore.delete(id: transcript.id)
        transcripts.removeAll { $0.id == transcript.id }
        if selectedTranscriptID == transcript.id {
            selectedTranscriptID = nil
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
}
