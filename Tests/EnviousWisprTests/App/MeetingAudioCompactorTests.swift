import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
import EnviousWisprStorage

/// #3147 PR4B: when these fail, preparing a meeting's compacted audio changes or removes an
/// original, leaves stray files behind, or hands publication a set that is incomplete, made
/// from audio that changed meanwhile, or not readable as the same meeting.
@MainActor
@Suite("Meeting audio compactor preparation", .tags(.productOutcome))
struct MeetingAudioCompactorTests {
  private typealias C = CompactedAudioFixture

  private struct Fixture {
    let folder: URL
    let record: MeetingRecord
    let ticket: MeetingAudioCompactionTicket
    let raw: [MeetingSegmentInfo]
    let cleaned: [MeetingSegmentInfo]
    let call: MeetingSegmentInfo
    let proofName: String
  }

  private func fixture() throws -> Fixture {
    let folder = try MeetingAudioFixture.folder("MeetingAudioCompactorTests")
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
    let proof = try C.proof(in: folder, twins: cleaned)
    var record = MeetingRecord(
      engine: .parakeet, trackStatus: [.microphone: .captured, .callSound: .captured])
    record.segments = [.microphone: raw, .callSound: [call]]
    let ticket = MeetingAudioCompactionTicket(
      meetingID: record.id, claimID: UUID(),
      transcriptGeneration: record.committedTranscriptGeneration, sourceSegments: record.segments)
    return Fixture(
      folder: folder, record: record, ticket: ticket, raw: raw, cleaned: cleaned, call: call,
      proofName: proof.0)
  }

  private func listing(_ folder: URL) throws -> [String: MeetingAudioFileIdentity] {
    var result: [String: MeetingAudioFileIdentity] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
      result[name] = try MeetingStore.audioFileIdentity(at: folder.appendingPathComponent(name))
    }
    return result
  }

  @Test("prepare encodes every segment once, verified, beside untouched originals")
  func preparesVerifiedInventory() async throws {
    let f = try fixture()
    let before = try listing(f.folder)
    let verified = try await MeetingAudioCompactor().prepare(
      ticket: f.ticket, record: f.record, folder: f.folder)
    let inventory = verified.inventory
    #expect(inventory.version == MeetingCompressedInventory.currentVersion)
    #expect(inventory.transcriptGeneration == f.ticket.transcriptGeneration)
    #expect(inventory.segments.count == 5)
    #expect(
      Set(inventory.segments.map(\.source.fileName))
        == Set((f.raw + f.cleaned + [f.call]).map(\.fileName)))
    #expect(inventory.cleanedProofs == [f.proofName: try #require(before[f.proofName])])
    let after = try listing(f.folder)
    // Every original is unchanged; the only new files are this attempt's uncommitted outputs.
    for (name, identity) in before { #expect(after[name] == identity, "\(name)") }
    let added = Set(after.keys).subtracting(before.keys)
    #expect(
      added
        == Set(inventory.segments.map { MeetingAudioCompactor.partialName($0.compressed.fileName) })
    )
    for segment in inventory.segments {
      #expect(segment.sourceIdentity == before[segment.source.fileName])
      #expect(segment.compressed.frameCount == segment.source.frameCount)
      #expect(segment.compressed.startMs == segment.source.startMs)
      #expect(
        MeetingSegmentNaming.parseAny(segment.compressed.fileName)?.inventoryID == inventory.id)
      #expect(
        segment.compressedIdentity
          == after[MeetingAudioCompactor.partialName(segment.compressed.fileName)])
    }
    let saved = inventory.segments.reduce(Int64(0)) { $0 + $1.compressedIdentity.byteCount }
    let original = inventory.segments.reduce(Int64(0)) { $0 + $1.sourceIdentity.byteCount }
    // One-second test tones carry the M4A header; a meeting-length segment saves far more.
    #expect(saved < original, "\(saved) of \(original) bytes")

    // Once the outputs take their final names (what publication does), recovery reads exactly
    // this inventory and the cleaned proof carries over.
    for segment in inventory.segments {
      try FileManager.default.moveItem(
        at: f.folder.appendingPathComponent(
          MeetingAudioCompactor.partialName(segment.compressed.fileName)),
        to: f.folder.appendingPathComponent(segment.compressed.fileName))
    }
    let report = MeetingTrackRecovery.recover(folder: f.folder, inventory: inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.representation == .aacM4A)
    #expect(report.problems.isEmpty && report.cleanedProblems.isEmpty)
    #expect(report.compressedProblems.isEmpty)
    #expect(
      MeetingMicrophoneSelection.decide(
        raw: report.segments[.microphone] ?? [], report: report, provenance: .compactionFixture)
        == .cleaned(report.cleanedSegments, .compactionFixture))
    let audio = MeetingTrackAudio(segments: report.segments[.microphone] ?? [], in: f.folder)
    #expect(audio.problems.isEmpty)
    #expect(audio.endSample == 40_000)
    #expect(try audio.read(from: 16_000, count: 16_000).allSatisfy { $0 == 0 })
  }

  @Test("a prepared inventory commits through the store, and recovery then reads it")
  func commitsThroughStore() async throws {
    let root = try MeetingAudioFixture.folder("MeetingAudioCompactorTests-store")
    let store = MeetingStore(root: root)
    var record = MeetingRecord(
      engine: .parakeet, trackStatus: [.microphone: .captured, .callSound: .captured])
    try store.create(record)
    let folder = store.folder(for: record.id)
    let raw = [
      try C.tone(in: folder, index: 1, startMs: 0, frames: 16_000, frequency: 440),
      try C.tone(in: folder, index: 2, startMs: 2_000, frames: 8_000, frequency: 660),
    ]
    let cleaned = [
      try C.tone(
        in: folder, variant: .cleaned, index: 1, startMs: 0, frames: 16_000, frequency: 330)
    ]
    let call = try C.tone(
      in: folder, track: .callSound, index: 3, startMs: 500, frames: 12_000, frequency: 880)
    _ = try C.proof(in: folder, twins: cleaned)
    record.segments = [.microphone: raw, .callSound: [call]]
    try store.save(record)
    let ticket = MeetingAudioCompactionTicket(
      meetingID: record.id, claimID: UUID(),
      transcriptGeneration: record.committedTranscriptGeneration, sourceSegments: record.segments)

    let verified = try await MeetingAudioCompactor().prepare(
      ticket: ticket, record: record, folder: folder)
    let committed = try store.commitCompressedAudio(
      meeting: record.id, expectedTranscriptGeneration: ticket.transcriptGeneration,
      expectedSegments: ticket.sourceSegments, inventory: verified.inventory)
    #expect(committed.compressedAudio == verified.inventory)
    let report = MeetingTrackRecovery.recover(
      folder: folder, inventory: committed.compressedAudio,
      identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.representation == .aacM4A)
    #expect(report.problems.isEmpty && report.cleanedProblems.isEmpty)
    #expect(report.compressedProblems.isEmpty)
    #expect(report.segments[.microphone]?.map(\.frameCount) == [16_000, 8_000])
    #expect(report.cleanedConfirmed.map(\.fileName) == report.cleanedSegments.map(\.fileName))
  }

  @Test("discard removes only this attempt's uncommitted outputs")
  func discardRemovesOwnOutputs() async throws {
    let f = try fixture()
    let before = try listing(f.folder)
    let verified = try await MeetingAudioCompactor().prepare(
      ticket: f.ticket, record: f.record, folder: f.folder)
    #expect(MeetingAudioCompactor.discard(verified, folder: f.folder) == 5)
    #expect(try listing(f.folder) == before)
  }

  @Test("a source changed during encoding: nothing is returned and no output is left")
  func sourceChangedDuringEncoding() async throws {
    let f = try fixture()
    let changed = f.raw[1]
    let compactor = MeetingAudioCompactor(
      dependencies: .init(afterEncoding: { folder in
        _ = try? C.tone(
          in: folder, index: changed.index, startMs: changed.startMs,
          frames: changed.frameCount, frequency: 700)
      }))
    let before = try listing(f.folder)
    await #expect(throws: MeetingAudioCompactor.PreparationError.sourceChanged) {
      _ = try await compactor.prepare(ticket: f.ticket, record: f.record, folder: f.folder)
    }
    #expect(Set(try listing(f.folder).keys) == Set(before.keys))
  }

  @Test("an encode failure partway removes the outputs already made, and only those")
  func encodeFailurePartway() async throws {
    let f = try fixture()
    let calls = CompactorEncodeCounter()
    let compactor = MeetingAudioCompactor(
      dependencies: .init(encode: { source, destination in
        if calls.next() == 3 { throw SpeechAudioEncoder.Failure.encodeFailed }
        return try SpeechAudioEncoder.encode(fileAt: source, purpose: .meeting, to: destination)
      }))
    let before = try listing(f.folder)
    await #expect(throws: MeetingAudioCompactor.PreparationError.self) {
      _ = try await compactor.prepare(ticket: f.ticket, record: f.record, folder: f.folder)
    }
    #expect(try listing(f.folder) == before)
  }

  @Test("cancelling prepare drains the work and leaves no output")
  func cancellationDrains() async throws {
    let f = try fixture()
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let calls = CompactorEncodeCounter()
    let compactor = MeetingAudioCompactor(
      dependencies: .init(encode: { source, destination in
        if calls.next() == 2 {
          started.continuation.yield()
          // deadline-fallback: the test signals after cancelling; 20 s only frees a test that never does.
          _ = release.wait(timeout: .now() + 20)
          try Task.checkCancellation()
        }
        return try SpeechAudioEncoder.encode(fileAt: source, purpose: .meeting, to: destination)
      }))
    let before = try listing(f.folder)
    let task = Task {
      try await compactor.prepare(ticket: f.ticket, record: f.record, folder: f.folder)
    }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    // Cancelling the caller cancels the detached work at once (its cancellation handler).
    task.cancel()
    release.signal()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    // `prepare` returned only after the work removed what it made.
    #expect(try listing(f.folder) == before)
  }

  @Test("a meeting that is not a finished, unchanged recording is refused")
  func refusals() async throws {
    let f = try fixture()
    let compactor = MeetingAudioCompactor()
    var other = f.ticket.sourceSegments
    other[.callSound] = []
    let staleTicket = MeetingAudioCompactionTicket(
      meetingID: f.record.id, claimID: UUID(), transcriptGeneration: nil, sourceSegments: other)
    await #expect(throws: MeetingAudioCompactor.PreparationError.sourceChanged) {
      _ = try await compactor.prepare(ticket: staleTicket, record: f.record, folder: f.folder)
    }
    var deleting = f.record
    deleting.deletionRequested = true
    await #expect(throws: MeetingAudioCompactor.PreparationError.notEligible("deleting")) {
      _ = try await compactor.prepare(ticket: f.ticket, record: deleting, folder: f.folder)
    }
    let before = try listing(f.folder)
    // An unpromoted recorder partial: the recording is not finished on disk.
    let partial = try MeetingAudioFixture.writeSegment(
      in: f.folder, index: 9, startMs: 5_000, frames: 1_600, partial: true)
    await #expect(throws: MeetingAudioCompactor.PreparationError.notEligible("partial")) {
      _ = try await compactor.prepare(ticket: f.ticket, record: f.record, folder: f.folder)
    }
    try FileManager.default.removeItem(at: partial)
    #expect(try listing(f.folder) == before)
  }
}

/// A thread-safe call counter for encode seams (they run off the main actor).
private final class CompactorEncodeCounter: @unchecked Sendable {
  // One integer behind one lock: safe from any thread.
  private let lock = NSLock()
  private var value = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}
