import AVFoundation
import CoreAudio
import Darwin
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

#if DEBUG
// Uses the writer's DEBUG-only queue seams.
/// #4248: when these fail, room talk the user meant to keep out is saved while they are muted,
/// words they said are lost, audio is written twice or out of place, or the recording's length
/// and segments change because silence was written.
///
/// Audio is SYNTHETIC: a constant 0.25 signal (16-bit file value 8192), so any sample the hold
/// zeroes reads back as exactly 0 and every other sample as non-zero.
@Suite("Meeting microphone silence hold", .serialized, .tags(.productOutcome))
struct MeetingMicrophoneSilenceTests {
  static let level: Float = 0.25
  static let rate = 16_000

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent(
        "MeetingMicrophoneSilenceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func ticks(_ seconds: Double) -> UInt64 {
    AudioConvertNanosToHostTime(UInt64((seconds * 1_000_000_000).rounded()))
  }

  private func ticks(samples: Int) -> UInt64 { MeetingMicrophoneSilence.ticks(forSamples: samples) }

  /// Every decoded sample of the track's finished segments, in file order.
  private func readBack(_ dir: URL) throws -> (samples: [Float], files: [String]) {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".caf") }
      .sorted {
        (MeetingSegmentNaming.parse($0)?.index ?? 0) < (MeetingSegmentNaming.parse($1)?.index ?? 0)
      }
    var all: [Float] = []
    for name in names {
      let file = try AVAudioFile(forReading: dir.appendingPathComponent(name))
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
      try file.read(into: buffer)
      let channel = try #require(buffer.floatChannelData?[0])
      all.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    return (all, names)
  }

  final class Released: Sendable {
    let chunks = OSAllocatedUnfairLock<[(MeetingReleasedChunk, [Float])]>(initialState: [])
    /// C as read from inside each release callback, beside that chunk's end.
    let watermarks = OSAllocatedUnfairLock<[(seen: UInt64, chunkEnd: UInt64)]>(initialState: [])
    /// Weak, so the writer's callback holding this collector forms no cycle; the rig keeps the
    /// writer alive.
    struct WeakWriter { weak var writer: MeetingTrackWriter? }
    let writer = OSAllocatedUnfairLock(initialState: WeakWriter())
    /// Fired once `count` samples have been released.
    let target = OSAllocatedUnfairLock<(count: Int, signal: BoundedWait.Signal)?>(initialState: nil)
    var all: [(MeetingReleasedChunk, [Float])] { chunks.withLock { $0 } }
    var samples: [Float] { all.flatMap(\.1) }
  }

  /// A test clock and the releases the writer asked to schedule.
  final class Clock: Sendable {
    let time: OSAllocatedUnfairLock<UInt64>
    let pending = OSAllocatedUnfairLock<[(UInt64, @Sendable () -> Void)]>(initialState: [])
    init(_ start: UInt64) { time = OSAllocatedUnfairLock(initialState: start) }
    var now: UInt64 { time.withLock { $0 } }
    func set(_ value: UInt64) { time.withLock { $0 = value } }
    /// Runs every scheduled release due by now.
    func fireDue() {
      let now = self.now
      let due = pending.withLock { list -> [@Sendable () -> Void] in
        let ready = list.filter { $0.0 <= now }.map(\.1)
        list.removeAll { $0.0 <= now }
        return ready
      }
      due.forEach { $0() }
    }
  }

  private struct Rig {
    let dir: URL
    let anchor: UInt64
    let writer: MeetingTrackWriter
    let released: Released
    let clock: Clock?
  }

  private func rig(
    hold: Double? = 3.0, manual: Bool = true, segmentSeconds: Double = 60,
    bufferCapacity: Int = 16_000 * 20, track: MeetingTrackKind = .microphone
  ) throws -> Rig {
    let dir = try folder()
    let anchor = mach_absolute_time()
    let released = Released()
    let clock = manual ? Clock(anchor) : nil
    let writer = MeetingTrackWriter(
      configuration: .init(
        meetingID: UUID(), track: track, folder: dir, anchorHostTime: anchor,
        segmentSeconds: segmentSeconds, bufferCapacity: bufferCapacity, silenceHoldSeconds: hold),
      onSegmentFinalized: { _ in }, onFailure: { _ in },
      onReleased: { frames, info in
        let copy = Array(frames)
        let seen = released.writer.withLock { $0.writer?.releasedHostTime } ?? 0
        let chunkEnd = info.hostTime &+ MeetingMicrophoneSilence.ticks(forSamples: copy.count)
        released.watermarks.withLock { $0.append((seen, chunkEnd)) }
        let total = released.chunks.withLock { list -> Int in
          list.append((info, copy))
          return list.reduce(0) { $0 + $1.1.count }
        }
        if let target = released.target.withLock({ $0 }), total >= target.count {
          target.signal.fire()
        }
      },
      now: { clock?.now ?? mach_absolute_time() },
      scheduler: clock.map { c -> MeetingTrackWriter.ReleaseScheduler in
        .manual { due, run in c.pending.withLock { $0.append((due, run)) } }
      } ?? .live)
    released.writer.withLock { $0.writer = writer }
    return Rig(dir: dir, anchor: anchor, writer: writer, released: released, clock: clock)
  }

  /// `seconds` of the constant signal in `chunk`-sample appends from `start` seconds after the
  /// anchor, with honest contiguous host times.
  private func feed(_ rig: Rig, from start: Double = 0, seconds: Double, chunk: Int = 1_600) {
    let total = Int(seconds * Double(Self.rate))
    let base = rig.anchor &+ ticks(start)
    var offset = 0
    while offset < total {
      let n = min(chunk, total - offset)
      rig.writer.append(
        [Float](repeating: Self.level, count: n), hostTime: base &+ ticks(samples: offset))
      offset += n
    }
  }

  private func interval(_ rig: Rig, _ start: Double, _ end: Double) -> MeetingSilenceInterval {
    MeetingSilenceInterval(start: rig.anchor &+ ticks(start), end: rig.anchor &+ ticks(end))
  }

  /// Indexes of zero samples, as half-open runs.
  private func zeroRuns(_ samples: [Float]) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    var start: Int?
    for (i, v) in samples.enumerated() {
      if v == 0 {
        start = start ?? i
      } else if let s = start {
        runs.append(s..<i)
        start = nil
      }
    }
    if let s = start { runs.append(s..<samples.count) }
    return runs
  }

  // MARK: - Sample boundaries

  @Test("a sample is silenced exactly when start <= its time < end")
  func sampleBoundaries() {
    let base: UInt64 = 1_000_000
    let s = { (n: Int) in base &+ MeetingMicrophoneSilence.ticks(forSamples: n) }
    func range(_ a: UInt64, _ b: UInt64, count: Int = 100) -> Range<Int> {
      MeetingMicrophoneSilence.silencedRange(
        of: MeetingSilenceInterval(start: a, end: b), chunkHostTime: base, count: count)
    }
    #expect(range(s(10), s(20)) == 10..<20)
    #expect(range(s(10) + 1, s(20)) == 11..<20, "a start just after sample 10 skips it")
    #expect(range(s(10), s(20) + 1) == 10..<21, "an end just after sample 20 includes it")
    #expect(range(0, s(5)) == 0..<5, "an interval begun before the chunk")
    #expect(range(s(90), .max) == 90..<100, "an open interval runs to the chunk's end")
    #expect(range(s(150), s(160)) == 100..<100, "after the chunk: nothing")
    #expect(range(0, base) == 0..<0, "ending at the chunk's first sample: nothing")
    #expect(range(s(20), s(10)) == 20..<20, "reversed: nothing")
  }

  // MARK: - File bytes

  @Test("muted stretches read back as exact zeros; every other frame is kept, once")
  func readBackZeros() async throws {
    let r = try rig()
    // [0.5, 1.25) starts on a 100 ms chunk boundary and ends inside a chunk; [1.55, 1.6) sits
    // inside one chunk.
    r.writer.setSilencedIntervals([interval(r, 0.5, 1.25), interval(r, 1.55, 1.6)])
    feed(r, seconds: 2)
    #expect(await r.writer.finish() == .finalized)
    let back = try readBack(r.dir)
    #expect(back.samples.count == 32_000)
    #expect(zeroRuns(back.samples) == [8_000..<20_000, 24_800..<25_600])
    #expect(back.samples.allSatisfy { $0 == 0 || abs($0 - Self.level) < 0.0001 })
    // The live-words stream is the same filtered audio, in the same places.
    #expect(r.released.samples == back.samples)
    #expect(r.writer.currentHealth.silencedFrames == 12_800)
    #expect(r.writer.currentHealth.gaps == 0)
    #expect(r.writer.currentHealth.framesWritten == 32_000)
  }

  @Test("a writer without a hold writes at once and ignores silence intervals")
  func noHoldControl() async throws {
    let r = try rig(hold: nil)
    r.writer.setSilencedIntervals([interval(r, 0, 10)])
    feed(r, seconds: 1)
    await r.writer.waitUntilWritten()
    #expect(r.released.samples.count == 16_000)
    #expect(r.released.samples.allSatisfy { $0 == Self.level })
    #expect(await r.writer.finish() == .finalized)
    #expect(zeroRuns(try readBack(r.dir).samples) == [])
    #expect(r.writer.releasedHostTime == 0)
  }

  // MARK: - The hold

  @Test("audio waits for the hold; an interval set before release still applies")
  func holdThenRelease() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    feed(r, seconds: 1)
    clock.set(r.anchor &+ ticks(1.5))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.released.all.isEmpty, "nothing is 3 s old yet")
    #expect(r.writer.releasedHostTime == 0)
    // The mute is learned late, while its audio is still held.
    r.writer.setSilencedIntervals([interval(r, 0.2, 0.4)])
    clock.set(r.anchor &+ ticks(3.55))
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    // Chunks ending by 0.55 s are due at 3.55 s: the first five (0 to 0.5 s).
    #expect(r.released.samples.count == 8_000)
    #expect(zeroRuns(r.released.samples) == [3_200..<6_400])
    #expect(r.writer.releasedHostTime == r.anchor &+ ticks(samples: 8_000))
    // Later chunks release on their own schedule, without another append.
    clock.set(r.anchor &+ ticks(4.1))
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.released.samples.count == 16_000)
    #expect(await r.writer.finish() == .finalized)
  }

  @Test("a correction that reaches released audio cannot change it (the released watermark)")
  func committedAudioIsFinal() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    feed(r, seconds: 2)
    clock.set(r.anchor &+ ticks(4.0))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    let c = r.writer.releasedHostTime
    #expect(c == r.anchor &+ ticks(samples: 16_000), "audio up to 1 s is out")
    // W beyond the hold: the mute is learned for [0.5, 1.5) after [0.5, 1) was released.
    r.writer.setSilencedIntervals([interval(r, 0.5, 1.5)])
    #expect(await r.writer.finish() == .finalized)
    let back = try readBack(r.dir).samples
    #expect(zeroRuns(back) == [16_000..<24_000], "only the unreleased half is silenced")
    #expect(r.writer.releasedHostTime >= c, "C never moves back")
  }

  @Test("interval updates apply in call order, even while a drain is queued")
  func updatesInOrder() async throws {
    let r = try rig()
    r.writer.suspendQueueForTesting()
    feed(r, seconds: 1)
    r.writer.setSilencedIntervals([interval(r, 0, 1)])
    r.writer.setSilencedIntervals([interval(r, 0.25, 0.5)])
    r.writer.resumeQueueForTesting()
    #expect(await r.writer.finish() == .finalized)
    #expect(zeroRuns(try readBack(r.dir).samples) == [4_000..<8_000])
  }

  @Test("a real scheduled release runs without a later append")
  func liveScheduledRelease() async throws {
    let r = try rig(hold: 0.05, manual: false)
    let signal = BoundedWait.Signal()
    r.released.target.withLock { $0 = (1_600, signal) }
    feed(r, seconds: 0.1)
    // The writer's own schedule releases it; nothing else is appended or forced.
    try await BoundedWait.until(signal)
    #expect(r.released.samples.count == 1_600)
    #expect(await r.writer.finish() == .finalized)
    #expect(try readBack(r.dir).samples.count == 1_600)
  }

  // MARK: - Draining

  @Test("finish, close and waitUntilWritten write every held frame exactly once")
  func forcedDrains() async throws {
    let a = try rig()
    feed(a, seconds: 1)
    await a.writer.waitUntilWritten()
    #expect(a.released.samples.count == 16_000, "waitUntilWritten releases what is held")
    #expect(await a.writer.finish() == .finalized)
    #expect(await a.writer.finish() == .finalized, "a second finish writes nothing twice")
    #expect(try readBack(a.dir).samples.count == 16_000)

    let b = try rig()
    feed(b, seconds: 1)
    #expect(b.writer.close(until: .now() + 5) == .finalized)
    // A release scheduled before the close finds nothing to do.
    b.clock?.set(b.anchor &+ ticks(10))
    b.clock?.fireDue()
    await b.writer.queueBarrierForTesting()
    #expect(b.released.samples.count == 16_000)
    #expect(try readBack(b.dir).samples.count == 16_000)
  }

  @Test("full storage releases the oldest audio early; nothing accepted is lost")
  func storageOverflow() async throws {
    let r = try rig()
    // One 7 s append is larger than the hold's 5 s of storage.
    r.writer.append(
      [Float](repeating: Self.level, count: 7 * Self.rate), hostTime: r.anchor &+ ticks(0.0))
    r.writer.setSilencedIntervals([interval(r, 6, 6.5)])
    #expect(await r.writer.finish() == .finalized)
    let back = try readBack(r.dir).samples
    #expect(back.count == 7 * Self.rate)
    #expect(zeroRuns(back) == [96_000..<104_000])
    // The pieces carry continuous host times: no gap, one segment.
    #expect(r.writer.currentHealth.gaps == 0)
    #expect(r.writer.currentHealth.segmentsFinalized == 1)
    #expect(r.released.all.first?.0.hostTime == r.anchor)
  }

  // MARK: - Decision steps (#4248 plan §18)

  @Test("a step sees the queue's own clock when it runs, and C; never the time it was sent")
  func stepStampsQueueTime() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    feed(r, seconds: 1)
    clock.set(r.anchor &+ ticks(4.0))
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    let c = r.writer.releasedHostTime
    let seen = OSAllocatedUnfairLock<(UInt64, UInt64)?>(initialState: nil)
    r.writer.suspendQueueForTesting()
    // Sent at 4 s; the queue runs it at 9 s.
    r.writer.applySilenceStep { now, released in
      seen.withLock { $0 = (now, released) }
      return nil
    }
    clock.set(r.anchor &+ ticks(9.0))
    r.writer.resumeQueueForTesting()
    await r.writer.queueBarrierForTesting()
    let got = try #require(seen.withLock { $0 })
    #expect(got.0 == r.anchor &+ ticks(9.0))
    #expect(got.1 == c)
    #expect(await r.writer.finish() == .finalized)
  }

  @Test("a step judged too late at the queue installs nothing, so no audio is silenced")
  func staleAtQueueInstallsNothing() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    feed(r, seconds: 1)
    let copied = r.anchor
    let staleness = ticks(1.5)
    r.writer.suspendQueueForTesting()
    r.writer.applySilenceStep { now, _ in
      now - copied <= staleness ? [MeetingSilenceInterval(start: copied, end: .max)] : nil
    }
    clock.set(r.anchor &+ ticks(2.0))
    r.writer.resumeQueueForTesting()
    #expect(await r.writer.finish() == .finalized)
    #expect(zeroRuns(try readBack(r.dir).samples) == [])
  }

  @Test("the clock step decides each release at release time, with no step sent")
  func clockRunsBeforeScheduledRelease() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    let expiresAt = r.anchor &+ ticks(3.5)
    // Muted until the reading expires at 3.5 s; after that the open stretch ends at 0.5 s.
    r.writer.setSilenceClock { now, _ in
      [MeetingSilenceInterval(start: r.anchor, end: now < expiresAt ? .max : r.anchor &+ ticks(0.5))]
    }
    feed(r, seconds: 1)
    clock.set(r.anchor &+ ticks(4.0))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.released.samples.count == 16_000)
    #expect(zeroRuns(r.released.samples) == [0..<8_000], "expiry judged at 4 s, before release")
    #expect(await r.writer.finish() == .finalized)
  }

  @Test("the clock step runs before forced releases when storage fills")
  func clockRunsBeforeForcedRelease() async throws {
    let r = try rig()
    r.writer.setSilenceClock { _, _ in [MeetingSilenceInterval(start: r.anchor, end: r.anchor &+ ticks(1))] }
    // 7 s in one append: the first 2 s leave as forced releases inside the append.
    r.writer.append(
      [Float](repeating: Self.level, count: 7 * Self.rate), hostTime: r.anchor &+ ticks(0.0))
    await r.writer.queueBarrierForTesting()
    #expect(r.released.samples.isEmpty == false, "storage forced a release before the finish")
    #expect(zeroRuns(r.released.samples).first == 0..<16_000)
    #expect(await r.writer.finish() == .finalized)
    #expect(zeroRuns(try readBack(r.dir).samples) == [0..<16_000])
  }

  @Test("a step sent after the close does not run")
  func stepAfterCloseIgnored() async throws {
    let r = try rig()
    feed(r, seconds: 0.5)
    #expect(await r.writer.finish() == .finalized)
    let ran = OSAllocatedUnfairLock(initialState: false)
    r.writer.applySilenceStep { _, _ in
      ran.withLock { $0 = true }
      return nil
    }
    await r.writer.queueBarrierForTesting()
    #expect(ran.withLock { $0 } == false)
  }

  /// Capture stamps each chunk's start on its own, so chunk B can begin before chunk A ends.
  /// Releasing A alone must not retire a mute that B still covers.
  @Test("a mute stays in force for a held chunk that overlaps audio already released")
  func overlappingChunkKeepsMute() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    // A = [0.00, 0.10), B = [0.05, 0.15), mute = [0.06, 0.08).
    r.writer.setSilencedIntervals([interval(r, 0.06, 0.08)])
    r.writer.append([Float](repeating: Self.level, count: 1_600), hostTime: r.anchor)
    r.writer.append(
      [Float](repeating: Self.level, count: 1_600), hostTime: r.anchor &+ ticks(0.05))
    // Due: A at 3.10, B at 3.15. Release A alone.
    clock.set(r.anchor &+ ticks(3.12))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.released.all.count == 1)
    // The follower stops sending the mute once it ends before C.
    r.writer.setSilencedIntervals([])
    clock.set(r.anchor &+ ticks(3.2))
    clock.fireDue()
    #expect(await r.writer.finish() == .finalized)
    let released = r.released.all
    #expect(released.count == 2)
    #expect(zeroRuns(released[0].1) == [960..<1_280])
    #expect(zeroRuns(released[1].1) == [160..<480], "B's part of the mute is still silenced")
  }

  /// A and B as in the overlap case; A is released, then the decisions are replaced. B's first
  /// half lies before C and keeps the decision made when that time was released; its second half
  /// follows the update.
  private func replaceAfterRelease(old: [MeetingSilenceInterval], new: [MeetingSilenceInterval], _ r: Rig)
    async throws -> [Float]
  {
    let clock = try #require(r.clock)
    r.writer.setSilencedIntervals(old)
    r.writer.append([Float](repeating: Self.level, count: 1_600), hostTime: r.anchor)
    r.writer.append(
      [Float](repeating: Self.level, count: 1_600), hostTime: r.anchor &+ ticks(0.05))
    clock.set(r.anchor &+ ticks(3.12))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.released.all.count == 1)
    r.writer.setSilencedIntervals(new)
    #expect(await r.writer.finish() == .finalized)
    return try #require(r.released.all.last?.1)
  }

  @Test("an update never lifts a mute already applied before C")
  func updateCannotUnmuteReleasedTime() async throws {
    let r = try rig()
    let b = try await replaceAfterRelease(old: [interval(r, 0, 0.2)], new: [], r)
    #expect(zeroRuns(b) == [0..<800], "before C stays muted; from C on follows the update")
  }

  @Test("an update never mutes time already released as live")
  func updateCannotMuteReleasedTime() async throws {
    let r = try rig()
    let b = try await replaceAfterRelease(old: [], new: [interval(r, 0, 0.2)], r)
    #expect(zeroRuns(b) == [800..<1_600], "before C stays live; from C on follows the update")
  }

  @Test("audio stamped more than the late-arrival bound behind C stays live and is counted")
  func lateArrivalLiveAndCounted() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    // Old chunk [1.5, 2.5) is held under a mute [1.5, 2.5), then released: that mute is frozen.
    // A chunk ending at 3.0 is still held, which keeps the frozen mute from retiring.
    r.writer.setSilencedIntervals([interval(r, 1.5, 2.5)])
    feed(r, from: 1.5, seconds: 1.5, chunk: 8_000)
    clock.set(r.anchor &+ ticks(5.55))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.writer.releasedHostTime == r.anchor &+ ticks(2.5))
    // Advance C to 3.0 by releasing the second chunk, holding a later one so the mute stays.
    feed(r, from: 3.0, seconds: 0.5, chunk: 8_000)
    clock.set(r.anchor &+ ticks(6.05))
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    #expect(r.writer.releasedHostTime == r.anchor &+ ticks(3.0))
    // A late chunk stamped [1.5, 2.5): its part before C - 1 s = 2.0 is late and stays live; the
    // rest falls under the frozen mute.
    r.writer.append([Float](repeating: Self.level, count: 16_000), hostTime: r.anchor &+ ticks(1.5))
    #expect(await r.writer.finish() == .finalized)
    let lateChunk = try #require(r.released.all.last { $0.0.hostTime == r.anchor &+ ticks(1.5) })
    #expect(zeroRuns(lateChunk.1) == [8_000..<16_000], "before 2.0 live; 2.0 to 2.5 frozen-muted")
    #expect(r.writer.currentHealth.silenceLateFrames == 8_000)
  }

  @Test("a sample straddling the late cutoff counts as late, by the silencing boundary rule")
  func lateBoundaryRule() {
    let silence = MeetingMicrophoneSilence(
      holdSeconds: 3, sampleCapacity: 160_000, chunkCapacity: 64)
    let base: UInt64 = 10_000_000_000
    let two = [Float](repeating: 1, count: 32_000)
    two.withUnsafeBufferPointer {
      silence.accept($0, hostTime: base, afterDrop: false, sourceBreak: false, emit: { _, _ in })
    }
    silence.releaseAll(emit: { _, _ in })
    // C = base + 2 s, so the cutoff is base + 1 s. Sample 0 of the next chunk sits one tick
    // before it (late); sample 1 sits after it.
    let cutoff = base &+ MeetingMicrophoneSilence.ticks(nanos: 1_000_000_000)
    [Float](repeating: 1, count: 1_600).withUnsafeBufferPointer {
      silence.accept(
        $0, hostTime: cutoff - 1, afterDrop: false, sourceBreak: false, emit: { _, _ in })
    }
    #expect(silence.lateFrames == 1)
  }

  @Test("C already covers each chunk when its release callback runs, forced releases included")
  func watermarkBeforeCallback() async throws {
    let r = try rig()
    let clock = try #require(r.clock)
    feed(r, seconds: 1)
    clock.set(r.anchor &+ ticks(3.5))
    await r.writer.queueBarrierForTesting()
    clock.fireDue()
    await r.writer.queueBarrierForTesting()
    // A 7 s append forces early releases from full storage, then finish releases the rest.
    r.writer.append([Float](repeating: Self.level, count: 7 * Self.rate), hostTime: r.anchor &+ ticks(1))
    #expect(await r.writer.finish() == .finalized)
    let marks = r.released.watermarks.withLock { $0 }
    #expect(marks.count > 3)
    #expect(marks.allSatisfy { $0.seen >= $0.chunkEnd })
  }

  @Test("call sound is never held or silenced, even when given a hold and intervals")
  func callSoundUntouched() async throws {
    let r = try rig(track: .callSound)
    r.writer.setSilencedIntervals([interval(r, 0, 10)])
    feed(r, seconds: 1)
    await r.writer.queueBarrierForTesting()
    #expect(r.released.samples.count == 16_000, "written at once, no hold")
    #expect(r.released.samples.allSatisfy { $0 == Self.level })
    #expect(r.writer.releasedHostTime == 0)
    #expect(await r.writer.finish() == .finalized)
    #expect(zeroRuns(try readBack(r.dir).samples) == [])
  }

  // MARK: - Metadata

  @Test("a handoff drop and a run break keep their flags and positions through the hold")
  func metadataThroughHold() async throws {
    // A handoff that holds 0.5 s: with the queue held, the second second is dropped.
    let r = try rig(bufferCapacity: 8_000)
    r.writer.suspendQueueForTesting()
    feed(r, seconds: 1)
    r.writer.resumeQueueForTesting()
    await r.writer.queueBarrierForTesting()
    feed(r, from: 1, seconds: 0.5)
    await r.writer.queueBarrierForTesting()
    [Float](repeating: Self.level, count: 1_600).withUnsafeBufferPointer {
      r.writer.append($0, hostTime: r.anchor &+ ticks(1.6), startsNewRun: true)
    }
    #expect(await r.writer.finish() == .finalized)
    let infos = r.released.all.map(\.0)
    #expect(infos.contains { $0.afterDrop }, "the chunk after the drop says so")
    #expect(infos.last?.sourceBreak == true)
    #expect(infos.last?.hostTime == r.anchor &+ ticks(1.6), "never restamped at release")
    let health = r.writer.currentHealth
    #expect(health.droppedFrames == 8_000)
    #expect(health.discontinuities == 1)
    #expect(health.segmentsFinalized == 3, "the drop and the run break each start a segment")
  }

  @Test("segment rollover and pre-anchor trimming work on held audio")
  func rolloverAndTrim() async throws {
    let r = try rig(segmentSeconds: 1)
    // 0.25 s before the anchor, then 2.25 s after it.
    r.writer.append(
      [Float](repeating: Self.level, count: 4_000), hostTime: r.anchor &- ticks(0.25))
    feed(r, seconds: 2.25)
    r.writer.setSilencedIntervals([interval(r, 0.9, 1.1)])
    #expect(await r.writer.finish() == .finalized)
    let back = try readBack(r.dir)
    #expect(back.files.count == 3)
    #expect(back.samples.count == 36_000)
    #expect(zeroRuns(back.samples) == [14_400..<17_600], "silence crosses the 1 s rollover")
    #expect(r.writer.currentHealth.preAnchorFrames == 4_000)
    #expect(r.released.samples.count == 40_000, "the observer gets the untrimmed chunks")
  }
}
#endif
