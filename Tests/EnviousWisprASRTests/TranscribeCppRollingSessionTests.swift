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
    return TranscribeCppRunResult(text: "", detectedLanguage: nil, segments: [])
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

  @Test("a re-heard committed word is not committed twice (thermal, then formal)")
  func revisedCommittedWord() async {
    let s = Self.session(Self.noDecode)
    let first = [Self.seg(0, 2, " Their thermal behavior is"), Self.seg(2, 3, " not")]
    await s.apply(first, realAudioEnd: 3)
    await s.apply(first, realAudioEnd: 3.5)
    #expect(await s.committedTextForTests == " Their thermal behavior is not")
    // The next decodes re-hear "thermal" as "formal" inside one long segment.
    let revised = [
      Self.seg(0, 4.5, " Their formal behavior is not as steady"), Self.seg(4.5, 5, " as"),
    ]
    await s.apply(revised, realAudioEnd: 5)
    await s.apply(revised, realAudioEnd: 5.5)
    let committed = await s.committedTextForTests
    let held = await s.heldBackTextForTests
    let text = committed + held
    #expect(text.components(separatedBy: "behavior").count == 2, "said once: \(text)")
    #expect(text.hasSuffix(" as steady as"), "the new words survive the cut: \(text)")
  }

  @Test("the cut aligns committed words with revisions and never eats a new segment")
  func cutIndexAlignment() {
    let cut = TranscribeCppRollingSession.cutIndex
    #expect(cut(["a", "b", "c"], ["a", "b", "c", "d"], 4) == 3)
    #expect(cut(["a", "b", "c"], ["a", "b", "x", "d"], 4) == 3, "a revised last word is consumed")
    #expect(cut(["a", "b", "c"], ["a", "b", "d", "e"], 2) == 2, "the limit protects new words")
    #expect(cut([], ["a"], 1) == 0)
    #expect(cut(["a"], ["a"], 0) == 0)
  }

  @Test("trimmed native segments keep the decoder's spacing; unspaced scripts get none")
  func spacingFromFullText() {
    let english = TranscribeCppRunResult(
      text: "maintain a fairly constant temperature",
      detectedLanguage: nil,
      segments: [
        Self.native(0, 1000, "maintain a"), Self.native(1000, 2500, "fairly constant temperature"),
      ])
    #expect(TranscribeCppRollingSession.spacedTexts(of: english).joined() == english.text)
    let japanese = TranscribeCppRunResult(
      text: "今日はいい天気です。散歩に行きましょう。", detectedLanguage: nil,
      segments: [Self.native(0, 1500, "今日はいい天気です。"), Self.native(1500, 3000, "散歩に行きましょう。")])
    #expect(TranscribeCppRollingSession.spacedTexts(of: japanese).joined() == japanese.text)
    let join = TranscribeCppRollingSession.join
    #expect(join("Cushing", "of") == "Cushing of")
    #expect(join("ground,", "said") == "ground, said")
    #expect(join("ground", ", said") == "ground, said")
    #expect(join("天気です。", "散歩") == "天気です。散歩")
    #expect(join("", "x") == "x")
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
    // 31 s > 25 + 5 with nothing committed: the origin advances to 23 s, inside the segment.
    await s.apply([Self.seg(0, 31, " long disputed run")], realAudioEnd: 31)
    #expect(await s.bufferStartForTests == 23)
    #expect(await s.discardedUnstableAudioForTests)
    #expect(await s.heldBackTextForTests == "", "a crossing segment's words are not kept")
    // The same words again: agreement starts over from retained audio, so they do not commit
    // on the strength of a hypothesis that partly described discarded audio.
    await s.apply([Self.seg(0, 8, " long disputed run")], realAudioEnd: 31.5)
    #expect(await s.committedTextForTests == "")
  }

  @Test(
    "empty or failing decodes on growing audio never decode past the bound, and the take falls back",
    arguments: [false, true])
  func emptyDecodesStayBounded(throwing: Bool) async {
    let d = ScriptedDecoder([])  // every decode is empty
    if throwing { d.failingEvery() }
    let audio = Audio()
    audio.set(Self.voiced(20))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(26))
    let afterFirstSet = d.callSampleCounts.count
    await Self.within("a decode of 26 s") { await d.calls(reach: afterFirstSet + 2) }
    audio.set(Self.voiced(32))
    let afterSecondSet = d.callSampleCounts.count
    await Self.within("a decode after 32 s") { await d.calls(reach: afterSecondSet + 2) }
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    let counts = d.callSampleCounts
    #expect(counts.allSatisfy { $0 <= 30 * 16_000 }, "no window past 25 + 5 s: \(counts)")
    #expect(counts.contains(26 * 16_000), "the 26 s window decoded whole")
    #expect(counts.last == 8 * 16_000, "past the bound: the retained 8 s of context")
    #expect(await s.bufferStartForTests == 24)
    #expect(result.accepted == false)
    #expect(result.strategy == "streaming_window_overflow_fallback")
  }

  @Test("cancel during the flush aborts it, waits for its native return, and releases no text")
  func cancelDuringFlush() async {
    let d = ScriptedDecoder([[Self.native(0, 1000, " One")], [Self.native(0, 2000, " One two")]])
    d.hold(call: 1)
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2.1))  // fresh speech at stop: finalize decodes once
    let finalize = Task { await s.finalize(finalSamples: [], speechSegments: []) }
    await Self.within("the flush decode") { await d.calls(reach: 2) }
    let cancelReturned = Once<Bool>()
    let cancel = Task {
      await s.cancel()
      cancelReturned.fulfil(true)
    }
    await Self.within("the flush's cancellation") { await d.heldCallCancelled() }
    // The flush's native run has not returned, so Cancel has not either.
    #expect(d.overlapped == false)
    cancelReturned.fulfil(false)
    #expect(await cancelReturned.value() == false, "cancel returned before the flush ended")
    d.release()
    guard await Self.joined(cancel, "cancel", onExpiry: { d.release() }) != nil,
      let result = await Self.joined(finalize, "finalize", onExpiry: { d.release() })
    else { return }
    #expect(result.accepted == false)
    #expect(result.text == nil, "no text after a cancel")
    #expect(result.strategy == "streaming_cancelled")
    // Reuse after the drain.
    let again = ScriptedDecoder([
      [Self.native(0, 1200, " Next.")], [Self.native(0, 1200, " Next.")],
    ])
    let reuse = Self.session(again.decode)
    audio.set(Self.voiced(1.2))
    await reuse.start(audioSamplesProvider: audio.provider)
    await Self.within("reuse cycle 1") { await reuse.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(1.2) + Self.silence(1.2))
    await Self.within("reuse cycle 2") { await reuse.cyclesCompleted(reach: 2) }
    #expect(await reuse.finalize(finalSamples: [], speechSegments: []).text == "Next.")
  }

  @Test("two Cancels both wait for the same aborted loop decode")
  func concurrentCancelsShareTheDrain() async {
    let d = ScriptedDecoder([[Self.native(0, 1200, " Later.")]])
    d.hold(call: 0)
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    let firstDone = Once<Bool>()
    let secondDone = Once<Bool>()
    let first = Task {
      await s.cancel()
      firstDone.fulfil(true)
    }
    let second = Task {
      await s.cancel()
      secondDone.fulfil(true)
    }
    await Self.within("both cancels at the drain") { await s.drainJoins(reach: 2) }
    firstDone.fulfil(false)
    secondDone.fulfil(false)
    #expect(await firstDone.value() == false, "a cancel returned before the native run ended")
    #expect(await secondDone.value() == false, "a cancel returned before the native run ended")
    d.release()
    guard await Self.joined(first, "first cancel", onExpiry: { d.release() }) != nil,
      await Self.joined(second, "second cancel", onExpiry: { d.release() }) != nil
    else { return }
    #expect(d.sawCancellation)
  }

  @Test("a restart while the cancelled decode is still native waits for it")
  func restartWaitsForTheDrain() async {
    let d = ScriptedDecoder([[Self.native(0, 1200, " Later.")], [Self.native(0, 1200, " Later.")]])
    d.hold(call: 0)
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    let cancel = Task { await s.cancel() }
    await Self.within("the loop decode's cancellation") { await d.heldCallCancelled() }
    await s.start(audioSamplesProvider: audio.provider)
    d.release()
    guard await Self.joined(cancel, "cancel", onExpiry: { d.release() }) != nil else { return }
    await Self.within("the restarted loop's decode") { await d.calls(reach: 2) }
    #expect(d.overlapped == false, "the restarted loop decoded while the aborted run was native")
    _ = await s.finalize(finalSamples: [], speechSegments: [])
  }

  // MARK: - Session lifecycle (fake decoder, real loop)

  /// A value set at most once; `value()` returns the FIRST fulfilment, whether it landed before
  /// or after the waiter registered.
  final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    func fulfil(_ value: Value) {
      let w = lock.withLock { () -> CheckedContinuation<Value, Never>? in
        guard stored == nil else { return nil }
        stored = value
        defer { waiter = nil }
        return waiter
      }
      w?.resume(returning: value)
    }
    func value() async -> Value {
      await withCheckedContinuation { c in
        let ready = lock.withLock { () -> Value? in
          if let stored { return stored }
          waiter = c
          return nil
        }
        if let ready { c.resume(returning: ready) }
      }
    }
  }

  /// Waits for `ready` with a deadline that never joins the waited-for work: the first of the
  /// two fulfils a one-shot. Expiry records an issue, runs `onExpiry` (release whatever gate the
  /// work may block on) and returns false, so a missing signal fails the test instead of
  /// hanging the lane (the deadline is a hang guard, not a settle budget).
  @discardableResult
  static func within(
    _ what: String, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
    onExpiry: @Sendable () -> Void = {},
    _ ready: @escaping @Sendable () async -> Void
  ) async -> Bool {
    let once = Once<Bool>()
    let watch = Task {
      await ready()
      once.fulfil(true)
    }
    let timer = Task {
      try? await Task.sleep(for: .seconds(seconds))  // deadline-fallback: hang guard only
      once.fulfil(false)
    }
    let ok = await once.value()
    watch.cancel()
    timer.cancel()
    if !ok {
      Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
      onExpiry()
    }
    return ok
  }

  /// A terminal task's value within the deadline, or nil (with a recorded issue) after the
  /// task is cancelled and `onExpiry` released its gate.
  static func joined<T: Sendable>(
    _ task: Task<T, Never>, _ what: String, seconds: Double = 10,
    sourceLocation: SourceLocation = #_sourceLocation, onExpiry: @Sendable () -> Void = {}
  ) async -> T? {
    let box = Once<T>()
    let arrived = await within(
      what, seconds: seconds, sourceLocation: sourceLocation,
      onExpiry: {
        task.cancel()
        onExpiry()
      },
      { box.fulfil(await task.value) })
    guard arrived else { return nil }
    return await box.value()
  }

  @Test("the wait helper reports the outcome that won, and a stalled terminal expires")
  func waitHelperControls() async {
    // The timer wins before anyone waits: the stored outcome is false, never a default true.
    let early = Once<Bool>()
    early.fulfil(false)
    early.fulfil(true)
    #expect(await early.value() == false)
    // A terminal task that never ends expires, is cancelled and has its gate released.
    let gate = Once<Bool>()
    let stalled = Task<Int, Never> {
      try? await Task.sleep(for: .seconds(600))  // deadline-fallback: a terminal that never ends
      return 1
    }
    await withKnownIssue("the terminal never ends, so the join must expire") {
      let value = await Self.joined(
        stalled, "a stalled terminal", seconds: 0.2, onExpiry: { gate.fulfil(true) })
      #expect(value == nil)
    }
    #expect(stalled.isCancelled)
    #expect(await gate.value())
  }

  /// Scripted decoder: returns the next scripted segments (timed in the window's coordinates),
  /// records every call, can hold a call until released (signalling when that held call is
  /// cancelled), and records any call that starts while another is still running.
  final class ScriptedDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [TranscribeCppRunResult]
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

    /// Each entry's full text is its segment texts concatenated, as the decoder spaced them.
    init(_ script: [[TranscribeCppSegment]]) {
      self.script = script.map {
        TranscribeCppRunResult(
          text: $0.map(\.text).joined().trimmingCharacters(in: .whitespaces),
          detectedLanguage: nil, segments: $0)
      }
    }
    init(runs: [TranscribeCppRunResult]) { self.script = runs }

    var callSampleCounts: [Int] { lock.withLock { calls } }

    func hold(call index: Int) { lock.withLock { holdIndex = index } }
    func failing(call index: Int) { lock.withLock { _ = throwOn.insert(index) } }
    private var failAll = false
    private var finishDespiteCancel = false
    /// A held call that is cancelled still returns its scripted result when released, like a
    /// native run that completed before the abort landed.
    func finishingDespiteCancel() { lock.withLock { finishDespiteCancel = true } }
    func failingEvery() { lock.withLock { failAll = true } }

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
          return (index, holdIndex == index, failAll || throwOn.contains(index), ready)
        }
        for waiter in ready { waiter.resume() }
        defer { lock.withLock { running -= 1 } }
        if held {
          // A held native run ends only when released, as an aborted run ends once the
          // executor's abort lands; its cancellation is signalled, never short-circuited.
          // `isolation: nil` for the same reason as the Whisper fake in
          // TranscribeCppWhisperBackendTests: the default overload's -Onone copy here was linked
          // with an -O frame size and the Release lane aborted with "freed pointer was not the
          // last allocation" (#3849; swiftlang/swift#86204, #3925).
          await withTaskCancellationHandler(
            operation: {
              await withCheckedContinuation { c in
                let go = lock.withLock { () -> Bool in
                  if released { return true }
                  holdRelease = c
                  return false
                }
                if go { c.resume() }
              }
            },
            onCancel: {
              let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                sawCancellation = true
                defer { cancelWaiters = [] }
                return cancelWaiters
              }
              for waiter in waiters { waiter.resume() }
            },
            isolation: nil)
          if Task.isCancelled, !lock.withLock({ finishDespiteCancel }) { throw CancellationError() }
        }
        if fails { throw TranscribeCppWhisperError.runFailed(status: 9) }
        return lock.withLock {
          script.isEmpty
            ? TranscribeCppRunResult(text: "", detectedLanguage: nil, segments: [])
            : script.removeFirst()
        }
      }
    }
  }

  /// The adapter's `streamingPCM`, with a signal for how often the session pulled it.
  final class Audio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var pulls = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldTotal = 0
    private var heldWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    /// While holding, every pull suspends until `releaseOldest`/`stopHolding`.
    func startHolding() { lock.withLock { holding = true } }
    func stopHolding() {
      let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        holding = false
        defer { held = [] }
        return held
      }
      for c in all { c.resume() }
    }
    func releaseOldest() {
      let first = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
      first?.resume()
    }
    /// Returns once `count` pulls have been held in total.
    func heldPulls(reach count: Int) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if heldTotal >= count { return true }
          heldWaiters.append((count, c))
          return false
        }
        if now { c.resume() }
      }
    }
    private var pullWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func set(_ s: [Float]) {
      lock.withLock {
        samples = s
        pulls = 0
      }
    }
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
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let (hold, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard holding else { return (false, []) }
            held.append(c)
            heldTotal += 1
            let ready = heldWaiters.filter { $0.0 <= heldTotal }.map(\.1)
            heldWaiters.removeAll { $0.0 <= heldTotal }
            return (true, ready)
          }
          for waiter in ready { waiter.resume() }
          if !hold { c.resume() }
        }
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
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2) + Self.silence(1.6))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
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
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    // Speech continued right up to the stop; under 1 s more, so no loop cycle decodes it.
    audio.set(Self.voiced(2.1))
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.accepted)
    #expect(result.text == "One two three")
    #expect(
      d.callSampleCounts == [Int(1.2 * 16_000), Int(2.1 * 16_000)], "one flush over the buffer")
  }

  /// #3801: a run as the backend returns it after the silent-tail filter.
  private static func filtered(_ segments: [TranscribeCppSegment], dropped: Int)
    -> TranscribeCppRunResult
  {
    TranscribeCppRunResult(
      text: segments.map(\.text).joined().trimmingCharacters(in: .whitespaces),
      detectedLanguage: nil, segments: segments, silentTailDropped: dropped)
  }

  @Test("the released flush reports its own silent-tail count, never the loop decodes' (#3801)")
  func flushReportsItsOwnSilentTailCount() async {
    let d = ScriptedDecoder(runs: [
      Self.filtered([Self.native(0, 1000, " One")], dropped: 2),
      Self.filtered([Self.native(0, 2000, " One two three")], dropped: 1),
    ])
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2.1))
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.text == "One two three")
    #expect(d.callSampleCounts.count == 2, "one loop decode, one flush")
    #expect(result.silentTailDropped == 1)
  }

  @Test("a caught-up release has no flush decode, so it reports no silent-tail count (#3801)")
  func caughtUpReleaseHasNoSilentTailCount() async {
    let d = ScriptedDecoder(runs: [
      Self.filtered(
        [Self.native(0, 1500, " Turn left at"), Self.native(1500, 2000, " the light")], dropped: 3),
      Self.filtered(
        [Self.native(0, 1500, " Turn left at"), Self.native(1500, 2000, " the light.")], dropped: 3),
    ])
    let audio = Audio()
    audio.set(Self.voiced(2) + Self.silence(0.5))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2) + Self.silence(1.6))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.text == "Turn left at the light.")
    #expect(d.callSampleCounts.count == 2, "caught up: no flush decode")
    #expect(result.silentTailDropped == nil)
  }

  @Test("a silent tail releases without a decode")
  func silentTail() async {
    let d = ScriptedDecoder([[Self.native(0, 1000, " Done.")], [Self.native(0, 1000, " Done.")]])
    let audio = Audio()
    audio.set(Self.voiced(1) + Self.silence(0.1))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(1) + Self.silence(1.5))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
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
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2.2))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
    audio.set(Self.voiced(3.1))
    let result = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(result.accepted == false)
    #expect(result.text == "Keep this.", "the prefix rides along as a diagnostic only")
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
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(32.5))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
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
    guard let result = await Self.joined(finalize, "finalize", onExpiry: { d.release() }) else {
      return
    }
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
    guard await Self.joined(cancel, "cancel", onExpiry: { d.release() }) != nil else { return }
    #expect(d.sawCancellation)
    #expect(d.overlapped == false)
    // Reuse: a fresh start decodes normally.
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(1.2) + Self.silence(1.2))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
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

  // MARK: - Round 2: stale terminals and caller cancellation

  @Test(
    "finalize, Cancel, then a restart while the old loop decode is native: the old finalize releases nothing"
  )
  func restartFencesTheOldFinalize() async {
    let d = ScriptedDecoder([
      [Self.native(0, 1200, " New take.")], [Self.native(0, 1200, " New take.")],
    ])
    d.hold(call: 0)
    let oldAudio = Audio()
    oldAudio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: oldAudio.provider)
    await Self.within("decode call 1") { await d.calls(reach: 1) }
    let oldFinalize = Task { await s.finalize(finalSamples: [], speechSegments: []) }
    let cancel = Task { await s.cancel() }
    await Self.within("finalize and cancel at the drain") { await s.drainJoins(reach: 2) }
    // The restart lands while the aborted run is still native.
    let newAudio = Audio()
    newAudio.set(Self.voiced(1.2))
    await s.start(audioSamplesProvider: newAudio.provider)
    d.release()
    guard let old = await Self.joined(oldFinalize, "old finalize", onExpiry: { d.release() }),
      await Self.joined(cancel, "cancel", onExpiry: { d.release() }) != nil
    else { return }
    #expect(old.accepted == false)
    #expect(old.text == nil, "the old finalize must not release the new run's audio")
    #expect(old.strategy == "streaming_cancelled")
    // The new run is untouched: its own cycles and its own text.
    await Self.within("new cycle 1") { await s.cyclesCompleted(reach: 1) }
    newAudio.set(Self.voiced(1.2) + Self.silence(1.2))
    await Self.within("new cycle 2") { await s.cyclesCompleted(reach: 2) }
    let fresh = await s.finalize(finalSamples: [], speechSegments: [])
    #expect(fresh.text == "New take.")
    #expect(d.overlapped == false)
  }

  @Test(
    "finalize, Cancel, then a restart while the old flush is native: the old finalize releases nothing"
  )
  func restartFencesTheOldFlush() async {
    let d = ScriptedDecoder([
      [Self.native(0, 1000, " One")], [Self.native(0, 2000, " One two")],
      [Self.native(0, 1200, " Fresh.")], [Self.native(0, 1200, " Fresh.")],
    ])
    d.hold(call: 1)
    d.finishingDespiteCancel()
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2.1))
    let oldFinalize = Task { await s.finalize(finalSamples: [], speechSegments: []) }
    await Self.within("the flush decode") { await d.calls(reach: 2) }
    let cancel = Task { await s.cancel() }
    await Self.within("the flush's cancellation") { await d.heldCallCancelled() }
    let newAudio = Audio()
    newAudio.set(Self.voiced(1.2))
    await s.start(audioSamplesProvider: newAudio.provider)
    d.release()  // the old flush returns "One two" anyway
    guard let old = await Self.joined(oldFinalize, "old finalize", onExpiry: { d.release() }),
      await Self.joined(cancel, "cancel", onExpiry: { d.release() }) != nil
    else { return }
    #expect(old.text == nil)
    #expect(old.strategy == "streaming_cancelled")
    await Self.within("new cycle 1") { await s.cyclesCompleted(reach: 1) }
    newAudio.set(Self.voiced(1.2) + Self.silence(1.2))
    await Self.within("new cycle 2") { await s.cyclesCompleted(reach: 2) }
    #expect(await s.finalize(finalSamples: [], speechSegments: []).text == "Fresh.")
    #expect(d.overlapped == false)
  }

  @Test("a caller-cancelled finalize on the caught-up path releases nothing")
  func callerCancelledCaughtUp() async {
    let d = ScriptedDecoder([
      [Self.native(0, 1500, " Turn left")], [Self.native(0, 1500, " Turn left")],
    ])
    let audio = Audio()
    audio.set(Self.voiced(1.5) + Self.silence(0.1))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(1.5) + Self.silence(1.2))
    await Self.within("cycle 2 applied") { await s.cyclesCompleted(reach: 2) }
    // Hold pulls: first the loop's, then (after the drain) finalize's own.
    audio.startHolding()
    await Self.within("the loop's held pull") { await audio.heldPulls(reach: 1) }
    let finalize = Task { await s.finalize(finalSamples: [], speechSegments: []) }
    await Self.within("finalize at the drain") { await s.drainJoins(reach: 1) }
    audio.releaseOldest()  // the loop's pull returns; the loop sees the stop and ends
    await Self.within("finalize's held pull") { await audio.heldPulls(reach: 2) }
    finalize.cancel()
    audio.stopHolding()
    guard let result = await Self.joined(finalize, "finalize", onExpiry: { audio.stopHolding() })
    else { return }
    #expect(result.accepted == false)
    #expect(result.text == nil, "caught up, but the caller cancelled: no text")
    #expect(result.strategy == "streaming_cancelled")
  }

  @Test("a flush that returns successfully after the caller cancelled releases nothing")
  func callerCancelledFlushReturnsLate() async {
    let d = ScriptedDecoder([[Self.native(0, 1000, " One")], [Self.native(0, 2000, " One two")]])
    d.hold(call: 1)
    d.finishingDespiteCancel()
    let audio = Audio()
    audio.set(Self.voiced(1.2))
    let s = Self.session(d.decode)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1 applied") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2.1))
    let finalize = Task { await s.finalize(finalSamples: [], speechSegments: []) }
    await Self.within("the flush decode") { await d.calls(reach: 2) }
    finalize.cancel()
    await Self.within("the flush's cancellation") { await d.heldCallCancelled() }
    d.release()
    guard let result = await Self.joined(finalize, "finalize", onExpiry: { d.release() }) else {
      return
    }
    #expect(result.text == nil, "the late \"One two\" is not released")
    #expect(result.strategy == "streaming_cancelled")
  }

  // MARK: - #3735 Chunk 9: preview mode (the Universal Live Preview)

  /// What the preview handed the display, in order.
  final class Shown: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var all: [String] { lock.withLock { texts } }
    func append(_ text: String) { lock.withLock { texts.append(text) } }
  }

  private static func previewSession(
    _ decode: @escaping TranscribeCppRollingSession.Decode, limit: Int, shown: Shown
  ) -> TranscribeCppRollingSession {
    TranscribeCppRollingSession(
      decode: decode, cadence: .milliseconds(1),
      publication: .init(
        retentionLimit: limit, onHypothesis: shown.append, onAudioReleased: { _ in }))
  }

  @Test(
    "the preview hands over a bounded tail from the end, never an empty one, and only when it changes"
  )
  func previewPublishesBoundedChangedTails() async {
    let long = (0..<30).map { " word\($0)" }.joined()  // 247 characters, one segment
    let d = ScriptedDecoder([
      [Self.native(0, 1000, long)],
      [],  // an empty decode: the last text stays up
      [Self.native(0, 1000, long)],  // agrees: the words commit, the shown text is unchanged
    ])
    let shown = Shown()
    let audio = Audio()
    audio.set(Self.voiced(1))
    let s = Self.previewSession(d.decode, limit: 40, shown: shown)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1") { await s.cyclesCompleted(reach: 1) }
    audio.set(Self.voiced(2))
    // Cycle 2's empty decode leaves the audio unheard, so cycle 3 retries it at once.
    await Self.within("cycles 2 and 3") { await s.cyclesCompleted(reach: 3) }
    await s.cancel()

    let expected = String(String(long.suffix(40)).drop { $0.isWhitespace })
    #expect(shown.all == [expected], "one text: bounded, from the end, not repeated, never empty")
    #expect(expected.count <= 40 && expected.hasSuffix("word29"))
    #expect(await s.committedTextForTests.count <= 40, "the committed text is kept to the limit")
    #expect(d.callSampleCounts.count == 3, "control: all three decodes ran")
  }

  @Test("preview mode keeps its transcript to the limit while heart mode keeps every word")
  func previewBoundsTheTranscriptHeartKeepsIt() async {
    let preview = Self.previewSession(Self.noDecode, limit: 50, shown: Shown())
    let heart = Self.session(Self.noDecode)
    // Twenty sentences, each agreed by two decodes, so all of them commit in both modes.
    var segments: [RollingSegment] = []
    for i in 0..<20 {
      segments.append(Self.seg(Float(i), Float(i + 1), " sentence\(i)."))
      for session in [preview, heart] {
        await session.apply(segments, realAudioEnd: Float(i + 1))
        await session.apply(segments, realAudioEnd: Float(i + 1) + 0.5)
      }
    }
    let heartText = await heart.committedTextForTests
    #expect(heartText.hasPrefix(" sentence0.") && heartText.hasSuffix(" sentence19."))
    let previewText = await preview.committedTextForTests
    #expect(previewText.count <= 50)
    #expect(heartText.hasSuffix(previewText), "the preview keeps the newest words")
  }

  @Test("an unbroken run longer than the limit (no spaces, CJK) is handed over cut to the limit")
  func previewBoundsUnbrokenText() async {
    let unbroken = String(repeating: "日本語の文章", count: 600)  // 3,600 characters, no spaces
    let d = ScriptedDecoder([[Self.native(0, 1000, unbroken)]])
    let shown = Shown()
    let audio = Audio()
    audio.set(Self.voiced(1))
    let s = Self.previewSession(d.decode, limit: 2_000, shown: shown)
    await s.start(audioSamplesProvider: audio.provider)
    await Self.within("cycle 1") { await s.cyclesCompleted(reach: 1) }
    await s.cancel()
    #expect(shown.all.count == 1)
    #expect(shown.all.first?.count == 2_000)
    #expect(shown.all.first.map { unbroken.hasSuffix($0) } == true, "the newest text, unspaced")
  }

  @Test(
    "an oversized committed word and an oversized hypothesis are both handed over within the limit")
  func previewBuildsOversizedTextWithinTheLimit() async {
    let unbroken = String(repeating: "日本語の文章", count: 600)  // 3,600 characters, no spaces
    let d = ScriptedDecoder([
      [Self.native(0, 1000, unbroken)],
      [Self.native(0, 1000, unbroken)],  // agrees: the oversized word commits
      [Self.native(0, 1000, unbroken), Self.native(1000, 2000, " and" + unbroken)],
    ])
    let shown = Shown()
    let audio = Audio()
    audio.set(Self.voiced(1))
    let s = Self.previewSession(d.decode, limit: 2_000, shown: shown)
    await s.start(audioSamplesProvider: audio.provider)
    for (step, seconds) in [2, 3].enumerated() {
      await Self.within("cycle \(step + 1)") { await s.cyclesCompleted(reach: step + 1) }
      audio.set(Self.voiced(Float(seconds)))
    }
    await Self.within("cycle 3") { await s.cyclesCompleted(reach: 3) }
    await s.cancel()
    #expect(d.callSampleCounts.count == 3, "control: all three decodes ran")
    #expect(
      await s.committedTextForTests.count <= 2_000, "the committed oversized word is kept bounded")
    #expect(!shown.all.isEmpty && shown.all.allSatisfy { $0.count <= 2_000 })
    #expect(
      shown.all.last.map { unbroken.hasSuffix($0) || $0.hasSuffix(String(unbroken.suffix(100))) }
        == true,
      "the newest text, from the end")
  }

  @Test("continuous unstable speech past the window bound keeps handing over bounded text")
  func previewStaysBoundedPastTheWindow() async {
    // Every decode disagrees with the last, so nothing commits and the window advances by force.
    // Each also ends differently: an unchanged tail is (rightly) not handed over again.
    let words = (0..<300).map { " w\($0)" }.joined()
    let d = ScriptedDecoder(
      (0..<6).map { i in
        [Self.native(0, 1000, (i.isMultiple(of: 2) ? words : " other" + words) + " end\(i)")]
      })
    let shown = Shown()
    let audio = Audio()
    let s = Self.previewSession(d.decode, limit: 100, shown: shown)
    audio.set(Self.voiced(20))
    await s.start(audioSamplesProvider: audio.provider)
    for (step, seconds) in [26, 32, 34].enumerated() {
      await Self.within("cycle \(step + 1)") { await s.cyclesCompleted(reach: step + 1) }
      audio.set(Self.voiced(Float(seconds)))
    }
    await Self.within("cycle 4") { await s.cyclesCompleted(reach: 4) }
    await s.cancel()
    #expect(await s.bufferStartForTests > 0, "control: the window advanced past the bound")
    #expect(d.callSampleCounts.allSatisfy { $0 <= 30 * 16_000 }, "no decode past 25 + 5 s")
    #expect(shown.all.count >= 2, "control: text kept flowing")
    #expect(shown.all.allSatisfy { $0.count <= 100 })
  }

  // MARK: - #2117: the preview owner keeps a rolling window

  /// The provider of a preview owner that drops what the session released: `count` stays
  /// absolute, the array holds only the tail. `release` is wired to `onAudioReleased`.
  final class TrimmingAudio: @unchecked Sendable {
    private let lock = NSLock()
    private let full: [Float]
    private var origin = 0
    private var end = 0
    private var marks: [Int] = []
    init(_ full: [Float]) { self.full = full }
    func set(seconds: Float) { lock.withLock { end = Int(seconds * 16_000) } }
    func release(_ mark: Int) {
      lock.withLock {
        marks.append(mark)
        origin = max(origin, min(mark, end))
      }
    }
    var released: [Int] { lock.withLock { marks } }
    var retained: Int { lock.withLock { end - origin } }
    var provider: @Sendable () async -> (samples: [Float], count: Int) {
      { [self] in lock.withLock { (Array(full[origin..<end]), end) } }
    }
  }

  /// Every decode input, in order.
  final class Windows: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [[Float]] = []
    var all: [[Float]] { lock.withLock { inputs } }
    /// Never agrees with the previous call, so nothing commits and the origin advances by
    /// force; non-empty, so every cycle is heard once.
    var decode: TranscribeCppRollingSession.Decode {
      { [self] samples in
        let call = lock.withLock { () -> Int in
          inputs.append(samples)
          return inputs.count
        }
        let ms = Int64(samples.count / 16)
        return TranscribeCppRunResult(
          text: "a\(call) b\(call)", detectedLanguage: nil,
          segments: [TranscribeCppSegment(startMs: 0, endMs: ms, text: " a\(call) b\(call)")])
      }
    }
  }

  /// When this fails, a long meeting's live words show text from the wrong moment, or stop.
  @Test("a provider that drops released audio decodes exactly the windows the whole recording would")
  func trimmedProviderDecodesTheSameWindows() async {
    // Position-dependent audio, so a window cut from the wrong offset cannot match.
    let full = (0..<(60 * 16_000)).map { Float(sin(Double($0) * 0.0123)) * 0.2 }
    var arms: [(windows: Windows, audio: TrimmingAudio, trims: Bool)] = []
    for trims in [false, true] {
      let windows = Windows()
      let audio = TrimmingAudio(full)
      let s = TranscribeCppRollingSession(
        decode: windows.decode, cadence: .milliseconds(1),
        publication: .init(
          retentionLimit: 2_000, onHypothesis: { _ in },
          onAudioReleased: { trims ? audio.release($0) : () }))
      audio.set(seconds: 20)
      await s.start(audioSamplesProvider: audio.provider)
      // 32 s and 60 s each push the unconfirmed window past 30 s: the origin moves twice.
      for (step, seconds) in [26, 32, 34, 50, 60].enumerated() {
        await Self.within("cycle \(step + 1)") { await s.cyclesCompleted(reach: step + 1) }
        audio.set(seconds: Float(seconds))
      }
      await Self.within("cycle 6") { await s.cyclesCompleted(reach: 6) }
      await s.cancel()
      arms.append((windows, audio, trims))
    }
    let (whole, trimmed) = (arms[0], arms[1])
    #expect(whole.windows.all.map(\.count) == [20, 26, 8, 10, 26, 8].map { $0 * 16_000 })
    #expect(trimmed.windows.all == whole.windows.all, "identical decode inputs, sample for sample")
    // Independent of both arms' slicing: each window starts at its literal origin.
    let starts = trimmed.windows.all.map(\.first)
    #expect(starts == [0, 0, 24, 24, 24, 52].map { Optional(full[$0 * 16_000]) })
    #expect(trimmed.audio.released == [24 * 16_000, 52 * 16_000], "one mark per origin move")
    #expect(trimmed.audio.retained == 8 * 16_000, "the owner keeps only the live window")
    #expect(whole.audio.retained == 60 * 16_000, "control: the other arm kept everything")
  }

  @Test("a committed-boundary trim releases the new origin monotonically")
  func releaseMarkIsTheNewOrigin() async {
    let marks = Shown()
    let preview = TranscribeCppRollingSession(
      decode: Self.noDecode, cadence: .milliseconds(1),
      publication: .init(
        retentionLimit: 2_000, onHypothesis: { _ in }, onAudioReleased: { marks.append("\($0)") }))
    // Sentences agreed by two decodes, so they commit; past 15 s the origin moves to the last
    // committed end that leaves 8 s of audio.
    var segments: [RollingSegment] = []
    for i in 0..<18 {
      segments.append(Self.seg(Float(i), Float(i + 1), " sentence\(i)."))
      await preview.apply(segments, realAudioEnd: Float(i + 1))
      await preview.apply(segments, realAudioEnd: Float(i + 1) + 0.5)
    }
    let origin = await preview.bufferStartForTests
    #expect(origin > 0, "control: the origin moved")
    #expect(marks.all.last == "\(Int(origin * 16_000))")
    #expect(marks.all.compactMap(Int.init) == marks.all.compactMap(Int.init).sorted())
  }
}
