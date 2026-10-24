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
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(() -> Bool, CheckedContinuation<Void, Never>)] = []
    private var open = false
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

    func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int {
      let failing = lock.withLock { () -> Bool in
        _lanes.append(lane)
        guard !failLoads else { return true }
        _loads += 1
        nextHandle += 1
        return false
      }
      if failing { throw TranscribeCppExecutor.ExecutorError.modelUnavailable }
      return lock.withLock { nextHandle }
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
      lock.withLock { _unloads.append(handle) }
      notify()
    }

    /// The preview runtime never settles a lane (only the heart backend's teardown does), and
    /// this fake's loads and unloads complete within the call.
    func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int { 0 }

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
