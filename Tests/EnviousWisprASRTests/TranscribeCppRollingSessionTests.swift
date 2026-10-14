import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3735 plan §3.11 / §3.5: Faster Transcription's rolling session over transcribe.cpp,
/// driven by a fake decoder.
///
/// **What the user sees when this fails:** with Faster Transcription on, a Whisper dictation
/// pastes duplicated words, loses words at a segment seam or at the end, spaces out Japanese,
/// ships a transcript with a gap after a long unstable stretch, keeps decoding after Stop and
/// slows the final text, or a cancelled take leaves the engine busy for the next one.
@Suite("Whisper rolling session over transcribe.cpp (#3735)", .serialized, .tags(.productOutcome))
struct TranscribeCppRollingSessionTests {

  // MARK: - Helpers

  private static func seg(_ start: Float, _ end: Float, _ text: String) -> RollingSegment {
    RollingSegment(start: start, end: end, text: text)
  }

  private static func native(_ startMs: Int64, _ endMs: Int64, _ text: String)
    -> TranscribeCppSegment
  {
    TranscribeCppSegment(startMs: startMs, endMs: endMs, text: text)
  }

  /// Speech-like audio (well above the 0.001 RMS floor) and true silence.
  private static func voiced(_ seconds: Float) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.2 }
  }
  private static func silence(_ seconds: Float) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * 16_000))
  }

  private static func session(_ decode: @escaping TranscribeCppRollingSession.Decode)
    -> TranscribeCppRollingSession
  {
    TranscribeCppRollingSession(decode: decode, cadence: .milliseconds(1))
  }

  /// An unused decoder: tests that drive `apply` directly never decode.
  private static let noDecode: TranscribeCppRollingSession.Decode = { _ in
    Issue.record("no decode expected")
    return []
  }

  // MARK: - Agreement over changing segment boundaries

  @Test("words agreed across two decodes commit only as complete segments, whatever the boundaries")
  func changingBoundaries() async {
    let s = Self.session(Self.noDecode)
    await s.apply(
      [Self.seg(0, 1.2, " Hello world."), Self.seg(1.2, 2.0, " How are")], realAudioEnd: 2)
    #expect(await s.committedTextForTests == "", "a first hypothesis has nothing to agree with")
    // Same words, different segmentation: "how" moved into the first segment.
    await s.apply(
      [Self.seg(0, 1.5, " Hello world. How"), Self.seg(1.5, 3.0, " are you")], realAudioEnd: 3)
    // Agreed prefix: hello world how are. Segment 0 is fully agreed; segment 1 is not
    // ("you" is new), so it stays held back even though "are" agreed.
    #expect(await s.committedTextForTests == " Hello world. How")
    #expect(await s.heldBackTextForTests == " are you")
  }

  @Test("a repeated phrase is compared word by word, not collapsed")
  func repeatedPhrase() async {
    let s = Self.session(Self.noDecode)
    await s.apply([Self.seg(0, 1, " no no"), Self.seg(1, 2, " no.")], realAudioEnd: 2)
    await s.apply([Self.seg(0, 1, " no no"), Self.seg(1, 2, " no.")], realAudioEnd: 2.5)
    #expect(await s.committedTextForTests == " no no no.")
    // The next decode repeats the committed words first; they are cut, not doubled.
    await s.apply(
      [Self.seg(0, 1, " no no"), Self.seg(1, 2, " no."), Self.seg(2, 3, " Yes yes.")],
      realAudioEnd: 3)
    await s.apply(
      [Self.seg(0, 1, " no no"), Self.seg(1, 2, " no."), Self.seg(2, 3, " Yes yes.")],
      realAudioEnd: 3.5)
    #expect(await s.committedTextForTests == " no no no. Yes yes.")
  }

  @Test("Japanese commits without added spaces")
  func cjkSpacing() async {
    let s = Self.session(Self.noDecode)
    let decode = [Self.seg(0, 1.5, "今日はいい天気です。"), Self.seg(1.5, 3, "散歩に行きましょう。")]
    await s.apply(decode, realAudioEnd: 3)
    await s.apply(decode, realAudioEnd: 3.5)
    #expect(await s.committedTextForTests == "今日はいい天気です。散歩に行きましょう。")
    #expect(TranscribeCppRollingSession.units(of: "今日はいい天気です。", segment: 0).count > 1)
  }

  @Test("an empty or blank decode is not heard and changes nothing")
  func emptyHypothesis() async {
    let s = Self.session(Self.noDecode)
    #expect(await s.apply([], realAudioEnd: 2) == false)
    #expect(await s.apply([Self.seg(0, 1, "  ")], realAudioEnd: 2) == false)
    #expect(await s.committedTextForTests == "")
    #expect(await s.heldBackTextForTests == "")
  }

  @Test("a segment starting past real audio is dropped; an end past it is clamped")
  func timestampsBeyondRealAudio() async {
    let s = Self.session(Self.noDecode)
    let decode = [Self.seg(0, 2.4, " Real words"), Self.seg(2.6, 4, " phantom thanks")]
    await s.apply(decode, realAudioEnd: 2.5)
    #expect(await s.heldBackTextForTests == " Real words")
    await s.apply(decode, realAudioEnd: 2.5)
    #expect(await s.committedTextForTests == " Real words")
  }

  @Test("a segment straddling the committed end does not repeat committed words")
  func seamDeduplication() async {
    let s = Self.session(Self.noDecode)
    await s.apply([Self.seg(0, 1, " one two"), Self.seg(1, 2, " three")], realAudioEnd: 2)
    await s.apply([Self.seg(0, 1, " one two"), Self.seg(1, 2, " three")], realAudioEnd: 2.2)
    #expect(await s.committedTextForTests == " one two three")
    // The decoder revises the committed words' segmentation: the cut falls back to time
    // and the repeated head at the seam is removed.
    let revised = [Self.seg(0, 0.4, " won"), Self.seg(0.4, 3, " two three four five")]
    await s.apply(revised, realAudioEnd: 3)
    await s.apply(revised, realAudioEnd: 3.2)
    #expect(await s.committedTextForTests == " one two three four five")
  }

  // MARK: - Retention (§3.5)

  @Test("a long buffer trims at a committed segment end that keeps 8 s of audio")
  func trimKeepsContext() async {
    let s = Self.session(Self.noDecode)
    let decode = (0..<16).map { Self.seg(Float($0), Float($0 + 1), " w\($0).") }
    await s.apply(decode, realAudioEnd: 16)
    await s.apply(decode, realAudioEnd: 16.5)
    // Buffer 16.5 s > 15: the latest committed end at or before 16.5 - 8 = 8.5 is 8.
    #expect(await s.bufferStartForTests == 8)
    #expect(await s.committedTextForTests.hasPrefix(" w0. w1."))
    #expect(await s.discardedUnstableAudioForTests == false)
  }

  @Test("stalled agreement past the bound advances to the retention line and is flagged")
  func stalledAgreement() async {
    let s = Self.session(Self.noDecode)
    // Every decode disagrees with the last, so nothing ever commits.
    for i in 0..<4 {
      let end = Float(26 + i * 2)
      await s.apply(
        [Self.seg(0, end, i.isMultiple(of: 2) ? " alpha beta" : " gamma delta")], realAudioEnd: end)
    }
    #expect(await s.committedTextForTests == "")
    // At 32 s (> 25 + 5) with no committed boundary: origin = 32 - 8.
    #expect(await s.bufferStartForTests == 24)
    #expect(await s.discardedUnstableAudioForTests)
  }

  @Test("a segment crossing the retention line never commits its disputed words")
  func crossingSegmentNotForceCommitted() async {
    let s = Self.session(Self.noDecode)
    await s.apply([Self.seg(0, 31, " long disputed run")], realAudioEnd: 31)
    await s.apply([Self.seg(0, 31, " long changing run")], realAudioEnd: 31)
    // "long" agrees but the segment is not fully agreed, so nothing commits.
    #expect(await s.committedTextForTests == "")
    #expect(await s.discardedUnstableAudioForTests)
  }

  // MARK: - Session lifecycle (fake decoder, real loop)

  /// Waits for `ready` with a deadline that never joins the waited-for work: the first of the
  /// two fulfils a one-shot. Expiry records an issue and returns, so a missing signal fails the
  /// test instead of hanging the lane (the deadline is a hang guard, not a settle budget).
  static func within(
    _ what: String, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
    _ ready: @escaping @Sendable () async -> Void
  ) async {
    final class Once: @unchecked Sendable {
      let lock = NSLock()
      var done = false
      var waiter: CheckedContinuation<Bool, Never>?
      func fulfil(_ ok: Bool) {
        let w = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
          guard !done else { return nil }
          done = true
          defer { waiter = nil }
          return waiter
        }
        w?.resume(returning: ok)
      }
    }
    let once = Once()
    let watch = Task { await ready(); once.fulfil(true) }
    let timer = Task {
      try? await Task.sleep(for: .seconds(seconds))  // deadline-fallback: hang guard only
      once.fulfil(false)
    }
    let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      once.lock.lock()
      if once.done {
        once.lock.unlock()
        c.resume(returning: true)
      } else {
        once.waiter = c
        once.lock.unlock()
      }
    }
    watch.cancel()
    timer.cancel()
    if !ok { Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation) }
  }

  /// Scripted decoder: returns the next scripted segments (timed in the window's coordinates),
  /// records every call, can hold a call until released (signalling when that held call is
  /// cancelled), and records any call that starts while another is still running.
  final class ScriptedDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[TranscribeCppSegment]]
    private var calls: [Int] = []
    private var running = 0
    private(set) var overlapped = false
    private var holdIndex: Int?
    private var holdRelease: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var sawCancellation = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var throwOn: Set<Int> = []

    init(_ script: [[TranscribeCppSegment]]) { self.script = script }

    var callSampleCounts: [Int] { lock.withLock { calls } }

    func hold(call index: Int) { lock.withLock { holdIndex = index } }
    func failing(call index: Int) { lock.withLock { _ = throwOn.insert(index) } }

    /// Returns once the decoder has been called `count` times.
    func calls(reach count: Int) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if calls.count >= count { return true }
          callWaiters.append((count, c))
          return false
        }
        if now { c.resume() }
      }
    }

    /// Returns once the held call has been cancelled.
    func heldCallCancelled() async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if sawCancellation { return true }
          cancelWaiters.append(c)
          return false
        }
        if now { c.resume() }
      }
    }

    func release() {
      let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        released = true
        defer { holdRelease = nil }
        return holdRelease
      }
      waiter?.resume()
    }

    var decode: TranscribeCppRollingSession.Decode {
      { [self] samples in
        let (index, held, fails, ready) = lock.withLock {
          () -> (Int, Bool, Bool, [CheckedContinuation<Void, Never>]) in
          calls.append(samples.count)
          if running > 0 { overlapped = true }
          running += 1
          let ready = callWaiters.filter { $0.0 <= calls.count }.map(\.1)
          callWaiters.removeAll { $0.0 <= calls.count }
          let index = calls.count - 1
          return (index, holdIndex == index, throwOn.contains(index), ready)
        }
        for waiter in ready { waiter.resume() }
        defer { lock.withLock { running -= 1 } }
        if held {
          // A held native run ends only when released, as an aborted run ends once the
          // executor's abort lands; its cancellation is signalled, never short-circuited.
          await withTaskCancellationHandler {
            await withCheckedContinuation { c in
              let go = lock.withLock { () -> Bool in
                if released { return true }
                holdRelease = c
                return false
              }
              if go { c.resume() }
            }
          } onCancel: {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
              sawCancellation = true
              defer { cancelWaiters = [] }
              return cancelWaiters
            }
            for waiter in waiters { waiter.resume() }
          }
          if Task.isCancelled { throw CancellationError() }
        }
        if fails { throw TranscribeCppWhisperError.runFailed(status: 9) }
        return lock.withLock { script.isEmpty ? [] : script.removeFirst() }
      }
    }
  }

  /// The adapter's `streamingPCM`, with a signal for how often the session pulled it.
  final class Audio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var pulls = 0
    private var pullWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func set(_ s: [Float]) { lock.withLock { samples = s; pulls = 0 } }
    func pulled(_ count: Int) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if pulls >= count { return true }
          pullWaiters.append((count, c))
          return false
        }
        if now { c.resume() }
      }
    }
    var provider: @Sendable () async -> (samples: [Float], count: Int) {
      { [self] in
        let (s, ready) = lock.withLock { () -> ([Float], [CheckedContinuation<Void, Never>]) in
          pulls += 1
          let ready = pullWaiters.filter { $0.0 <= pulls }.map(\.1)
          pullWaiters.removeAll { $0.0 <= pulls }
          return (samples, ready)
        }
        for waiter in ready { waiter.resume() }
        return (s, s.count)
      }
    }
  }

  @Test("caught up at stop: the agreed text plus the held-back hypothesis, no flush decode")
  func caughtUpRelease() async {
    let d = ScriptedDecoder([
      [Self.native(0, 1500, " Turn left at"), Self.native(1500, 2000, " the light")],
      [Self.native(0, 1500, " Turn left at"), Self.native(1500, 2000, " the light.")],
    ])
    let audio = Audio()
    audio.set(Self.voiced(2) + Self.silence(0.5))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    audio.set(Self.voiced(2) + Self.silence(1.6))
    await Self.within("decode call 2") { await d.calls(reach: 2) }
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.accepted)
    #expect(result.text == "Turn left at the light.")
    #expect(result.tailDecodeMs == 0)
    #expect(d.callSampleCounts.count == 2, "caught up: no flush decode")
  }

  @Test("fresh speech at stop: one decode of the retained buffer, never the whole recording twice")
  func voicedTailFlush() async {
    let d = ScriptedDecoder([
      [Self.native(0, 1000, " One")],
      [Self.native(0, 2000, " One two three")],
    ])
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    // Speech continued right up to the stop; under 1 s more, so no loop cycle decodes it.
    audio.set(Self.voiced(2.1))
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.accepted)
    #expect(result.text == "One two three")
    #expect(d.callSampleCounts == [Int(1.2 * 16_000), Int(2.1 * 16_000)], "one flush over the buffer")
  }

  @Test("a silent tail releases without a decode")
  func silentTail() async {
    let d = ScriptedDecoder([[Self.native(0, 1000, " Done.")], [Self.native(0, 1000, " Done.")]])
    let audio = Audio()
    audio.set(Self.voiced(1) + Self.silence(0.1))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    audio.set(Self.voiced(1) + Self.silence(1.5))
    await Self.within("decode call 2") { await d.calls(reach: 2) }
    audio.set(Self.voiced(1) + Self.silence(2.4))
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.text == "Done.")
    #expect(d.callSampleCounts.count == 2)
  }

  @Test(
    "an empty or failed flush is not accepted, even with a committed prefix, so the adapter re-transcribes",
    arguments: [false, true])
  func flushFailureFallsBack(throws flushThrows: Bool) async {
    let d = ScriptedDecoder([
      [Self.native(0, 1000, " Keep this.")], [Self.native(0, 1000, " Keep this.")], [],
    ])
    if flushThrows { d.failing(call: 2) }
    let audio = Audio()
    audio.set(Self.voiced(1.1))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    audio.set(Self.voiced(2.2))
    await Self.within("decode call 2") { await d.calls(reach: 2) }
    audio.set(Self.voiced(3.1))
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.accepted == false)
    #expect(result.text == " Keep this.", "the prefix rides along as a diagnostic only")
    #expect(
      result.strategy
        == (flushThrows ? "streaming_flush_failed" : "streaming_buffer_empty_fallback"))
  }

  @Test("an overflowed stream is not released; the adapter re-transcribes")
  func overflowFallsBack() async {
    let d = ScriptedDecoder([
      [Self.native(0, 31_000, " alpha")], [Self.native(0, 31_000, " beta")],
    ])
    let audio = Audio()
    audio.set(Self.voiced(31))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    audio.set(Self.voiced(32.5))
    await Self.within("decode call 2") { await d.calls(reach: 2) }
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.accepted == false)
    #expect(result.strategy == "streaming_window_overflow_fallback")
  }

  @Test(
    "Stop during a loop decode: snapshot taken, the decode aborted and awaited before the flush")
  func stopDuringLoopDecode() async {
    // The held call is cancelled before it takes a script entry, so the flush gets the first.
    let d = ScriptedDecoder([[Self.native(0, 1500, " Hi there")]])
    d.hold(call: 0)
    let audio = Audio()
    audio.set(Self.voiced(1.5))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    await s.noteStopRequested()
    let finalize = Task { await s.finalize(finalSamples: [], speechSegments: []) }
    // Stop cancels the loop's decode; it then ends on its own, like an aborted native run.
    await Self.within("the loop decode's cancellation") { await d.heldCallCancelled() }
    #expect(d.callSampleCounts.count == 1, "the flush must wait for the aborted loop decode")
    d.release()
    let result = await finalize.value
    #expect(result.stopWhileDecodeInFlight)
    #expect(result.text == "Hi there", "the flush ran after the drain, unpoisoned by the abort")
    #expect(d.callSampleCounts.count == 2)
    #expect(d.overlapped == false, "two decodes never ran at once on the model")
  }

  @Test("cancel aborts the loop decode and returns only after it ends; the session can run again")
  func cancelDrainsAndReuses() async {
    let d = ScriptedDecoder([
      [Self.native(0, 1200, " Again.")], [Self.native(0, 1200, " Again.")],
    ])
    d.hold(call: 0)
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    let cancel = Task { await s.cancel() }
    await Self.within("the loop decode's cancellation") { await d.heldCallCancelled() }
    d.release()
    await cancel.value
    #expect(d.sawCancellation)
    #expect(d.overlapped == false)
    // Reuse: a fresh start decodes normally.
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 2") { await d.calls(reach: 2) }
    audio.set(Self.voiced(1.2) + Self.silence(1.2))
    await Self.within("decode call 3") { await d.calls(reach: 3) }
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.text == "Again.")
  }

  @Test("the loop waits for 1 s of new audio before decoding again")
  func newAudioGate() async {
    let d = ScriptedDecoder([[Self.native(0, 1000, " a")]])
    let audio = Audio()
    audio.set(Self.voiced(1.0))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    audio.set(Self.voiced(1.5))
    // Five cycles pull the half-second-longer buffer; none of them may decode it.
    await Self.within("five loop cycles") { await audio.pulled(5) }
    #expect(d.callSampleCounts.count == 1, "half a second of new audio is not enough")
    _ = await s.finalize(finalSamples: [], speechSegments: [])
  }
}
