import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprLivePreview
@testable import EnviousWisprTranscribeCpp
@testable import EnviousWisprWhisperPreviewAdapter

/// #3735 Chunk 9: the Universal preview engine over transcribe.cpp, through the recognizer the
/// coordinator drives (live-preview.md RULE: universal-preview-engine-safety invariants 2 and 3).
///
/// **What the user sees when this fails:** after a quick stop and restart, the pill shows the
/// previous recording's words or the Mac runs two preview decodes at once; or the preview
/// model stays in memory after the user turned the preview off, changed engine or removed it.
@Suite(
  "Universal preview recognizer on transcribe.cpp (#3735)", .serialized, .tags(.productOutcome))
struct TranscribeCppPreviewRecognizerTests {

  /// A native boundary under test control: decodes hold until released (cancellation does not
  /// end them, as an aborted native run still returns on its own schedule), and every load,
  /// unload, overlap and lane is recorded.
  final class FakeDriver: WhisperExecutorDriving, @unchecked Sendable {
    typealias Handle = Int
    /// Recursive: `until` evaluates its condition under this lock, and conditions read the
    /// public counters, which take it again.
    private let lock = NSRecursiveLock()
    private var nextHandle = 0
    private var running = 0
    private(set) var overlapped = false
    private var _loads = 0
    private var _unloads: [Int] = []
    private var _lanes: [TranscribeCppExecutor.Lane] = []
    private var _entered = 0
    private var _exited = 0
    private var _cancelled = 0
    private var _languages: [String?] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(() -> Bool, CheckedContinuation<Void, Never>)] = []
    private var open = false
    // #3973: loads and unloads held inside the "native" call while their hold is on.
    private var holdingLoads = false
    private var holdingUnloads = false
    private var loadGates: [CheckedContinuation<Void, Never>] = []
    private var unloadGates: [CheckedContinuation<Void, Never>] = []
    private var _loadsEntered = 0
    private var _unloadsEntered = 0
    private var _exitedAtUnload: [Int] = []
    var failLoads = false
    let text: String

    init(text: String = "Hello there.") { self.text = text }

    var loads: Int { lock.withLock { _loads } }
    var unloads: [Int] { lock.withLock { _unloads } }
    var lanes: [TranscribeCppExecutor.Lane] { lock.withLock { _lanes } }
    var entered: Int { lock.withLock { _entered } }
    var exited: Int { lock.withLock { _exited } }
    /// Held decodes whose caller was cancelled (the abort reached the boundary).
    var cancelled: Int { lock.withLock { _cancelled } }
    /// The language each decode was asked for, in order.
    var languages: [String?] { lock.withLock { _languages } }
    /// Loads and unloads that reached the "native" call, held or not.
    var loadsEntered: Int { lock.withLock { _loadsEntered } }
    var unloadsEntered: Int { lock.withLock { _unloadsEntered } }
    /// How many decodes had returned when each unload began: an ordering record.
    var exitedAtUnload: [Int] { lock.withLock { _exitedAtUnload } }

    /// Holds later loads and unloads inside the call until `releaseLoads`/`releaseUnloads`.
    func hold(loads: Bool = false, unloads: Bool = false) {
      lock.withLock {
        holdingLoads = loads
        holdingUnloads = unloads
      }
    }

    func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int {
      let failing = lock.withLock { () -> Bool in
        _lanes.append(lane)
        return failLoads
      }
      if failing { throw TranscribeCppExecutor.ExecutorError.modelUnavailable }
      await park(unload: false)
      return lock.withLock {
        _loads += 1
        nextHandle += 1
        return nextHandle
      }
    }

    /// Arrival and releasability publish in one lock step, as for decodes (#3808).
    private func park(unload: Bool) async {
      await withCheckedContinuation { c in
        let pass = lock.withLock { () -> Bool in
          if unload { _unloadsEntered += 1 } else { _loadsEntered += 1 }
          guard unload ? holdingUnloads : holdingLoads else { return true }
          if unload { unloadGates.append(c) } else { loadGates.append(c) }
          return false
        }
        if pass { c.resume() }
        notify()
      }
    }

    func releaseLoads() { resume(\.loadGates, stopping: \.holdingLoads) }
    func releaseUnloads() { resume(\.unloadGates, stopping: \.holdingUnloads) }

    private func resume(
      _ gates: ReferenceWritableKeyPath<FakeDriver, [CheckedContinuation<Void, Never>]>,
      stopping hold: ReferenceWritableKeyPath<FakeDriver, Bool>
    ) {
      let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        self[keyPath: hold] = false
        defer { self[keyPath: gates] = [] }
        return self[keyPath: gates]
      }
      for gate in parked { gate.resume() }
    }

    func detectLanguage(_ handle: Int, samples: [Float], lane: TranscribeCppExecutor.Lane)
      async throws -> TranscribeCppLanguageObservation
    {
      Issue.record("the preview never runs language detection")
      throw TranscribeCppExecutor.ExecutorError.modelUnavailable
    }

    func transcribe(
      _ handle: Int, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
      onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> TranscribeCppRunResult {
      // Held until released, cancelled or not: the "native" run ends on its own schedule.
      await withTaskCancellationHandler {
        await withCheckedContinuation { c in
          // Arrival and releasability publish in ONE lock step: a decode counts as entered only
          // once its gate is parked, so a release that follows an observed entry always finds
          // it (#3808: counting first let a release hit an empty gate and hang `end()`).
          let passThrough = lock.withLock { () -> Bool in
            _lanes.append(lane)
            _languages.append(language)
            if running > 0 { overlapped = true }
            running += 1
            _entered += 1
            guard !open else { return true }
            gates.append(c)
            return false
          }
          if passThrough { c.resume() }
          notify()
        }
      } onCancel: {
        lock.withLock { _cancelled += 1 }
        notify()
      }
      let cancelled = Task.isCancelled
      lock.withLock {
        running -= 1
        _exited += 1
      }
      notify()
      if cancelled { throw TranscribeCppExecutor.ExecutorError.cancelled }
      return TranscribeCppRunResult(
        text: text, detectedLanguage: nil,
        segments: [TranscribeCppSegment(startMs: 0, endMs: 1_100, text: text)])
    }

    func waitForDrain(_ handle: Int) async {
      await until { self.running == 0 }
    }

    func unload(_ handle: Int) async {
      lock.withLock { _exitedAtUnload.append(_exited) }
      await park(unload: true)
      lock.withLock { _unloads.append(handle) }
      notify()
    }

    /// The preview runtime never settles a lane (only the heart backend's teardown does), and
    /// this fake's loads and unloads complete within the call.
    func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int { 0 }

    /// Ends the oldest held decode.
    func releaseOne() {
      let first = lock.withLock { gates.isEmpty ? nil : gates.removeFirst() }
      first?.resume()
    }

    /// Ends every held decode.
    func releaseAll() {
      let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        defer { gates = [] }
        return gates
      }
      for gate in all { gate.resume() }
    }

    /// Hang-guard expiry: ends every held decode and lets every later one through, so whatever
    /// the expired step left running finishes and the test fails instead of stalling.
    @Sendable func openAll() {
      lock.withLock { open = true }
      releaseAll()
      releaseLoads()
      releaseUnloads()
    }

    func until(_ condition: @escaping () -> Bool) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if condition() { return true }
          waiters.append((condition, c))
          return false
        }
        if now { c.resume() }
      }
    }

    private func notify() {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        let met = waiters.filter { $0.0() }.map(\.1)
        waiters.removeAll { $0.0() }
        return met
      }
      for waiter in ready { waiter.resume() }
    }
  }

  /// Texts delivered to the pill, per session.
  final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var all: [String] { lock.withLock { texts } }
    func append(_ text: String) { lock.withLock { texts.append(text) } }
  }

  /// 1.0 s of tone then 0.2 s of silence (19_200 samples). #3801: preview results pass the
  /// silent-tail filter, which needs room quieter than the speech; an unbroken tone would
  /// classify its own fake segment as unvoiced.
  private static let speech: [Float] = (0..<19_200).map {
    $0 < 16_000 ? Float(sin(Double($0) * 0.05)) * 0.2 : 0
  }

  private static func recognizer(
    _ driver: FakeDriver, admitted: @escaping @Sendable () async -> Bool = { true },
    residency: TranscribeCppPreviewResidency
  ) -> WhisperPreviewRecognizer {
    WhisperPreviewRecognizer(
      runtime: TranscribeCppPreviewRuntime(
        driver: driver, modelPath: "/models/whisper-small-Q8_0.gguf", isAdmitted: admitted,
        cadence: .milliseconds(1), residency: residency),
      language: nil)
  }

  /// Every await in this suite goes through `within` or `step`: a hang fails in seconds and
  /// names the step instead of stalling the CI lane until its job limit (#3808). Expiry opens
  /// the driver, so work the expired step left holding a decode finishes too.
  private static func within(
    _ what: String, _ driver: FakeDriver, sourceLocation: SourceLocation = #_sourceLocation,
    _ ready: @escaping @Sendable () async -> Void
  ) async {
    await PreviewWait.within(
      what, sourceLocation: sourceLocation, onExpiry: driver.openAll, ready)
  }

  private static func step<T: Sendable>(
    _ what: String, _ driver: FakeDriver, sourceLocation: SourceLocation = #_sourceLocation,
    _ work: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await PreviewWait.value(
      what, sourceLocation: sourceLocation, onExpiry: driver.openAll, work)
  }

  @Test(
    "a quick stop and restart waits for the old decode's native return and never overlaps two decodes"
  )
  func rapidStopStartNeverOverlaps() async throws {
    let driver = FakeDriver()
    let recognizer = Self.recognizer(driver, residency: .init())
    let first = Delivered()
    let a = try await Self.step("the first open", driver) {
      try await recognizer.openSession(vocabulary: .init(lookups: nil, contextualPhrases: [], dictionaryEnabled: true), onText: first.append)
    }
    try await Self.step("the first feed", driver) { await a.feed(Self.speech) }
    await Self.within("the first session's decode", driver) {
      await driver.until { driver.entered == 1 }
    }

    // The coordinator cancels its task without awaiting `end()`; the next recording opens at
    // once. The new open must wait until the old decode physically returned.
    let stopping = Task { await a.end() }
    let second = Delivered()
    let opening = Task { () throws -> (any LivePreviewEngineSession, Int) in
      let session = try await recognizer.openSession(vocabulary: .init(lookups: nil, contextualPhrases: [], dictionaryEnabled: true), onText: second.append)
      return (session, driver.exited)
    }
    await Self.within("the old decode's cancellation reaching the boundary", driver) {
      await driver.until { driver.cancelled == 1 }
    }
    #expect(driver.exited == 0, "control: the old native run is still inside")
    driver.releaseAll()
    let (b, exitedWhenOpened) = try await Self.step("the second open", driver) {
      try await opening.value
    }
    try await Self.step("the first session's end", driver) { await stopping.value }
    #expect(exitedWhenOpened == 1, "the new session opened only after the old run returned")

    try await Self.step("the second feed", driver) { await b.feed(Self.speech) }
    await Self.within("the second session's decode", driver) {
      await driver.until { driver.entered == 2 }
    }
    driver.releaseAll()
    try await Self.step("the second session's end", driver) { await b.end() }
    #expect(driver.overlapped == false)
    #expect(first.all.isEmpty, "the stopped session's late decode reached nobody")
    #expect(driver.lanes.allSatisfy { $0 == .preview }, "load and decodes stay on the preview lane")
  }

  @Test("Apple-only dictionary controls preserve Universal's original correction lookups")
  func appleApplicationFlagDoesNotGateUniversal() async throws {
    let driver = FakeDriver(text: "Hello aliasword.")
    let recognizer = Self.recognizer(driver, residency: .init())
    let (texts, delivered) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { delivered.finish(); driver.openAll() }
    let lookups = WordCorrector.buildLookups(words: [
      CustomWord(canonical: "PreviewWord", aliases: ["aliasword"])
    ])
    let session = try await Self.step("the dictionary-off Universal open", driver) {
      try await recognizer.openSession(
        vocabulary: .init(lookups: lookups, contextualPhrases: ["UnusedHint"], dictionaryEnabled: false),
        onText: { text in delivered.yield(text); delivered.finish() })
    }
    do {
      try await Self.step("the compatibility feed", driver) { await session.feed(Self.speech) }
      await Self.within("the compatibility decode", driver) {
        await driver.until { driver.entered == 1 }
      }
      driver.releaseAll()
      let text = try await Self.step("the corrected Universal preview", driver) {
        for await text in texts { return text }
        throw CancellationError()
      }
      #expect(text == "Hello PreviewWord.")
    } catch {
      driver.openAll()
      try? await Self.step("the compatibility failure cleanup", driver) { await session.end() }
      throw error
    }
    try await Self.step("the compatibility end", driver) { await session.end() }
  }

  @Test("a refused open releases the turnover, and the next open works once the model is admitted")
  func refusedOpenDoesNotWedge() async throws {
    let driver = FakeDriver()
    let admitted = AdmissionSwitch()
    let recognizer = Self.recognizer(driver, admitted: { admitted.value }, residency: .init())
    await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.notAdmitted) {
      _ = try await Self.step("the refused open", driver) {
        try await recognizer.openSession(vocabulary: .init(lookups: nil, contextualPhrases: [], dictionaryEnabled: true), onText: { _ in })
      }
    }
    #expect(driver.loads == 0, "an unadmitted model is never loaded")
    admitted.value = true
    let session = try await Self.step("the admitted open", driver) {
      try await recognizer.openSession(vocabulary: .init(lookups: nil, contextualPhrases: [], dictionaryEnabled: true), onText: { _ in })
    }
    try await Self.step("the admitted session's end", driver) { await session.end() }
    #expect(driver.loads == 1)
  }

  @Test(
    "releasing a prepared engine after a recording frees its model once; a failed load frees nothing"
  )
  func releasedEngineFreesItsModelOnce() async throws {
    let driver = FakeDriver()
    let residency = TranscribeCppPreviewResidency()
    var recognizer: WhisperPreviewRecognizer? = Self.recognizer(driver, residency: residency)
    // A finished recording stays reachable (the caller's handle, and the engine's turnover
    // record); it must not keep the model once the engine itself goes.
    let session: any LivePreviewEngineSession
    do {
      let engine = try #require(recognizer)
      try await Self.step("the first preparation", driver) { try await engine.prepare() }
      try await Self.step("the repeated preparation", driver) { try await engine.prepare() }
      #expect(driver.loads == 1)
      #expect(residency.loadedCount == 1)
      session = try await Self.step("the recording's open", driver) {
        try await engine.openSession(vocabulary: .init(lookups: nil, contextualPhrases: [], dictionaryEnabled: true), onText: { _ in })
      }
    }
    try await Self.step("the recording's feed", driver) { await session.feed(Self.speech) }
    await Self.within("the recording's decode", driver) {
      await driver.until { driver.entered == 1 }
    }
    driver.releaseAll()
    try await Self.step("the recording's end", driver) { await session.end() }
    // A stale preparation, a disabled preview, an engine change and Remove all end the same
    // way: the coordinator drops its last reference.
    recognizer = nil
    await Self.within("the released model's free", driver) { await residency.waitUntilNoneLoaded() }
    #expect(driver.unloads == [1], "freed exactly once")
    withExtendedLifetime(session) {}

    let failing = FakeDriver()
    failing.failLoads = true
    let failedResidency = TranscribeCppPreviewResidency()
    var broken: WhisperPreviewRecognizer? = Self.recognizer(failing, residency: failedResidency)
    do {
      let engine = try #require(broken)
      await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.self) {
        try await Self.step("the failing preparation", failing) { try await engine.prepare() }
      }
    }
    broken = nil
    #expect(failing.unloads.isEmpty)
    #expect(failedResidency.loadedCount == 0)
  }

  @Test("a step that never finishes fails fast and names itself (deadline control)")
  func stepDeadlineControl() async {
    let driver = FakeDriver()
    var expired: PreviewWait.Expired?
    await withKnownIssue("the step never finishes, so its expiry must record an issue") {
      do {
        try await PreviewWait.value(
          "a step that never finishes", seconds: 0.2, onExpiry: driver.openAll
        ) {
          try? await Task.sleep(for: .seconds(600))  // deadline-fallback: a step that never finishes
        }
      } catch let error as PreviewWait.Expired {
        expired = error
      }
    }
    #expect(expired?.what == "a step that never finishes")
  }

  /// #2117: before, the session kept every sample and stopped decoding at 10 minutes, so a
  /// long meeting's live words froze. Through the shipped wiring (recognizer, runtime, rolling
  /// core, owner), decoding must continue past the retained ceiling, which only holds if the
  /// core's releases reach the owner: without them the owner hits the ceiling and stops.
  @Test("decoding keeps going past the retained ceiling because the owner drops released audio")
  func decodingContinuesPastTheRetainedCeiling() async throws {
    let driver = FakeDriver()
    driver.openAll()  // every decode passes straight through
    let recognizer = Self.recognizer(driver, residency: .init())
    let session = try await Self.step("the open", driver) {
      try await recognizer.openSession(
        vocabulary: .init(lookups: nil, contextualPhrases: [], dictionaryEnabled: true),
        onText: { _ in })
    }
    let owner = try #require(session as? TranscribeCppPreviewSession)
    // 1.2 s per feed: 125 feeds is 150 s, past the 120 s ceiling.
    let feeds = TranscribeCppPreviewSession.maxRetainedSamples / Self.speech.count + 25
    var maxRetained = 0
    for n in 1...feeds {
      try await Self.step("feed \(n)", driver) { await session.feed(Self.speech) }
      // One decode per feed: each adds more than the loop's one second of new audio.
      await Self.within("decode \(n)", driver) { await driver.until { driver.entered >= n } }
      maxRetained = max(maxRetained, owner.retainedSampleCountForTests)
    }
    #expect(feeds * Self.speech.count > TranscribeCppPreviewSession.maxRetainedSamples)
    #expect(driver.entered >= feeds, "decoding never stopped")
    #expect(maxRetained < 40 * 16_000, "the owner kept a rolling window, not the recording")
    try await Self.step("the end", driver) { await session.end() }
  }

  // MARK: - #3973: transcript forwarding and per-session decode admission

  /// A growing recording the session pulls, as its owner's provider would return it.
  final class Recording: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func set(seconds: Double) {
      let count = Int(seconds * 16_000)
      lock.withLock {
        samples = (0..<count).map { i in
          // Tone then silence per 1.2 s, so the silent-tail filter sees speech followed by quiet.
          i % 19_200 < 16_000 ? Float(sin(Double(i) * 0.05)) * 0.2 : 0
        }
      }
    }
    var provider: @Sendable () async -> (samples: [Float], count: Int) {
      { [self] in lock.withLock { (samples, samples.count) } }
    }
  }

  /// Transcript events and displayed texts, with waits on their counts.
  final class Outputs: @unchecked Sendable {
    /// Recursive, as in `FakeDriver`: waiter conditions run under this lock and read the public
    /// accessors, which take it again.
    private let lock = NSRecursiveLock()
    private var events: [TranscriptEvent] = []
    private var texts: [String] = []
    private var releases: [Int] = []
    private var waiters: [(() -> Bool, CheckedContinuation<Void, Never>)] = []
    var allEvents: [TranscriptEvent] { lock.withLock { events } }
    var allTexts: [String] { lock.withLock { texts } }
    var allReleases: [Int] { lock.withLock { releases } }
    func event(_ e: TranscriptEvent) { change { events.append(e) } }
    func text(_ t: String) { change { texts.append(t) } }
    func released(_ mark: Int) { change { releases.append(mark) } }
    private func change(_ body: () -> Void) {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        body()
        let met = waiters.filter { $0.0() }.map(\.1)
        waiters.removeAll { $0.0() }
        return met
      }
      for waiter in ready { waiter.resume() }
    }
    func until(_ condition: @escaping () -> Bool) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if condition() { return true }
          waiters.append((condition, c))
          return false
        }
        if now { c.resume() }
      }
    }
    var finalized: String {
      allEvents.reduce(into: "") { text, event in
        if case .update(let finalized, _) = event { text += finalized }
      }
    }
  }

  /// Counts admission calls and refuses while `refusing`; with `gated`, each call waits for
  /// `open()` and signals its arrival first.
  final class Admission: @unchecked Sendable {
    struct Refused: Error {}
    private let lock = NSLock()
    private var refusing: Bool
    private var gated: Bool
    private var calls = 0
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(refusing: Bool = false, gated: Bool = false) {
      self.refusing = refusing
      self.gated = gated
    }
    var count: Int { lock.withLock { calls } }
    func allow() { lock.withLock { refusing = false } }
    @Sendable func open() {
      let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        opened = true
        defer { gate = [] }
        return gate
      }
      for c in parked { c.resume() }
    }
    func reach(_ n: Int) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if calls >= n { return true }
          waiters.append((n, c))
          return false
        }
        if now { c.resume() }
      }
    }
    var admit: @Sendable () async throws -> Void {
      { [self] in
        let (ready, wait) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
          calls += 1
          let ready = waiters.filter { $0.0 <= calls }.map(\.1)
          waiters.removeAll { $0.0 <= calls }
          return (ready, gated && !opened)
        }
        for c in ready { c.resume() }
        if wait {
          await withCheckedContinuation { c in
            let now = lock.withLock { () -> Bool in
              if opened { return true }
              gate.append(c)
              return false
            }
            if now { c.resume() }
          }
        }
        if lock.withLock({ refusing }) { throw Refused() }
      }
    }
  }

  private static func runtime(
    _ driver: FakeDriver, residency: TranscribeCppPreviewResidency = .init(),
    joins: Joins? = nil, isAdmitted: @escaping @Sendable () async -> Bool = { true }
  ) -> TranscribeCppPreviewRuntime {
    TranscribeCppPreviewRuntime(
      driver: driver, modelPath: "/models/whisper-small-Q8_0.gguf", isAdmitted: isAdmitted,
      cadence: .milliseconds(1), residency: residency, observe: { joins?.record($0) })
  }

  private static func transcriptSession(
    _ runtime: TranscribeCppPreviewRuntime, _ outputs: Outputs, language: String? = "en",
    transcript: Bool = true, admission: Admission? = nil
  ) async throws -> any WhisperIncrementalSession {
    if let admission {
      return try await runtime.makeSession(
        language: language, hypothesisRetentionLimit: 2_000, onHypothesis: outputs.text,
        onAudioReleased: outputs.released, onTranscript: transcript ? outputs.event : nil,
        admitDecode: admission.admit)
    }
    if transcript {
      return try await runtime.makeSession(
        language: language, hypothesisRetentionLimit: 2_000, onHypothesis: outputs.text,
        onAudioReleased: outputs.released, onTranscript: outputs.event)
    }
    return try await runtime.makeSession(
      language: language, hypothesisRetentionLimit: 2_000, onHypothesis: outputs.text,
      onAudioReleased: outputs.released)
  }

  @Test("transcript events travel through a runtime-made session, with a finalized delta")
  func transcriptThroughRuntime() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let outputs = Outputs()
    let recording = Recording()
    recording.set(seconds: 1.2)
    let session = try await Self.transcriptSession(Self.runtime(driver), outputs)
    try await Self.step("the start", driver) { await session.start(audioSamplesProvider: recording.provider) }
    await Self.within("the first decode", driver) { await driver.until { driver.entered >= 1 } }
    recording.set(seconds: 2.4)
    await Self.within("a finalized delta", driver) {
      await outputs.until { outputs.finalized.contains("Hello there.") }
    }
    try await Self.step("the cancel", driver) { await session.cancel() }
    #expect(outputs.allEvents.first == .update(finalized: "", inProgress: "Hello there."))
    #expect(outputs.finalized == "Hello there.", "finalized exactly once")
  }

  @Test("a session made without the new inputs shows exactly what it showed before")
  func defaultsPreserveTheDisplay() async throws {
    var shown: [[String]] = []
    for transcript in [false, true] {
      let driver = FakeDriver()
      driver.openAll()
      let outputs = Outputs()
      let recording = Recording()
      recording.set(seconds: 1.2)
      let session = try await Self.transcriptSession(
        Self.runtime(driver), outputs, transcript: transcript)
      try await Self.step("the start", driver) { await session.start(audioSamplesProvider: recording.provider) }
      await Self.within("the first decode", driver) { await driver.until { driver.entered >= 1 } }
      recording.set(seconds: 2.4)
      await Self.within("the second decode", driver) { await driver.until { driver.exited >= 2 } }
      try await Self.step("the cancel", driver) { await session.cancel() }
      shown.append(outputs.allTexts)
      #expect(transcript || outputs.allEvents.isEmpty, "no transcript owner, no events")
    }
    #expect(shown[0] == ["Hello there."], "control: the display text arrived")
    #expect(shown[0] == shown[1])
  }

  @Test("a refused decode never reaches native code, and the same session decodes once admitted")
  func refusedThenAdmitted() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let outputs = Outputs()
    let recording = Recording()
    recording.set(seconds: 1.2)
    let admission = Admission(refusing: true)
    let session = try await Self.transcriptSession(
      Self.runtime(driver), outputs, admission: admission)
    try await Self.step("the start", driver) { await session.start(audioSamplesProvider: recording.provider) }
    await Self.within("three refusals", driver) { await admission.reach(3) }
    #expect(driver.entered == 0, "refused decodes never enter native code")
    admission.allow()
    await Self.within("the retried decode", driver) {
      await outputs.until { !outputs.allEvents.isEmpty }
    }
    try await Self.step("the cancel", driver) { await session.cancel() }
    #expect(outputs.allEvents.first == .update(finalized: "", inProgress: "Hello there."))
    #expect(driver.loads == 1, "the same session and model, never reloaded")
  }

  @Test("two sessions on one runtime keep their own admission decisions")
  func admissionIsPerSession() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let runtime = Self.runtime(driver)
    let refusedOutputs = Outputs()
    let admittedOutputs = Outputs()
    let refused = Admission(refusing: true)
    let admitted = Admission()
    let recording = Recording()
    recording.set(seconds: 1.2)
    let a = try await Self.transcriptSession(runtime, refusedOutputs, admission: refused)
    let b = try await Self.transcriptSession(runtime, admittedOutputs, admission: admitted)
    try await Self.step("the start", driver) { await a.start(audioSamplesProvider: recording.provider) }
    try await Self.step("the start", driver) { await b.start(audioSamplesProvider: recording.provider) }
    await Self.within("the admitted session's text", driver) {
      await admittedOutputs.until { !admittedOutputs.allEvents.isEmpty }
    }
    await Self.within("refusals on the other session", driver) { await refused.reach(3) }
    try await Self.step("the cancel", driver) { await a.cancel() }
    try await Self.step("the cancel", driver) { await b.cancel() }
    #expect(refusedOutputs.allEvents.isEmpty && refusedOutputs.allTexts.isEmpty)
    #expect(driver.loads == 1, "one model for both")
  }

  @Test("a session cancelled while its admission waits never starts the decode")
  func cancelDuringAdmission() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let outputs = Outputs()
    let recording = Recording()
    recording.set(seconds: 1.2)
    let admission = Admission(gated: true)
    let session = try await Self.transcriptSession(
      Self.runtime(driver), outputs, admission: admission)
    try await Self.step("the start", driver) { await session.start(audioSamplesProvider: recording.provider) }
    let rolling = try #require(session as? TranscribeCppRollingSession)
    await Self.within("the waiting admission", driver) { await admission.reach(1) }
    let cancelling = Task { await session.cancel() }
    // The cancel has cancelled the loop and is waiting to join it; the parked admission is what
    // it waits on. Opening it lets the loop resume into a cancelled task.
    await Self.within("the cancel reaching its drain", driver, { await rolling.drainJoins(reach: 1) })
    admission.open()
    await Self.within("the cancel", driver) { await cancelling.value }
    #expect(driver.entered == 0, "no native decode after a cancel that landed during admission")
  }

  @Test("the new path keeps the preview lane, the language and the audio-release notices")
  func preservesLaneLanguageAndRelease() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let outputs = Outputs()
    let recording = Recording()
    recording.set(seconds: 17)
    let session = try await Self.transcriptSession(
      Self.runtime(driver), outputs, language: "de", admission: Admission())
    try await Self.step("the start", driver) { await session.start(audioSamplesProvider: recording.provider) }
    await Self.within("the first decode", driver) { await driver.until { driver.exited >= 1 } }
    recording.set(seconds: 18.2)
    // The second decode agrees, commits, and the window trims past 15 s: one release notice.
    await Self.within("the release notice", driver) {
      await outputs.until { !outputs.allReleases.isEmpty }
    }
    try await Self.step("the cancel", driver) { await session.cancel() }
    #expect(driver.lanes.allSatisfy { $0 == .preview })
    #expect(!driver.languages.isEmpty && driver.languages.allSatisfy { $0 == "de" })
    #expect(outputs.allReleases.first == 17_600, "released up to the committed 1.1 s boundary")
  }

  // MARK: - #3973: meeting release and drain

  /// The runtime's own join notices: a caller is waiting on another caller's load or release.
  final class Joins: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [TranscribeCppPreviewRuntime.Join] = []
    private var waiters: [(TranscribeCppPreviewRuntime.Join, CheckedContinuation<Void, Never>)] = []
    func record(_ join: TranscribeCppPreviewRuntime.Join) {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        seen.append(join)
        let met = waiters.filter { $0.0 == join }.map(\.1)
        waiters.removeAll { $0.0 == join }
        return met
      }
      for waiter in ready { waiter.resume() }
    }
    func until(_ join: TranscribeCppPreviewRuntime.Join) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if seen.contains(join) { return true }
          waiters.append((join, c))
          return false
        }
        if now { c.resume() }
      }
    }
  }

  private static func session(
    _ runtime: TranscribeCppPreviewRuntime, _ outputs: Outputs
  ) async throws -> any WhisperIncrementalSession {
    try await runtime.makeSession(
      language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: outputs.text,
      onAudioReleased: outputs.released)
  }

  @Test("an idle release frees the model once for every caller, and the runtime never loads again")
  func idleReleaseFreesOnce() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let residency = TranscribeCppPreviewResidency()
    let runtime = Self.runtime(driver, residency: residency)
    try await Self.step("the load", driver) { try await runtime.ensureLoaded() }
    // A session made before the release and still held after it, as a retained handle.
    let outputs = Outputs()
    let retained = try await Self.step("the open", driver) { try await Self.session(runtime, outputs) }
    try await Self.step("three releases at once", driver) {
      async let a: Void = runtime.releaseAndDrain()
      async let b: Void = runtime.releaseAndDrain()
      async let c: Void = runtime.releaseAndDrain()
      _ = await (a, b, c)
    }
    try await Self.step("a later release", driver) { await runtime.releaseAndDrain() }
    #expect(driver.unloads == [1], "one physical free")
    #expect(residency.loadedCount == 0)
    #expect(await runtime.isLoaded == false)
    await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.released) {
      try await runtime.ensureLoaded()
    }
    await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.released) {
      _ = try await Self.session(runtime, Outputs())
    }
    // The retained session's decodes are refused before native code.
    let recording = Recording()
    recording.set(seconds: 1.2)
    try await Self.step("the start", driver) {
      await retained.start(audioSamplesProvider: recording.provider)
    }
    let rolling = try #require(retained as? TranscribeCppRollingSession)
    await Self.within("three refused cycles", driver) { await rolling.cyclesCompleted(reach: 3) }
    try await Self.step("the cancel", driver) { await retained.cancel() }
    #expect(driver.entered == 0, "no decode against a freed model")
    #expect(driver.loads == 1)
  }

  @Test("a release while the artifact admission is still deciding prevents a late load")
  func releaseDuringAdmission() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let admission = Admission(gated: true)
    let runtime = Self.runtime(driver) {
      try? await admission.admit()
      return true
    }
    let load = Task { try await runtime.ensureLoaded() }
    await Self.within("the admission question", driver) { await admission.reach(1) }
    try await Self.step("the release", driver) { await runtime.releaseAndDrain() }
    admission.open()
    let result = try await Self.step("the refused load", driver) { await load.result }
    #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.released) { try result.get() }
    #expect(driver.loadsEntered == 0, "no native load after the release won")
    #expect(driver.unloads.isEmpty)
  }

  @Test("a release during a native load joins it, frees the late model and never publishes it")
  func releaseDuringLoad() async throws {
    let driver = FakeDriver()
    driver.openAll()
    driver.hold(loads: true)
    let residency = TranscribeCppPreviewResidency()
    let runtime = Self.runtime(driver, residency: residency)
    let load = Task { try await runtime.ensureLoaded() }
    await Self.within("the native load", driver) { await driver.until { driver.loadsEntered >= 1 } }
    let release = await runtime.beginRelease()
    // What the driver had done when the release reported completion: an ordering record.
    let atCompletion = Task { () -> (loads: Int, unloads: [Int]) in
      await release.value
      return (driver.loads, driver.unloads)
    }
    driver.releaseLoads()
    let seen = try await Self.step("the release", driver) { await atCompletion.value }
    #expect(seen.loads == 1 && seen.unloads == [1], "complete only after the late model loaded and was freed")
    let result = try await Self.step("the refused load", driver) { await load.result }
    #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.released) { try result.get() }
    #expect(driver.loads == 1 && driver.unloads == [1], "the late model was freed once")
    #expect(residency.loadedCount == 0)
    #expect(await runtime.isLoaded == false)
  }

  @Test("opens waiting on a shared load never escape a release as usable sessions")
  func pendingOpensCannotEscape() async throws {
    let driver = FakeDriver()
    driver.openAll()
    driver.hold(loads: true)
    let joins = Joins()
    let runtime = Self.runtime(driver, joins: joins)
    // The first open starts the load; the second joins that same pending load.
    let first = Task { try await Self.session(runtime, Outputs()) }
    await Self.within("the native load", driver) { await driver.until { driver.loadsEntered >= 1 } }
    let second = Task { try await Self.session(runtime, Outputs()) }
    await Self.within("the second open joining the load", driver) { await joins.until(.load) }
    let release = await runtime.beginRelease()
    driver.releaseLoads()
    await Self.within("the release", driver) { await release.value }
    for open in [first, second] {
      let result = try await Self.step("a refused open", driver) { await open.result }
      #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.released) { _ = try result.get() }
    }
    #expect(driver.loadsEntered == 1, "the second open joined the first load")
    #expect(driver.unloads == [1])
  }

  @Test("with two tracks decoding, the model is freed only after both native runs returned")
  func releaseWaitsForEveryDecode() async throws {
    let driver = FakeDriver()  // decodes held until released one by one
    let residency = TranscribeCppPreviewResidency()
    let runtime = Self.runtime(driver, residency: residency)
    let recording = Recording()
    recording.set(seconds: 1.2)
    let a = try await Self.step("open A", driver) { try await Self.session(runtime, Outputs()) }
    let b = try await Self.step("open B", driver) { try await Self.session(runtime, Outputs()) }
    try await Self.step("start A", driver) { await a.start(audioSamplesProvider: recording.provider) }
    try await Self.step("start B", driver) { await b.start(audioSamplesProvider: recording.provider) }
    await Self.within("both decodes inside", driver) { await driver.until { driver.entered >= 2 } }
    let release = await runtime.beginRelease()
    driver.releaseOne()
    await Self.within("the first decode's return", driver) { await driver.until { driver.exited >= 1 } }
    driver.releaseOne()
    await Self.within("the release", driver) { await release.value }
    #expect(driver.exitedAtUnload == [2], "the free began only after both native runs returned")
    #expect(driver.unloads == [1])
    #expect(residency.loadedCount == 0)
    driver.openAll()
    try await Self.step("the cancels", driver) {
      await a.cancel()
      await b.cancel()
    }
    // Both loops have ended: this count is final.
    #expect(driver.entered == 2, "no decode entered after the release began")
  }

  @Test("a free that has not returned keeps the release incomplete, even for a cancelled caller")
  func releaseWaitsForTheUnload() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let residency = TranscribeCppPreviewResidency()
    let joins = Joins()
    let runtime = Self.runtime(driver, residency: residency, joins: joins)
    try await Self.step("the load", driver) { try await runtime.ensureLoaded() }
    driver.hold(unloads: true)
    // Each caller records what the driver had freed when its wait returned.
    let cancelled = Task { () -> [Int] in
      await runtime.releaseAndDrain()
      return driver.unloads
    }
    await Self.within("the native free", driver) { await driver.until { driver.unloadsEntered >= 1 } }
    cancelled.cancel()
    #expect(residency.loadedCount == 1, "still resident while the free is inside native code")
    let later = Task { () -> [Int] in
      await runtime.releaseAndDrain()
      return driver.unloads
    }
    await Self.within("the later caller joining the release", driver) { await joins.until(.release) }
    driver.releaseUnloads()
    let seen = try await Self.step("both callers", driver) { (await cancelled.value, await later.value) }
    #expect(seen.0 == [1], "the cancelled caller returned only after the free")
    #expect(seen.1 == [1], "the joined caller returned only after the free")
    #expect(driver.unloadsEntered == 1 && driver.unloads == [1], "the cleanup finished, once")
    #expect(residency.loadedCount == 0)
  }

  @Test("releasing the meeting runtime leaves a separate dictation runtime loaded")
  func releaseIsPerRuntime() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let residency = TranscribeCppPreviewResidency()
    let dictation = Self.runtime(driver, residency: residency)
    let meeting = Self.runtime(driver, residency: residency)
    try await Self.step("dictation's load", driver) { try await dictation.ensureLoaded() }
    try await Self.step("the meeting's load", driver) { try await meeting.ensureLoaded() }
    try await Self.step("the meeting's release", driver) { await meeting.releaseAndDrain() }
    #expect(driver.unloads == [2], "only the meeting's model was freed")
    #expect(residency.loadedCount == 1)
    #expect(await dictation.isLoaded)
    try await Self.step("dictation still opens", driver) {
      _ = try await Self.session(dictation, Outputs())
    }
  }

  @Test("a runtime nobody released is still freed once when its last holder lets go")
  func unreleasedRuntimeStillFreedOnDeinit() async throws {
    let driver = FakeDriver()
    driver.openAll()
    let residency = TranscribeCppPreviewResidency()
    var runtime: TranscribeCppPreviewRuntime? = Self.runtime(driver, residency: residency)
    try await Self.step("the load", driver) { [runtime] in try await runtime?.ensureLoaded() }
    #expect(residency.loadedCount == 1)
    runtime = nil
    await Self.within("the free", driver) { await residency.waitUntilNoneLoaded() }
    #expect(driver.unloads == [1])
  }

  @Test("the retained preview audio ceiling is two minutes at 16 kHz (#2117)")
  func retainedAudioCeilingIsTwoMinutes() {
    #expect(TranscribeCppPreviewSession.maxRetainedSamples == 1_920_000)
  }

  final class AdmissionSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
      get { lock.withLock { _value } }
      set { lock.withLock { _value = newValue } }
    }
  }
}

/// A bounded wait: the first of the signal and a hang-guard deadline wins. Expiry records an
/// issue and runs `onExpiry` (release what the work may block on), so a missing signal fails
/// the test instead of hanging the lane.
enum PreviewWait {
  final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func fulfil(_ value: Bool) {
      let w = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
        guard stored == nil else { return nil }
        stored = value
        defer { waiter = nil }
        return waiter
      }
      w?.resume(returning: value)
    }
    func value() async -> Bool {
      await withCheckedContinuation { c in
        let ready = lock.withLock { () -> Bool? in
          if let stored { return stored }
          waiter = c
          return nil
        }
        if let ready { c.resume(returning: ready) }
      }
    }
  }

  @discardableResult
  static func within(
    _ what: String, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
    onExpiry: @Sendable () -> Void = {}, _ ready: @escaping @Sendable () async -> Void
  ) async -> Bool {
    let once = Once()
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

  /// Thrown by `value` when its step expired; `within` has already recorded the named issue.
  struct Expired: Error, Equatable {
    let what: String
  }

  /// `within` for an await that returns or throws: the step's own result, or `Expired`.
  static func value<T: Sendable>(
    _ what: String, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
    onExpiry: @Sendable () -> Void = {}, _ work: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let slot = Slot<T>()
    // An expired step throws even if the cancelled work later stores a result.
    let ok = await within(
      what, seconds: seconds, sourceLocation: sourceLocation, onExpiry: onExpiry
    ) {
      do {
        slot.set(.success(try await work()))
      } catch {
        slot.set(.failure(error))
      }
    }
    guard ok, let result = slot.result else { throw Expired(what: what) }
    return try result.get()
  }

  final class Slot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, any Error>?
    var result: Result<T, any Error>? { lock.withLock { stored } }
    func set(_ value: Result<T, any Error>) { lock.withLock { stored = value } }
  }
}
