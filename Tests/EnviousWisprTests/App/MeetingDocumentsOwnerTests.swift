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

  /// Makes every notes write fail: `notes.md` is a directory, so the atomic replace throws.
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

  @Test("quit saves an unsaved draft inside its deadline, read first or not")
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
    #expect(notesOnly.formatVersion == MeetingRecord.notesOnlyFormatVersion)
    #expect(notesOnly.failureCode == "no_audio")
    #expect(Self.notesOnDisk(harness, empty.id) == "Kept")
    let notesOnlyActions = MeetingsPresentation.actions(notesOnly, isActive: false)
    #expect(notesOnlyActions.transcribeAgain == false)
    #expect(notesOnlyActions.deleteAudio == false)

    let failed = try harness.store.load(id: damaged.id)
    #expect(failed.failureCode == "audio_unreadable")
    #expect(MeetingsPresentation.actions(failed, isActive: false).transcribeAgain)
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
}
