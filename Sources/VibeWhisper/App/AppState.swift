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

    var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode") }
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

    init() {
        // Load persisted settings
        let defaults = UserDefaults.standard
        selectedBackend = ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .pushToTalk
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .none
        llmModel = defaults.string(forKey: "llmModel") ?? "gpt-4o-mini"
        autoCopyToClipboard = defaults.object(forKey: "autoCopyToClipboard") as? Bool ?? true

        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        pipeline.autoCopyToClipboard = autoCopyToClipboard
        pipeline.llmProvider = llmProvider
        pipeline.llmModel = llmModel
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
            // Update the transcript in the list
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
