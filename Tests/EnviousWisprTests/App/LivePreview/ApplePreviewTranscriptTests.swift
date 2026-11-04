import AVFoundation
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #3973: Apple speech's transcript session for EnviousMeet's live words, through the production
/// collector and teardown with Apple's results loop and analyzer calls replaced at their seam.
///
/// **What the user sees when this fails:** a meeting's live words repeat a sentence, lose the
/// last sentence when the meeting stops, mangle a custom word, keep showing a stopped engine as
/// live, or leave Apple's speech model claimed after the meeting.
@Suite("Apple transcript session (#3973)", .tags(.productOutcome))
struct ApplePreviewTranscriptTests {

  /// Apple's results stream, driven by the test.
  final class Results: @unchecked Sendable {
    let stream: AsyncThrowingStream<LiveTranscriptResult, any Error>
    let continuation: AsyncThrowingStream<LiveTranscriptResult, any Error>.Continuation
    init() {
      (stream, continuation) = AsyncThrowingStream.makeStream(of: LiveTranscriptResult.self)
    }
    func yield(_ text: String, final: Bool) {
      continuation.yield(.untimed(text, isFinal: final))
    }
    func yield(_ result: LiveTranscriptResult) { continuation.yield(result) }
    var consume:
      @Sendable (@escaping @Sendable (LiveTranscriptResult) -> Void) async throws -> Void
    {
      { [stream] deliver in
        for try await result in stream { deliver(result) }
      }
    }
  }

  /// Every event and every teardown step, in order, with a wait for a count.
  final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var all: [String] { lock.withLock { items } }
    func append(_ item: String) {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        items.append(item)
        let ready = waiters.filter { $0.0 <= items.count }.map(\.1)
        waiters.removeAll { $0.0 <= items.count }
        return ready
      }
      for waiter in ready { waiter.resume() }
    }
    func event(_ event: LiveWordsEvent) {
      switch event {
      case .update(let finalized, let inProgress):
        append("update[\(MeetingTimedPiece.text(of: finalized))|\(inProgress)]")
      case .discontinuity: append("discontinuity")
      case .ended(.requested): append("ended:requested")
      case .ended(.failed(let reason)): append("ended:failed:\(reason)")
      }
    }
    func reach(_ count: Int) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if items.count >= count { return true }
          waiters.append((count, c))
          return false
        }
        if now { c.resume() }
      }
    }
  }

  private static func collector(
    _ results: Results, log: Log, lookups: WordCorrector.Lookups? = nil
  ) -> LiveTranscriptCollector {
    LiveTranscriptCollector(
      lookups: lookups, timing: nil, onEvent: log.event, consume: results.consume)
  }

  /// A teardown whose analyzer end closes the results stream, as Apple's does.
  private static func teardown(_ results: Results, log: Log) -> LiveTranscriptCollector.Teardown {
    LiveTranscriptCollector.Teardown(
      endAnalyzer: {
        log.append("analyzer-ended")
        results.continuation.finish()
      },
      release: { log.append("released") })
  }

  @Test("words in progress then their final version arrive once each, in order")
  func volatileThenFinal() async {
    let results = Results()
    let log = Log()
    let collector = Self.collector(results, log: log)
    results.yield("Hello wor", final: false)
    results.yield("Hello world.", final: true)
    results.yield("How are", final: false)
    results.yield("How are you?", final: true)
    await PreviewWait.within("four updates") { await log.reach(4) }
    await collector.end(Self.teardown(results, log: log))
    #expect(
      log.all == [
        "update[|Hello wor]", "update[Hello world.|]", "update[|How are]",
        "update[How are you?|]", "analyzer-ended", "ended:requested", "released",
      ])
  }

  @Test("custom words are corrected in every piece")
  func correctionPerPiece() async {
    let lookups = WordCorrector.buildLookups(words: [
      CustomWord(canonical: "EnviousWispr", aliases: ["envious whisper"])
    ])
    let results = Results()
    let log = Log()
    let collector = Self.collector(results, log: log, lookups: lookups)
    results.yield("I use envious whisper", final: false)
    results.yield("I use envious whisper daily.", final: true)
    await PreviewWait.within("two updates") { await log.reach(2) }
    await collector.end(Self.teardown(results, log: log))
    #expect(log.all.prefix(2) == ["update[|I use EnviousWispr]", "update[I use EnviousWispr daily.|]"])
  }

  @Test("ending waits for queued finals before the end event and the locale release")
  func endDrainsQueuedFinals() async {
    let results = Results()
    let log = Log()
    let gate = PreviewWait.Once()
    // The results loop is slow: each piece waits for the gate, as a busy collector would.
    let collector = LiveTranscriptCollector(
      lookups: nil, timing: nil, onEvent: log.event,
      consume: { [stream = results.stream] deliver in
        for try await result in stream {
          _ = await gate.value()
          deliver(result)
        }
      })
    results.yield("One.", final: true)
    results.yield("Two.", final: true)
    let ended = PreviewWait.Once()
    let ending = Task {
      await collector.end(Self.teardown(results, log: log))
      ended.fulfil(true)
    }
    await PreviewWait.within("the analyzer end", onExpiry: { gate.fulfil(true) }) {
      await log.reach(1)
    }
    #expect(log.all == ["analyzer-ended"], "control: nothing delivered while the loop is gated")
    gate.fulfil(true)
    await PreviewWait.within("the end", onExpiry: { gate.fulfil(true) }) { await ending.value }
    #expect(await ended.value())
    #expect(
      log.all == [
        "analyzer-ended", "update[One.|]", "update[Two.|]", "ended:requested", "released",
      ])
  }

  @Test("results that stop without being asked end the session as failed, once")
  func unrequestedCompletion() async {
    let results = Results()
    let log = Log()
    let collector = Self.collector(results, log: log)
    results.yield("Still talking", final: false)
    results.continuation.finish()
    await PreviewWait.within("the failure") { await log.reach(2) }
    await collector.end(Self.teardown(results, log: log))
    #expect(
      log.all == [
        "update[|Still talking]", "ended:failed:stream ended", "analyzer-ended", "released",
      ])
  }

  @Test("an error is a failure, before or during a requested end; a clean finish after end is not")
  func errorAndRequestedEnd() async {
    struct ServiceDied: Error {}
    let results = Results()
    let log = Log()
    _ = Self.collector(results, log: log)
    results.continuation.finish(throwing: ServiceDied())
    await PreviewWait.within("the failure") { await log.reach(1) }
    #expect(log.all == ["ended:failed:ServiceDied"])

    let later = Results()
    let laterLog = Log()
    let collector = Self.collector(later, log: laterLog)
    await collector.end(
      LiveTranscriptCollector.Teardown(
        endAnalyzer: {
          laterLog.append("analyzer-ended")
          // Ending the analyzer surfaces as an error on the results stream.
          later.continuation.finish(throwing: ServiceDied())
        },
        release: { laterLog.append("released") }))
    #expect(laterLog.all == ["analyzer-ended", "ended:failed:ServiceDied", "released"])
  }

  @Test("two ends at once run one teardown, one end event and one locale release")
  func concurrentEnds() async {
    let results = Results()
    let log = Log()
    let collector = Self.collector(results, log: log)
    let teardown = Self.teardown(results, log: log)
    async let first: Void = collector.end(teardown)
    async let second: Void = collector.end(teardown)
    _ = await (first, second)
    await collector.end(teardown)
    #expect(log.all == ["analyzer-ended", "ended:requested", "released"])
  }

  @Test("an analyzer that got no audio is cancelled; a failing finalize falls back to cancel")
  func analyzerEndRule() async {
    struct Refused: Error {}
    for (fed, finalizeThrows, expected) in [
      (false, false, ["input-closed", "cancelled"]),
      (true, false, ["input-closed", "finalized"]),
      (true, true, ["input-closed", "finalize-threw", "cancelled"]),
    ] {
      let log = Log()
      await LiveTranscriptCollector.endAnalyzer(
        finishInput: { log.append("input-closed") }, fedAnyAudio: fed,
        finalize: {
          if finalizeThrows {
            log.append("finalize-threw")
            throw Refused()
          }
          log.append("finalized")
        },
        cancel: { log.append("cancelled") })
      #expect(log.all == expected, "fed=\(fed) finalizeThrows=\(finalizeThrows)")
    }
  }

  @Test("a discarded opening reports nothing, and ending one session leaves another's claim")
  func discardAndIsolation() async {
    let discarded = Results()
    let discardedLog = Log()
    let quiet = Self.collector(discarded, log: discardedLog)
    quiet.silence()
    discarded.yield("never shown", final: true)
    discarded.continuation.finish()
    await quiet.task?.value
    #expect(discardedLog.all.isEmpty)

    let liveA = Results()
    let liveB = Results()
    let logA = Log()
    let logB = Log()
    let a = Self.collector(liveA, log: logA)
    _ = Self.collector(liveB, log: logB)
    await a.end(Self.teardown(liveA, log: logA))
    #expect(logA.all == ["analyzer-ended", "ended:requested", "released"])
    #expect(logB.all.isEmpty, "the other session is still live and still holds its claim")
    liveB.continuation.finish()
  }

  @Test("the locale is released only after the analyzer ended and the results loop finished")
  func releaseOrder() async {
    let results = Results()
    let log = Log()
    let collector = Self.collector(results, log: log)
    results.yield("Last words.", final: true)
    await collector.end(Self.teardown(results, log: log))
    let released = log.all.firstIndex(of: "released")
    let ended = log.all.firstIndex(of: "ended:requested")
    let analyzer = log.all.firstIndex(of: "analyzer-ended")
    #expect(released != nil && ended != nil && analyzer != nil)
    #expect((analyzer ?? 0) < (released ?? 0) && (ended ?? 0) < (released ?? 0))
    #expect(log.all.contains("update[Last words.|]"))
  }

  @Test("a discarded opening stays quiet even when closing its input ends the results")
  func discardOrder() async {
    let results = Results()
    let log = Log()
    let collector = Self.collector(results, log: log)
    results.yield("half a word", final: false)
    await LiveTranscriptCollector.discardOpening(
      silence: collector.silence, finishInput: { results.continuation.finish() },
      cancelResults: { collector.task?.cancel() }, cancelAnalyzer: { log.append("cancelled") })
    await collector.task?.value
    #expect(
      log.all.allSatisfy { !$0.hasPrefix("ended") },
      "no end event for an opening nobody received")
    #expect(log.all.last == "cancelled")
  }

  @Test("a hint fallback discards the first attempt without ending the replacement's words")
  func fallbackIsolation() async throws {
    struct HintsRefused: Error {}
    final class Attempts: @unchecked Sendable {
      var made: [(Results, Log, LiveTranscriptCollector)] = []
    }
    let attempts = Attempts()
    let accepted = try await ApplePreviewSessionSetup.start(
      phrases: ["EnviousWispr"],
      make: { () -> Int in
        let results = Results()
        let log = Log()
        attempts.made.append((results, log, Self.collector(results, log: log)))
        return attempts.made.count - 1
      },
      attach: { index, _ in if index == 0 { throw HintsRefused() } },
      start: { _ in },
      discard: { index in
        let (results, _, collector) = attempts.made[index]
        await LiveTranscriptCollector.discardOpening(
          silence: collector.silence, finishInput: { results.continuation.finish() },
          cancelResults: { collector.task?.cancel() }, cancelAnalyzer: {})
      },
      isCurrent: { true }, contextFailed: { _ in })
    #expect(accepted == 1, "control: the fallback built a second attempt")
    let (firstResults, firstLog, firstCollector) = attempts.made[0]
    let (results, log, collector) = attempts.made[1]
    firstResults.yield("stale", final: true)
    await firstCollector.task?.value
    results.yield("Live words.", final: true)
    await PreviewWait.within("the replacement's update") { await log.reach(1) }
    await collector.end(Self.teardown(results, log: log))
    #expect(firstLog.all.isEmpty, "the discarded attempt reported nothing")
    #expect(log.all == ["update[Live words.|]", "analyzer-ended", "ended:requested", "released"])
  }

  /// A minimal macOS claim table for `LocaleClaims`: holds what was reserved and records releases.
  private actor ClaimTable {
    var reserved: [String] = []
    var released: [String] = []
    func reserve(_ tag: String) -> Bool {
      guard !reserved.contains(tag) else { return false }
      reserved.append(tag)
      return true
    }
    func release(_ tag: String) -> Bool {
      released.append(tag)
      reserved.removeAll { $0 == tag }
      return true
    }
  }

  @Test("ending one of two sessions on a language keeps the claim; ending both gives it back")
  func claimAccounting() async throws {
    let table = ClaimTable()
    let claims = LocaleClaims(
      inventory: LocaleInventory(
        reserved: { await table.reserved.map { Locale(identifier: $0) } },
        reserve: { await table.reserve($0.identifier(.bcp47)) },
        release: { await table.release($0.identifier(.bcp47)) },
        maximumReserved: { 5 }))
    let locale = Locale(identifier: "en-US")
    try await claims.claim(locale, purpose: "session")
    try await claims.claim(locale, purpose: "session")
    #expect(await claims.useCount("en-US") == 2, "control: two sessions registered")

    var sessions: [(Results, Log, LiveTranscriptCollector)] = []
    for _ in 0..<2 {
      let results = Results()
      let log = Log()
      sessions.append((results, log, Self.collector(results, log: log)))
    }
    func teardown(_ index: Int) -> LiveTranscriptCollector.Teardown {
      let (results, log, _) = sessions[index]
      return LiveTranscriptCollector.Teardown(
        endAnalyzer: { results.continuation.finish() },
        release: {
          await claims.finish(locale)
          log.append("released")
        })
    }
    await sessions[0].2.end(teardown(0))
    await sessions[0].2.end(teardown(0))
    #expect(await claims.useCount("en-US") == 1, "a repeated end releases once")
    #expect(await table.released.isEmpty, "the other session still uses the claim")
    await sessions[1].2.end(teardown(1))
    #expect(await claims.useCount("en-US") == 0)
    #expect(await table.released == ["en-US"])
  }

  /// #4105 real boundary (off unless `EW_APPLE_LIVE_WAV` names a 16 kHz mono 16-bit WAV of
  /// English speech): dictation's preview and a meeting's two tracks run at the same time on the
  /// real modules, sharing English through `LocaleClaims.shared`. Takes REAL machine-wide claims,
  /// which is why it is env-gated like the meeting harness. Each session must produce words from
  /// audio that really went through format conversion, and the English claim must be back at zero
  /// once the last one ends. Every opened session is ended on every exit.
  @Test(
    "Dictation and a meeting's two tracks run together on the real modules",
    .enabled(if: ProcessInfo.processInfo.environment["EW_APPLE_LIVE_WAV"] != nil))
  func dictationAndMeetingTogether() async throws {
    guard #available(macOS 26.0, *) else { return }
    let path = try #require(ProcessInfo.processInfo.environment["EW_APPLE_LIVE_WAV"])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let samples: [Float] = data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
      raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
    }
    let speech = Array(samples.prefix(16_000 * 20))
    let english = Locale(identifier: "en-US")
    let vocabulary = LivePreviewVocabulary(
      lookups: nil, contextualPhrases: [], dictionaryEnabled: false)

    /// What each session showed: dictation's whole text (each update replaces it), or a track's
    /// finalized deltas accumulated (`LiveWordsEvent` delivers each finalized delta once) plus its
    /// latest words in progress.
    final class Shown: @unchecked Sendable {
      let lock = NSLock()
      var text: [String: String] = [:]
      var inProgress: [String: String] = [:]
      func set(_ key: String, _ value: String) { lock.withLock { text[key] = value } }
      func update(_ key: String, finalized: String, inProgress latest: String) {
        lock.withLock {
          text[key, default: ""] += finalized
          inProgress[key] = latest
        }
      }
      func words(_ key: String) -> Int {
        lock.withLock {
          ((text[key] ?? "") + " " + (inProgress[key] ?? ""))
            .split(whereSeparator: { !$0.isLetter }).count
        }
      }
    }
    let shown = Shown()

    let dictation = ApplePreviewRecognizer(locale: english)
    let you = ApplePreviewRecognizer(locale: english, kind: .meeting)
    let call = ApplePreviewRecognizer(locale: english, kind: .meeting)
    var sessions: [any LivePreviewEngineSession] = []
    do {
      try await dictation.prepare()
      try await you.prepare()
      try await call.prepare()
      for engine in [dictation, you, call] {
        let formats = try #require(await engine.preparedFormats())
        #expect(formats.source != formats.target, "audio is converted to Apple's format")
      }
      sessions.append(
        try await dictation.openSession(
          vocabulary: vocabulary, onText: { shown.set("dictation", $0) }))
      for (name, engine) in [("you", you), ("call", call)] {
        sessions.append(
          try await engine.openTranscriptSession(
            vocabulary: vocabulary,
            onEvent: { event in
              if case .update(let finalized, let inProgress) = event {
                shown.update(
                  name, finalized: MeetingTimedPiece.text(of: finalized), inProgress: inProgress)
              }
            }))
      }
      #expect(await LocaleClaims.shared.useCount("en-US") == 3)

      // Real time, 100 ms chunks, the cadence the pumps feed at.
      var index = 0
      let clock = ContinuousClock()
      let start = clock.now
      while index < speech.count {
        let chunk = Array(speech[index..<min(index + 1_600, speech.count)])
        for session in sessions { await session.feed(chunk) }
        index += 1_600
        // settle: wall-clock pacing of a real-time feed, not a wait for state.
        try await clock.sleep(until: start + .milliseconds(index / 16))
      }
    } catch {
      for session in sessions { await session.end() }
      throw error
    }
    for session in sessions { await session.end() }

    #expect(shown.words("dictation") >= 5, "dictation's preview showed words")
    #expect(shown.words("you") >= 5, "the meeting's first track showed words")
    #expect(shown.words("call") >= 5, "the meeting's second track showed words")
    #expect(
      await LocaleClaims.shared.useCount("en-US") == 0, "English went back after the last end")
  }

  /// #4105: the Apple preview's assembly now runs through the factory's `consume` closure. Its
  /// text must stay bounded on long speech, and a pause must not wipe what was said.
  @Test(
    "The Apple preview text stays bounded and survives a pause",
    .enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
  func appleCollectorBoundsAndKeepsSegments() async {
    guard #available(macOS 26.0, *) else { return }
    let long = String(repeating: "word ", count: 1_000)  // 5,000 characters, over the bound
    let module = AppleTranscriberFactory.Module(
      speechModule: AppleTranscriberFactory.makeModule(.dictation, locale: Locale(identifier: "en-US"))
        .speechModule,
      consume: { deliver in
        deliver(.untimed("hello there.", isFinal: true))
        deliver(.untimed("new segment", isFinal: false))  // after a pause: only the new segment
        deliver(.untimed(long, isFinal: true))
      })
    final class Seen: @unchecked Sendable {
      let lock = NSLock()
      var texts: [String] = []
      func add(_ text: String) { lock.withLock { texts.append(text) } }
    }
    let seen = Seen()
    await ApplePreviewRecognizer.collect(from: module, lookups: nil, onText: { seen.add($0) }).value
    let texts = seen.lock.withLock { seen.texts }
    #expect(texts.count == 3)
    #expect(texts[1] == "hello there.new segment", "the pause kept the finished segment")
    #expect(texts.allSatisfy { $0.count <= LivePreviewTextBound.maxCharacters })
    #expect(texts[2].hasSuffix("word "))
  }

  // MARK: - Timed finals (#4355 chunk 6b)

  /// Every finalized piece list the collector emitted, in order.
  final class Finals: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [[MeetingTimedPiece]] = []
    private var provisional: [String] = []
    var all: [[MeetingTimedPiece]] { lock.withLock { list } }
    var inProgress: [String] { lock.withLock { provisional } }
    func event(_ event: LiveWordsEvent) {
      guard case .update(let finalized, let inProgress) = event else { return }
      lock.withLock {
        if !finalized.isEmpty { list.append(finalized) }
        if !inProgress.isEmpty { provisional.append(inProgress) }
      }
    }
  }

  static let recording = UUID()

  @available(macOS 26.0, *)
  private static func recorder(written starts: [Int], capacity: Int = 16) async
    -> AppleMeetingInputRecorder
  {
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: capacity)
    for start in starts {
      let buffer = AVAudioPCMBuffer(
        pcmFormat: AVAudioFormat(
          commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!,
        frameCapacity: 1_600)!
      buffer.frameLength = 1_600
      recorder.push(
        buffer, frames: 1_600, sourceFrames: 1_600,
        slices: [
          MeetingLiveAudioSlice(
            offset: 0,
            span: MeetingAudioSpan(
              recording: recording, track: .callSound, run: 0, startSample: start,
              sampleCount: 1_600)!)
        ])
    }
    recorder.finish()
    var iterator = recorder.sequence.makeAsyncIterator()
    while await iterator.next() != nil {}
    return recorder
  }

  @available(macOS 26.0, *)
  private static func timing(_ recorder: AppleMeetingInputRecorder) -> LiveTranscriptCollector.Timing {
    .init(
      project: { recorder.project(startSeconds: $0, endSeconds: $1) },
      prune: { recorder.prune(beforeSeconds: $0) })
  }

  private static func span(_ start: Int, _ count: Int) -> MeetingAudioSpan? {
    MeetingAudioSpan(
      recording: recording, track: .callSound, run: 0, startSample: start, sampleCount: count)
  }

  private static func run(_ text: String, _ start: Double?, _ end: Double?)
    -> LiveTranscriptResult.Run
  {
    .init(text: text, startSeconds: start, endSeconds: end)
  }

  /// Runs `results` through a collector with `timing` and returns what it emitted.
  private static func collect(
    _ results: [LiveTranscriptResult], timing: LiveTranscriptCollector.Timing?
  ) async -> Finals {
    let finals = Finals()
    let collector = LiveTranscriptCollector(
      lookups: nil, timing: timing, onEvent: finals.event,
      consume: { deliver in for result in results { deliver(result) } })
    await collector.task?.value
    return finals
  }

  @Test("a final's runs become pieces projected through the session's consumed input, every character kept")
  func timedFinalPieces() async {
    guard #available(macOS 26.0, *) else { return }
    // Written 32,000..<33,600 then 33,600..<35,200 were consumed as input 0 s..<0.2 s.
    let recorder = await Self.recorder(written: [32_000, 33_600])
    let result = LiveTranscriptResult(
      text: "Hello there, friend.", isFinal: true,
      runs: [
        Self.run("Hello", 0, 0.05), Self.run(" there,", 0.05, 0.15),
        Self.run(" friend.", nil, nil),
      ], startSeconds: 0)
    let finals = await Self.collect([result], timing: Self.timing(recorder))
    let pieces = finals.all.first ?? []
    #expect(MeetingTimedPiece.text(of: pieces) == "Hello there, friend.", "byte for byte")
    #expect(pieces.map(\.span) == [Self.span(32_000, 800), Self.span(32_800, 1_600), nil])
  }

  @Test("runs that do not reproduce the text, and a session without timing, give one untimed piece")
  func untimedFallbacks() async {
    guard #available(macOS 26.0, *) else { return }
    let recorder = await Self.recorder(written: [0])
    let mismatched = LiveTranscriptResult(
      text: "Hello there.", isFinal: true, runs: [Self.run("Hello", 0, 0.05)], startSeconds: 0)
    let finals = await Self.collect([mismatched], timing: Self.timing(recorder))
    #expect(finals.all == [MeetingTimedPiece.untimed("Hello there.")])
    let timed = LiveTranscriptResult(
      text: "Hi.", isFinal: true, runs: [Self.run("Hi.", 0, 0.05)], startSeconds: 0)
    let noTiming = await Self.collect([timed], timing: nil)
    #expect(noTiming.all == [MeetingTimedPiece.untimed("Hi.")])
  }

  @Test("volatile results stay provisional words and never gain finalized ownership")
  func volatileStaysProvisional() async {
    guard #available(macOS 26.0, *) else { return }
    let recorder = await Self.recorder(written: [0])
    let volatile = LiveTranscriptResult(
      text: "Hel", isFinal: false, runs: [Self.run("Hel", 0, 0.03)], startSeconds: 0)
    let finals = await Self.collect([volatile], timing: Self.timing(recorder))
    #expect(finals.all.isEmpty)
    #expect(finals.inProgress == ["Hel"])
  }

  @Test("after a final, input before its start is pruned: a later final reaching back abstains, later ones stay exact")
  func pruneAfterFinal() async {
    guard #available(macOS 26.0, *) else { return }
    let recorder = await Self.recorder(written: [0, 1_600, 3_200])
    let second = LiveTranscriptResult(
      text: " two", isFinal: true, runs: [Self.run(" two", 0.1, 0.2)], startSeconds: 0.1)
    let late = LiveTranscriptResult(
      text: " back", isFinal: true, runs: [Self.run(" back", 0.0, 0.05)], startSeconds: 0)
    let third = LiveTranscriptResult(
      text: " three", isFinal: true, runs: [Self.run(" three", 0.2, 0.3)], startSeconds: 0.2)
    let finals = await Self.collect([second, late, third], timing: Self.timing(recorder))
    #expect(finals.all.map { $0.map(\.span) } == [[Self.span(1_600, 1_600)], [nil], [Self.span(3_200, 1_600)]])
  }

  @Test("input dropped while the analyzer was behind never shifts the runs that follow")
  func droppedInputNeverShifts() async {
    guard #available(macOS 26.0, *) else { return }
    // Capacity 2: of five inputs fed before any is taken, only the last two are heard.
    let recorder = await Self.recorder(written: [0, 1_600, 3_200, 4_800, 6_400], capacity: 2)
    let result = LiveTranscriptResult(
      text: "Late words", isFinal: true,
      runs: [Self.run("Late", 0, 0.1), Self.run(" words", 0.1, 0.2)], startSeconds: 0)
    let finals = await Self.collect([result], timing: Self.timing(recorder))
    #expect(finals.all.first?.map(\.span) == [Self.span(4_800, 1_600), Self.span(6_400, 1_600)])
  }

  @Test("a late final of an ended session reads its own session's map, never the replacement's")
  func lateFinalReadsOwnMap() async {
    guard #available(macOS 26.0, *) else { return }
    let old = await Self.recorder(written: [0])
    let replacement = await Self.recorder(written: [16_000])
    let late = LiveTranscriptResult(
      text: "Old words", isFinal: true, runs: [Self.run("Old words", 0, 0.1)], startSeconds: 0)
    let oldFinals = await Self.collect([late], timing: Self.timing(old))
    let newFinals = await Self.collect([late], timing: Self.timing(replacement))
    #expect(oldFinals.all.first?.first?.span == Self.span(0, 1_600))
    #expect(newFinals.all.first?.first?.span == Self.span(16_000, 1_600))
  }
}
