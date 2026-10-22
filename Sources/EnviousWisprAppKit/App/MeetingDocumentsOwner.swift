import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// The one owner of each meeting's notes and summary in memory (#3972 R46, R53), held by
/// `MeetingCoordinator`. Drafts live here, not in a view, so closing the detail view never
/// loses typing. Every write goes through the coordinator's `MeetingFileWriter`, in order with
/// the meeting's other file operations, and the store refuses a meeting that is gone, being
/// deleted, or newer, so a late write never brings a deleted meeting back.
///
/// Notes save one debounce interval after the last change; `flush` saves at once (Stop, leaving
/// the detail view), and `flushForQuit` saves inside the quit's shared deadline (best effort).
@MainActor
@Observable
final class MeetingDocumentsOwner {
  struct Dependencies {
    /// Waits one debounce interval: one second in the app, a gate in tests.
    var debounce: @Sendable () async -> Void = {
      try? await Task.sleep(for: .seconds(1))
    }
    var log: @MainActor (String) -> Void
  }

  /// One meeting's documents as this session knows them.
  struct Entry: Equatable {
    /// The notes as typed (the draft), saved or not.
    var notes = ""
    var summary: String?
    /// The manifest as last written (or read).
    var manifest = MeetingDocumentsManifest()
    /// The notes revision of the draft; above `manifest.notes?.revision` while unsaved.
    var notesRevision = 0
    var loaded = false
  }

  private(set) var entries: [UUID: Entry] = [:]
  private let writer: MeetingFileWriter
  private let deps: Dependencies
  private var debounceTasks: [UUID: Task<Void, Never>] = [:]
  private var loadTasks: [UUID: Task<Void, Never>] = [:]

  init(writer: MeetingFileWriter, dependencies: Dependencies) {
    self.writer = writer
    self.deps = dependencies
  }

  // MARK: - Reads

  func notes(_ meetingID: UUID) -> String { entries[meetingID]?.notes ?? "" }
  func summary(_ meetingID: UUID) -> String? { entries[meetingID]?.summary }
  func manifest(_ meetingID: UUID) -> MeetingDocumentsManifest? { entries[meetingID]?.manifest }

  /// Notes not yet saved.
  func hasUnsavedNotes(_ meetingID: UUID) -> Bool {
    guard let entry = entries[meetingID] else { return false }
    return entry.notesRevision != (entry.manifest.notes?.revision ?? 0)
  }

  /// Whether the meeting has notes, in the draft or on disk (read when not yet loaded).
  func notesExist(_ meetingID: UUID) async -> Bool {
    await load(meetingID)
    return !(entries[meetingID]?.notes.isEmpty ?? true)
  }

  /// Reads the meeting's documents once per session. A draft typed before the read finished
  /// wins over the file; a manifest the read repaired is saved.
  func load(_ meetingID: UUID) async {
    if entries[meetingID]?.loaded == true { return }
    if let task = loadTasks[meetingID] {
      await task.value
      return
    }
    let task = Task { await readFromDisk(meetingID) }
    loadTasks[meetingID] = task
    await task.value
    loadTasks[meetingID] = nil
  }

  private func readFromDisk(_ meetingID: UUID) async {
    let loaded: MeetingStore.LoadedDocuments
    do {
      loaded = try await writer.run { try $0.loadDocuments(meeting: meetingID) }
    } catch {
      deps.log("meeting documents unreadable error=\(type(of: error))")
      // Marked loaded so a draft can still be typed; its save refuses a missing meeting.
      entries[meetingID, default: Entry()].loaded = true
      return
    }
    var entry = entries[meetingID] ?? Entry()
    let typedMeanwhile = entry.notesRevision > 0
    entry.manifest = loaded.manifest
    entry.summary = loaded.summary
    if typedMeanwhile {
      entry.notesRevision = (loaded.manifest.notes?.revision ?? 0) + entry.notesRevision
    } else {
      entry.notes = loaded.notes
      entry.notesRevision = loaded.manifest.notes?.revision ?? 0
    }
    entry.loaded = true
    entries[meetingID] = entry
    if loaded.repaired {
      let manifest = loaded.manifest
      do {
        try await writer.run { try $0.saveManifest(manifest, meeting: meetingID) }
      } catch {
        deps.log("meeting documents repair failed error=\(type(of: error))")
      }
    }
    if typedMeanwhile { scheduleSave(meetingID) }
  }

  // MARK: - Notes

  /// The user's typing. Saved one debounce interval after the last change.
  func setNotes(_ meetingID: UUID, _ text: String) {
    var entry = entries[meetingID] ?? Entry()
    guard entry.notes != text else { return }
    entry.notes = text
    entry.notesRevision += 1
    entries[meetingID] = entry
    guard entry.loaded else {
      // The file is read first, so the draft is never saved over notes it has not seen.
      Task { await load(meetingID) }
      return
    }
    scheduleSave(meetingID)
  }

  private func scheduleSave(_ meetingID: UUID) {
    debounceTasks[meetingID]?.cancel()
    let debounce = deps.debounce
    debounceTasks[meetingID] = Task { [weak self] in
      await debounce()
      guard !Task.isCancelled else { return }
      await self?.saveNotes(meetingID)
    }
  }

  /// Saves the notes now (Stop, leaving the detail view).
  func flush(_ meetingID: UUID) async {
    debounceTasks[meetingID]?.cancel()
    debounceTasks[meetingID] = nil
    await saveNotes(meetingID)
  }

  private func saveNotes(_ meetingID: UUID) async {
    guard let entry = entries[meetingID], entry.loaded, hasUnsavedNotes(meetingID) else { return }
    let text = entry.notes
    let revision = entry.notesRevision
    do {
      let written = try await writer.run {
        try $0.saveNotes(text, revision: revision, meeting: meetingID)
      }
      // Only the newest write's manifest may stand; typing since then stays a draft.
      guard var current = entries[meetingID],
        (current.manifest.notes?.revision ?? 0) < revision
      else { return }
      current.manifest.notes = written.notes
      entries[meetingID] = current
    } catch {
      deps.log("meeting notes save failed error=\(type(of: error))")
    }
  }

  /// The quit path: every unsaved draft is written behind the queued file work, no later than
  /// `deadline`. Best effort within that deadline; a write still running finishes on its own.
  func flushForQuit(deadline: DispatchTime) {
    for task in debounceTasks.values { task.cancel() }
    debounceTasks.removeAll()
    for (meetingID, entry) in entries where entry.loaded && hasUnsavedNotes(meetingID) {
      let text = entry.notes
      let revision = entry.notesRevision
      let outcome = writer.runBounded(
        until: deadline, { _ = try $0.saveNotes(text, revision: revision, meeting: meetingID) },
        late: { _ in })
      if case .finished(.failure(let error)) = outcome {
        deps.log("meeting notes quit save failed error=\(type(of: error))")
      }
    }
  }

  /// The meeting was deleted: its drafts and pending saves go with it.
  func forget(_ meetingID: UUID) {
    debounceTasks.removeValue(forKey: meetingID)?.cancel()
    entries.removeValue(forKey: meetingID)
  }
}
