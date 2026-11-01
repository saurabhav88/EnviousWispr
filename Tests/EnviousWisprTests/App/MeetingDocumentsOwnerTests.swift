import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3972 R46, R53, R56 (build chunk C7): when these fail, meeting notes the user typed are lost
/// (on quit, on a failed recording, by closing the view, or by a relaunch), a deleted meeting's
/// notes come back, a meeting says "your notes are kept" before they are, or a meeting with no
/// audio is transcribed again on every launch.
@MainActor
@Suite("Meeting notes owner", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingDocumentsOwnerTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  /// The notes debounce as a gate: any number of waiters, each released by `open()` or by its
  /// own task's cancellation, so a cancelled debounce never stays parked.
  @MainActor
  @Observable
  final class DebounceGate {
    private(set) var waiting = 0
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var opened = false

    func wait() async {
      guard !opened else { return }
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          guard !opened, !Task.isCancelled else {
            continuation.resume()
            return
          }
          waiters[id] = continuation
          waiting += 1
        }
      } onCancel: {
        Task { @MainActor in self.release(id) }
      }
    }

    private func release(_ id: UUID) {
      guard let continuation = waiters.removeValue(forKey: id) else { return }
      waiting -= 1
      continuation.resume()
    }

    /// Releases every waiter now and every later one at once. Also the test's shutdown.
    func open() {
      opened = true
      for id in Array(waiters.keys) { release(id) }
    }
  }

  /// A coordinator whose notes debounce waits on `gate`, or returns at once when nil.
  static func coordinator(_ harness: Harness, gate: DebounceGate? = nil) -> MeetingCoordinator {
    var deps = harness.dependencies()
    deps.notesDebounce = { [gate] in await gate?.wait() }
    return MeetingCoordinator(dependencies: deps)
  }

  static func notesOnDisk(_ harness: Harness, _ meetingID: UUID) -> String? {
    try? String(contentsOf: harness.store.notesURL(for: meetingID), encoding: .utf8)
  }

  /// Holds the meeting file queue until `release` is signalled, so a read or a save is provably
  /// in flight.
  static func holdFileQueue() -> DispatchSemaphore {
    let release = DispatchSemaphore(value: 0)
    // deadline-fallback: the test signals the release; 20 s only frees the queue if it never does.
    MeetingFileWriter.queue.async { _ = release.wait(timeout: .now() + 20) }
    return release
  }

  /// Makes the first document read fail; saves that must read first also fail. Loaded writes
  /// can replace an empty directory, so use a read-only parent to fail a write after loading.
  static func breakNotesWrites(_ harness: Harness, _ meetingID: UUID) throws {
    try FileManager.default.createDirectory(
      at: harness.store.notesURL(for: meetingID), withIntermediateDirectories: false)
  }

  @Test("notes save one debounce after the last change, and only the newest text is kept")
  func debouncedSave() async throws {
    let harness = try Harness()
    let gate = DebounceGate()
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    let documents = coordinator.documents
    await documents.load(meetingID)

    documents.setNotes(meetingID, "Bud")
    documents.setNotes(meetingID, "Budget")
    await MeetingCoordinatorTests.eventually("debounce parked") { gate.waiting == 1 }
    #expect(Self.notesOnDisk(harness, meetingID) == nil, "nothing is saved before the debounce")
    #expect(documents.hasPendingWork, "a relaunch waits for typed notes")

    gate.open()
    await MeetingCoordinatorTests.eventually("saved") {
      !documents.hasUnsavedNotes(meetingID) && !documents.hasPendingWork
    }
    #expect(Self.notesOnDisk(harness, meetingID) == "Budget")
    await coordinator.stop()
  }

  @Test("typed notes hold a relaunch: during the first read, the debounce and the write")
  func relaunchWaitsForNotes() async throws {
    let harness = try Harness()
    let gate = DebounceGate()
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await MeetingCoordinatorTests.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && !coordinator.isWorkInFlight
    }

    // The first read held: typing before it answers.
    let hold = Self.holdFileQueue()
    coordinator.documents.setNotes(meetingID, "Action items")
    await MeetingWorkAdmission.waitUntil { coordinator.documents.hasPendingWork }
    #expect(coordinator.isWorkInFlight)
    hold.signal()
    // Then the debounce.
    await MeetingCoordinatorTests.eventually("debounce parked") { gate.waiting == 1 }
    #expect(coordinator.isWorkInFlight)
    // Then the write.
    gate.open()
    await MeetingCoordinatorTests.eventually("saved, nothing pending") {
      !coordinator.documents.hasUnsavedNotes(meetingID) && !coordinator.isWorkInFlight
    }
    #expect(Self.notesOnDisk(harness, meetingID) == "Action items")
  }

  @Test("Stop saves the notes at once, also before the first read answered")
  func stopFlushes() async throws {
    let harness = try Harness()
    let gate = DebounceGate()  // not opened before the asserts
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    // No load first: Stop must read, then save.
    coordinator.documents.setNotes(meetingID, "Decisions: ship Friday")
    await coordinator.stop()
    #expect(Self.notesOnDisk(harness, meetingID) == "Decisions: ship Friday")
    #expect(coordinator.documents.hasUnsavedNotes(meetingID) == false)
  }

  @Test("quit saves unsaved notes and summary inside its deadline, read first or not")
  func quitFlushes() async throws {
    let harness = try Harness()
    let gate = DebounceGate()
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let first = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await MeetingCoordinatorTests.eventually("ready") {
      coordinator.record(id: first)?.state == .ready
    }
    await coordinator.documents.load(first)
    coordinator.documents.setNotes(first, "Follow up with legal")
    coordinator.documents.setSummary(first, "Reviewed at quit")
    #expect(coordinator.documents.hasUnsavedSummary(first))
    #expect(try harness.store.loadDocuments(meeting: first).summary != "Reviewed at quit")

    // A second meeting whose notes were never read this session, with notes on disk; its
    // read stays queued behind the held file queue when quit starts.
    var second = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    second.state = .failed
    try harness.store.create(second)
    _ = try harness.store.saveNotes("on disk", revision: 3, meeting: second.id)
    let hold = Self.holdFileQueue()
    coordinator.documents.setNotes(second.id, "typed at quit")
    hold.signal()
    coordinator.prepareForTermination(deadline: .now() + 5)

    #expect(Self.notesOnDisk(harness, first) == "Follow up with legal")
    #expect(try harness.store.loadDocuments(meeting: first).summary == "Reviewed at quit")
    #expect(Self.notesOnDisk(harness, second.id) == "typed at quit")
    #expect(try harness.store.loadDocuments(meeting: second.id).manifest.notes?.revision ?? 0 > 3)
  }

  @Test("notes typed before the file was read are kept, numbered after what was on disk")
  func draftBeforeLoad() async throws {
    let harness = try Harness()
    let coordinator = Self.coordinator(harness)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    _ = try harness.store.saveNotes("old", revision: 4, meeting: meetingID)

    coordinator.documents.setNotes(meetingID, "new")
    // `eventually` re-checks on observed changes: read the owner's state, not only the file.
    await MeetingCoordinatorTests.eventually("saved") {
      coordinator.documents.manifest(meetingID)?.notes?.revision == 5
    }
    #expect(Self.notesOnDisk(harness, meetingID) == "new")
    await coordinator.stop()
  }

  @Test("a read that failed never lets a draft replace notes it did not see")
  func failedReadKeepsUnseenNotes() async throws {
    let harness = try Harness()
    let coordinator = Self.coordinator(harness)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    _ = try harness.store.saveNotes("seen by nobody", revision: 2, meeting: meetingID)
    let good = try Data(contentsOf: harness.store.documentsURL(for: meetingID))
    try Data("not json".utf8).write(to: harness.store.documentsURL(for: meetingID))

    #expect(await coordinator.documents.load(meetingID) == false)
    #expect(coordinator.documents.loadState(meetingID) == .failed)
    coordinator.documents.setNotes(meetingID, "typed")
    #expect(await coordinator.documents.flush(meetingID) == false, "the save read the bad file")
    #expect(Self.notesOnDisk(harness, meetingID) == "seen by nobody")

    // Readable again: the draft saves after what was on disk.
    try good.write(to: harness.store.documentsURL(for: meetingID))
    #expect(await coordinator.documents.flush(meetingID))
    #expect(Self.notesOnDisk(harness, meetingID) == "typed")
    #expect(try harness.store.loadDocuments(meeting: meetingID).manifest.notes?.revision ?? 0 > 2)
    await coordinator.stop()
  }

  @Test("deleting a meeting during a held read or debounce leaves nothing behind")
  func deleteFences() async throws {
    let harness = try Harness()
    let gate = DebounceGate()
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)

    let hold = Self.holdFileQueue()
    coordinator.documents.setNotes(meetingID, "secret")
    await MeetingWorkAdmission.waitUntil {
      coordinator.documents.loadState(meetingID) == .loading
    }
    let deletion = Task { await coordinator.delete(meetingID: meetingID) }
    hold.signal()
    await deletion.value
    gate.open()
    await MeetingCoordinatorTests.eventually("nothing pending") {
      !coordinator.documents.hasPendingWork && coordinator.queuedFileOperations == 0
    }
    #expect(coordinator.documents.entries[meetingID] == nil, "the late read did not bring it back")
    #expect(!FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path))
  }

  @Test("no audio with notes is notes-only once the notes are saved, never queued again")
  func notesOnlyNeedsSavedNotes() async throws {
    let harness = try Harness()
    var empty = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(empty)
    empty.state = .queued
    try harness.store.save(empty)
    _ = try harness.store.saveNotes("Kept", revision: 1, meeting: empty.id)

    // Unreadable audio and notes: failed, Retry still offered.
    var damaged = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(damaged)
    damaged.state = .queued
    try harness.store.save(damaged)
    _ = try harness.store.saveNotes("Also kept", revision: 1, meeting: damaged.id)
    let name = MeetingSegmentNaming.fileName(
      track: .microphone, index: 1, startMs: 0, partial: false)
    try Data(repeating: 7, count: 4_096).write(
      to: harness.store.folder(for: damaged.id).appendingPathComponent(name))

    let coordinator = Self.coordinator(harness)
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("both settled") {
      coordinator.record(id: empty.id)?.state == .notesOnly
        && coordinator.record(id: damaged.id)?.state == .failed
    }
    let notesOnly = try harness.store.load(id: empty.id)
    // #3973 C2: a new record starts at the current format; marking it notes-only never lowers it.
    #expect(notesOnly.formatVersion == MeetingRecord.currentFormatVersion)
    #expect(notesOnly.failureCode == "no_audio")
    #expect(Self.notesOnDisk(harness, empty.id) == "Kept")
    let notesOnlyActions = MeetingsPresentation.actions(
      notesOnly, isActive: false, canTranscribeAgain: coordinator.canTranscribeAgain(empty.id))
    #expect(notesOnlyActions.transcribeAgain == false)
    #expect(notesOnlyActions.deleteAudio == false)

    let failed = try harness.store.load(id: damaged.id)
    #expect(failed.failureCode == "audio_unreadable")
    #expect(coordinator.canTranscribeAgain(damaged.id))
    #expect(Self.notesOnDisk(harness, damaged.id) == "Also kept")
    #expect(harness.jobs.isEmpty)

    let relaunched = Self.coordinator(harness)
    relaunched.launch()
    await MeetingCoordinatorTests.eventually("listed") { relaunched.record(id: empty.id) != nil }
    #expect(relaunched.record(id: empty.id)?.state == .notesOnly)
    #expect(harness.jobs.isEmpty)
  }

  @Test("no audio and notes that cannot be saved: failed, notice shown, the draft kept")
  func notesOnlyRefusedWhenSaveFails() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    try Self.breakNotesWrites(harness, record.id)
    let coordinator = Self.coordinator(harness)
    await coordinator.documents.load(record.id)
    coordinator.documents.setNotes(record.id, "cannot be written")
    record.state = .queued
    try harness.store.save(record)
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("failed") {
      coordinator.record(id: record.id)?.state == .failed
    }
    #expect(coordinator.notice == .storageFailed)
    #expect(coordinator.documents.notes(record.id) == "cannot be written")
    #expect(coordinator.documents.hasUnsavedNotes(record.id))
  }

  @Test("a rename while the notes are saved for a notes-only meeting keeps the new title")
  func renameDuringNotesSave() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    let gate = DebounceGate()  // the notes stay a draft until the pass saves them
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.documents.load(record.id)
    coordinator.documents.setNotes(record.id, "notes")
    let hold = Self.holdFileQueue()
    coordinator.launch()
    // The listing waits behind the hold; release it, then rename while the pass saves notes.
    hold.signal()
    await MeetingWorkAdmission.waitUntil { coordinator.record(id: record.id) != nil }
    await coordinator.rename(meetingID: record.id, title: "Board review")
    await MeetingCoordinatorTests.eventually("notes only") {
      coordinator.record(id: record.id)?.state == .notesOnly
    }
    #expect(try harness.store.load(id: record.id).title == "Board review")
  }

  @Test("no audio and no notes still fails, as before")
  func noAudioNoNotesFails() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    let coordinator = Self.coordinator(harness)
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("failed") {
      coordinator.record(id: record.id)?.state == .failed
    }
    #expect(try harness.store.load(id: record.id).failureCode == "no_audio")
  }

  @Test("a Start that recorded nothing keeps notes still in their debounce, saved first")
  func failedStartWithUnsavedNotes() async throws {
    let harness = try Harness()
    harness.recorderStart = .failEmpty
    // Set before the coordinator is built: its recovery closure captures the hold.
    harness.recoveryHold = DispatchSemaphore(value: 0)
    let gate = DebounceGate()  // never opened: the notes are only a draft
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    let start = Task { await coordinator.start(from: .menu) }
    await MeetingCoordinatorTests.eventually("meeting created") { !coordinator.meetings.isEmpty }
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.documents.load(meetingID)
    coordinator.documents.setNotes(meetingID, "Typed while it started")
    await MeetingWorkAdmission.waitUntil { gate.waiting == 1 }
    harness.recoveryHold?.signal()
    _ = await start.value
    await MeetingCoordinatorTests.eventually("notes only") {
      coordinator.record(id: meetingID)?.state == .notesOnly
    }
    #expect(Self.notesOnDisk(harness, meetingID) == "Typed while it started")
    #expect(harness.ended.last?.outcome == .startFailed)
  }

  @Test("a failed notes save is shown until a later save works, and the notes are kept (#4075)")
  func notesSaveFailureIsShownUntilSaved() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .failed
    try harness.store.create(record)
    let coordinator = Self.coordinator(harness)
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") { coordinator.record(id: record.id) != nil }
    let documents = coordinator.documents
    await documents.load(record.id)
    // A read-only meeting folder: every write into it fails, as on a full or locked disk.
    let folder = harness.store.notesURL(for: record.id).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    #expect(documents.notesSaveFailed(record.id) == false)

    documents.setNotes(record.id, "kept in the app")
    #expect(await documents.flush(record.id) == false)
    #expect(documents.notesSaveFailed(record.id))
    #expect(documents.notes(record.id) == "kept in the app")

    // The disk works again: Try again saves, and the warning goes.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    #expect(await documents.flush(record.id))
    #expect(documents.notesSaveFailed(record.id) == false)
    #expect(Self.notesOnDisk(harness, record.id) == "kept in the app")
  }

  @Test("a failed summary-edit save is shown until a later save works (#4075)")
  func summarySaveFailureIsShownUntilSaved() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .failed
    try harness.store.create(record)
    let coordinator = Self.coordinator(harness)
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") { coordinator.record(id: record.id) != nil }
    let documents = coordinator.documents
    await documents.load(record.id)
    let summaryURL = harness.store.summaryURL(for: record.id)
    let folder = summaryURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    documents.setSummary(record.id, "My own words")
    #expect(await documents.flushSummary(record.id) == false)
    #expect(documents.summarySaveFailed(record.id))
    #expect(documents.summary(record.id) == "My own words")

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    #expect(await documents.flushSummary(record.id))
    #expect(documents.summarySaveFailed(record.id) == false)
    #expect(
      (try? String(contentsOf: summaryURL, encoding: .utf8))?.contains("My own words") == true)
  }

  @Test(
    "an older successful save keeps the warning for newer typing (#4075)",
    arguments: [false, true]
  )
  func warningSurvivesOlderSuccessfulSave(summary: Bool) async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)

    let debounce = DebounceGate()
    let completion = DebounceGate()
    defer {
      debounce.open()
      completion.open()
    }

    var writes = 0
    let documents = MeetingDocumentsOwner(
      writer: MeetingFileWriter(store: harness.store, writeRecord: { try $0.save($1) }),
      dependencies: .init(
        debounce: { await debounce.wait() },
        log: { _ in },
        afterEditWrite: {
          writes += 1
          if writes == 2 { await completion.wait() }
        }))
    try #require(await documents.load(record.id))

    let setText: @MainActor (String) -> Void = { text in
      if summary {
        documents.setSummary(record.id, text)
      } else {
        documents.setNotes(record.id, text)
      }
    }
    let flush: @MainActor () async -> Bool = {
      if summary { return await documents.flushSummary(record.id) }
      return await documents.flush(record.id)
    }
    let failed: @MainActor () -> Bool = {
      summary
        ? documents.summarySaveFailed(record.id)
        : documents.notesSaveFailed(record.id)
    }

    let folder = harness.store.notesURL(for: record.id).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    setText("first")
    #expect(await flush() == false)
    try #require(failed())

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    setText("second")
    let olderSave = Task { await flush() }
    await MeetingCoordinatorTests.eventually("older save result parked") {
      completion.waiting == 1
    }

    setText("latest")
    completion.open()
    #expect(await olderSave.value == false)
    #expect(failed(), "the older success must not dismiss the warning")

    #expect(await flush())
    #expect(failed() == false)
    let url =
      summary
      ? harness.store.summaryURL(for: record.id)
      : harness.store.notesURL(for: record.id)
    #expect(try String(contentsOf: url, encoding: .utf8) == "latest")
  }

  @Test("unsaved notes hold a relaunch at once, and still after a failed save has drained")
  func relaunchWaitsAfterFailedSave() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .failed
    try harness.store.create(record)
    let coordinator = Self.coordinator(harness)
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("initial documents loaded") {
      coordinator.record(id: record.id) != nil
        && coordinator.documents.loadState(record.id) == .loaded
    }
    #expect(coordinator.isWorkInFlight == false)
    let folder = harness.store.notesURL(for: record.id).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    coordinator.documents.setNotes(record.id, "cannot be written")
    #expect(coordinator.isWorkInFlight, "held from the first keystroke")
    #expect(await coordinator.documents.flush(record.id) == false)
    await MeetingCoordinatorTests.eventually("save attempts drained") {
      harness.logs.contains { $0.hasPrefix("meeting notes save failed") }
    }
    #expect(coordinator.documents.hasUnsavedNotes(record.id))
    #expect(coordinator.isWorkInFlight, "the unsaved draft still holds the relaunch")
  }

  @Test("a failed Start whose cleanup is reading the notes keeps notes typed meanwhile")
  func failedStartNotesDuringCleanupRead() async throws {
    let harness = try Harness()
    harness.recorderStart = .failEmpty
    harness.recoveryHold = DispatchSemaphore(value: 0)
    let coordinator = Self.coordinator(harness)
    let start = Task { await coordinator.start(from: .menu) }
    await MeetingCoordinatorTests.eventually("meeting created") { !coordinator.meetings.isEmpty }
    let meetingID = try #require(coordinator.meetings.first?.id)

    // The cleanup's notes read is held on the file queue; the user types during it.
    let hold = Self.holdFileQueue()
    harness.recoveryHold?.signal()
    await MeetingWorkAdmission.waitUntil {
      coordinator.documents.loadState(meetingID) == .loading
    }
    coordinator.documents.setNotes(meetingID, "typed during cleanup")
    hold.signal()
    _ = await start.value
    await MeetingCoordinatorTests.eventually("notes only") {
      coordinator.record(id: meetingID)?.state == .notesOnly
    }
    #expect(Self.notesOnDisk(harness, meetingID) == "typed during cleanup")
  }

  @Test("once a failed Start's empty folder is being removed, no note is accepted for it")
  func failedStartFenceRefusesLateNotes() async throws {
    let harness = try Harness()
    harness.recorderStart = .failEmpty
    let coordinator = Self.coordinator(harness)
    _ = await coordinator.start(from: .menu)
    #expect(coordinator.meetings.isEmpty)
    let folders = try FileManager.default.contentsOfDirectory(atPath: harness.root.path)
      .filter { UUID(uuidString: $0) != nil }
    #expect(folders.isEmpty)
    #expect(coordinator.documents.entries.isEmpty)
  }

  @Test("a failed Start whose emptied notes cannot be saved ends failed, folder and draft kept")
  func failedStartEmptiedNotesSaveFails() async throws {
    let harness = try Harness()
    harness.recorderStart = .failEmpty
    harness.recoveryHold = DispatchSemaphore(value: 0)
    let gate = DebounceGate()  // never opened: only the cleanup's flush saves
    defer { gate.open() }
    let coordinator = Self.coordinator(harness, gate: gate)
    let start = Task { await coordinator.start(from: .menu) }
    await MeetingCoordinatorTests.eventually("meeting created") { !coordinator.meetings.isEmpty }
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.documents.load(meetingID)
    coordinator.documents.setNotes(meetingID, "first")
    #expect(await coordinator.documents.flush(meetingID))
    // Every later document write fails: documents.json becomes a directory.
    let manifest = harness.store.documentsURL(for: meetingID)
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    coordinator.documents.setNotes(meetingID, "")

    harness.recoveryHold?.signal()
    _ = await start.value  // returns: the cleanup does not loop on the failing save
    await MeetingCoordinatorTests.eventually("failed") {
      coordinator.record(id: meetingID)?.state == .failed
    }
    #expect(coordinator.notice == .storageFailed)
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path))
    #expect(coordinator.documents.hasUnsavedNotes(meetingID))
  }

  @Test("a deletion after a removal fence stays final; reopen undoes only its own fence")
  func reopenNeverUndoesDeletion() async throws {
    let harness = try Harness()
    let coordinator = Self.coordinator(harness)
    let documents = coordinator.documents
    var ids: [UUID] = []
    for _ in 0..<2 {
      let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      try harness.store.create(record)
      #expect(await documents.load(record.id))
      ids.append(record.id)
    }

    // Fence, then a deletion, then a late reopen: notes stay refused.
    let deleted = ids[0]
    let staleToken = try #require(documents.fenceEmptyForRemoval(deleted))
    documents.forget(deleted)
    documents.reopen(deleted, token: staleToken)
    documents.setNotes(deleted, "after deletion")
    #expect(documents.entries[deleted] == nil)

    // Fence, then reopen with its own token: notes are accepted again.
    let kept = ids[1]
    let token = try #require(documents.fenceEmptyForRemoval(kept))
    documents.setNotes(kept, "refused while fenced")
    #expect(documents.entries[kept] == nil)
    documents.reopen(kept, token: token)
    documents.setNotes(kept, "accepted again")
    #expect(documents.notes(kept) == "accepted again")
  }

  @Test("the notes box takes typing only once the saved notes are read")
  func canEditOnlyWhenLoaded() async throws {
    let harness = try Harness()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    _ = try harness.store.saveNotes("saved earlier", revision: 1, meeting: record.id)
    let coordinator = Self.coordinator(harness)
    let documents = coordinator.documents
    #expect(documents.canEdit(record.id) == false)
    let hold = Self.holdFileQueue()
    let load = Task { await documents.load(record.id) }
    await MeetingWorkAdmission.waitUntil { documents.loadState(record.id) == .loading }
    #expect(documents.canEdit(record.id) == false, "not while the saved notes are on their way")
    hold.signal()
    await load.value
    #expect(documents.canEdit(record.id))
    #expect(documents.notes(record.id) == "saved earlier")

    // Unreadable notes: the box stays locked until a read succeeds.
    let other = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(other)
    try Data("not json".utf8).write(to: harness.store.documentsURL(for: other.id))
    #expect(await documents.load(other.id) == false)
    #expect(documents.canEdit(other.id) == false)
  }

  // Moved from the retired MeetingLivePreviewTests (#3973): Save reads the notes first.
  @Test("Save waits for the notes, and says so when they cannot be read")
  func exportReadsNotesFirst() async throws {
    let harness = try Harness()
    let rig = MeetingHistoryPresentationTests.Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)
    _ = try harness.store.saveNotes("Budget owner: Priya", revision: 1, meeting: record.id)
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    rig.infos[record.id] = MeetingHistoryInfo(echoTurnIDs: [], title: nil)
    try await rig.coordinator.saveAndShowDurably(row)
    let coordinator = MeetingDocumentsOwnerTests.coordinator(harness)

    // Notes not read yet, the read held: Save waits for it and carries the notes.
    let hold = MeetingDocumentsOwnerTests.holdFileQueue()
    let export = Task {
      await MeetingExport.document(
        meetingID: record.id, rowID: row.id, documents: coordinator.documents,
        transcripts: rig.coordinator)
    }
    hold.signal()
    guard case .document(let text) = await export.value else {
      Issue.record("Save wrote nothing")
      return
    }
    #expect(text.hasSuffix("Notes\n\nBudget owner: Priya\n"))

    // Unreadable notes: nothing is written, and Save says why.
    let other = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(other)
    try Data("not json".utf8).write(to: harness.store.documentsURL(for: other.id))
    #expect(
      await MeetingExport.document(
        meetingID: other.id, rowID: row.id, documents: coordinator.documents,
        transcripts: rig.coordinator) == .notesUnreadable)
  }

  // MARK: - Meeting facts (#4286)

  /// An owner over the harness store, with its own log and an optional parked read result.
  static func factsOwner(
    _ harness: Harness, logs: LogBox = LogBox(), readGate: DebounceGate? = nil
  ) -> MeetingDocumentsOwner {
    MeetingDocumentsOwner(
      writer: MeetingFileWriter(store: harness.store, writeRecord: { try $0.save($1) }),
      dependencies: .init(
        debounce: {}, log: { logs.lines.append($0) },
        afterDocumentsRead: { await readGate?.wait() }))
  }

  @MainActor
  final class LogBox {
    var lines: [String] = []
  }

  static func invitee(_ name: String?, _ email: String?, status: AttendeeFact.Status = .accepted)
    -> MeetingFact
  {
    AttendeeFact(
      name: name, email: email, role: .required, status: status, isSelf: false,
      isOrganizer: false
    ).fact(source: MeetingFact.eventKitSource, capturedAt: Date(timeIntervalSinceReferenceDate: 1))
  }

  static func readyMeeting(_ harness: Harness) throws -> MeetingRecord {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)
    return record
  }

  @Test("saved facts load with the documents; absent or unreadable facts never fail them")
  func factsLoadWithDocuments() async throws {
    let harness = try Harness()
    let documents = Self.factsOwner(harness)
    let withFacts = try Self.readyMeeting(harness)
    try harness.store.appendFacts([Self.invitee("Ana", "ana@acme.com")], meeting: withFacts.id)
    _ = try harness.store.saveNotes("agenda", revision: 1, meeting: withFacts.id)
    #expect(documents.context(withFacts.id) == nil, "reading never starts a load")
    try #require(await documents.load(withFacts.id))
    #expect(documents.context(withFacts.id)?.attendees.map(\.name) == ["Ana"])
    #expect(documents.notes(withFacts.id) == "agenda")

    let absent = try Self.readyMeeting(harness)
    try #require(await documents.load(absent.id))
    #expect(documents.context(absent.id) == nil)

    let damaged = try Self.readyMeeting(harness)
    let damagedBytes = Data("{nope".utf8)
    try damagedBytes.write(to: harness.store.contextURL(for: damaged.id))
    try #require(await documents.load(damaged.id))
    #expect(documents.context(damaged.id) == nil)
    #expect(try Data(contentsOf: harness.store.contextURL(for: damaged.id)) == damagedBytes)
    #expect(documents.context(withFacts.id)?.attendees.count == 1, "other meetings unaffected")
  }

  @Test("facts save before any read, keep unknown facts, and leave notes unread and untouched")
  func recordBeforeLoad() async throws {
    let harness = try Harness()
    let documents = Self.factsOwner(harness)
    let record = try Self.readyMeeting(harness)
    let existing = """
      {"formatVersion": 1, "facts": [{"kind": "futureThing", "source": "x", "capturedAt": 0, "value": {"k": [1]}}]}
      """
    try Data(existing.utf8).write(to: harness.store.contextURL(for: record.id))

    #expect(await documents.recordFacts(record.id, [Self.invitee("Dana Lee", "dana@acme.com")]))
    let context = try #require(documents.context(record.id))
    #expect(context.facts.map(\.kind) == ["futureThing", "attendee"])
    #expect(documents.loadState(record.id) == .notLoaded, "unread notes are not marked read")
    #expect(documents.notes(record.id) == "")
    #expect(documents.manifest(record.id) == MeetingDocumentsManifest())
    #expect(documents.hasPendingWork == false)
    #expect(documents.invitedSearchTerms(record.id) == ["Dana Lee", "dana@acme.com", "acme.com"])
  }

  @Test("search terms are names, emails and domains; declined people stay; one email is one person")
  func searchTerms() async throws {
    let harness = try Harness()
    let documents = Self.factsOwner(harness)
    let record = try Self.readyMeeting(harness)
    #expect(
      await documents.recordFacts(
        record.id,
        [
          Self.invitee("Dana Lee", "Dana@Acme.com"),
          Self.invitee("Kim", nil),
          Self.invitee("Bo", "bo@other.org", status: .declined),
          Self.invitee(nil, "dana@acme.com"),
        ]))
    #expect(
      documents.invitedSearchTerms(record.id)
        == ["Dana Lee", "dana@acme.com", "acme.com", "Kim", "Bo", "bo@other.org", "other.org"])
    let other = try Self.readyMeeting(harness)
    #expect(documents.invitedSearchTerms(other.id) == [])
  }

  @Test("a failed save returns false, publishes nothing, and logs only the error type")
  func failedSave() async throws {
    let harness = try Harness()
    let logs = LogBox()
    let documents = Self.factsOwner(harness, logs: logs)
    let record = try Self.readyMeeting(harness)
    try Data("{nope".utf8).write(to: harness.store.contextURL(for: record.id))
    #expect(await documents.recordFacts(record.id, [Self.invitee("Dana Lee", "dana@acme.com")]) == false)
    #expect(documents.context(record.id) == nil)
    #expect(documents.invitedSearchTerms(record.id) == [])
    #expect(documents.hasPendingWork == false)
    #expect(logs.lines.contains { $0.hasPrefix("meeting facts save failed error=") })
    #expect(logs.lines.contains { $0.contains("Dana") || $0.contains("acme") } == false)
  }

  @Test("a deleted meeting refuses facts before any file work, and a deletion marker refuses too")
  func refusals() async throws {
    let harness = try Harness()
    let documents = Self.factsOwner(harness)
    let forgotten = try Self.readyMeeting(harness)
    documents.forget(forgotten.id)
    let hold = Self.holdFileQueue()
    // Answered while the file queue is held: nothing was submitted to it.
    #expect(await documents.recordFacts(forgotten.id, [Self.invitee("Ana", nil)]) == false)
    hold.signal()
    #expect(documents.entries[forgotten.id] == nil)
    #expect(documents.invitedSearchTerms(forgotten.id) == [])
    #expect(FileManager.default.fileExists(atPath: harness.store.contextURL(for: forgotten.id).path) == false)

    var marked = try Self.readyMeeting(harness)
    marked.deletionRequested = true
    try harness.store.save(marked)
    #expect(await documents.recordFacts(marked.id, [Self.invitee("Ana", nil)]) == false)
    #expect(FileManager.default.fileExists(atPath: harness.store.contextURL(for: marked.id).path) == false)
    #expect(documents.hasPendingWork == false)
  }

  @Test("a save admitted before a deletion is counted while held and publishes nothing after it")
  func saveThenForget() async throws {
    let harness = try Harness()
    let documents = Self.factsOwner(harness)
    let record = try Self.readyMeeting(harness)
    let hold = Self.holdFileQueue()
    let save = Task { await documents.recordFacts(record.id, [Self.invitee("Ana", "ana@acme.com")]) }
    await MeetingCoordinatorTests.eventually("save admitted", drainFiles: false) {
      documents.hasPendingWork
    }
    documents.forget(record.id)
    hold.signal()
    #expect(await save.value == false)
    #expect(documents.entries[record.id] == nil)
    #expect(documents.invitedSearchTerms(record.id) == [])
    #expect(documents.hasPendingWork == false)
  }

  @Test("a read held past a deletion publishes no facts")
  func readThenForget() async throws {
    let harness = try Harness()
    let documents = Self.factsOwner(harness)
    let record = try Self.readyMeeting(harness)
    try harness.store.appendFacts([Self.invitee("Ana", nil)], meeting: record.id)
    let hold = Self.holdFileQueue()
    let load = Task { await documents.load(record.id) }
    await MeetingCoordinatorTests.eventually("read admitted", drainFiles: false) {
      documents.loadState(record.id) == .loading
    }
    documents.forget(record.id)
    hold.signal()
    _ = await load.value
    #expect(documents.entries[record.id] == nil)
    #expect(documents.context(record.id) == nil)
  }

  @Test("a read that started before a fact save never erases the saved facts")
  func olderReadKeepsSavedFacts() async throws {
    let harness = try Harness()
    let gate = DebounceGate()
    defer { gate.open() }
    let documents = Self.factsOwner(harness, readGate: gate)
    let record = try Self.readyMeeting(harness)
    // The read finds no facts on disk, then parks before applying its result.
    let load = Task { await documents.load(record.id) }
    await MeetingCoordinatorTests.eventually("read parked") { gate.waiting == 1 }
    #expect(await documents.recordFacts(record.id, [Self.invitee("Ana", "ana@acme.com")]))
    gate.open()
    #expect(await load.value)
    #expect(documents.context(record.id)?.attendees.map(\.name) == ["Ana"])
    #expect(documents.invitedSearchTerms(record.id) == ["Ana", "ana@acme.com", "acme.com"])
  }
}
