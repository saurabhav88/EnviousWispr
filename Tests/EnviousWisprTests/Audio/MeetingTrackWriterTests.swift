import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #3972 R3, R15: when these fail, meeting audio is lost, written to the wrong place on the
/// timeline, overwritten, or unreadable after a crash.
@Suite("MeetingTrackWriter", .tags(.productOutcome, .realBoundary))
struct MeetingTrackWriterTests {

  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingTrackWriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tone(seconds: Double) -> [Float] {
    let n = Int(seconds * 16_000)
    return (0..<n).map { sin(Float($0) * 0.05) * 0.3 }
  }

  private func ticks(_ seconds: Double) -> UInt64 {
    AudioConvertNanosToHostTime(UInt64(seconds * 1_000_000_000))
  }

  private final class Collector: Sendable {
    let segments = OSAllocatedUnfairLock<[MeetingSegmentInfo]>(initialState: [])
    let failures = OSAllocatedUnfairLock<Int>(initialState: 0)
  }

  private func makeWriter(_ dir: URL, anchor: UInt64, _ collector: Collector) -> MeetingTrackWriter
  {
    MeetingTrackWriter(
      configuration: .init(
        meetingID: UUID(), track: .microphone, folder: dir, anchorHostTime: anchor),
      onSegmentFinalized: { info in collector.segments.withLock { $0.append(info) } },
      onFailure: { _ in collector.failures.withLock { $0 += 1 } })
  }

  private func frames(_ url: URL) throws -> Int {
    Int(try AVAudioFile(forReading: url).length)
  }

  @Test("150 s of audio becomes three readable segments at 0, 60 and 120 s holding every frame")
  func rollsSegmentsAndKeepsEveryFrame() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let writer = makeWriter(dir, anchor: anchor, collector)
    let audio = tone(seconds: 150)
    // Hand it over in 100 ms chunks with honest, contiguous host times.
    let chunk = 1_600
    var offset = 0
    while offset < audio.count {
      let end = min(audio.count, offset + chunk)
      writer.append(Array(audio[offset..<end]), hostTime: anchor + ticks(Double(offset) / 16_000))
      offset = end
      // Real capture arrives in real time; feeding 150 s at once would overflow the writer's
      // 20 s handoff buffer (which counts the loss). Let the writer catch up every 10 s of audio.
      if offset % (16_000 * 10) == 0 { await writer.waitUntilWritten() }
    }
    await writer.finish()
    #expect(writer.currentHealth.droppedFrames == 0)

    let segments = collector.segments.withLock { $0 }
    #expect(collector.failures.withLock { $0 } == 0)
    #expect(segments.map(\.index) == [1, 2, 3])
    #expect(segments.map(\.startMs) == [0, 60_000, 120_000])
    #expect(segments.reduce(0) { $0 + $1.frameCount } == audio.count)
    for segment in segments {
      let url = dir.appendingPathComponent(segment.fileName)
      #expect(try frames(url) == segment.frameCount)
      #expect(MeetingSegmentNaming.parse(segment.fileName)?.startMs == segment.startMs)
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(MeetingAudioFormat.partialExtension) }
    #expect(leftovers.isEmpty)
  }

  @Test("a stall longer than the gap threshold starts a new segment at the real time")
  func gapStartsNewSegment() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let writer = makeWriter(dir, anchor: anchor, collector)
    writer.append(tone(seconds: 2), hostTime: anchor)
    // The next audio arrives 10 s after the meeting started although only 2 s were written.
    writer.append(tone(seconds: 2), hostTime: anchor + ticks(10))
    await writer.finish()
    let segments = collector.segments.withLock { $0 }
    #expect(segments.count == 2)
    #expect(segments.first?.startMs == 0)
    #expect(abs((segments.last?.startMs ?? 0) - 10_000) <= 5)
    #expect(writer.currentHealth.gaps == 1)
  }

  @Test("an unfinished segment (as a crash leaves it) is readable and holds the audio written")
  func unfinishedSegmentIsReadable() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let writer = makeWriter(dir, anchor: anchor, collector)
    writer.append(tone(seconds: 20), hostTime: anchor)
    await writer.waitUntilWritten()
    #expect(writer.currentHealth.framesWritten == 20 * 16_000)
    let partial = try #require(
      try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .first { $0.hasSuffix(MeetingAudioFormat.partialExtension) })
    // Read it while the writer still holds it open: the on-disk state a crash leaves.
    let readable = try frames(dir.appendingPathComponent(partial))
    print("MEETING_PARTIAL_READABLE frames=\(readable) of \(20 * 16_000)")
    #expect(readable > 0, "an unfinished CAF segment must be readable")
    await writer.finish()
  }

  @Test("a resumed writer continues numbering past existing files and never overwrites them")
  func resumeNeverOverwrites() async throws {
    let dir = try folder()
    let existing = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 3, startMs: 0, partial: false))
    try Data([1, 2, 3]).write(to: existing)
    let collector = Collector()
    let anchor = mach_absolute_time()
    let writer = makeWriter(dir, anchor: anchor, collector)
    writer.resumeNumbering(after: 3)
    writer.append(tone(seconds: 1), hostTime: anchor)
    await writer.finish()
    #expect(collector.segments.withLock { $0 }.map(\.index) == [4])
    #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
  }

  // MARK: - C2a

  private typealias F = MeetingAudioFixture

  private func writer(
    _ dir: URL, anchor: UInt64, _ collector: Collector, segmentSeconds: Double = 60,
    bufferCapacity: Int = 16_000 * 20, maxPendingChunks: Int = 8_192
  ) -> MeetingTrackWriter {
    MeetingTrackWriter(
      configuration: .init(
        meetingID: UUID(), track: .microphone, folder: dir, anchorHostTime: anchor,
        segmentSeconds: segmentSeconds, bufferCapacity: bufferCapacity,
        maxPendingChunks: maxPendingChunks),
      onSegmentFinalized: { info in collector.segments.withLock { $0.append(info) } },
      onFailure: { _ in collector.failures.withLock { $0 += 1 } })
  }

  private func samples(_ range: Range<Int>, seed: Int = 0) -> [Float] {
    range.map { F.value($0, seed: seed) }
  }

  @Test("decoded audio equals what was appended, through an exact rollover, a rollover inside an append and a short tail")
  func decodedAudioMatchesAcrossRollovers() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector, segmentSeconds: 1)
    let all = samples(0..<44_000)
    // 16,000 exactly fills segment 1; 20,000 fills segment 2 and spills 4,000 into segment 3;
    // the last 8,000 are a short tail.
    var at = 0
    for count in [16_000, 20_000, 8_000] {
      w.append(Array(all[at..<(at + count)]), hostTime: anchor + ticks(Double(at) / 16_000))
      at += count
    }
    #expect(await w.finish() == .finalized)
    let segments = collector.segments.withLock { $0 }
    #expect(segments.map(\.startMs) == [0, 1_000, 2_000])
    #expect(segments.map(\.frameCount) == [16_000, 16_000, 12_000])
    var decoded: [Float] = []
    for segment in segments { decoded += try F.decode(dir.appendingPathComponent(segment.fileName)) }
    #expect(F.matches(decoded[...], all))
    #expect(w.currentHealth.framesWritten == 44_000)
    #expect(collector.failures.withLock { $0 } == 0)
  }

  #if DEBUG
  @Test("a full handoff counts every dropped frame, keeps accepted audio, and restarts at the next audio's own time")
  func overflowIsCountedAndMarked() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector, bufferCapacity: 1_000)
    w.suspendQueueForTesting()
    // 600 fit; of the next 600 only 400 fit; the next 300 find no room at all.
    w.append(samples(0..<600), hostTime: anchor)
    w.append(samples(600..<1_200), hostTime: anchor + ticks(600.0 / 16_000))
    w.append(samples(1_200..<1_500), hostTime: anchor + ticks(1_200.0 / 16_000))
    w.resumeQueueForTesting()
    await w.waitUntilWritten()
    w.append(samples(1_500..<2_000), hostTime: anchor + ticks(1_500.0 / 16_000))
    #expect(await w.finish() == .finalized)

    let health = w.currentHealth
    #expect(health.droppedFrames == 500)
    #expect(health.framesWritten == 1_500)
    #expect(health.discontinuities == 1)
    let segments = collector.segments.withLock { $0 }
    // The second segment starts at the 1 ms boundary at or before its arrival (1,488).
    #expect(segments.map(\.startMs) == [0, 93])
    #expect(segments.map(\.frameCount) == [1_000, 500])
    let audio = MeetingTrackAudio(files: segments.map { (dir.appendingPathComponent($0.fileName), $0.startMs) })
    let read = try audio.read(from: 0, count: 1_988)
    #expect(F.matches(read[0..<1_000], samples(0..<1_000)))
    #expect(read[1_000..<1_488].allSatisfy { $0 == 0 })
    #expect(F.matches(read[1_488..<1_988], samples(1_500..<2_000)))
  }
  #endif

  #if DEBUG
  @Test("more appends than the handoff can track between drains are dropped and counted, not stored")
  func pendingChunkLimitDrops() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector, maxPendingChunks: 2)
    w.suspendQueueForTesting()
    for i in 0..<3 {
      w.append(samples((i * 160)..<((i + 1) * 160)), hostTime: anchor + ticks(Double(i) * 0.01))
    }
    w.resumeQueueForTesting()
    #expect(await w.finish() == .finalized)
    #expect(w.currentHealth.droppedFrames == 160)
    #expect(w.currentHealth.framesWritten == 320)
  }
  #endif

  #if DEBUG
  @Test("the handoff buffer is reused across drains, never reallocated")
  func handoffStorageIsReused() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector)
    var addresses = Set<UInt>()
    for i in 0..<50 {
      w.append(samples(0..<1_600), hostTime: anchor + ticks(Double(i) * 0.1))
      addresses.insert(w.handoffStorageForTesting())
      await w.waitUntilWritten()
    }
    await w.finish()
    // Two buffers swap places; a reallocation would show a third address.
    #expect(addresses.count <= 2, "\(addresses.count) distinct handoff buffers")
  }
  #endif

  @Test("existing files are never erased: the writer skips every index already in the folder")
  func existingFilesAreNeverErased() async throws {
    let dir = try folder()
    let partial = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: true))
    let final = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 2, startMs: 7_000, partial: false))
    try Data([9, 9]).write(to: partial)
    try Data([8, 8]).write(to: final)
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector)
    w.append(samples(0..<1_600), hostTime: anchor)
    #expect(await w.finish() == .finalized)
    #expect(collector.segments.withLock { $0 }.map(\.index) == [3])
    #expect(try Data(contentsOf: partial) == Data([9, 9]))
    #expect(try Data(contentsOf: final) == Data([8, 8]))
  }

  @Test("a rename that would overwrite is refused once, keeps the partial and reports nothing finished")
  func renameCollisionIsReportedOnce() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector)
    w.append(samples(0..<1_600), hostTime: anchor)
    await w.waitUntilWritten()
    let finalName = MeetingSegmentNaming.fileName(
      track: .microphone, index: 1, startMs: 0, partial: false)
    try Data([7]).write(to: dir.appendingPathComponent(finalName))
    #expect(await w.finish() == .failed)
    #expect(await w.finish() == .failed)
    #expect(collector.failures.withLock { $0 } == 1)
    #expect(collector.segments.withLock { $0 }.isEmpty)
    #expect(try Data(contentsOf: dir.appendingPathComponent(finalName)) == Data([7]))
    let partial = MeetingSegmentNaming.fileName(
      track: .microphone, index: 1, startMs: 0, partial: true)
    #expect(try F.decode(dir.appendingPathComponent(partial)).count == 1_600)
  }

  @Test("a folder it cannot write to fails the writer once and rejects later audio")
  func createFailureIsReportedOnce() async throws {
    let dir = try folder()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector)
    w.append(samples(0..<1_600), hostTime: anchor)
    #expect(await w.finish() == .failed)
    w.append(samples(0..<1_600), hostTime: anchor + ticks(1))
    #expect(await w.finish() == .failed)
    #expect(collector.failures.withLock { $0 } == 1)
    #expect(w.currentHealth.failed)
    #expect(w.currentHealth.rejectedFrames == 1_600)
  }

  #if DEBUG
  @Test("a close past its deadline keeps ownership: the queued close finishes the file once")
  func closeTimeoutKeepsOwnership() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector)
    w.append(samples(0..<1_600), hostTime: anchor)
    w.suspendQueueForTesting()
    #expect(w.close(until: .now() + .milliseconds(50)) == .timedOut)
    #expect(collector.segments.withLock { $0 }.isEmpty)
    // Audio after a close is refused, not written.
    w.append(samples(0..<800), hostTime: anchor + ticks(0.1))
    w.resumeQueueForTesting()
    #expect(await w.finish() == .finalized)
    #expect(w.close(until: .now() + .seconds(5)) == .finalized)
    let segments = collector.segments.withLock { $0 }
    #expect(segments.map(\.frameCount) == [1_600])
    #expect(w.currentHealth.rejectedFrames == 800)
  }
  #endif

  @Test("a folder it cannot list fails the writer: no index is guessed and existing files stay")
  func unlistableFolderFailsTheWriter() async throws {
    let dir = try folder()
    let existing = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 5_000, partial: false))
    try Data([4, 4]).write(to: existing)
    // Write and search but not list: exclusive creation alone could reuse index 1.
    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let collector = Collector()
    let anchor = mach_absolute_time()
    let w = writer(dir, anchor: anchor, collector)
    w.append(samples(0..<1_600), hostTime: anchor)
    #expect(await w.finish() == .failed)
    #expect(collector.failures.withLock { $0 } == 1)
    #expect(collector.segments.withLock { $0 }.isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [existing.lastPathComponent])
    #expect(try Data(contentsOf: existing) == Data([4, 4]))
  }

  @Test("audio stamped before the meeting's start is trimmed, counted, and the rest starts at 0")
  func preAnchorAudioIsTrimmed() async throws {
    let dir = try folder()
    let collector = Collector()
    let anchor = mach_absolute_time() + ticks(1)
    let w = writer(dir, anchor: anchor, collector)
    w.append(samples(0..<16_000), hostTime: anchor - ticks(0.5))
    #expect(await w.finish() == .finalized)
    #expect(w.currentHealth.preAnchorFrames == 8_000)
    let segments = collector.segments.withLock { $0 }
    #expect(segments.map(\.startMs) == [0])
    #expect(segments.map(\.frameCount) == [8_000])
    let decoded = try F.decode(dir.appendingPathComponent(segments[0].fileName))
    #expect(F.matches(decoded[...], samples(8_000..<16_000)))
  }
}
