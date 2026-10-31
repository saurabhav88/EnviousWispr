import EnviousWisprAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #4254 plan §16.2, §16.6: a meeting's live words skip Whisper on confirmed silence, through
/// the production rolling loop, with a fake detector and decoder.
///
/// **What the user sees when this fails:** EnviousMeet's live words invent "Thank you." over
/// silence, lose the first words after a long pause, show words at the wrong moment, repeat or
/// skip audio, keep stale text, or stop updating after the detector fails.
@Suite(
  "Meeting live words speech gate (#4254)", .serialized, .timeLimit(.minutes(1)),
  .tags(.productOutcome))
struct MeetingLiveSpeechGateTests {
  typealias Rolling = TranscribeCppRollingSessionTests
  static let rate = 16_000

  struct Broken: Error {}

  final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var current: Value { lock.withLock { value } }
    @discardableResult
    func update(_ change: (inout Value) -> Void) -> Value {
      lock.withLock {
        change(&value)
        return value
      }
    }
  }

  /// Raw speech at fixed absolute ranges; whole 4,096-sample chunks are classified, as the
  /// real detector does. Records every append and prune.
  actor FakeDetector: LiveSpeechDetecting {
    let speech: [Range<Int>]
    let chunk: Int
    private let failOnAppend: Int?
    private var fedCount = 0
    private(set) var appends: [Range<Int>] = []
    private(set) var prunes: [Int] = []
    private var holdFirst: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var didEnter = false

    init(
      speech: [Range<Int>] = [], chunk: Int = 4_096, failOnAppend: Int? = nil,
      holdFirst: Bool = false
    ) {
      self.speech = speech
      self.chunk = chunk
      self.failOnAppend = failOnAppend
      self.holdFirst = holdFirst
    }

    func append(_ samples: [Float]) async throws {
      let index = appends.count
      appends.append(fedCount..<(fedCount + samples.count))
      if holdFirst {
        holdFirst = false
        didEnter = true
        for waiter in entered { waiter.resume() }
        entered = []
        // Like the vendor model call: cancellation does not end it early.
        await withCheckedContinuation { held = $0 }
      }
      if index == failOnAppend { throw Broken() }
      fedCount += samples.count
    }

    var classifiedSamples: Int { fedCount / chunk * chunk }

    /// A range reaching past the classified end is speech still open.
    func liveSpeech(in window: Range<Int>) -> MeetingLiveSpeech {
      let classified = classifiedSamples
      let inside = speech.compactMap { range -> Range<Int>? in
        let lower = max(range.lowerBound, window.lowerBound)
        let upper = min(range.upperBound, classified, window.upperBound)
        return upper > lower ? lower..<upper : nil
      }
      let open = speech.contains { $0.lowerBound < classified && $0.upperBound > classified }
      return MeetingLiveSpeech(speech: inside, speechOpen: open, classifiedEnd: classified)
    }

    func prune(before sample: Int) { prunes.append(sample) }

    func entered() async {
      if didEnter { return }
      await withCheckedContinuation { entered.append($0) }
    }

    func release() {
      held?.resume()
      held = nil
    }
  }

  /// Both decode routes. `from` calls record (window size, trim); raw calls record the size.
  final class Decoder: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[TranscribeCppSegment]]
    private(set) var fromCalls: [(count: Int, from: Int, to: Int)] = []
    private(set) var rawCalls: [Int] = []
    private let failing: Bool
    private let neverAgree: Bool

    init(_ script: [[TranscribeCppSegment]] = [], failing: Bool = false, neverAgree: Bool = false) {
      self.script = script
      self.failing = failing
      self.neverAgree = neverAgree
    }

    var calls: Int { lock.withLock { fromCalls.count + rawCalls.count } }
    var froms: [(count: Int, from: Int, to: Int)] { lock.withLock { fromCalls } }
    var raws: [Int] { lock.withLock { rawCalls } }

    private func next(_ count: Int) throws -> TranscribeCppRunResult {
      if failing { throw TranscribeCppExecutor.ExecutorError.heartBusy }
      let segments = lock.withLock { () -> [TranscribeCppSegment] in
        if neverAgree {
          let n = fromCalls.count + rawCalls.count
          return [TranscribeCppSegment(startMs: 0, endMs: Int64(count / 16), text: " a\(n) b\(n)")]
        }
        return script.isEmpty ? [] : script.removeFirst()
      }
      return TranscribeCppRunResult(
        text: segments.map(\.text).joined().trimmingCharacters(in: .whitespaces),
        detectedLanguage: nil, segments: segments)
    }

    var from: TranscribeCppRollingSession.DecodeFrom {
      { [self] samples, from, to in
        lock.withLock { fromCalls.append((samples.count, from, to)) }
        return try next(to - from)
      }
    }

    var raw: TranscribeCppRollingSession.Decode {
      { [self] samples in
        lock.withLock { rawCalls.append(samples.count) }
        return try next(samples.count)
      }
    }
  }

  static func meeting(
    _ detector: @escaping @Sendable () -> any LiveSpeechDetecting, decoder: Decoder,
    audio: Rolling.TrimmingAudio, events: Rolling.Events
  ) -> TranscribeCppRollingSession {
    var publication = TranscribeCppRollingSession.Publication(
      retentionLimit: 2_000, onHypothesis: { _ in }, onAudioReleased: audio.release)
    publication.onTranscript = events.append
    return TranscribeCppRollingSession(
      decode: decoder.raw, cadence: .milliseconds(1), publication: publication,
      meetingSpeech: .init(makeDetector: detector, decodeFrom: decoder.from))
  }

  static func seg(_ startMs: Int64, _ endMs: Int64, _ text: String) -> TranscribeCppSegment {
    TranscribeCppSegment(startMs: startMs, endMs: endMs, text: text)
  }

  static func audio(seconds: Int) -> Rolling.TrimmingAudio {
    Rolling.TrimmingAudio((0..<(seconds * rate)).map { Float(sin(Double($0) * 0.0123)) * 0.2 })
  }

  // MARK: - Outcomes and marks

  @Test("confirmed silence skips native work and moves the mark to the classified end")
  func silenceSkips() async {
    let detector = FakeDetector()
    let decoder = Decoder()
    let audio = Self.audio(seconds: 30)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: .init())
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("cycle 1") { await s.cyclesCompleted(reach: 1) }
    #expect(decoder.calls == 0, "no native decode on silence")
    #expect(
      await s.processedSampleMarkForTests == 320_000 / 4_096 * 4_096,
      "the classified end, not the captured end")
    await s.cancel()
  }

  @Test("unclassified audio, an empty recognition and a refusal never move the mark")
  func pendingEmptyRefusedKeepTheMark() async {
    // Pending: nothing classified yet.
    let pending = FakeDetector(chunk: 1_000_000)
    let pendingDecoder = Decoder()
    let a1 = Self.audio(seconds: 30)
    let s1 = Self.meeting({ pending }, decoder: pendingDecoder, audio: a1, events: .init())
    a1.set(seconds: 20)
    await s1.start(audioSamplesProvider: a1.provider)
    await Rolling.within("pending cycles") { await s1.cyclesCompleted(reach: 3) }
    await s1.cancel()
    #expect(pendingDecoder.calls == 0)
    #expect(await s1.processedSampleMarkForTests == 0)
    // Empty recognition on speech, and a refused decode.
    for decoder in [Decoder(), Decoder(failing: true)] {
      let detector = FakeDetector(speech: [0..<1_000_000])
      let audio = Self.audio(seconds: 30)
      let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: .init())
      audio.set(seconds: 20)
      await s.start(audioSamplesProvider: audio.provider)
      await Rolling.within("decoded cycles") { await s.cyclesCompleted(reach: 2) }
      await s.cancel()
      #expect(decoder.calls >= 2, "the audio is tried again")
      #expect(await s.processedSampleMarkForTests == 0)
    }
  }

  // MARK: - Feeding

  @Test("odd appends and a releasing owner feed every sample exactly once, in order")
  func feedsEachSampleOnce() async {
    let detector = FakeDetector()
    let decoder = Decoder()
    let events = Rolling.Events()
    let audio = Self.audio(seconds: 60)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: events)
    let steps: [Float] = [20.3, 21.9, 33.7, 41.1, 60]
    audio.set(seconds: steps[0])
    await s.start(audioSamplesProvider: audio.provider)
    for (index, seconds) in steps.dropFirst().enumerated() {
      await Rolling.within("cycle \(index + 1)") { await s.cyclesCompleted(reach: index + 1) }
      audio.set(seconds: seconds)
    }
    await Rolling.within("last cycle") { await s.cyclesCompleted(reach: steps.count) }
    await s.cancel()
    let appends = await detector.appends
    #expect(appends.first?.lowerBound == 0)
    #expect(appends.last?.upperBound == 60 * Self.rate)
    #expect(
      zip(appends, appends.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "\(appends)")
    let prunes = await detector.prunes
    #expect(
      prunes == prunes.sorted() && (prunes.last ?? 0) > 0, "pruned up to each new origin: \(prunes)"
    )
    #expect(!audio.released.isEmpty, "control: the owner dropped released audio")
    #expect(audio.retained <= 30 * Self.rate, "silence keeps the window bounded")
    #expect(events.all.isEmpty, "advancing through silence discards nothing")
    #expect(decoder.calls == 0)
  }

  @Test("audio dropped before the detector saw it turns detection off for the session")
  func missingAudioDegrades() async {
    let detector = FakeDetector()
    let decoder = Decoder([[Self.seg(0, 500, " later")]])
    let full = (0..<(40 * Self.rate)).map { Float($0 % 7) * 0.01 }
    let pulls = Box(0)
    let provider: @Sendable () async -> (samples: [Float], count: Int) = {
      if pulls.update({ $0 += 1 }) == 1 { return (Array(full[0..<(20 * Self.rate)]), 20 * Self.rate) }
      // The owner kept only the last 5 s: 15 s the detector never saw are gone.
      return (Array(full[(35 * Self.rate)..<(40 * Self.rate)]), 40 * Self.rate)
    }
    var publication = TranscribeCppRollingSession.Publication(
      retentionLimit: 2_000, onHypothesis: { _ in }, onAudioReleased: { _ in })
    publication.onTranscript = { _ in }
    let s = TranscribeCppRollingSession(
      decode: decoder.raw, cadence: .milliseconds(1), publication: publication,
      meetingSpeech: .init(makeDetector: { detector }, decodeFrom: decoder.from))
    await s.start(audioSamplesProvider: provider)
    await Rolling.within("two cycles") { await s.cyclesCompleted(reach: 2) }
    #expect(await s.speechDetectionDegradedForTests == true)
    await s.cancel()
    #expect(await detector.appends.count == 1, "never fed across the gap")
    #expect(decoder.raws.first != nil, "later windows take today's raw route")
  }

  // MARK: - Trim and timing

  @Test("speech after 60 s of silence is trimmed, decoded twice, committed at its real time")
  func speechAfterLongSilence() async {
    let detector = FakeDetector(speech: [(61 * Self.rate)..<(64 * Self.rate)])
    let words = [Self.seg(100, 1_500, " hello there.")]
    let decoder = Decoder([words, words])
    let events = Rolling.Events()
    let audio = Self.audio(seconds: 80)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: events)
    audio.set(seconds: 60)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("silent cycle") { await s.cyclesCompleted(reach: 1) }
    #expect(decoder.calls == 0)
    let origin = await s.bufferStartForTests
    #expect(origin == 52, "the origin advanced through silence to 8 s before the end")
    audio.set(seconds: 70)
    await Rolling.within("first speech decode") { await s.cyclesCompleted(reach: 2) }
    audio.set(seconds: 71.5)
    await Rolling.within("second speech decode") { await s.cyclesCompleted(reach: 3) }
    await s.cancel()
    let froms = decoder.froms
    #expect(
      froms.map(\.from) == [9 * Self.rate, 9 * Self.rate], "leading silence trimmed to the speech")
    #expect(froms.map(\.count) == [18 * Self.rate, Int(19.5 * Float(Self.rate))])
    #expect(froms.map(\.to) == [12 * Self.rate, 12 * Self.rate], "the slice ends where the closed speech ends")
    #expect(events.finalized == "hello there.", "held-back words commit on agreement")
    #expect(await s.lastCommittedEndForTests == 52 + 9 + 1.5, "origin + trim + segment end, once")
    #expect(!events.all.contains(.discontinuity))
  }

  @Test("interior silence with speech on both sides is decoded whole from the first speech")
  func interiorGapKept() async {
    let detector = FakeDetector(speech: [
      (2 * Self.rate)..<(4 * Self.rate), (12 * Self.rate)..<(14 * Self.rate),
    ])
    let decoder = Decoder([[Self.seg(0, 2_000, " one."), Self.seg(10_000, 12_000, " two.")]])
    let audio = Self.audio(seconds: 30)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: .init())
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("decode") { await s.cyclesCompleted(reach: 1) }
    await s.cancel()
    #expect(
      decoder.froms.first?.count == 20 * Self.rate, "the whole window, interior silence included")
    #expect(decoder.froms.first?.from == 2 * Self.rate)
    #expect(decoder.froms.first?.to == 14 * Self.rate, "interior silence kept; the slice ends at the last speech")
    #expect(await s.heldBackTextForTests == "one. two.", "both sides kept")
  }

  @Test("words in dispute that a forced advance discards emit a discontinuity")
  func disputedDiscardIsADiscontinuity() async {
    let detector = FakeDetector(speech: [0..<(60 * Self.rate)])
    let decoder = Decoder(neverAgree: true)
    let events = Rolling.Events()
    let audio = Self.audio(seconds: 60)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: events)
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("cycle 1") { await s.cyclesCompleted(reach: 1) }
    audio.set(seconds: 32)
    await Rolling.within("cycle 2") { await s.cyclesCompleted(reach: 2) }
    await s.cancel()
    #expect(events.all.contains(.discontinuity))
    #expect(events.finalized.isEmpty, "silence or force never finalizes disputed words")
  }

  // MARK: - Failure, isolation, teardown

  @Test("a detector failure after good chunks turns detection off; later speech is raw and on time")
  func detectorFailureFallsBackToRaw() async {
    let detector = FakeDetector(failOnAppend: 1)
    let decoder = Decoder([[Self.seg(1_000, 2_000, " after.")]])
    let audio = Self.audio(seconds: 30)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: .init())
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("silent cycle") { await s.cyclesCompleted(reach: 1) }
    audio.set(seconds: 22)
    await Rolling.within("raw cycle") { await s.cyclesCompleted(reach: 2) }
    #expect(await s.speechDetectionDegradedForTests == true)
    await s.cancel()
    #expect(decoder.raws == [22 * Self.rate], "the untrimmed window from origin 0")
    #expect(decoder.froms.isEmpty)
    #expect(await detector.appends.count == 2, "no append after the failure")
    #expect(await s.heldBackTextForTests == "after.")
  }

  @Test("each run of each session owns its own detector")
  func detectorsAreIndependent() async {
    let made = Box<[Int]>([])
    let detectors = [FakeDetector(), FakeDetector()]
    var sessions: [TranscribeCppRollingSession] = []
    for index in 0..<2 {
      let audio = Self.audio(seconds: 30)
      let s = Self.meeting(
        { made.update { $0.append(index) }; return detectors[index] }, decoder: Decoder(), audio: audio,
        events: .init())
      audio.set(seconds: Float(18 + index))
      await s.start(audioSamplesProvider: audio.provider)
      sessions.append(s)
    }
    for s in sessions { await Rolling.within("cycle") { await s.cyclesCompleted(reach: 1) } }
    for s in sessions { await s.cancel() }
    #expect(made.current.sorted() == [0, 1])
    #expect(await detectors[0].appends.last?.upperBound == 18 * Self.rate)
    #expect(await detectors[1].appends.last?.upperBound == 19 * Self.rate)
  }

  @Test("cancel returns only after the detector's work in flight has returned")
  func cancelJoinsDetectorWork() async {
    let detector = FakeDetector(holdFirst: true)
    let audio = Self.audio(seconds: 30)
    let s = Self.meeting({ detector }, decoder: Decoder(), audio: audio, events: .init())
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("append entered") { await detector.entered() }
    let done = Box(false)
    let cancelling = Task {
      await s.cancel()
      done.update { $0 = true }
    }
    // The terminal has reached the shared drain, which waits on the held append.
    await Rolling.within("cancel at the drain") { await s.drainJoins(reach: 1) }
    #expect(!done.current, "cancel waits for the detector")
    await detector.release()
    await Rolling.within("cancel") { await cancelling.value }
    #expect(done.current)
  }

  @Test("a closed speech ends the slice: padding-only text dropped, crossing ends clamped, mark at the slice end")
  func closedSpeechEndsTheSlice() async {
    let detector = FakeDetector(speech: [(41 * Self.rate)..<(44 * Self.rate)])
    // Times relative to the slice start (41 s); the slice is 3 s long.
    let words = [Self.seg(0, 1_000, " hi."), Self.seg(2_000, 4_000, " crossing"), Self.seg(3_500, 3_800, " pad")]
    let decoder = Decoder([words, words])
    let events = Rolling.Events()
    let audio = Self.audio(seconds: 60)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: events)
    audio.set(seconds: 40)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("silent cycle") { await s.cyclesCompleted(reach: 1) }
    #expect(await s.bufferStartForTests == 32, "control: a nonzero origin")
    audio.set(seconds: 50)
    await Rolling.within("decode 1") { await s.cyclesCompleted(reach: 2) }
    audio.set(seconds: 51.5)
    await Rolling.within("decode 2") { await s.cyclesCompleted(reach: 3) }
    await s.cancel()
    #expect(decoder.froms.map(\.from) == [9 * Self.rate, 9 * Self.rate])
    #expect(decoder.froms.map(\.to) == [12 * Self.rate, 12 * Self.rate])
    #expect(events.finalized == "hi. crossing", "the segment starting past the slice end is not real")
    #expect(await s.lastCommittedEndForTests == 44, "the crossing end clamped to the slice end")
    #expect(await s.processedSampleMarkForTests == 44 * Self.rate, "processed only to the slice end")
  }

  @Test("speech starting in the unclassified remainder is left out, then reached later")
  func remainderSpeechIsReachedLater() async {
    // Classified end at 20 s is 319,488; the second speech starts after it.
    let detector = FakeDetector(speech: [(2 * Self.rate)..<(4 * Self.rate), 319_600..<(30 * Self.rate)])
    let decoder = Decoder()
    let audio = Self.audio(seconds: 30)
    let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: .init())
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("decode 1") { await s.cyclesCompleted(reach: 1) }
    audio.set(seconds: 23)
    await Rolling.within("decode 2") { await s.cyclesCompleted(reach: 2) }
    await s.cancel()
    let froms = decoder.froms
    #expect(froms.first?.to == 4 * Self.rate, "the remainder is not decoded with the closed speech")
    #expect(froms.last?.to == 23 * Self.rate, "open speech keeps the window end: the remainder is reached")
    #expect(froms.count == 2)
  }

  @Test("empty and refused decodes past the retention ceiling keep the window bounded")
  func emptyAndRefusedStayBounded() async {
    for decoder in [Decoder(), Decoder(failing: true)] {
      let detector = FakeDetector(speech: [0..<(60 * Self.rate)])
      let audio = Self.audio(seconds: 60)
      let s = Self.meeting({ detector }, decoder: decoder, audio: audio, events: .init())
      audio.set(seconds: 20)
      await s.start(audioSamplesProvider: audio.provider)
      await Rolling.within("cycle 1") { await s.cyclesCompleted(reach: 1) }
      audio.set(seconds: 40)
      await Rolling.within("cycle past the ceiling") { await s.cyclesCompleted(reach: 2) }
      await s.cancel()
      #expect(!audio.released.isEmpty, "the origin moved past the ceiling")
      #expect(audio.retained <= 30 * Self.rate, "bounded: \(audio.retained)")
    }
  }

  @Test("cancel releases the drained run's detector; an older cancel never clears a newer run's")
  func cancelReleasesTheDetector() async {
    final class Weak: @unchecked Sendable {
      private let lock = NSLock()
      private weak var stored: FakeDetector?
      var value: FakeDetector? { lock.withLock { stored } }
      func set(_ detector: FakeDetector) { lock.withLock { stored = detector } }
    }
    let released = Weak()
    do {
      let audio = Self.audio(seconds: 30)
      let s = Self.meeting(
        {
          let made = FakeDetector()
          released.set(made)
          return made
        }, decoder: Decoder(), audio: audio, events: .init())
      audio.set(seconds: 20)
      await s.start(audioSamplesProvider: audio.provider)
      await Rolling.within("cycle") { await s.cyclesCompleted(reach: 1) }
      #expect(released.value != nil, "control: the detector is alive while the session runs")
      await s.cancel()
      #expect(released.value == nil, "the retained, cancelled session holds no detector")
      #expect(await s.speechDetectionDegradedForTests == nil)
    }
    // An older cancel still draining while a newer run starts.
    let held = FakeDetector(holdFirst: true)
    let fresh = FakeDetector()
    let runs = Box(0)
    let audio = Self.audio(seconds: 30)
    let s = Self.meeting(
      { runs.update { $0 += 1 } == 1 ? held : fresh }, decoder: Decoder(), audio: audio,
      events: .init())
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("held append") { await held.entered() }
    let older = Task { await s.cancel() }
    await Rolling.within("older cancel at the drain") { await s.drainJoins(reach: 1) }
    await s.start(audioSamplesProvider: audio.provider)
    await held.release()
    await Rolling.within("older cancel") { await older.value }
    #expect(await s.speechDetectionDegradedForTests == false, "the newer run keeps its detector")
    await s.cancel()
  }

  @Test("a session without the meeting flag has no speech detection")
  func flagIsolation() async {
    let decoder = Decoder()
    let s = TranscribeCppRollingSession(decode: decoder.raw, cadence: .milliseconds(1))
    let audio = Self.audio(seconds: 30)
    audio.set(seconds: 20)
    await s.start(audioSamplesProvider: audio.provider)
    await Rolling.within("cycle") { await s.cyclesCompleted(reach: 1) }
    await s.cancel()
    #expect(await s.speechDetectionDegradedForTests == nil)
    #expect(decoder.raws == [20 * Self.rate], "today's decode of the whole window")
  }
}
