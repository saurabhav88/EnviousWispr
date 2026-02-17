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

    // Settings
    var selectedBackend: ASRBackendType = .parakeet
    var recordingMode: RecordingMode = .pushToTalk
    var llmProvider: LLMProvider = .none
    var autoCopyToClipboard: Bool = true

    init() {
        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
            transcriptStore: transcriptStore
        )
        pipeline.autoCopyToClipboard = autoCopyToClipboard
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
        // Refresh transcript list after transcription completes
        if pipeline.state == .complete {
            loadTranscripts()
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
