#if DEBUG
import EnviousWisprAppKitTestSupport
import Foundation
import os
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3147 PR4B I2: when these fail, background compaction publishes a copy over a meeting that
/// was deleted, had its audio deleted, was transcribed again, changed, or was playing; a quit, a
/// crash or a full folder leaves a meeting without usable audio or with a record that points at
/// files that are not there; a later edit drops the compacted copy; or retiring the originals
/// removes audio the copy does not replace. All on temporary meetings.
@MainActor
@Suite("Meeting audio compaction lifecycle", .tags(.productOutcome))
struct MeetingAudioCompactionLifecycleTests {
  typealias Harness = MeetingCoordinatorTests.Harness
  private typealias C = CompactedAudioFixture

  /// Delegates to the production compactor, then runs `afterPrepare` before handing back the
  /// verified copy: the window between the last preparation step and publication.
  final class WindowedCompactor: MeetingAudioCompacting {
    let real = MeetingAudioCompactor()
    var afterPrepare: (@MainActor () async -> Void)?
    private(set) var prepared = 0

    func prepare(
      ticket: MeetingAudioCompactionTicket, record: MeetingRecord, folder: URL
    ) async throws -> VerifiedMeetingAudioInventory {
      let verified = try await real.prepare(ticket: ticket, record: record, folder: folder)
      prepared += 1
      await afterPrepare?()
      return verified
    }
  }

  final class Silence: PlaybackWindowAudio, @unchecked Sendable {
    func window(startMs: Int, count: Int) throws -> [Float] {
      [Float](repeating: 0, count: count * 16)
    }
  }

  /// A ready meeting on disk with two microphone segments (a gap between), their proof-backed
  /// cleaned twins and one call segment; nothing compacted yet.
  static func readyMeeting(_ harness: Harness) throws -> MeetingRecord {
    var record = MeetingRecord(
      engine: .parakeet, trackStatus: [.microphone: .captured, .callSound: .captured])
    try harness.store.create(record)
    let folder = harness.store.folder(for: record.id)
    let raw = [
      try C.tone(in: folder, index: 1, startMs: 0, frames: 16_000, frequency: 440),
      try C.tone(in: folder, index: 2, startMs: 2_000, frames: 8_000, frequency: 660),
    ]
    let cleaned = [
      try C.tone(
        in: folder, variant: .cleaned, index: 1, startMs: 0, frames: 16_000, frequency: 330),
      try C.tone(
        in: folder, variant: .cleaned, index: 2, startMs: 2_000, frames: 8_000, frequency: 550),
    ]
    let call = try C.tone(
      in: folder, track: .callSound, index: 3, startMs: 500, frames: 12_000, frequency: 880)
    _ = try C.proof(in: folder, twins: cleaned)
    record.segments = [.microphone: raw, .callSound: [call]]
    record.state = .ready
    record.endedAt = Date()
    record.echoProvenance = .compactionFixture
    try harness.store.save(record)
    return record
  }

  /// Waits on `semaphore` off the main actor, at most 10 s (a hang guard, never a timing).
  nonisolated static func waitBounded(_ semaphore: DispatchSemaphore) {
    _ = semaphore.wait(timeout: .now() + 10)
  }

  static func launched(_ harness: Harness, _ meetingID: UUID) async {
    harness.coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed and launched") {
      harness.coordinator.record(id: meetingID) != nil
        && harness.coordinator.audioCompactionCandidates().contains(meetingID)
    }
  }

  static func names(_ harness: Harness, _ meetingID: UUID) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: harness.store.folder(for: meetingID).path
    ).sorted()
  }

  static func compactedNames(_ harness: Harness, _ meetingID: UUID) throws -> [String] {
    try names(harness, meetingID).filter {
      MeetingSegmentNaming.parseAny($0)?.encoding == .aacM4A
    }
  }

  static func originals(_ record: MeetingRecord) -> [String] {
    (record.segments.values.flatMap { $0 }).map(\.fileName)
  }

  // MARK: - Publication

  @Test("a compacted copy is committed as the meeting's audio; every original stays")
  func compactionCommits() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let before = coordinator.playbackSource(meetingID: record.id)

    let attempt = await coordinator.compactAudio(
      meetingID: record.id, with: MeetingAudioCompactor())

    #expect(attempt == .committed)
    let disk = try harness.store.load(id: record.id)
    let inventory = try #require(disk.compressedAudio)
    #expect(disk.formatVersion == MeetingRecord.compressedAudioFormatVersion)
    #expect(coordinator.record(id: record.id)?.compressedAudio == inventory)
    #expect(disk.segments == record.segments)
    #expect(disk.committedTranscriptGeneration == record.committedTranscriptGeneration)
    for name in Self.originals(record) {
      #expect(try Self.names(harness, record.id).contains(name))
    }
    #expect(try Self.compactedNames(harness, record.id).count == inventory.segments.count)
    // The playback source changes with the representation, so the page rebuilds its player.
    let after = coordinator.playbackSource(meetingID: record.id)
    #expect(after != nil)
    #expect(after != before)
    #expect(coordinator.audioCompactionCandidates().contains(record.id) == false)
  }

  @Test("a meeting playing when its copy is ready is deferred; nothing is published")
  func playingDefers() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    let arbiter = PlaybackArbiter()
    coordinator.playbackArbiter = arbiter
    await Self.launched(harness, record.id)
    let player = MeetingPlaybackController(
      media: .transcript(Silence()), durationMs: 3_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), sourceID: .meeting(record.id),
      arbiter: arbiter)
    player.play()
    #expect(arbiter.isPlaying(.meeting(record.id)))

    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .deferred)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)
    #expect(try Self.compactedNames(harness, record.id).isEmpty)
    #expect(player.state == .playing, "listening was not interrupted")
  }

  @Test("deleting the meeting while its copy is prepared fences the copy and deletes everything")
  func deletionDuringPreparation() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let compactor = WindowedCompactor()
    var deletion: Task<Bool, Never>?
    compactor.afterPrepare = {
      deletion = Task { await coordinator.delete(meetingID: record.id) }
      await MeetingCoordinatorTests.eventually("deleting", drainFiles: false) {
        coordinator.isDeletingForTesting(record.id)
      }
    }

    #expect(await coordinator.compactAudio(meetingID: record.id, with: compactor) == .stale)
    #expect(await deletion?.value == true)
    #expect(
      FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path)
        == false)
    #expect(coordinator.record(id: record.id) == nil)
  }

  @Test("Delete audio while the copy is prepared removes every representation; no copy commits")
  func deleteAudioDuringPreparation() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let compactor = WindowedCompactor()
    var removal: Task<Bool, Never>?
    compactor.afterPrepare = {
      removal = Task { await coordinator.deleteAudio(meetingID: record.id) }
      await MeetingCoordinatorTests.eventually("audio marked deleted", drainFiles: false) {
        coordinator.liveRecordForTesting(record.id)?.audioKept == false
      }
    }

    #expect(await coordinator.compactAudio(meetingID: record.id, with: compactor) == .stale)
    #expect(await removal?.value == true)
    let disk = try harness.store.load(id: record.id)
    #expect(disk.audioKept == false)
    #expect(disk.compressedAudio == nil)
    #expect(try harness.store.segmentFiles(meeting: record.id).isEmpty)
  }

  @Test("Transcribe again while the copy is prepared wins; no copy commits over the new attempt")
  func retranscriptionDuringPreparation() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let compactor = WindowedCompactor()
    compactor.afterPrepare = {
      #expect(await coordinator.transcribeAgain(meetingID: record.id, engine: .parakeet))
    }

    #expect(await coordinator.compactAudio(meetingID: record.id, with: compactor) == .stale)
    await MeetingCoordinatorTests.livePassFinished(
      coordinator, record.id, replacing: record.committedTranscriptGeneration)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)
    #expect(try Self.compactedNames(harness, record.id).isEmpty, "the unpublished copy went")
    // The pass read the originals, all still there.
    let job = try #require(harness.jobs.last)
    #expect(job.receivedTracks[.microphone]?.segments.allSatisfy { !$0.compressed } == true)
  }

  @Test("Quit while the copy is prepared publishes nothing and leaves no copy")
  func quitDuringPreparation() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let compactor = WindowedCompactor()
    compactor.afterPrepare = { coordinator.prepareForTermination() }

    #expect(await coordinator.compactAudio(meetingID: record.id, with: compactor) == .stale)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)
    #expect(try Self.compactedNames(harness, record.id).isEmpty)
    #expect(coordinator.claimAudioCompaction(meetingID: record.id) == nil, "no claim after Quit")
  }

  @Test("an original changed after preparation fails publication; the originals stay the audio")
  func sourceChangeFails() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let compactor = WindowedCompactor()
    let folder = harness.store.folder(for: record.id)
    compactor.afterPrepare = {
      _ = try? C.tone(in: folder, index: 1, startMs: 0, frames: 16_000, frequency: 445)
    }

    #expect(await coordinator.compactAudio(meetingID: record.id, with: compactor) == .failed)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)
    #expect(coordinator.record(id: record.id)?.compressedAudio == nil)
    #expect(try Self.compactedNames(harness, record.id).isEmpty)
    for name in Self.originals(record) {
      #expect(try Self.names(harness, record.id).contains(name))
    }
  }

  @Test("a failed promotion (folder not writable) publishes nothing; a later run commits")
  func failedPromotion() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let folder = harness.store.folder(for: record.id)
    let compactor = WindowedCompactor()
    compactor.afterPrepare = {
      try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    }
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    #expect(await coordinator.compactAudio(meetingID: record.id, with: compactor) == .failed)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)
    for name in Self.originals(record) {
      #expect(try Self.names(harness, record.id).contains(name))
    }
    // Its uncommitted files are temporary; the next run starts clean and commits.
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
  }

  @Test("an open paused player defers publication and keeps its place; released, it proceeds")
  func openPlayerDefers() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    let arbiter = PlaybackArbiter()
    coordinator.playbackArbiter = arbiter
    await Self.launched(harness, record.id)
    let source = coordinator.playbackSource(meetingID: record.id)
    var player: MeetingPlaybackController? = MeetingPlaybackController(
      media: .transcript(Silence()), durationMs: 3_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), sourceID: .meeting(record.id),
      arbiter: arbiter)
    player?.setPlaybackRate(1.5)
    player?.seek(toMs: 1_500)
    #expect(player?.state != .playing)

    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .deferred)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)
    #expect(try Self.compactedNames(harness, record.id).isEmpty)
    #expect(coordinator.playbackSource(meetingID: record.id) == source)
    #expect(player?.positionMs == 1_500)
    #expect(player?.playbackRate == 1.5)
    #expect(player?.state != .unavailable)

    // The page closed: its player is gone, and the next run publishes.
    player = nil
    #expect(arbiter.hasPlayer(.meeting(record.id)) == false)
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
  }

  @Test("no player is offered while the copy is committed, so none starts on the old files")
  func noPlayerDuringCommit() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    #expect(coordinator.playbackSource(meetingID: record.id) != nil)
    let arbiter = PlaybackArbiter()
    coordinator.playbackArbiter = arbiter
    let hold = DispatchSemaphore(value: 0)
    let compactor = WindowedCompactor()
    compactor.afterPrepare = {
      // The writer is busy with earlier work when the commit is asked for.
      MeetingFileWriter.queue.async { _ = hold.wait(timeout: .now() + 10) }
    }
    let compaction = Task { await coordinator.compactAudio(meetingID: record.id, with: compactor) }
    await MeetingCoordinatorTests.eventually("commit waiting, no player offered", drainFiles: false) {
      // The observed read comes first, so the wait is registered on it.
      coordinator.playbackSource(meetingID: record.id) == nil && compactor.prepared == 1
    }
    // A player a page made from a source it read just before (registered now) cannot start.
    let player = MeetingPlaybackController(
      media: .transcript(Silence()), durationMs: 3_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), sourceID: .meeting(record.id),
      arbiter: arbiter)
    player.play()
    #expect(player.state != .playing, "no start while the files are switched")
    hold.signal()
    #expect(await compaction.value == .committed)
    #expect(coordinator.playbackSource(meetingID: record.id) != nil)
  }

  @Test("deleting a meeting while its audio is being encoded waits for the encoder to stop")
  func deletionDuringEncoding() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let first = OSAllocatedUnfairLock(initialState: true)
    let compactor = MeetingAudioCompactor(
      dependencies: .init(encode: { source, destination in
        if first.withLock({ value in defer { value = false }; return value }) {
          entered.signal()
          _ = release.wait(timeout: .now() + 10)
        }
        return try SpeechAudioEncoder.encode(fileAt: source, purpose: .meeting, to: destination)
      }))
    let compaction = Task { await coordinator.compactAudio(meetingID: record.id, with: compactor) }
    await Task.detached { Self.waitBounded(entered) }.value
    let deletion = Task { await coordinator.delete(meetingID: record.id) }
    await MeetingCoordinatorTests.eventually("deletion waits for the compaction", drainFiles: false) {
      coordinator.compactionSettlesWaitingForTesting.contains(record.id)
    }
    // The encoder still holds its first segment: the folder must still be there.
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path))
    release.signal()
    #expect(await compaction.value == .stale)
    #expect(await deletion.value == true)
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path)
      == false)
  }

  // MARK: - Edits and Delete audio after a commit

  @Test("a rename after the commit keeps the compacted copy on disk and in memory")
  func renameKeepsInventory() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
    let inventory = try #require(try harness.store.load(id: record.id).compressedAudio)
    #expect(await coordinator.rename(meetingID: record.id, title: "Board review"))
    let disk = try harness.store.load(id: record.id)
    #expect(disk.title == "Board review")
    #expect(disk.compressedAudio == inventory)
    #expect(coordinator.record(id: record.id)?.compressedAudio == inventory)
  }

  @Test("a record saved from a copy made before the commit never drops the inventory on disk")
  func staleSaveCarriesInventory() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    await Self.launched(harness, record.id)
    let stale = try harness.store.load(id: record.id)
    #expect(
      await harness.coordinator.compactAudio(
        meetingID: record.id, with: MeetingAudioCompactor()) == .committed)
    let inventory = try #require(try harness.store.load(id: record.id).compressedAudio)
    let carried = MeetingCoordinator.carryingCommittedAudio(stale, store: harness.store)
    #expect(carried.compressedAudio == inventory)
  }

  @Test("Delete audio after a commit removes every representation and keeps the record's text")
  func deleteAudioAfterCommit() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
    #expect(await coordinator.deleteAudio(meetingID: record.id))
    let disk = try harness.store.load(id: record.id)
    #expect(disk.audioKept == false)
    #expect(try harness.store.segmentFiles(meeting: record.id).isEmpty)
    // The inventory stays as history; nothing reads it without audio (readers gate on it).
    #expect(disk.compressedAudio != nil)
    #expect(coordinator.playbackSource(meetingID: record.id) == nil)
    #expect(coordinator.canTranscribeAgain(record.id) == false)
  }

  // MARK: - Relaunch

  @Test("relaunch after an exit before the commit removes the abandoned copy, then compacts")
  func relaunchBeforeCommit() async throws {
    let first = try Harness()
    let record = try Self.readyMeeting(first)
    // An exit right after preparation: candidates on disk, nothing committed.
    let ticket = MeetingAudioCompactionTicket(
      meetingID: record.id, claimID: UUID(),
      transcriptGeneration: record.committedTranscriptGeneration, sourceSegments: record.segments)
    _ = try await MeetingAudioCompactor().prepare(
      ticket: ticket, record: record, folder: first.store.folder(for: record.id))
    #expect(try Self.compactedNames(first, record.id).isEmpty == false)

    let second = try Harness(copying: first.root)
    await Self.launched(second, record.id)
    #expect(try Self.compactedNames(second, record.id).isEmpty, "leftovers removed at launch")
    for name in Self.originals(record) { #expect(try Self.names(second, record.id).contains(name)) }
    #expect(
      await second.coordinator.compactAudio(
        meetingID: record.id, with: MeetingAudioCompactor()) == .committed)
  }

  @Test("relaunch after the commit keeps the copy; retirement then resumes idempotently")
  func relaunchAfterCommitThenRetire() async throws {
    let first = try Harness()
    let record = try Self.readyMeeting(first)
    await Self.launched(first, record.id)
    #expect(
      await first.coordinator.compactAudio(
        meetingID: record.id, with: MeetingAudioCompactor()) == .committed)
    let inventory = try #require(try first.store.load(id: record.id).compressedAudio)

    let second = try Harness(copying: first.root)
    second.coordinator.launch()
    // Launch recovery has finished once Transcribe again is offered for the ready meeting.
    await MeetingCoordinatorTests.eventually("listed and launched") {
      second.coordinator.record(id: record.id)?.compressedAudio == inventory
        && second.coordinator.canTranscribeAgain(record.id)
    }
    #expect(try Self.compactedNames(second, record.id).count == inventory.segments.count)
    #expect(
      await second.coordinator.retireSupersededAudio(meetingID: record.id)
        == .removed(inventory.segments.count))
    for name in inventory.segments.map(\.source.fileName) {
      #expect(try Self.names(second, record.id).contains(name) == false)
    }
    #expect(try Self.compactedNames(second, record.id).count == inventory.segments.count)
    #expect(await second.coordinator.retireSupersededAudio(meetingID: record.id) == .removed(0))
    #expect(second.coordinator.playbackSource(meetingID: record.id) != nil)
  }

  @Test("a failed removal reports it and keeps the originals; the retry finishes")
  func retirementFailureRetries() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
    let inventory = try #require(try harness.store.load(id: record.id).compressedAudio)
    let folder = harness.store.folder(for: record.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    #expect(await coordinator.retireSupersededAudio(meetingID: record.id) == .failed(removed: 0))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    for name in Self.originals(record) {
      #expect(try Self.names(harness, record.id).contains(name))
    }
    #expect(
      await coordinator.retireSupersededAudio(meetingID: record.id)
        == .removed(inventory.segments.count))
  }

  @Test("retirement refuses a meeting with no committed copy, or one that is playing")
  func retirementRefuses() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    let arbiter = PlaybackArbiter()
    coordinator.playbackArbiter = arbiter
    await Self.launched(harness, record.id)
    #expect(await coordinator.retireSupersededAudio(meetingID: record.id) == .refused)
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
    let player = MeetingPlaybackController(
      media: .transcript(Silence()), durationMs: 3_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), sourceID: .meeting(record.id),
      arbiter: arbiter)
    player.play()
    #expect(await coordinator.retireSupersededAudio(meetingID: record.id) == .refused)
    for name in Self.originals(record) {
      #expect(try Self.names(harness, record.id).contains(name))
    }
  }

  @Test("Transcribe again after the commit does not block retirement under the new generation")
  func retirementAfterRetranscription() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    await Self.launched(harness, record.id)
    #expect(
      await coordinator.compactAudio(meetingID: record.id, with: MeetingAudioCompactor())
        == .committed)
    let inventory = try #require(try harness.store.load(id: record.id).compressedAudio)
    await MeetingCoordinatorTests.transcribeAgainOnceOffered(coordinator, meetingID: record.id)
    await MeetingCoordinatorTests.livePassFinished(
      coordinator, record.id, replacing: record.committedTranscriptGeneration)
    let current = try harness.store.load(id: record.id)
    #expect(current.committedTranscriptGeneration != inventory.transcriptGeneration)
    #expect(current.compressedAudio == inventory, "the same audio inventory stays")

    // A retirement carrying the earlier generation is refused by the store.
    #expect(throws: MeetingStore.CompactionError.staleGeneration) {
      try harness.store.removeSupersededPCM(
        meeting: record.id, expectedTranscriptGeneration: inventory.transcriptGeneration,
        inventoryID: inventory.id)
    }
    #expect(
      await coordinator.retireSupersededAudio(meetingID: record.id)
        == .removed(inventory.segments.count))
  }

  @Test("playback of a compacted meeting falls back to the verified originals, like recovery")
  func playbackUsesRecoveryFallback() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let folder = harness.store.folder(for: record.id)
    let ticket = MeetingAudioCompactionTicket(
      meetingID: record.id, claimID: UUID(),
      transcriptGeneration: record.committedTranscriptGeneration, sourceSegments: record.segments)
    let verified = try await MeetingAudioCompactor().prepare(
      ticket: ticket, record: record, folder: folder)
    let committed = try harness.store.commitCompressedAudio(
      meeting: record.id, expectedTranscriptGeneration: ticket.transcriptGeneration,
      expectedSegments: ticket.sourceSegments, inventory: verified.inventory)
    let source = MeetingPlaybackSource(record: committed, folder: folder)
    guard case .compactedMeeting = source.media else {
      Issue.record("a committed copy opens through recovery")
      return
    }
    let originals = MeetingPlaybackController.TrackSources(
      uniqueKeysWithValues: record.segments.map { track, segments in
        (
          track,
          segments.map {
            MeetingTrackAudio.SourceFile(
              url: folder.appendingPathComponent($0.fileName), startMs: $0.startMs,
              logicalFrames: nil)
          }
        )
      })
    let expected = try MeetingPlaybackController.open(.meeting(originals))
      .window(startMs: 0, count: 3_000)

    // Whole copy: the compacted files play on the same timeline (lossy, close).
    let whole = try MeetingPlaybackController.open(source.media).window(startMs: 0, count: 3_000)
    #expect(C.maxDifference(whole, expected) < 0.2)

    // One committed file lost: recovery reads the verified originals whole, and playback too.
    let lost = try #require(verified.inventory.segments.first { $0.variant == .raw })
    try FileManager.default.removeItem(at: folder.appendingPathComponent(lost.compressed.fileName))
    let before = try Self.names(harness, record.id)
    let report = MeetingTrackRecovery.recover(
      folder: folder, inventory: verified.inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.compressedProblems.contains(.fellBackToOriginals))
    let fallback = try MeetingPlaybackController.open(source.media)
      .window(startMs: 0, count: 3_000)
    #expect(fallback == expected, "the originals, whole, never a mix")
    #expect(try Self.names(harness, record.id) == before, "playback changed no file")
  }

  // MARK: - Scheduler

  @Test("the scheduler waits for its turn, then compacts an eligible meeting on its own")
  func schedulerCompacts() async throws {
    let harness = try Harness()
    let record = try Self.readyMeeting(harness)
    let coordinator = harness.coordinator
    let wakes = MeetingWakeSignal()
    final class Turn { var mayRun = false }
    let turn = Turn()
    coordinator.audioCompaction = MeetingAudioCompactionScheduler(
      coordinator: coordinator, compactor: MeetingAudioCompactor(),
      dependencies: .init(mayRun: { turn.mayRun }, wakes: wakes, log: { _ in }))
    await Self.launched(harness, record.id)
    #expect(coordinator.audioCompaction?.isRunning == true)
    #expect(try harness.store.load(id: record.id).compressedAudio == nil)

    turn.mayRun = true
    wakes.poke()
    await MeetingCoordinatorTests.eventually("compacted in the background") {
      coordinator.record(id: record.id)?.compressedAudio != nil
    }
    for name in Self.originals(record) {
      #expect(try Self.names(harness, record.id).contains(name))
    }
    coordinator.prepareForTermination()
    #expect(coordinator.audioCompaction?.isRunning == false)
  }
}
#endif
