import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
import EnviousWisprPipeline
@testable import EnviousWisprStorage
@testable import EnviousWisprAudio

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

  /// Holds one row check until released; bounded so a subject that never reaches it fails.
  @MainActor final class RowCheckGate {
    private var held = false
    private var heldWaiters: [CheckedContinuation<Bool, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
      held = true
      heldWaiters.forEach { $0.resume(returning: true) }
      heldWaiters.removeAll()
      if released { return }
      await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHeld(sourceLocation: SourceLocation = #_sourceLocation) async throws {
      if held { return }
      let arrived = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        heldWaiters.append(c)
        Task { @MainActor [weak self] in
          // deadline-fallback: a hang guard only; no assertion depends on this clock.
          try? await Task.sleep(for: .seconds(10))
          guard let self, !self.heldWaiters.isEmpty else { return }
          self.heldWaiters.removeFirst().resume(returning: false)
        }
      }
      try #require(arrived, "the publication never reached its row check", sourceLocation: sourceLocation)
    }

    func release() {
      released = true
      releaseWaiter?.resume()
      releaseWaiter = nil
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

  static func request(_ rowID: UUID, samples: [Float], on: Bool) -> DictationRecordingRequest {
    DictationRecordingRequest(
      rowID: rowID, samples: samples, recordingsOn: on,
      asr: DictationASREvidence(
        text: "hello", backend: .parakeet, source: .batch, input: .conditionedBatch,
        wordTimingsAvailable: false))
  }

  @Test("an older publication suspended on its row check never takes the newer take's place")
  func newerSubmissionDuringOlderPublication() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    // The older take encodes and starts publishing; its row check is held.
    let rowCheck = RowCheckGate()
    rig.recordings.rowCheckWillRunForTesting = { await rowCheck.hold() }
    rig.gate.release(1)
    rig.recordings.submit(Self.request(row.id, samples: [0], on: true))
    try await rowCheck.waitUntilHeld()
    // A newer take is handed over while the older publication is suspended.
    rig.recordings.rowCheckWillRunForTesting = nil
    rig.gate.release(2)
    rig.recordings.submit(Self.request(row.id, samples: [0, 0, 0, 0, 0], on: true))
    rowCheck.release()
    await rig.recordings.waitForSubmissions()

    #expect(try await audioBytes(rig, row.id) == 5, "the newer take owns the final bytes")
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("a stored recording keeps the delivering decode's text beside it, with no timings invented")
  func sidecarKeepsASRText() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.release(1)

    rig.recordings.submit(Self.request(row.id, samples: [0], on: true))
    await rig.recordings.waitForSubmissions()

    let timing = try #require(try await rig.archive.timing(for: row.id))
    #expect(timing.exactASRText == "hello")
    #expect(timing.textVersion.hasPrefix("asr-sha256:"))
    #expect(timing.anchors.isEmpty)
    #expect(try await rig.recordings.timing(for: row.id) == timing)
  }

  @Test("History's Delete recordings only removes the audio, keeps the text, then is already absent")
  func historyDeleteRecordingsOnly() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.release(1)
    #expect(await rig.recordings.record(rowID: row.id, samples: [0], timing: nil) == .stored)

    let first = await rig.coordinator.deleteHistoryItem(
      id: .transcript(row.id), kind: .recordingsOnly)
    #expect(first == .removed)
    #expect(await rig.archive.url(for: row.id) == nil)
    #expect(rig.coordinator.currentRow(id: row.id) != nil)
    #expect(
      await rig.coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .recordingsOnly)
        == .alreadyAbsent)
  }

  @Test("a hand-off returns at once; the recording is kept once its encode finishes")
  func submitDoesNotWait() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)

    // The encode is held, yet the hand-off has already returned (paste is never delayed).
    rig.recordings.submit(Self.request(row.id, samples: [0, 0], on: true))
    try await rig.gate.waitUntilStarted(1)
    #expect(await rig.archive.url(for: row.id) == nil)
    rig.gate.release(1)
    await rig.recordings.waitForSubmissions()

    #expect(try await audioBytes(rig, row.id) == 2)
  }

  @Test("a deletion right after the hand-off, before encoding begins, still wins")
  func deletionRightAfterHandOffWins() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    rig.gate.release(1)

    rig.recordings.submit(Self.request(row.id, samples: [0], on: true))
    try await rig.recordings.deleteRecording(rowID: row.id, reason: .deleted)
    await rig.recordings.waitForSubmissions()

    #expect(await rig.archive.url(for: row.id) == nil)
    #expect(try await rig.archive.absence(for: row.id) == .deleted)
  }

  @Test("a take started with recordings off encodes nothing and keeps the reason")
  func recordingsOffKeepsReason() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)

    rig.recordings.submit(Self.request(row.id, samples: [0], on: false))
    await rig.recordings.waitForSubmissions()

    #expect(try await rig.archive.absence(for: row.id) == .recordingsOff)
    #expect(try await rig.archive.recordedRowIDs().isEmpty)
    #expect(try await rig.archive.usage().temporaryBytes == 0)
  }

  @Test("an off hand-off never overwrites a deletion that came after it")
  func staleOffDoesNotOverwrite() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)

    rig.recordings.submit(Self.request(row.id, samples: [0], on: false))
    try await rig.recordings.deleteRecording(rowID: row.id, reason: .deleted)
    await rig.recordings.waitForSubmissions()

    #expect(try await rig.archive.absence(for: row.id) == .deleted)
  }

  /// A real AAC recording stored for `rowID` through the archive, bypassing the gate encoder.
  private func storeRealRecording(_ rig: Rig, rowID: UUID, seconds: Double = 1) async throws {
    let partial = try await rig.archive.partialURL(for: rowID)
    let samples = (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    _ = try SpeechAudioEncoder.encode(samples: samples, purpose: .dictation, to: partial)
    try await rig.archive.store(rowID: rowID, fileURL: partial, timing: nil)
  }

  @Test("History reads a recording's file length and Keep state, a recorded reason, or a read failure")
  func statusForHistory() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    try await storeRealRecording(rig, rowID: row.id, seconds: 1)
    try await rig.recordings.pin(rowID: row.id)

    guard case .available(_, let durationMs, let pinned) = await rig.recordings.status(for: row.id)
    else {
      Issue.record("a stored recording is available")
      return
    }
    #expect(abs(durationMs - 1_000) <= 50, "the file's own length, not the text's")
    #expect(pinned)

    try await rig.recordings.deleteRecording(rowID: row.id, reason: .deleted)
    #expect(await rig.recordings.status(for: row.id) == .absent(RecordedAbsence(.deleted)))
    #expect(await rig.recordings.status(for: UUID()) == .absent(nil), "legacy rows give no reason")

    try Data("not json".utf8).write(to: rig.archive.directory.appendingPathComponent("absences.json"))
    #expect(await rig.recordings.status(for: row.id) == .unreadable, "a read failure is no absence")
  }

  @Test("every recording deletion stops that recording's players before its files go")
  func deletionsStopPlayback() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let arbiter = PlaybackArbiter()
    rig.recordings.arbiter = arbiter
    let silent: MeetingPlaybackController.Reader = { _, loaded, _, count in
      (
        loaded ?? (DictationPlaybackTests.SilentAudio() as any PlaybackWindowAudio),
        [Float](repeating: 0, count: count * 16)
      )
    }
    /// A playing player whose output records, at the moment it stops, whether the audio file
    /// was still on disk.
    func playingPlayer(_ id: UUID) async throws -> (MeetingPlaybackController, () -> Bool?) {
      let file = try #require(await rig.archive.url(for: id))
      let output = MeetingPlaybackControllerTests.FakeOutput()
      var fileAtStop: Bool?
      output.onStop = { fileAtStop = FileManager.default.fileExists(atPath: file.path) }
      let player = MeetingPlaybackController(
        media: .dictation(file), durationMs: 5_000, output: output, read: silent,
        sourceID: .dictation(id), arbiter: arbiter)
      player.play()
      return (player, { fileAtStop })
    }
    let audioOnly = try savedRow(rig, "audio only")
    let wholeRow = try savedRow(rig, "whole row")
    let lastRow = try savedRow(rig, "last row")
    for row in [audioOnly, wholeRow, lastRow] { try await storeRealRecording(rig, rowID: row.id) }

    let (first, firstSaw) = try await playingPlayer(audioOnly.id)
    try await rig.recordings.deleteRecording(rowID: audioOnly.id, reason: .deleted)
    #expect(first.state == .unavailable)
    #expect(firstSaw() == true, "audio-only deletion: playback stopped while the file was there")
    #expect(await rig.archive.url(for: audioOnly.id) == nil, "then the file went")

    let (second, secondSaw) = try await playingPlayer(wholeRow.id)
    await rig.coordinator.delete(wholeRow)
    #expect(second.state == .unavailable)
    #expect(secondSaw() == true, "row deletion: playback stopped while the file was there")
    #expect(await rig.archive.url(for: wholeRow.id) == nil)

    let (third, thirdSaw) = try await playingPlayer(lastRow.id)
    await rig.coordinator.deleteAll()
    #expect(third.state == .unavailable)
    #expect(thirdSaw() == true, "Delete All: playback stopped while the file was there")
    #expect(try await rig.archive.recordedRowIDs().isEmpty)
  }

  @Test("a failed recording deletion keeps the audio, reports it, and lets Play work again")
  func failedDeletionRestoresPlay() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let arbiter = PlaybackArbiter()
    rig.recordings.arbiter = arbiter
    let row = try savedRow(rig)
    try await storeRealRecording(rig, rowID: row.id)
    let file = try #require(await rig.archive.url(for: row.id))
    let player = MeetingPlaybackController(
      media: .dictation(file), durationMs: 1_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), sourceID: .dictation(row.id),
      arbiter: arbiter)
    let revision = rig.recordings.changes.revision(for: row.id)
    // A locked file cannot be removed.
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }

    await #expect(throws: (any Error).self, "the failure reaches the caller, which shows it") {
      try await rig.recordings.deleteRecording(rowID: row.id, reason: .deleted)
    }

    #expect(player.state == .unavailable, "the old player never plays again")
    #expect(rig.recordings.changes.revision(for: row.id) != revision, "the detail reads again")
    guard case .available(let url, _, _) = await rig.recordings.status(for: row.id) else {
      Issue.record("the audio survived the failed removal")
      return
    }
    #expect(url == file)
    #expect(
      HistoryDictationCard.needsNewPlayer(current: player, currentURL: file, read: url),
      "the fresh read builds a new player, so Play works again")
    let live = MeetingPlaybackController(
      media: .dictation(file), durationMs: 1_000,
      output: MeetingPlaybackControllerTests.FakeOutput())
    #expect(
      !HistoryDictationCard.needsNewPlayer(current: live, currentURL: file, read: file),
      "a working player for the same file is kept")
  }

  @Test("Delete all dictation recordings removes every recording, kept ones too, and keeps the text")
  func deleteAllRecordingsKeepsText() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let kept = try savedRow(rig, "kept")
    let plain = try savedRow(rig, "plain")
    let encoding = try savedRow(rig, "encoding")
    let off = try savedRow(rig, "off")
    for row in [kept, plain] { try await storeRealRecording(rig, rowID: row.id) }
    try await rig.recordings.pin(rowID: kept.id)
    try await rig.archive.recordAbsence(.recordingsOff, for: off.id)
    let pending = Task {
      await rig.recordings.record(rowID: encoding.id, samples: [0, 0, 0], timing: nil)
    }
    try await rig.gate.waitUntilStarted(1)
    let arbiter = PlaybackArbiter()
    rig.recordings.arbiter = arbiter
    let silent: MeetingPlaybackController.Reader = { _, loaded, _, count in
      (
        loaded ?? (DictationPlaybackTests.SilentAudio() as any PlaybackWindowAudio),
        [Float](repeating: 0, count: count * 16)
      )
    }
    let player = MeetingPlaybackController(
      media: .dictation(URL(filePath: "/dev/null")), durationMs: 5_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), read: silent,
      sourceID: .dictation(plain.id), arbiter: arbiter)
    player.play()

    let result = await rig.recordings.deleteAllRecordingsKeepingText()
    rig.gate.release(1)

    #expect(result == DictationRecordings.BulkDeletion(removed: 2, remaining: 0, failed: false))
    #expect(await pending.value == .discarded, "an encode in flight never brings audio back")
    #expect(try await rig.archive.recordedRowIDs().isEmpty)
    #expect(try await rig.archive.usage().temporaryBytes == 0, "its partial file went too")
    #expect(player.state == .unavailable, "playback stopped")
    #expect(try await rig.archive.absence(for: kept.id) == .deleted, "kept audio is deleted on request")
    #expect(try await rig.archive.absence(for: plain.id) == .deleted)
    #expect(try await rig.archive.absence(for: off.id) == .recordingsOff, "other reasons stay")
    #expect(
      try await rig.archive.absence(for: encoding.id) == .deleted,
      "the row whose encode was withdrawn says deleted, never unexplained")
    let rowsLeft = try #require(try await rig.store.permanentRowIDs())
    #expect(rowsLeft.isSuperset(of: [kept.id, plain.id, encoding.id, off.id]), "every text row stays")
  }

  @Test("Delete all dictation recordings reports what it could not delete")
  func deleteAllRecordingsReportsFailure() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let rows = [try savedRow(rig, "a"), try savedRow(rig, "b"), try savedRow(rig, "c")]
    for row in rows { try await storeRealRecording(rig, rowID: row.id) }
    let locked = try #require(await rig.archive.url(for: rows[1].id))
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }

    let result = await rig.recordings.deleteAllRecordingsKeepingText()

    #expect(result.failed)
    // The archive stops at the first failure, so the locked one and any after it remain.
    #expect((1...3).contains(result.remaining ?? 0), "what is left is counted, never zero")
    #expect((result.removed ?? 0) + (result.remaining ?? 0) == 3)
    #expect(await rig.archive.url(for: rows[1].id) != nil)
  }

  @Test("Delete all dictation recordings reports a failure even when every audio file went")
  func deleteAllRecordingsReportsMetadataFailure() async throws {
    let rig = rig()
    defer { rig.gate.releaseAll() }
    let row = try savedRow(rig)
    try await storeRealRecording(rig, rowID: row.id)
    // A reason file that exists and cannot be replaced: the audio goes, the reasons cannot be
    // written.
    try await rig.archive.recordAbsence(.recordingsOff, for: UUID())
    let reasons = rig.archive.directory.appendingPathComponent("absences.json")
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: reasons.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: reasons.path) }

    let result = await rig.recordings.deleteAllRecordingsKeepingText()

    #expect(await rig.archive.url(for: row.id) == nil, "the audio went")
    #expect(result.remaining == 0)
    #expect(result.failed, "the reasons were not written, so it is not a success")
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
