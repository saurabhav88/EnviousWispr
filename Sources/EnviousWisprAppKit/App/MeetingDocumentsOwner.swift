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
/// **Never over unseen notes.** A draft is saved over the file only once this session read
/// and reconciled it (`loaded`); before that, or after a read failed, the draft is saved by
/// `saveDraftNotes`, which reads and saves in one file operation. **A deletion fences.**
/// `forget` moves the meeting's generation, and every step after an await checks it, so a
/// read or a save that finishes after a deletion never brings the entry back.
///
/// Notes save one debounce interval after the last change; `flush` saves at once and says
/// whether the notes are durable; `flushForQuit` saves inside the quit's shared deadline
/// (best effort). `hasPendingWork` is true from a change until its save was answered, so a
/// relaunch waits for typed notes.
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

  enum LoadState: Equatable {
    case notLoaded
    case loading
    case loaded
    /// The read failed; the draft is kept and saved only by a read-and-save operation.
    case failed
  }

  /// One meeting's documents as this session knows them.
  struct Entry: Equatable {
    /// The notes as typed (the draft), saved or not.
    var notes = ""
    var summary: String?
    /// The manifest as last read or written.
    var manifest = MeetingDocumentsManifest()
    /// Changes typed since the notes were last read or saved.
    var unsavedEdits = 0
    /// Changes typed into the summary since it was last read or saved.
    var unsavedSummaryEdits = 0
    var load = LoadState.notLoaded
  }

  /// What `ensureNotesDurable` found.
  enum Durability: Equatable {
    /// No notes, in the draft or on disk.
    case none
    /// Notes exist and are saved.
    case saved
    /// Notes exist, and the newest of them could not be saved.
    case failed
    /// The notes file could not be read and nothing was typed: notes may exist on disk.
    case unknown
  }

  private(set) var entries: [UUID: Entry] = [:]
  private let writer: MeetingFileWriter
  private let deps: Dependencies
  private var generations: [UUID: Int] = [:]
  /// Meetings deleted this session: nothing creates an entry for them again (ids are never
  /// reused), so a Stop or a late caller after the deletion does nothing.
  private var forgotten: Set<UUID> = []
  /// Fences `fenceEmptyForRemoval` set and `reopen` may still undo, by token. A deletion
  /// (`forget`) removes the token, so a late `reopen` never undoes it (Codex C7 r3).
  private var temporaryFences: [UUID: UUID] = [:]
  private var debounceTasks: [UUID: Task<Void, Never>] = [:]
  private var summaryDebounceTasks: [UUID: Task<Void, Never>] = [:]
  private var loadTasks: [UUID: Task<Void, Never>] = [:]
  /// Reads and saves on their way, per meeting.
  private var operations: [UUID: Int] = [:]
  /// Each meeting's saves run one after another, each reading the entry fresh.
  private var saveChains: [UUID: Task<Void, Never>] = [:]

  init(writer: MeetingFileWriter, dependencies: Dependencies) {
    self.writer = writer
    self.deps = dependencies
  }

  // MARK: - Reads

  func notes(_ meetingID: UUID) -> String { entries[meetingID]?.notes ?? "" }
  func summary(_ meetingID: UUID) -> String? { entries[meetingID]?.summary }
  func manifest(_ meetingID: UUID) -> MeetingDocumentsManifest? { entries[meetingID]?.manifest }
  func loadState(_ meetingID: UUID) -> LoadState { entries[meetingID]?.load ?? .notLoaded }

  /// Whether the notes box may take typing: only once the saved notes are read and shown, so
  /// nobody types into an apparently empty box over notes not yet on screen (Codex C8 r1).
  func canEdit(_ meetingID: UUID) -> Bool { entries[meetingID]?.load == .loaded }

  /// Notes typed and not yet saved.
  func hasUnsavedNotes(_ meetingID: UUID) -> Bool { (entries[meetingID]?.unsavedEdits ?? 0) > 0 }

  /// Typed notes or summary edits are not yet saved, or a save is on its way: a relaunch must
  /// wait. A draft whose save failed keeps it waiting until a save succeeds (Codex C7 r2); a
  /// draft typed before its first read counts from the keystroke. A plain read with nothing
  /// typed (the launch read for notes search) does not hold a relaunch: losing it loses nothing.
  var hasPendingWork: Bool {
    entries.values.contains { $0.unsavedEdits > 0 || $0.unsavedSummaryEdits > 0 }
      || !debounceTasks.isEmpty || !summaryDebounceTasks.isEmpty
      || !saveChains.isEmpty || operations.values.contains { $0 > 0 }
  }

  /// Summary edits typed and not yet saved.
  func hasUnsavedSummary(_ meetingID: UUID) -> Bool {
    (entries[meetingID]?.unsavedSummaryEdits ?? 0) > 0
  }

  private func generation(_ meetingID: UUID) -> Int { generations[meetingID] ?? 0 }

  /// The meeting was deleted this session.
  func isForgotten(_ meetingID: UUID) -> Bool { forgotten.contains(meetingID) }

  // MARK: - Load

  /// Reads and reconciles the meeting's documents once per session; true when loaded. A draft
  /// typed before the read finished wins over the file and is saved after it.
  @discardableResult
  func load(_ meetingID: UUID) async -> Bool {
    guard !forgotten.contains(meetingID) else { return false }
    switch entries[meetingID]?.load ?? .notLoaded {
    case .loaded: return true
    case .loading:
      await loadTasks[meetingID]?.value
      return entries[meetingID]?.load == .loaded
    case .notLoaded, .failed:
      break
    }
    let gen = generation(meetingID)
    entries[meetingID, default: Entry()].load = .loading
    let task = Task { await readFromDisk(meetingID, generation: gen) }
    loadTasks[meetingID] = task
    await task.value
    if generation(meetingID) == gen { loadTasks[meetingID] = nil }
    return entries[meetingID]?.load == .loaded
  }

  private func readFromDisk(_ meetingID: UUID, generation gen: Int) async {
    let result = await perform(meetingID, counted: false) {
      try $0.loadDocuments(meeting: meetingID)
    }
    guard generation(meetingID) == gen, var entry = entries[meetingID] else { return }
    switch result {
    case .failure(let error):
      deps.log("meeting documents unreadable error=\(type(of: error))")
      entry.load = .failed
      entries[meetingID] = entry
    case .success(let loaded):
      entry.manifest = loaded.manifest
      if entry.unsavedSummaryEdits == 0 { entry.summary = loaded.summary }
      if entry.unsavedEdits == 0 { entry.notes = loaded.notes }
      entry.load = .loaded
      entries[meetingID] = entry
      if entry.unsavedEdits > 0 { scheduleSave(meetingID) }
    }
  }

  // MARK: - Notes

  /// The user's typing. Saved one debounce interval after the last change.
  func setNotes(_ meetingID: UUID, _ text: String) {
    guard !forgotten.contains(meetingID) else { return }
    var entry = entries[meetingID] ?? Entry()
    guard entry.notes != text else { return }
    entry.notes = text
    entry.unsavedEdits += 1
    entries[meetingID] = entry
    switch entry.load {
    case .loaded, .failed:
      scheduleSave(meetingID)
    case .notLoaded:
      // The file is read first; the read schedules the save.
      Task { await load(meetingID) }
    case .loading:
      break
    }
  }

  private func scheduleSave(_ meetingID: UUID) {
    debounceTasks[meetingID]?.cancel()
    let debounce = deps.debounce
    let gen = generation(meetingID)
    debounceTasks[meetingID] = Task { [weak self] in
      await debounce()
      guard let self, !Task.isCancelled, self.generation(meetingID) == gen else { return }
      self.debounceTasks[meetingID] = nil
      await self.saveNotes(meetingID)
    }
  }

  /// Saves the notes now (Stop, leaving the detail view). True when the notes are durable.
  @discardableResult
  func flush(_ meetingID: UUID) async -> Bool {
    guard !forgotten.contains(meetingID) else { return false }
    debounceTasks.removeValue(forKey: meetingID)?.cancel()
    // A meeting this session never touched is `notLoaded` too: its file is read first.
    let state = entries[meetingID]?.load ?? .notLoaded
    if state == .notLoaded || state == .loading {
      await load(meetingID)
      // A draft typed before the read is still unsaved; the read scheduled a debounced save.
      debounceTasks.removeValue(forKey: meetingID)?.cancel()
    }
    await saveNotes(meetingID)
    return !hasUnsavedNotes(meetingID)
  }

  /// Notes the meeting has, made durable first (#3972 R53, Codex C7 r1): the notes-only state
  /// is published only for notes that are saved.
  func ensureNotesDurable(_ meetingID: UUID) async -> Durability {
    guard !forgotten.contains(meetingID) else { return .unknown }
    let durable = await flush(meetingID)
    guard let entry = entries[meetingID] else { return .unknown }
    // A failed save comes first: `.none` means confirmed, saved emptiness (Codex C7 r3), so an
    // emptied draft that could not be saved is `.failed`, never `.none`.
    guard durable else { return .failed }
    if entry.notes.isEmpty {
      return entry.load == .loaded ? .none : .unknown
    }
    return .saved
  }

  /// Queues one save behind the meeting's previous one, and waits for it.
  private func saveNotes(_ meetingID: UUID) async {
    let previous = saveChains[meetingID]
    let task = Task { [weak self] in
      await previous?.value
      await self?.saveOnce(meetingID)
    }
    saveChains[meetingID] = task
    await task.value
    if saveChains[meetingID] == task { saveChains[meetingID] = nil }
  }

  private func saveOnce(_ meetingID: UUID) async {
    guard let entry = entries[meetingID], entry.unsavedEdits > 0 else { return }
    let text = entry.notes
    let edits = entry.unsavedEdits
    let gen = generation(meetingID)
    /// The manifest the save wrote, and the documents as read when the save read them first.
    let result: Result<(MeetingDocumentsManifest, MeetingStore.LoadedDocuments?), Error>
    switch entry.load {
    case .loaded:
      let revision = (entry.manifest.notes?.revision ?? 0) + edits
      result = await perform(meetingID) {
        (try $0.saveNotes(text, revision: revision, meeting: meetingID), nil)
      }
    case .failed, .notLoaded:
      result = await perform(meetingID) {
        let saved = try $0.saveDraftNotes(text, edits: edits, meeting: meetingID)
        return (saved.manifest, saved)
      }
    case .loading:
      return
    }
    guard generation(meetingID) == gen, var current = entries[meetingID] else { return }
    switch result {
    case .failure(let error):
      deps.log("meeting notes save failed error=\(type(of: error))")
    case .success(let (manifest, read)):
      if let read {
        // The save read the documents: the entry is now fully loaded from that read.
        current.manifest = manifest
        if current.unsavedSummaryEdits == 0 { current.summary = read.summary }
        current.load = .loaded
      } else {
        current.manifest.notes = manifest.notes
      }
      // Typing during the save stays unsaved.
      current.unsavedEdits = max(0, current.unsavedEdits - edits)
      entries[meetingID] = current
    }
  }

  // MARK: - Summary

  /// The user's edit of the summary (#3972 R46): the summary becomes the user's own text, which
  /// a generated one never replaces without the user's confirmation. Saved one debounce interval
  /// after the last change, only once this session read the documents (`canEdit`).
  func setSummary(_ meetingID: UUID, _ text: String) {
    guard !forgotten.contains(meetingID), var entry = entries[meetingID], entry.load == .loaded,
      entry.summary != text
    else { return }
    entry.summary = text
    entry.unsavedSummaryEdits += 1
    entries[meetingID] = entry
    summaryDebounceTasks[meetingID]?.cancel()
    let debounce = deps.debounce
    let gen = generation(meetingID)
    summaryDebounceTasks[meetingID] = Task { [weak self] in
      await debounce()
      guard let self, !Task.isCancelled, self.generation(meetingID) == gen else { return }
      self.summaryDebounceTasks[meetingID] = nil
      await self.saveSummaryEdit(meetingID)
    }
  }

  /// Saves the summary edit now (leaving the detail view, before Write again). True when
  /// nothing typed into the summary is left unsaved.
  @discardableResult
  func flushSummary(_ meetingID: UUID) async -> Bool {
    guard !forgotten.contains(meetingID) else { return false }
    summaryDebounceTasks.removeValue(forKey: meetingID)?.cancel()
    await saveSummaryEdit(meetingID)
    return !hasUnsavedSummary(meetingID)
  }

  /// Queues one summary save behind the meeting's previous save (notes or summary), and waits.
  private func saveSummaryEdit(_ meetingID: UUID) async {
    let previous = saveChains[meetingID]
    let task = Task { [weak self] in
      await previous?.value
      await self?.saveSummaryOnce(meetingID)
    }
    saveChains[meetingID] = task
    await task.value
    if saveChains[meetingID] == task { saveChains[meetingID] = nil }
  }

  private func saveSummaryOnce(_ meetingID: UUID) async {
    guard let entry = entries[meetingID], entry.unsavedSummaryEdits > 0,
      let text = entry.summary
    else { return }
    let edits = entry.unsavedSummaryEdits
    // The inputs stay: an edited generated summary still shows out of date when the meeting
    // changed (R60).
    let inputs = entry.manifest.summary?.inputs
    let gen = generation(meetingID)
    let result = await perform(meetingID) {
      try $0.saveSummary(text, origin: .userEdited, inputs: inputs, meeting: meetingID)
    }
    guard generation(meetingID) == gen, var current = entries[meetingID] else { return }
    switch result {
    case .failure(let error):
      deps.log("meeting summary edit save failed error=\(type(of: error))")
    case .success(let manifest):
      current.manifest.summary = manifest.summary
      current.manifest.summaryPending = manifest.summaryPending
      current.unsavedSummaryEdits = max(0, current.unsavedSummaryEdits - edits)
      entries[meetingID] = current
    }
  }

  /// Saves a generated summary through the store's checked write (#3972 R46): never over the
  /// user's own summary unless it is exactly the text the user approved replacing
  /// (`approvedUserEdit`, its SHA-256), never from older notes, and it ends the owed mark. Nil
  /// when the meeting was deleted or the write failed.
  func publishGeneratedSummary(
    _ meetingID: UUID, text: String, inputs: SummaryInputs, approvedUserEdit: String?
  ) async -> MeetingStore.GeneratedSummarySave? {
    guard !forgotten.contains(meetingID) else { return nil }
    // Typing in the summary not yet saved is saved first: it is the user's text, so the
    // checked write below keeps it.
    // If that save fails, nothing is published: the typing stays the newest text.
    if hasUnsavedSummary(meetingID) {
      guard await flushSummary(meetingID) else { return nil }
    }
    let gen = generation(meetingID)
    let result = await perform(meetingID) {
      try $0.saveGeneratedSummary(
        text, inputs: inputs, approvedUserEdit: approvedUserEdit, meeting: meetingID)
    }
    guard generation(meetingID) == gen else { return nil }
    switch result {
    case .failure(let error):
      deps.log("meeting summary save failed error=\(type(of: error))")
      return nil
    case .success(let outcome):
      if var entry = entries[meetingID], entry.load == .loaded {
        switch outcome {
        case .saved(let manifest):
          entry.manifest.summary = manifest.summary
          // Typing that arrived during the write stays on screen; its own save (already
          // scheduled) then writes it over the generated text as the user's.
          if entry.unsavedSummaryEdits == 0 { entry.summary = text }
          entry.manifest.summaryPending = manifest.summaryPending
        case .userEditKept(let manifest), .notesChanged(let manifest):
          entry.manifest.summaryPending = manifest.summaryPending
        }
        entries[meetingID] = entry
      }
      return outcome
    }
  }

  /// Marks a summary as owed or no longer owed (#3972 R50). False when the meeting was deleted
  /// or the write failed.
  @discardableResult
  func setSummaryPending(_ meetingID: UUID, _ pending: Bool) async -> Bool {
    guard !forgotten.contains(meetingID) else { return false }
    let gen = generation(meetingID)
    let result = await perform(meetingID) { try $0.setSummaryPending(pending, meeting: meetingID) }
    guard generation(meetingID) == gen else { return false }
    switch result {
    case .failure(let error):
      deps.log("meeting summary mark failed error=\(type(of: error))")
      return false
    case .success(let manifest):
      if var entry = entries[meetingID], entry.load == .loaded {
        entry.manifest.summaryPending = manifest.summaryPending
        entries[meetingID] = entry
      }
      return true
    }
  }

  /// The quit path: every unsaved draft is written behind the queued file work, no later than
  /// `deadline`. Best effort within that deadline; a write still running finishes on its own.
  func flushForQuit(deadline: DispatchTime) {
    for task in debounceTasks.values { task.cancel() }
    debounceTasks.removeAll()
    for task in summaryDebounceTasks.values { task.cancel() }
    summaryDebounceTasks.removeAll()
    for (meetingID, entry) in entries where entry.unsavedSummaryEdits > 0 {
      guard let text = entry.summary else { continue }
      let inputs = entry.manifest.summary?.inputs
      let outcome = writer.runBounded(
        until: deadline,
        { _ = try $0.saveSummary(text, origin: .userEdited, inputs: inputs, meeting: meetingID) },
        late: { _ in })
      if case .finished(.failure(let error)) = outcome {
        deps.log("meeting summary quit save failed error=\(type(of: error))")
      }
    }
    for (meetingID, entry) in entries where entry.unsavedEdits > 0 {
      let text = entry.notes
      let edits = entry.unsavedEdits
      let loaded = entry.load == .loaded
      let revision = (entry.manifest.notes?.revision ?? 0) + edits
      let outcome = writer.runBounded(
        until: deadline,
        {
          if loaded {
            _ = try $0.saveNotes(text, revision: revision, meeting: meetingID)
          } else {
            _ = try $0.saveDraftNotes(text, edits: edits, meeting: meetingID)
          }
        },
        late: { _ in })
      if case .finished(.failure(let error)) = outcome {
        deps.log("meeting notes quit save failed error=\(type(of: error))")
      }
    }
  }

  /// For removing a meeting that recorded nothing (failed Start): true only when its notes are
  /// read, empty, unchanged and nothing is on its way, and then, in the same main-actor step,
  /// no further edit is accepted (Codex C7 r2). False means notes may exist: keep the folder.
  /// The returned token lets `reopen` undo this fence, and only this one, if the removal fails.
  func fenceEmptyForRemoval(_ meetingID: UUID) -> UUID? {
    guard let entry = entries[meetingID], entry.load == .loaded, entry.notes.isEmpty,
      entry.unsavedEdits == 0, debounceTasks[meetingID] == nil, loadTasks[meetingID] == nil,
      saveChains[meetingID] == nil, (operations[meetingID] ?? 0) == 0
    else { return nil }
    forget(meetingID)
    let token = UUID()
    temporaryFences[meetingID] = token
    return token
  }

  /// The removal `fenceEmptyForRemoval` allowed did not happen: the meeting accepts notes
  /// again, unless a deletion fenced it since (its token is then gone).
  func reopen(_ meetingID: UUID, token: UUID) {
    guard temporaryFences[meetingID] == token else { return }
    temporaryFences[meetingID] = nil
    forgotten.remove(meetingID)
  }

  /// The meeting was deleted: its drafts and pending work go with it, and nothing on its way
  /// may bring them back.
  func forget(_ meetingID: UUID) {
    generations[meetingID] = generation(meetingID) + 1
    forgotten.insert(meetingID)
    // Permanent from here: no earlier temporary fence may be undone.
    temporaryFences[meetingID] = nil
    debounceTasks.removeValue(forKey: meetingID)?.cancel()
    summaryDebounceTasks.removeValue(forKey: meetingID)?.cancel()
    loadTasks.removeValue(forKey: meetingID)
    saveChains.removeValue(forKey: meetingID)
    entries.removeValue(forKey: meetingID)
  }

  /// One file operation, counted in `hasPendingWork` until it answered.
  private func perform<T: Sendable>(
    _ meetingID: UUID, counted: Bool = true,
    _ work: @escaping @Sendable (MeetingStore) throws -> T
  ) async -> Result<T, Error> {
    if counted { operations[meetingID, default: 0] += 1 }
    defer {
      if counted {
        operations[meetingID, default: 1] -= 1
        if operations[meetingID] == 0 { operations[meetingID] = nil }
      }
    }
    do {
      return .success(try await writer.run(work))
    } catch {
      return .failure(error)
    }
  }
}
