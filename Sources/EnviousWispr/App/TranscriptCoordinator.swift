import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

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

  init(store: TranscriptStore) {
    self.store = store
  }

  func load() {
    loadTask?.cancel()
    loadTask = Task {
      do {
        let diskRows = try await store.loadAll()
        // Phase C union-by-ID merge. Preserve any in-memory rows whose IDs
        // are not yet on disk (append-during-load race window) in their
        // existing order, then append disk rows. Protects the newest-first
        // invariant under multiple concurrent completions while a slow
        // startup load is still running.
        let diskIDs = Set(diskRows.map(\.id))
        let inFlightRows = transcripts.filter { !diskIDs.contains($0.id) }
        transcripts = inFlightRows + diskRows
      } catch {
        await AppLogger.shared.log(
          "Failed to load transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  func waitForLoadForTesting() async {
    await loadTask?.value
  }

  /// Append a just-completed transcript to the in-memory cache.
  ///
  /// Precondition: the transcript has already been persisted by
  /// `TranscriptFinalizer.save(_:)`. This method does no disk I/O. Caller
  /// must not invoke it twice for the same transcript — duplicate-ID
  /// protection would mask heart-path bugs.
  func append(_ transcript: Transcript) {
    transcripts.insert(transcript, at: 0)
  }

  func delete(_ transcript: Transcript) {
    do {
      try store.delete(id: transcript.id)
      transcripts.removeAll { $0.id == transcript.id }
      if selectedTranscriptID == transcript.id {
        selectedTranscriptID = nil
      }
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to delete transcript: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  func deleteAll() {
    do {
      try store.deleteAll()
      transcripts.removeAll()
      selectedTranscriptID = nil
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to delete all transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }
}
