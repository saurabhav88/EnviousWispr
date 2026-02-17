import SwiftUI

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
    // Sub-systems
    let permissions = PermissionsService()
    let asrManager = ASRManager()
    let transcriptStore = TranscriptStore()

    // Pipeline state
    var pipelineState: PipelineState = .idle
    var activePartialText: String = ""
    var activeTranscript: Transcript?

    // Transcript history
    var transcripts: [Transcript] = []
    var searchQuery: String = ""

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

    /// Load transcript history from disk.
    func loadTranscripts() {
        do {
            transcripts = try transcriptStore.loadAll()
        } catch {
            print("Failed to load transcripts: \(error)")
        }
    }
}
