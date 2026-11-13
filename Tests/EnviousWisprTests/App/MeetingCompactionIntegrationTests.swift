import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #3147 PR4B I1: when these fail, a meeting whose audio was compacted is transcribed again from
/// the wrong files or at the wrong times, loses its echo-cleaned microphone copy, hides a missing
/// stretch or marks the wrong one, or keeps playing old files after its representation changed.
@MainActor
@Suite("Compacted meeting audio in the coordinator and playback", .tags(.productOutcome))
struct MeetingCompactionIntegrationTests {
  typealias Harness = MeetingCoordinatorTests.Harness
  private typealias C = CompactedAudioFixture

  private struct Meeting {
    let record: MeetingRecord
    let folder: URL
    let raw: [MeetingSegmentInfo]
    let call: MeetingSegmentInfo
    let inventory: MeetingCompressedInventory
  }

  /// A ready meeting on disk: microphone segments at 0 and 2 s (a 1 s gap between), their
  /// proof-backed cleaned twins, one call segment, and the production-prepared compacted copy
  /// committed through the store. Every original is still on disk.
  private func committedMeeting(_ harness: Harness) async throws -> Meeting {
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
    record.echoProvenance = .compactionFixture
    try harness.store.save(record)
    let ticket = MeetingAudioCompactionTicket(
      meetingID: record.id, claimID: UUID(),
      transcriptGeneration: record.committedTranscriptGeneration, sourceSegments: record.segments)
    let verified = try await MeetingAudioCompactor().prepare(
      ticket: ticket, record: record, folder: folder)
    let committed = try harness.store.commitCompressedAudio(
      meeting: record.id, expectedTranscriptGeneration: ticket.transcriptGeneration,
      expectedSegments: ticket.sourceSegments, inventory: verified.inventory)
    return Meeting(
      record: committed, folder: folder, raw: raw, call: call, inventory: verified.inventory)
  }

  private func compactedName(_ meeting: Meeting, _ source: MeetingSegmentInfo) throws -> String {
    try #require(meeting.inventory.segments.first { $0.source == source }).compressed.fileName
  }

  @Test(
    "Transcribe again reads the committed compacted files at the recorder's times, both engines",
    arguments: MeetingEngineChoice.allCases)
  func transcribeAgainReadsCompacted(engine: MeetingEngineChoice) async throws {
    let harness = try Harness()
    let meeting = try await committedMeeting(harness)
    let coordinator = harness.coordinator
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      coordinator.record(id: meeting.record.id) != nil
    }
    await MeetingCoordinatorTests.transcribeAgainOnceOffered(
      coordinator, meetingID: meeting.record.id, engine: engine)
    await MeetingCoordinatorTests.livePassFinished(coordinator, meeting.record.id)

    let job = try #require(harness.jobs.last)
    let microphone = try #require(job.receivedTracks[.microphone])
    let call = try #require(job.receivedTracks[.callSound])
    // The proof-backed cleaned copy reached transcription, from compacted files.
    #expect(job.receivedMicrophoneCopies.last == .cleaned(.compactionFixture))
    for track in [microphone, call] {
      #expect(track.problems.isEmpty)
      #expect(track.segments.allSatisfy { $0.compressed })
      #expect(
        track.segments.allSatisfy {
          MeetingSegmentNaming.parseAny($0.url.lastPathComponent)?.inventoryID
            == meeting.inventory.id
        })
    }
    #expect(microphone.segments.map(\.startSample) == [0, 32_000])
    #expect(microphone.segments.map(\.frameCount) == [16_000, 8_000])
    #expect(call.segments.map(\.startSample) == [8_000])
    #expect(try microphone.read(from: 16_000, count: 16_000).allSatisfy { $0 == 0 })
    #expect(job.receivedMissingAudio.isEmpty)
    // The record keeps the recorder's descriptors and its committed inventory.
    let disk = try harness.store.load(id: meeting.record.id)
    #expect(disk.segments == meeting.record.segments)
    #expect(disk.compressedAudio == meeting.inventory)
  }

  @Test("a missing committed file with a changed original is a gap bounded by the inventory")
  func missingCommittedFileIsBounded() async throws {
    let harness = try Harness()
    let meeting = try await committedMeeting(harness)
    let lost = try compactedName(meeting, meeting.raw[0])
    try FileManager.default.removeItem(at: meeting.folder.appendingPathComponent(lost))
    // The original changed too: there is no verified complete representation to read instead.
    try C.tone(in: meeting.folder, index: 1, startMs: 0, frames: 16_000, frequency: 450)
    let coordinator = harness.coordinator
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      coordinator.record(id: meeting.record.id) != nil
    }
    await MeetingCoordinatorTests.transcribeAgainOnceOffered(
      coordinator, meetingID: meeting.record.id)
    await MeetingCoordinatorTests.livePassFinished(coordinator, meeting.record.id)

    let job = try #require(harness.jobs.last)
    // The lost file's own stretch, from its start to the next file's start: never unbounded.
    let missing = job.receivedMissingAudio[.microphone] ?? []
    #expect(missing.map(\.startMs) == [0])
    #expect(missing.map(\.endMs) == [2_000])
    #expect(job.receivedMissingAudio[.callSound] == nil)
    // What is left is still the compacted copy (never a mix with an original).
    let microphone = try #require(job.receivedTracks[.microphone])
    #expect(microphone.segments.map(\.startSample) == [32_000])
    #expect(microphone.segments.allSatisfy { $0.compressed })
    #expect(harness.logs.contains("meeting compacted audio finding=originals_unavailable"))
    #expect(harness.logs.allSatisfy { !$0.contains("finding=") || !$0.contains(".m4a") })
    // The logical segments are not shrunk by the damage.
    #expect(try harness.store.load(id: meeting.record.id).segments == meeting.record.segments)
  }

  @Test("an unreadable committed copy with no verified originals fails, never notes-only")
  func refusedInventoryIsNotNotesOnly() async throws {
    let harness = try Harness()
    let meeting = try await committedMeeting(harness)
    _ = try harness.store.saveNotes("Agenda", revision: 1, meeting: meeting.record.id)
    // A committed inventory the selector refuses (one segment listed twice, differently), and an
    // original that no longer matches: nothing verified is left to read.
    var record = try harness.store.load(id: meeting.record.id)
    let first = meeting.inventory.segments[0]
    let conflicting = MeetingCompressedSegment(
      track: first.track, variant: first.variant,
      source: MeetingSegmentInfo(
        index: first.source.index, fileName: first.source.fileName, startMs: 7,
        frameCount: first.source.frameCount),
      sourceIdentity: first.sourceIdentity, compressed: first.compressed,
      compressedIdentity: first.compressedIdentity)
    let refused = MeetingCompressedInventory(
      id: meeting.inventory.id, transcriptGeneration: meeting.inventory.transcriptGeneration,
      segments: meeting.inventory.segments + [conflicting],
      cleanedProofs: meeting.inventory.cleanedProofs)
    record.forceCompressedAudioForTesting(refused)
    try harness.store.save(record)
    try C.tone(in: meeting.folder, index: 1, startMs: 0, frames: 16_000, frequency: 450)

    let coordinator = harness.coordinator
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      coordinator.record(id: meeting.record.id) != nil
    }
    await MeetingCoordinatorTests.transcribeAgainOnceOffered(
      coordinator, meetingID: meeting.record.id)
    await MeetingCoordinatorTests.eventually("the pass ended") {
      coordinator.processing == nil
        && coordinator.record(id: meeting.record.id)?.state != .queued
        && coordinator.record(id: meeting.record.id)?.state != .processing
    }
    let disk = try harness.store.load(id: meeting.record.id)
    #expect(disk.state == .failed)
    #expect(disk.failureCode == "audio_unreadable")
    #expect(harness.logs.contains("meeting compacted audio finding=originals_unavailable"))
  }

  @Test("committing a compacted copy is a new playback source that plays the same timeline")
  func playbackSourceChangesOnCommit() async throws {
    let harness = try Harness()
    let meeting = try await committedMeeting(harness)
    let before = MeetingPlaybackSource(
      record: try harness.store.load(id: meeting.record.id).withoutCompaction(),
      folder: meeting.folder)
    let after = MeetingPlaybackSource(record: meeting.record, folder: meeting.folder)
    #expect(before.inventoryID == nil)
    #expect(after.inventoryID == meeting.inventory.id)
    #expect(MeetingPlaybackSource.change(from: before, to: after) == .replace)
    #expect(MeetingPlaybackSource.change(from: after, to: after) == .keep)
    // Playback is the raw copy: the compacted raw files, at the recorder's lengths.
    let microphone = try #require(after.files[.microphone])
    #expect(
      microphone.map(\.url.lastPathComponent)
        == (try meeting.raw.map { try compactedName(meeting, $0) }))
    #expect(microphone.map(\.logicalFrames) == [16_000, 8_000])
    let tracks = try MeetingPlaybackController.load(after.trackSources)
    let original = try MeetingPlaybackController.load(before.trackSources)
    #expect(tracks.map(\.endSample) == original.map(\.endSample))
    #expect(tracks.allSatisfy { $0.problems.isEmpty })

    let coordinator = harness.coordinator
    coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      coordinator.record(id: meeting.record.id) != nil
    }
    #expect(coordinator.playbackSource(meetingID: meeting.record.id) == after)
  }
}

extension MeetingRecord {
  /// The same record as it was before its compacted copy was committed (a test's "before").
  fileprivate func withoutCompaction() throws -> MeetingRecord {
    var object = try #require(
      try JSONSerialization.jsonObject(with: MeetingStore.encoder.encode(self)) as? [String: Any])
    object.removeValue(forKey: "compressedAudio")
    return try MeetingStore.decoder.decode(
      MeetingRecord.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

extension MeetingRecord {
  /// Sets a committed inventory directly (a test of an inventory the store would never commit).
  fileprivate mutating func forceCompressedAudioForTesting(_ inventory: MeetingCompressedInventory) {
    commitCompressedAudio(inventory)
  }
}

