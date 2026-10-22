import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3972 R46, R53, R56 (build chunk C7): when these fail, meeting notes the user typed are lost
/// (on quit, on a failed recording, or by closing the view), a deleted meeting's notes come
/// back, or a meeting with no audio is transcribed again on every launch.
@MainActor
@Suite("Meeting notes owner", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingDocumentsOwnerTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  /// A coordinator whose notes debounce waits on `gate` (opened by the test), or returns at
  /// once when `gate` is nil.
  static func coordinator(_ harness: Harness, gate: MeetingCoordinatorTests.Gate? = nil)
    -> MeetingCoordinator
  {
    var deps = harness.dependencies()
    deps.notesDebounce = { [gate] in await gate?.wait() }
    return MeetingCoordinator(dependencies: deps)
  }

  static func notesOnDisk(_ harness: Harness, _ meetingID: UUID) -> String? {
    try? String(contentsOf: harness.store.notesURL(for: meetingID), encoding: .utf8)
  }

  @Test("notes save one debounce after the last change, and only the newest text is kept")
  func debouncedSave() async throws {
    let harness = try Harness()
    let gate = MeetingCoordinatorTests.Gate()
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    let documents = coordinator.documents
    await documents.load(meetingID)

    documents.setNotes(meetingID, "Bud")
    documents.setNotes(meetingID, "Budget")
    await MeetingCoordinatorTests.eventually("debounce parked") { gate.parked }
    #expect(Self.notesOnDisk(harness, meetingID) == nil, "nothing is saved before the debounce")
    #expect(documents.hasUnsavedNotes(meetingID))

    gate.open()
    await MeetingCoordinatorTests.eventually("saved") { !documents.hasUnsavedNotes(meetingID) }
    #expect(Self.notesOnDisk(harness, meetingID) == "Budget")
    await coordinator.stop()
  }

  @Test("Stop saves the notes at once, without waiting for the debounce")
  func stopFlushes() async throws {
    let harness = try Harness()
    let gate = MeetingCoordinatorTests.Gate()  // never opened
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.documents.load(meetingID)
    coordinator.documents.setNotes(meetingID, "Decisions: ship Friday")
    await coordinator.stop()
    #expect(Self.notesOnDisk(harness, meetingID) == "Decisions: ship Friday")
    #expect(coordinator.documents.hasUnsavedNotes(meetingID) == false)
  }

  @Test("quit saves an unsaved draft inside its deadline, even with nothing recording")
  func quitFlushes() async throws {
    let harness = try Harness()
    let coordinator = Self.coordinator(harness, gate: MeetingCoordinatorTests.Gate())
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await MeetingCoordinatorTests.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready
    }
    await coordinator.documents.load(meetingID)
    coordinator.documents.setNotes(meetingID, "Follow up with legal")
    coordinator.prepareForTermination(deadline: .now() + 2)
    #expect(Self.notesOnDisk(harness, meetingID) == "Follow up with legal")
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
    #expect(try harness.store.loadDocuments(meeting: meetingID).manifest.notes?.revision == 5)
    await coordinator.stop()
  }

  @Test("deleting a meeting drops its draft; no late save brings the folder back")
  func deleteForgets() async throws {
    let harness = try Harness()
    let gate = MeetingCoordinatorTests.Gate()
    let coordinator = Self.coordinator(harness, gate: gate)
    await coordinator.start(from: .menu)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.documents.load(meetingID)
    coordinator.documents.setNotes(meetingID, "secret")
    await MeetingCoordinatorTests.eventually("debounce parked") { gate.parked }

    await coordinator.delete(meetingID: meetingID)
    gate.open()
    await MeetingCoordinatorTests.eventually("file queue idle") {
      coordinator.queuedFileOperations == 0
    }
    #expect(coordinator.documents.notes(meetingID) == "")
    #expect(!FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path))
  }

  @Test("no audio with notes is notes-only, never queued again; unreadable audio keeps Retry")
  func notesOnlyOnlyForConfirmedAbsence() async throws {
    // No audio file at all, notes typed: notes-only.
    let harness = try Harness()
    var empty = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(empty)
    empty.state = .queued
    try harness.store.save(empty)
    _ = try harness.store.saveNotes("Kept", revision: 1, meeting: empty.id)

    // An audio file that cannot be read, notes typed: failed, Retry still offered.
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

    // A relaunch leaves the notes-only meeting alone.
    let relaunched = Self.coordinator(harness)
    relaunched.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      relaunched.record(id: empty.id) != nil
    }
    #expect(relaunched.record(id: empty.id)?.state == .notesOnly)
    #expect(harness.jobs.isEmpty)
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

  @Test("a Start that recorded nothing keeps the folder when notes were typed")
  func failedStartWithNotes() async throws {
    let harness = try Harness()
    harness.recorderStart = .failEmpty
    // Set before the coordinator is built: its recovery closure captures the hold.
    harness.recoveryHold = DispatchSemaphore(value: 0)
    let coordinator = Self.coordinator(harness)
    let start = Task { await coordinator.start(from: .menu) }
    await MeetingCoordinatorTests.eventually("meeting created") {
      !coordinator.meetings.isEmpty
    }
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.documents.load(meetingID)
    coordinator.documents.setNotes(meetingID, "Typed while it started")
    await coordinator.documents.flush(meetingID)
    harness.recoveryHold?.signal()
    _ = await start.value
    await MeetingCoordinatorTests.eventually("notes only") {
      coordinator.record(id: meetingID)?.state == .notesOnly
    }
    #expect(Self.notesOnDisk(harness, meetingID) == "Typed while it started")
    #expect(harness.ended.last?.outcome == .startFailed)
  }
}
