import Foundation
import Observation
import EnviousWisprCore
import EnviousWisprStorage

/// Manages transcript history state, search, and persistence.
@MainActor @Observable
final class TranscriptCoordinator {
    var transcripts: [Transcript] = []
    var searchQuery: String = ""
    var selectedTranscriptID: UUID?

    private let store: TranscriptStore
    private var loadTask: Task<Void, Never>?

    var filteredTranscripts: [Transcript] {
        guard !searchQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var transcriptCount: Int { transcripts.count }

    var averageProcessingSpeed: Double {
        let withTimes = transcripts.filter { $0.processingTime > 0 }
        guard !withTimes.isEmpty else { return 0 }
        return withTimes.map(\.processingTime).reduce(0, +) / Double(withTimes.count)
    }

    init(store: TranscriptStore) {
        self.store = store
    }

    func load() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                transcripts = try await store.loadAll()
            } catch {
                await AppLogger.shared.log(
                    "Failed to load transcripts: \(error)",
                    level: .info, category: "TranscriptCoordinator"
                )
            }
        }
    }

    func delete(_ transcript: Transcript) {
        do {
            try store.delete(id: transcript.id)
            transcripts.removeAll { $0.id == transcript.id }
            if selectedTranscriptID == transcript.id {
                selectedTranscriptID = nil
            }
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to delete transcript: \(error)",
                level: .info, category: "TranscriptCoordinator"
            ) }
        }
    }

    func deleteAll() {
        do {
            try store.deleteAll()
            transcripts.removeAll()
            selectedTranscriptID = nil
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to delete all transcripts: \(error)",
                level: .info, category: "TranscriptCoordinator"
            ) }
        }
    }
}
