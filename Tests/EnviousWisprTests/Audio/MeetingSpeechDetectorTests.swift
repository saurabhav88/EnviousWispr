@preconcurrency import FluidAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4254: when these fail, meeting Whisper decodes silence (and invents "Thank you."), drops
/// the start or end of what someone said, or reads speech at the wrong time.
///
/// The model is a SCRIPTED fake: each 4,096-sample chunk may carry one boundary event, so the
/// expected ranges below are literal sample indices.
@Suite("Meeting speech detector", .tags(.productOutcome))
struct MeetingSpeechDetectorTests {
  static let chunk = MeetingSpeechDetector.chunkSize
  static let pad = AudioConstants.speechPaddingSamples

  /// Returns, for the n-th chunk it is asked about, the scripted event; throws at `failAt`.
  final class Script: StreamingVad, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let events: [Int: VadStreamEvent]
    private let failAt: Int?
    private(set) var firstSamples: [Float] = []
    /// Chunk index whose model call waits until `release()`; `reached` fires as it waits.
    private let holdAt: Int?
    let reached = BoundedWait.Signal()
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    struct Boom: Error {}

    init(
      _ events: [Int: (VadStreamEvent.Kind, Int)] = [:], failAt: Int? = nil, holdAt: Int? = nil
    ) {
      self.events = events.mapValues { VadStreamEvent(kind: $0.0, sampleIndex: $0.1) }
      self.failAt = failAt
      self.holdAt = holdAt
    }

    func release() {
      let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        released = true
        defer { held = nil }
        return held
      }
      waiting?.resume()
    }

    var chunks: Int { lock.withLock { calls } }

    func processStreamingChunk(
      _ audioChunk: [Float], state: VadStreamState, config: VadSegmentationConfig,
      returnSeconds: Bool, timeResolution: Int
    ) async throws -> VadStreamResult {
      let n = lock.withLock { () -> Int in
        defer { calls += 1 }
        firstSamples.append(audioChunk.first ?? 0)
        return calls
      }
      if n == failAt { throw Boom() }
      if n == holdAt {
        await withCheckedContinuation { c in
          let go = lock.withLock { () -> Bool in
            if released { return true }
            held = c
            return false
          }
          reached.fire()
          if go { c.resume() }
        }
      }
      var next = state
      next.processedSamples += audioChunk.count
      return VadStreamResult(state: next, event: events[n], probability: 0)
    }
  }

  private func detector(_ script: Script) -> MeetingSpeechDetector {
    MeetingSpeechDetector(makeStreamingVad: { script })
  }

  private func audio(_ count: Int, _ value: Float = 0.1) -> [Float] {
    [Float](repeating: value, count: count)
  }

  // MARK: - Final pass

  @Test("no speech gives no ranges")
  func silence() async throws {
    let spans = try await detector(Script()).finalSpans(audio(5 * Self.chunk))
    #expect(spans == [])
  }

  @Test("a speech range is padded by 1,600 samples on each side")
  func padding() async throws {
    let script = Script([1: (.speechStart, 5_000), 4: (.speechEnd, 20_000)])
    let spans = try await detector(script).finalSpans(audio(8 * Self.chunk))
    #expect(spans == [(5_000 - Self.pad)..<(20_000 + Self.pad)])
  }

  @Test("ranges whose padding touches or overlaps merge; farther ones stay apart")
  func merging() async throws {
    let touching = Script([
      0: (.speechStart, 2_000), 1: (.speechEnd, 6_000), 2: (.speechStart, 9_200),
      3: (.speechEnd, 14_000), 5: (.speechStart, 24_000), 6: (.speechEnd, 27_000),
    ])
    let spans = try await detector(touching).finalSpans(audio(8 * Self.chunk))
    #expect(spans == [400..<15_600, 22_400..<28_600])
  }

  @Test("speech still open at the end closes at the last real sample, clamped")
  func openAtEnd() async throws {
    let script = Script([0: (.speechStart, 2_000)])
    let spans = try await detector(script).finalSpans(audio(10_000))
    #expect(spans == [400..<10_000])
  }

  @Test("the final partial chunk is classified, and a boundary in its padding is clamped")
  func partialFinalChunk() async throws {
    // 10,000 samples: chunks 0, 1 whole; chunk 2 holds 1,808 real samples plus private padding.
    let script = Script([2: (.speechStart, 9_000)])
    let spans = try await detector(script).finalSpans(audio(10_000))
    #expect(script.chunks == 3)
    #expect(spans == [7_400..<10_000])
    let late = Script([2: (.speechStart, 11_000)])
    #expect(try await detector(late).finalSpans(audio(10_000)) == [], "a start past the real end")
  }

  @Test("each decode input gets a fresh detector")
  func freshPerInput() async throws {
    let script = Script([0: (.speechStart, 1_000)])
    let first = try await detector(script).finalSpans(audio(Self.chunk))
    let second = try await detector(Script()).finalSpans(audio(Self.chunk))
    #expect(first == [0..<Self.chunk])
    #expect(second == [])
  }

  @Test("the model's copy is high-pass conditioned; the caller's audio is not touched")
  func conditioning() async throws {
    let script = Script()
    let samples = audio(Self.chunk, 0.5)
    _ = try await detector(script).finalSpans(samples)
    var reference = VADInputHighPass()
    #expect(script.firstSamples.first == reference.process(samples).first)
    #expect(samples.allSatisfy { $0 == 0.5 })
  }

  @Test("cancellation is cancellation, never an empty result")
  func cancellation() async {
    let script = Script()
    let task = Task { try await detector(script).finalSpans(audio(4 * Self.chunk)) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  // MARK: - Live

  @Test("live: an unclassified suffix is unknown, never silence")
  func liveUnknownSuffix() async throws {
    let d = detector(Script())
    try await d.append(audio(5_000))
    #expect(await d.classifiedSamples == Self.chunk)
    let first = await d.liveSpeech(in: 0..<5_000)
    #expect(first.speech.isEmpty && first.classifiedEnd == Self.chunk, "904 samples wait for a whole chunk")
    try await d.append(audio(Self.chunk))
    let second = await d.liveSpeech(in: 0..<5_000)
    #expect(second.speech.isEmpty && second.classifiedEnd >= 5_000, "now all classified, all silent")
  }

  @Test("live: each sample reaches the model once, however the audio is split")
  func liveEachSampleOnce() async throws {
    let script = Script()
    let d = detector(script)
    for size in [100, 4_000, 3, 4_089, 8_192] { try await d.append(audio(size)) }
    #expect(script.chunks == (100 + 4_000 + 3 + 4_089 + 8_192) / Self.chunk)
    #expect(await d.classifiedSamples == 4 * Self.chunk)
  }

  @Test("live: open speech counts as speech, clamped to the window; closed ranges prune")
  func liveOpenAndPrune() async throws {
    let script = Script([
      1: (.speechStart, 6_000), 3: (.speechEnd, 15_000), 5: (.speechStart, 22_000),
    ])
    let d = detector(script)
    try await d.append(audio(6 * Self.chunk))
    let both = await d.liveSpeech(in: 0..<6 * Self.chunk)
    #expect(both.speech == [4_400..<16_600, 20_400..<24_576] && both.speechOpen)
    #expect(await d.liveSpeech(in: 17_000..<20_000).speech.isEmpty)
    await d.prune(before: 17_000)
    #expect(await d.liveSpeech(in: 0..<6 * Self.chunk).speech == [20_400..<24_576])
  }

  @Test("live snapshot: closed and open speech, classified end, and padding alone is no speech")
  func liveSnapshot() async throws {
    let script = Script([1: (.speechStart, 6_000), 3: (.speechEnd, 15_000)])
    let d = detector(script)
    try await d.append(audio(5 * Self.chunk + 100))
    let closed = await d.liveSpeech(in: 0..<(5 * Self.chunk + 100))
    #expect(closed == MeetingLiveSpeech(speech: [4_400..<16_600], speechOpen: false, classifiedEnd: 5 * Self.chunk))
    // Cut inside the padding after the speech ended (15,000 to 16,600): nothing real is there.
    let paddingOnly = await d.liveSpeech(in: 15_200..<20_000)
    #expect(paddingOnly.speech.isEmpty, "\(paddingOnly)")
    // A sliver under 100 ms of speech that began before the window is a remnant, not speech;
    // 100 ms or more still counts.
    #expect(await d.liveSpeech(in: 14_000..<20_000).speech.isEmpty, "1,000 samples of remnant")
    #expect(await d.liveSpeech(in: 13_400..<20_000).speech == [13_400..<16_600], "1,600 samples count")
    let open = Script([1: (.speechStart, 6_000)])
    let o = detector(open)
    try await o.append(audio(3 * Self.chunk))
    #expect(await o.liveSpeech(in: 0..<(3 * Self.chunk)).speechOpen)
  }

  @Test("live: an error after good chunks stops the detector for good")
  func liveFailureStops() async throws {
    let d = detector(Script(failAt: 2))
    try await d.append(audio(2 * Self.chunk))
    await #expect(throws: Script.Boom.self) { try await d.append(audio(Self.chunk)) }
    await #expect(throws: MeetingSpeechDetector.DetectorError.stopped) {
      try await d.append(audio(Self.chunk))
    }
    #expect(await d.classifiedSamples == 2 * Self.chunk, "the clock never passes unprocessed audio")
  }

  // MARK: - Ordering and cancellation

  @Test("overlapping appends and finish run in call order; no chunk is classified twice")
  func overlappingCallsAreOrdered() async throws {
    let script = Script(holdAt: 0)
    let queued = BoundedWait.Signal()
    let d = MeetingSpeechDetector(makeStreamingVad: { script }, onWait: { queued.fire() })
    // Distinct values per chunk, so a repeat or reorder is visible in what the model saw.
    let first = audio(Self.chunk, 0.1)
    let second = audio(Self.chunk, 0.2)
    let third = audio(1_000, 0.3)
    let a = Task { try await d.append(first) }
    try await BoundedWait.until(script.reached)
    // The second append waits behind the held first call; finish follows it in the same task,
    // so its order is fixed. (Two separate tasks start in no guaranteed order.)
    let b = Task {
      try await d.append(second + third)
      try await d.finish()
    }
    try await BoundedWait.until(queued)
    script.release()
    try await a.value
    try await b.value
    #expect(script.chunks == 3, "two whole chunks and the remainder, once each")
    let seen = script.firstSamples
    var conditioned = VADInputHighPass()
    let expected = [first, second, third + audio(Self.chunk - 1_000, 0)].map {
      conditioned.process($0).first ?? 0
    }
    #expect(seen == expected, "in call order")
    #expect(await d.classifiedSamples == 2 * Self.chunk + 1_000)
  }

  @Test("a cancelled append that would only buffer, and a cancelled finish, are cancellation")
  func cancelledBufferOnlyCalls() async throws {
    let script = Script()
    let a = detector(script)
    let append = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await a.append(audio(100))
    }
    await #expect(throws: CancellationError.self) { try await append.value }
    await #expect(throws: MeetingSpeechDetector.DetectorError.stopped) { try await a.finish() }
    let b = detector(script)
    let finish = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await b.finish()
    }
    await #expect(throws: CancellationError.self) { try await finish.value }
    await #expect(throws: MeetingSpeechDetector.DetectorError.stopped) {
      try await b.append(audio(100))
    }
    #expect(script.chunks == 0, "nothing reached the model")
  }

  @Test("cancellation during the last, partial chunk's model call is cancellation")
  func cancelDuringLastChunk() async throws {
    // 9,000 samples: chunks 0 and 1 whole, chunk 2 partial (the last); hold its model call.
    let script = Script(holdAt: 2)
    let d = detector(script)
    let task = Task { try await d.finalSpans(audio(9_000)) }
    try await BoundedWait.until(script.reached)
    task.cancel()
    script.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: MeetingSpeechDetector.DetectorError.stopped) {
      try await d.append(audio(Self.chunk))
    }
  }
}
