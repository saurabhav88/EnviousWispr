import EnviousWisprCore
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
      lock.withLock {
        _lanes.append(lane)
        if running > 0 { overlapped = true }
        running += 1
        _entered += 1
      }
      notify()
      // Held until released, cancelled or not: the "native" run ends on its own schedule.
      await withTaskCancellationHandler {
        await withCheckedContinuation { c in lock.withLock { gates.append(c) } }
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

    /// Ends every held decode.
    func releaseAll() {
      let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        defer { gates = [] }
        return gates
      }
      for gate in all { gate.resume() }
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

  private static let speech: [Float] = (0..<19_200).map { Float(sin(Double($0) * 0.05)) * 0.2 }

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

  private static func within(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    onExpiry: @Sendable () -> Void = {},
    _ ready: @escaping @Sendable () async -> Void
  ) async {
    await PreviewWait.within(what, sourceLocation: sourceLocation, onExpiry: onExpiry, ready)
  }

  @Test(
    "a quick stop and restart waits for the old decode's native return and never overlaps two decodes"
  )
  func rapidStopStartNeverOverlaps() async throws {
    let driver = FakeDriver()
    let recognizer = Self.recognizer(driver, residency: .init())
    let first = Delivered()
    let a = try await recognizer.openSession(lookups: nil, onText: first.append)
    await a.feed(Self.speech)
    await Self.within("the first session's decode", onExpiry: driver.releaseAll) {
      await driver.until { driver.entered == 1 }
    }

    // The coordinator cancels its task without awaiting `end()`; the next recording opens at
    // once. The new open must wait until the old decode physically returned.
    let stopping = Task { await a.end() }
    let second = Delivered()
    let opening = Task { () throws -> (any LivePreviewEngineSession, Int) in
      let session = try await recognizer.openSession(lookups: nil, onText: second.append)
      return (session, driver.exited)
    }
    await Self.within(
      "the old decode's cancellation reaching the boundary", onExpiry: driver.releaseAll
    ) {
      await driver.until { driver.cancelled == 1 }
    }
    #expect(driver.exited == 0, "control: the old native run is still inside")
    driver.releaseAll()
    let (b, exitedWhenOpened) = try await opening.value
    await stopping.value
    #expect(exitedWhenOpened == 1, "the new session opened only after the old run returned")

    await b.feed(Self.speech)
    await Self.within("the second session's decode", onExpiry: driver.releaseAll) {
      await driver.until { driver.entered == 2 }
    }
    driver.releaseAll()
    await b.end()
    #expect(driver.overlapped == false)
    #expect(first.all.isEmpty, "the stopped session's late decode reached nobody")
    #expect(driver.lanes.allSatisfy { $0 == .preview }, "load and decodes stay on the preview lane")
  }

  @Test("a refused open releases the turnover, and the next open works once the model is admitted")
  func refusedOpenDoesNotWedge() async throws {
    let driver = FakeDriver()
    let admitted = AdmissionSwitch()
    let recognizer = Self.recognizer(driver, admitted: { admitted.value }, residency: .init())
    await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.notAdmitted) {
      _ = try await recognizer.openSession(lookups: nil, onText: { _ in })
    }
    #expect(driver.loads == 0, "an unadmitted model is never loaded")
    admitted.value = true
    let session = try await recognizer.openSession(lookups: nil, onText: { _ in })
    await session.end()
    #expect(driver.loads == 1)
  }

  @Test("releasing a prepared engine after a recording frees its model once; a failed load frees nothing")
  func releasedEngineFreesItsModelOnce() async throws {
    let driver = FakeDriver()
    let residency = TranscribeCppPreviewResidency()
    var recognizer: WhisperPreviewRecognizer? = Self.recognizer(driver, residency: residency)
    try await recognizer?.prepare()
    try await recognizer?.prepare()
    #expect(driver.loads == 1)
    #expect(residency.loadedCount == 1)
    // A finished recording stays reachable from the engine (its turnover record); it must not
    // keep the model once the engine itself goes.
    let session = try #require(try await recognizer?.openSession(lookups: nil, onText: { _ in }))
    await session.feed(Self.speech)
    await Self.within("the recording's decode", onExpiry: driver.releaseAll) {
      await driver.until { driver.entered == 1 }
    }
    driver.releaseAll()
    await session.end()
    // A stale preparation, a disabled preview, an engine change and Remove all end the same
    // way: the coordinator drops its last reference.
    recognizer = nil
    await Self.within("the released model's free") { await residency.waitUntilNoneLoaded() }
    #expect(driver.unloads == [1], "freed exactly once")

    let failing = FakeDriver()
    failing.failLoads = true
    let failedResidency = TranscribeCppPreviewResidency()
    var broken: WhisperPreviewRecognizer? = Self.recognizer(failing, residency: failedResidency)
    await #expect(throws: TranscribeCppPreviewRuntime.LoadFailure.self) {
      try await broken?.prepare()
    }
    broken = nil
    #expect(failing.unloads.isEmpty)
    #expect(failedResidency.loadedCount == 0)
  }

  @Test("the preview audio cap is ten minutes at 16 kHz")
  func audioCapIsTenMinutes() {
    #expect(TranscribeCppPreviewSession.maxRetainedSamples == 9_600_000)
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

  static func within(
    _ what: String, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
    onExpiry: @Sendable () -> Void = {}, _ ready: @escaping @Sendable () async -> Void
  ) async {
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
  }
}
