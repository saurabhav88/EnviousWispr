import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #3147 §3.1: when these fail, a recording the user deleted comes back after a slow encode, an
/// older take overwrites a newer one, deleting a dictation leaves its audio on disk, or launch
/// cleanup deletes a recording whose text still exists.
///
/// Real History store, real archive and real command queue in temporary folders. Only the
/// encoder is stood in for, so a test can hold an encode at the moment that matters; it writes
/// one byte per sample, which tells two takes apart.
@MainActor
@Suite("Dictation recordings through History's command queue", .tags(.productOutcome))
struct DictationRecordingsTests {

  /// Holds each encode until the test releases it by number (1 = the first encode to start), and
  /// reports when encodes have started. Every wait is bounded: a subject that never reaches the
  /// encoder, or a test that never releases one, fails the case instead of hanging the run.
  final class EncodeGate: @unchecked Sendable {
    struct NeverReleased: Error {}
    private let lock = NSLock()
    private var releases: [Int: DispatchSemaphore] = [:]
    private var startedCount = 0
    private var startedWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var failing = false
    var fails: Bool {
      get { lock.withLock { failing } }
      set { lock.withLock { failing = newValue } }
    }

    private func semaphore(_ index: Int) -> DispatchSemaphore {
      lock.withLock {
        if let existing = releases[index] { return existing }
        let created = DispatchSemaphore(value: 0)
        releases[index] = created
        return created
      }
    }

    func encode(_ samples: [Float], _ destination: URL) throws {
      let index = lock.withLock { () -> Int in
        startedCount += 1
        for (id, waiter) in startedWaiters where waiter.count <= startedCount {
          waiter.continuation.resume(returning: true)
          startedWaiters.removeValue(forKey: id)
        }
        return startedCount
      }
      // deadline-fallback: a hang guard only; no assertion depends on this clock.
      guard semaphore(index).wait(timeout: .now() + 10) == .success else { throw NeverReleased() }
      if fails { throw CocoaError(.fileWriteUnknown) }
      guard FileManager.default.createFile(atPath: destination.path, contents: Data(count: samples.count))
      else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Resolves once `count` encodes have started; fails the case instead of hanging.
    func waitUntilStarted(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
      let id = UUID()
      let arrived = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let now = lock.withLock { () -> Bool in
          if startedCount >= count { return true }
          startedWaiters[id] = (count, continuation)
          return false
        }
        if now {
          continuation.resume(returning: true)
          return
        }
        Task { [self] in
          // deadline-fallback: a hang guard only; no assertion depends on this clock.
          try? await Task.sleep(for: .seconds(10))
          lock.withLock { startedWaiters.removeValue(forKey: id) }?.continuation
            .resume(returning: false)
        }
      }
      try #require(arrived, "only \(lock.withLock { startedCount }) of \(count) encodes started", sourceLocation: sourceLocation)
    }

    /// Lets encode number `index` finish (it may not have started yet).
    func release(_ index: Int) { semaphore(index).signal() }

    /// Test cleanup: lets every outstanding encode finish, including ones not started yet.
    func releaseAll() {
      let pending = lock.withLock { () -> [DispatchSemaphore] in
        let started = startedCount
        for index in 1...(started + 8) where releases[index] == nil {
          releases[index] = DispatchSemaphore(value: 0)
        }
        return Array(releases.values)
      }
      pending.forEach { $0.signal() }
    }
  }

  @MainActor struct Rig {
    let store: TranscriptStore
    let storeDirectory: URL
    let archive: RecordingArchive
    let coordinator: TranscriptCoordinator
    let gate: EncodeGate
    var recordings: DictationRecordings { coordinator.recordings! }
  }

  private func rig() -> Rig {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("DictationRecordingsTests-\(UUID().uuidString)", isDirectory: true)
    let storeDirectory = root.appendingPathComponent("transcripts", isDirectory: true)
    let store = TranscriptStore(directory: storeDirectory)
    let archive = RecordingArchive(
      directory: root.appendingPathComponent("dictations", isDirectory: true))
    let gate = EncodeGate()
    let coordinator = TranscriptCoordinator(
      store: store, recordingArchive: archive,
      encodeRecording: { try gate.encode($0, $1) })
    return Rig(
      store: store, storeDirectory: storeDirectory, archive: archive, coordinator: coordinator,
      gate: gate)
  }

  /// A saved dictation row, listed in History.
  private func savedRow(_ rig: Rig, _ text: String = "hello") throws -> Transcript {
    let row = Transcript(text: text, createdAt: Date())
    try rig.store.save(row)
    rig.coordinator.load()
    return row
  }

  private func audioBytes(_ rig: Rig, _ id: UUID) async throws -> Int? {
    guard let url = await rig.archive.url(for: id) else { return nil }
    return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .intValue
  }

  @Test("a finished encode for a saved row is kept")
  func publishes() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.release(1)

    #expect(
      await rig.recordings.record(
        rowID: row.id, samples: Array(repeating: 0, count: 10), timing: nil) == .stored)
    #expect(try await audioBytes(rig, row.id) == 10)
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("deleting the recording while it encodes: the late encode cannot bring it back")
  func audioDeletionWins() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    let pending = Task {
      await rig.recordings.record(rowID: row.id, samples: [0, 0, 0], timing: nil)
    }
    try await rig.gate.waitUntilStarted(1)

    try await rig.recordings.deleteRecording(rowID: row.id, reason: .deleted)
    rig.gate.release(1)

    #expect(await pending.value == .discarded)
    #expect(await rig.archive.url(for: row.id) == nil)
    #expect(try await rig.archive.absence(for: row.id) == .deleted)
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("deleting the dictation while it encodes leaves no recording and no reason behind")
  func rowDeletionWins() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    let pending = Task {
      await rig.recordings.record(rowID: row.id, samples: [0, 0, 0], timing: nil)
    }
    try await rig.gate.waitUntilStarted(1)

    await rig.coordinator.delete(row)
    rig.gate.release(1)

    #expect(await pending.value == .discarded)
    #expect(try await rig.archive.recordedRowIDs().isEmpty)
    #expect(try await rig.archive.absence(for: row.id) == nil)
    #expect(rig.coordinator.actionFailure == nil)
  }

  @Test("Delete All while a recording encodes leaves an empty archive")
  func deleteAllWins() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let kept = try savedRow(rig, "kept")
    rig.gate.release(1)
    #expect(await rig.recordings.record(rowID: kept.id, samples: [0], timing: nil) == .stored)
    try await rig.recordings.pin(rowID: kept.id)
    let row = try savedRow(rig, "encoding")
    let pending = Task { await rig.recordings.record(rowID: row.id, samples: [0, 0], timing: nil) }
    try await rig.gate.waitUntilStarted(2)

    await rig.coordinator.deleteAll()
    rig.gate.release(2)

    #expect(await pending.value == .discarded)
    #expect(try await rig.archive.recordedRowIDs().isEmpty)
    #expect(try await rig.archive.pinnedRowIDs().isEmpty)
    #expect(try await rig.archive.usage() == .init(committedBytes: 0, temporaryBytes: 0))
  }

  @Test("an older encode that finishes last never replaces the newer take")
  func newerTakeSurvives() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    let older = Task { await rig.recordings.record(rowID: row.id, samples: [0], timing: nil) }
    try await rig.gate.waitUntilStarted(1)
    let newer = Task {
      await rig.recordings.record(rowID: row.id, samples: [0, 0, 0, 0], timing: nil)
    }
    try await rig.gate.waitUntilStarted(2)

    // The newer take finishes and publishes first; the older one finishes last.
    rig.gate.release(2)
    #expect(await newer.value == .stored)
    rig.gate.release(1)
    #expect(await older.value == .discarded)
    #expect(try await audioBytes(rig, row.id) == 4)
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("a failed encode records why the recording is missing and leaves nothing partial")
  func failedEncodeIsRecorded() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.fails = true
    rig.gate.release(1)

    #expect(await rig.recordings.record(rowID: row.id, samples: [0], timing: nil) == .failed)
    #expect(try await rig.archive.absence(for: row.id) == .saveFailed)
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("an encode for a row that was never saved permanently is discarded")
  func unsavedRowIsDiscarded() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    rig.gate.release(1)

    #expect(await rig.recordings.record(rowID: UUID(), samples: [0], timing: nil) == .discarded)
    #expect(try await rig.archive.recordedRowIDs().isEmpty)
  }

  @Test("Keep this recording is set and cleared through the same queue")
  func pinAndUnpin() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.release(1)
    await rig.recordings.record(rowID: row.id, samples: [0], timing: nil)

    try await rig.recordings.pin(rowID: row.id)
    #expect(try await rig.archive.isPinned(row.id))
    try await rig.recordings.unpin(rowID: row.id)
    #expect(try await rig.archive.isPinned(row.id) == false)
  }

  @Test("deleting a dictation deletes its recording; a failure to do so is reported")
  func rowDeletionRemovesRecording() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    let other = try savedRow(rig, "other")
    for (number, id) in [row.id, other.id].enumerated() {
      rig.gate.release(number + 1)
      await rig.recordings.record(rowID: id, samples: [0], timing: nil)
    }

    await rig.coordinator.delete(row)
    #expect(await rig.archive.url(for: row.id) == nil)
    #expect(rig.coordinator.actionFailure == nil)

    // Damaged archive metadata: the text still goes, and the leftover recording is reported.
    try Data("not json".utf8).write(to: rig.archive.directory.appendingPathComponent("pins.json"))
    await rig.coordinator.delete(other)
    #expect(rig.coordinator.actionFailure == .delete)
    #expect(await rig.archive.url(for: other.id) != nil)
  }

  @Test("removing a meeting or imported row never depends on the dictation archive")
  func meetingAndImportRowsSkipArchive() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let meeting = Transcript(text: "meeting", createdAt: Date(), meetingID: UUID())
    let imported = Transcript(text: "file", createdAt: Date(), importedFileName: "talk.m4a")
    try rig.store.save(meeting)
    try rig.store.save(imported)
    rig.coordinator.load()
    await rig.coordinator.diskReconcilerForTesting.waitForLoadForTesting()
    #expect(rig.coordinator.visibleTranscripts.count == 2)
    // Damaged dictation metadata would fail any archive cleanup.
    _ = try await rig.archive.partialURL(for: UUID())
    try Data("not json".utf8).write(to: rig.archive.directory.appendingPathComponent("pins.json"))

    try await rig.coordinator.removeRow(id: meeting.id)
    await rig.coordinator.delete(imported)

    #expect(rig.coordinator.actionFailure == nil)
    #expect(try await rig.store.permanentRowIDs()?.isEmpty == true)
  }

  @Test("launch cleanup removes interrupted encodes and orphans, never a recording with its row")
  func launchCleanup() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.release(1)
    await rig.recordings.record(rowID: row.id, samples: [0], timing: nil)
    // An orphan: a recording whose text row file is gone.
    let orphan = UUID()
    let orphanFile = try await rig.archive.partialURL(for: orphan)
    #expect(FileManager.default.createFile(atPath: orphanFile.path, contents: Data(count: 3)))
    try await rig.archive.store(rowID: orphan, fileURL: orphanFile, timing: nil)
    // An encode a previous run left behind.
    let interrupted = try await rig.archive.partialURL(for: UUID())
    #expect(FileManager.default.createFile(atPath: interrupted.path, contents: Data(count: 5)))

    rig.recordings.start()
    await rig.recordings.waitForStartup()

    #expect(try await rig.archive.recordedRowIDs() == [row.id])
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("launch cleanup keeps every recording when the History rows cannot be certified")
  func uncertifiedInventoryKeepsRecordings() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let orphan = UUID()
    let file = try await rig.archive.partialURL(for: orphan)
    #expect(FileManager.default.createFile(atPath: file.path, contents: Data(count: 3)))
    try await rig.archive.store(rowID: orphan, fileURL: file, timing: nil)
    // The text folder is missing: absence of rows proves nothing.
    try FileManager.default.removeItem(at: rig.storeDirectory)

    rig.recordings.start()
    await rig.recordings.waitForStartup()

    #expect(try await rig.archive.recordedRowIDs() == [orphan])
  }
}
