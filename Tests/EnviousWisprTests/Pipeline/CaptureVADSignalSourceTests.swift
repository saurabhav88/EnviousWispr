import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

// MARK: - CaptureVADSignalSourceTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `CaptureVADSignalSource` — signal bridging, the
// `speechEvidenceAtStop()` tri-state, and `SessionID` stamping.

@MainActor
@Suite struct CaptureVADSignalSourceTests {

  @Test("noteAutoStopTriggered yields an autoStop signal stamped with the current session")
  func autoStopBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    source.noteAutoStopTriggered()
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  @Test("noteMaxDurationReached yields a maxDuration signal")
  func maxDurationBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    source.noteMaxDurationReached()
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .maxDurationReached, sessionID: sid))
  }

  @Test("noteApproachingMaxDuration yields a warning signal stamped with the current session")
  func warningBridging() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    var iterator = source.subscribeWarningSignals().makeAsyncIterator()
    source.noteApproachingMaxDuration(remainingSeconds: 60)
    let signal = await iterator.next()
    #expect(signal == VADWarningSignal(remainingSeconds: 60, sessionID: sid))
  }

  @Test("a warning never appears on the stop stream (#1060 separate streams)")
  func warningDoesNotRideStopStream() async {
    let source = CaptureVADSignalSource()
    source.setCurrentSessionID(SessionID())
    var stopIterator = source.subscribeStopSignals().makeAsyncIterator()
    source.noteApproachingMaxDuration(remainingSeconds: 60)  // must NOT reach the stop stream
    source.noteMaxDurationReached()
    let signal = await stopIterator.next()
    #expect(signal?.kind == .maxDurationReached)
  }

  @Test("bind claims onVADAutoStop — the XPC callback drives a stop signal")
  func bindOwnsXPCCallback() async {
    let source = CaptureVADSignalSource()
    let capture = FakeAudioCapture()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    source.bind(audioCapture: capture)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    capture.fireVADAutoStop()  // the XPC service-side detector fires
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  /// #1408 A3: `bind` claims BOTH callback slots. The manager's hard-cap
  /// backstop funnels into the SAME typed, session-stamped stop route the
  /// graceful wall-clock cap uses — a normal `.maxDuration` stop, never an
  /// engine interruption.
  @Test("bind claims onMaxDurationReached — the backstop drives a typed stop signal")
  func bindOwnsMaxDurationCallback() async {
    let source = CaptureVADSignalSource()
    let capture = FakeAudioCapture()
    let sid = SessionID()
    source.setCurrentSessionID(sid)
    source.bind(audioCapture: capture)
    var iterator = source.subscribeStopSignals().makeAsyncIterator()
    capture.fireMaxDurationReached()  // the manager backstop fires
    let signal = await iterator.next()
    #expect(signal == VADStopSignal(kind: .maxDurationReached, sessionID: sid))
  }

  @Test("each signal carries the session current at emit time")
  func sessionStamping() async {
    let source = CaptureVADSignalSource()
    let first = SessionID()
    let second = SessionID()
    var iterator = source.subscribeStopSignals().makeAsyncIterator()

    source.setCurrentSessionID(first)
    source.noteAutoStopTriggered()
    source.setCurrentSessionID(second)
    source.noteAutoStopTriggered()

    let a = await iterator.next()
    let b = await iterator.next()
    #expect(a?.sessionID == first)
    #expect(b?.sessionID == second, "a re-stamped session is reflected in later signals")
  }

  // MARK: PR-5 Rung 5 Codex code-diff r1 P1 — per-subscriber broadcast
  //
  // The source is shared between two `KernelDictationDriver`s in production
  // (Parakeet + WhisperKit) via `WisprBootstrapper.swift:148`. A single
  // `AsyncStream` delivers each yield to exactly one iterator, so an
  // overlap between the two kernels' `subscribeVADSignals` tasks could
  // swallow a stop signal before the active driver saw it. Each
  // `subscribeStopSignals()` call must vend a fresh stream, and every
  // emit must reach every live subscriber.

  @Test("subscribeStopSignals — every live subscriber receives every signal")
  func broadcastDeliversToAllSubscribers() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)

    var iterA = source.subscribeStopSignals().makeAsyncIterator()
    var iterB = source.subscribeStopSignals().makeAsyncIterator()

    source.noteAutoStopTriggered()
    let a = await iterA.next()
    let b = await iterB.next()

    #expect(a == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
    #expect(b == VADStopSignal(kind: .autoStopTriggered, sessionID: sid))
  }

  @Test("subscribeStopSignals — second subscriber added mid-stream sees only later signals")
  func lateSubscriberSeesLaterSignalsOnly() async {
    let source = CaptureVADSignalSource()
    let sid = SessionID()
    source.setCurrentSessionID(sid)

    var iterA = source.subscribeStopSignals().makeAsyncIterator()
    source.noteAutoStopTriggered()  // delivered to A only — B is not subscribed yet
    let a1 = await iterA.next()
    #expect(a1?.kind == .autoStopTriggered)

    var iterB = source.subscribeStopSignals().makeAsyncIterator()
    source.noteMaxDurationReached()  // delivered to A AND B
    let a2 = await iterA.next()
    let b1 = await iterB.next()
    #expect(a2?.kind == .maxDurationReached)
    #expect(b1?.kind == .maxDurationReached)
  }

  @Test("speechEvidenceAtStop returns the configured tri-state")
  func evidenceTriState() {
    let source = CaptureVADSignalSource()
    // Default — no detector ran.
    #expect(source.speechEvidenceAtStop() == .unavailable)

    source.setEvidenceProvider { .voiced }
    #expect(source.speechEvidenceAtStop() == .voiced)

    source.setEvidenceProvider { .confirmedNoSpeech }
    #expect(source.speechEvidenceAtStop() == .confirmedNoSpeech)
  }

  // MARK: - Record-start markers + monitor identity (#1780)
  //
  // #1780 crashed inside first-chunk processing and left no trail. These tests
  // freeze the two suspension points (preparation, first chunk), interrupt the
  // run each way it can really be interrupted, and prove no stale marker
  // escapes. Test 9 reuses the SAME SessionID on purpose: it is the one that
  // fails if the generation guard is removed and only the session is checked.

  /// Cross-actor: the fake VAD is an actor, the sink spy is `@MainActor`.
  /// Lock-backed rather than unlocked-unchecked.
  final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private var _released = false
    private var cont: CheckedContinuation<Void, Never>?

    var entered: Bool { lock.withLock { _entered } }

    func markEntered() { lock.withLock { _entered = true } }

    /// The deliberate suspension point the fake blocks on. Unbounded by design
    /// — this is the SUT-side block the test is constructing, not an assertion
    /// wait — and every harness releases it, including on the failure path.
    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow: Bool = lock.withLock {
          if _released { return true }
          cont = c
          return false
        }
        if resumeNow { c.resume() }
      }
    }

    /// Re-arms for a subsequent run's signal.
    func reset() {
      lock.withLock {
        _entered = false
        _released = false
        cont = nil
      }
    }

    /// Idempotent so cleanup after an assertion failure cannot double-resume.
    func release() {
      let c: CheckedContinuation<Void, Never>? = lock.withLock {
        if _released { return nil }
        _released = true
        _entered = true
        let held = cont
        cont = nil
        return held
      }
      c?.resume()
    }
  }

  /// Suspends inside `processStreamingChunk` (the first-chunk boundary).
  /// Observes cancellation so a test can prove `invalidateMonitor()` ran
  /// BEFORE it resumes, instead of guessing with a yield count.
  actor GatedChunkVad: StreamingVad {
    private let gate: Gate
    private let cancelSeen: Gate
    init(gate: Gate, cancelSeen: Gate = Gate()) {
      self.gate = gate
      self.cancelSeen = cancelSeen
    }
    func processStreamingChunk(
      _ audioChunk: [Float], state: VadStreamState, config: VadSegmentationConfig,
      returnSeconds: Bool, timeResolution: Int
    ) async throws -> VadStreamResult {
      gate.markEntered()
      await withTaskCancellationHandler {
        await gate.wait()
      } onCancel: {
        cancelSeen.markEntered()
        cancelSeen.release()
      }
      var next = state
      next.processedSamples += audioChunk.count
      return VadStreamResult(state: next, event: nil, probability: 0.0)
    }
  }

  /// Never suspends — for runs that should complete normally.
  actor OpenVad: StreamingVad {
    func processStreamingChunk(
      _ audioChunk: [Float], state: VadStreamState, config: VadSegmentationConfig,
      returnSeconds: Bool, timeResolution: Int
    ) async throws -> VadStreamResult {
      var next = state
      next.processedSamples += audioChunk.count
      return VadStreamResult(state: next, event: nil, probability: 0.0)
    }
  }

  struct PrepFailure: Error {}

  @MainActor final class SinkSpy {
    var prep: [(backend: String, route: String, ready: Bool, reused: Bool)] = []
    var started: [(backend: String, route: String, ms: Double)] = []
    var completed: [(backend: String, route: String, ms: Double, stop: Bool)] = []
    /// Fired by the markers waiters actually block on, so a wait resolves on a
    /// real event and never a yield count (`test-timing.md`: wait for a
    /// signal, not a clock).
    let completedMarker = Gate()
    let prepMarker = Gate()

    func makeSink() -> RecordStartTelemetrySink {
      RecordStartTelemetrySink(
        breadcrumb: { _, _, _ in },
        emitPreparation: { [self] b, r, ready, reused in
          prep.append((b, r, ready, reused))
          prepMarker.release()
        },
        emitChunkStarted: { [self] b, r, ms in
          started.append((b, r, ms))
        },
        emitChunkCompleted: { [self] b, r, ms, stop in
          completed.append((b, r, ms, stop))
          completedMarker.release()
        })
    }
  }

  /// Builds a source whose detector is backed by the supplied fake, with a
  /// per-instance sink spy. `startMonitoring` is NOT called here so each test
  /// controls the exact moment.
  private static func makeSource(
    spy: SinkSpy,
    vad: @escaping @Sendable () -> any StreamingVad,
    prepFails: Bool = false,
    detectorCount: Box<Int>? = nil
  ) -> CaptureVADSignalSource {
    CaptureVADSignalSource(
      makeDetector: { timeout, cfg in
        detectorCount?.value += 1
        return SilenceDetector(
          silenceTimeout: timeout, vadConfig: cfg,
          makeStreamingVad: {
            if prepFails { throw PrepFailure() }
            return vad()
          })
      },
      recordStartTelemetry: spy.makeSink())
  }

  @MainActor final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
  }

  /// Feeds whole VAD chunks through the fake's own delivery API rather than
  /// reaching into its private storage.
  private static func feedChunks(_ capture: FakeAudioCapture, _ n: Int) {
    capture.deliverBuffer(frameCount: SilenceDetector.chunkSize * n, amplitude: 0.1)
  }

  /// Drives the source to a live monitor with one chunk available.
  private static func begin(
    _ source: CaptureVADSignalSource, capture: FakeAudioCapture,
    sid: SessionID, backend: String, live: Box<Bool>
  ) {
    source.configureSession(config: .testDefault(), audioCapture: capture)
    source.setCurrentSessionID(sid)
    source.startMonitoring(
      recordingStartTime: Date(), backend: backend, isRecording: { live.value })
  }

  /// Waits for the gate's entry signal with a BOUNDED net.
  ///
  /// Deliberately not an unconditional `withCheckedContinuation` await on the
  /// entry signal: `swift-patterns.md` RULE: tests-no-unconditional-continuation-await
  /// exists because a signal that never fires HANGS the suite instead of
  /// failing it. I hit exactly that — a 10-minute wedge — before reverting to
  /// this shape. The bound is a failure net; the returned Bool is asserted by
  /// every caller, so a missing signal fails loudly and fast.
  private static func awaitSignal(_ gate: Gate, limit: Int = 20_000) async -> Bool {
    for _ in 0..<limit {
      if gate.entered { return true }
      await Task.yield()
    }
    return gate.entered
  }

  /// Old-run marker counts, captured at the invalidation point.
  struct MarkerBaseline: Equatable {
    var prep = 0
    var started = 0
    var completed = 0
  }

  private static func baseline(_ spy: SinkSpy, backend: String) -> MarkerBaseline {
    MarkerBaseline(
      prep: spy.prep.filter { $0.backend == backend }.count,
      started: spy.started.filter { $0.backend == backend }.count,
      completed: spy.completed.filter { $0.backend == backend }.count)
  }

  /// Absence proof for a superseded run, BASELINE-AWARE.
  ///
  /// First-chunk tests legitimately hold a preparation + started marker for the
  /// old backend BEFORE invalidation. An earlier version treated those as a
  /// leak and returned instantly, so it never waited for the stale `completed`
  /// callback — that is why mutation detection silently fell from 6/6 to 3/6.
  /// This waits only for an old-backend count to EXCEED its baseline.
  ///
  /// An absence can only be established up to a bound, so the loop is a FAILURE
  /// NET, never the proof: it exits early the instant a genuine leak appears so
  /// the caller's assertion fails loudly instead of passing silently.
  private static func settleAwaitingNoLeak(
    _ spy: SinkSpy, oldBackend: String, baseline base: MarkerBaseline, limit: Int = 5_000
  ) async {
    for _ in 0..<limit {
      if baseline(spy, backend: oldBackend) != base { return }
      await Task.yield()
    }
  }

  @Test("markers carry the backend and route captured at monitor start")
  func snapshotsAreTakenSynchronously() async throws {
    let spy = SinkSpy()
    let capture = FakeAudioCapture()
    capture.routeOverride = "routeA"
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let source = Self.makeSource(spy: spy, vad: { OpenVad() })

    Self.begin(source, capture: capture, sid: SessionID(), backend: "backendA", live: live)
    // Mutate the route before the task first executes: the markers must keep A.
    capture.routeOverride = "routeB"

    try #require(
      await Self.awaitSignal(spy.completedMarker),
      "the run never completed its first chunk — the test would be vacuous")
    live.value = false
    await source.finalizeAtStop(rawSampleCount: capture.capturedSamples.count)

    #expect(spy.prep.count == 1)
    #expect(spy.started.count == 1)
    #expect(spy.completed.count == 1)
    // Backend AND route, on all three markers. Asserting route alone would let a
    // backend regression through on started/completed.
    #expect(spy.prep.allSatisfy { $0.backend == "backendA" && $0.route == "routeA" })
    #expect(spy.started.allSatisfy { $0.backend == "backendA" && $0.route == "routeA" })
    #expect(spy.completed.allSatisfy { $0.backend == "backendA" && $0.route == "routeA" })
    #expect(spy.completed.first?.stop == false)
  }

  @Test("a run superseded before it first executes emits nothing")
  func staleSessionBeforeFirstExecution() async {
    let spy = SinkSpy()
    let capture = FakeAudioCapture()
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let source = Self.makeSource(spy: spy, vad: { OpenVad() })

    Self.begin(source, capture: capture, sid: SessionID(), backend: "old", live: live)
    // Synchronously stamp a new session before the task body runs.
    source.setCurrentSessionID(SessionID())
    live.value = false

    await Self.settleAwaitingNoLeak(spy, oldBackend: "old", baseline: MarkerBaseline())

    #expect(spy.prep.isEmpty)
    #expect(spy.started.isEmpty)
    #expect(spy.completed.isEmpty)
  }

  @Test("model_reused is read before preparation, so the first run reports false")
  func modelReusedOrderingAcrossRuns() async throws {
    let spy = SinkSpy()
    let capture = FakeAudioCapture()
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let count = Box(0)
    let source = Self.makeSource(
      spy: spy, vad: { OpenVad() }, detectorCount: count)
    let sid = SessionID()

    Self.begin(source, capture: capture, sid: sid, backend: "b", live: live)
    try #require(
      await Self.awaitSignal(spy.completedMarker),
      "first run never completed — the reuse comparison would be vacuous")
    live.value = false
    await source.finalizeAtStop(rawSampleCount: capture.capturedSamples.count)

    // Second run reuses the retained, now-ready detector.
    spy.completedMarker.reset()
    live.value = true
    Self.feedChunks(capture, 1)
    Self.begin(source, capture: capture, sid: sid, backend: "b", live: live)
    try #require(
      await Self.awaitSignal(spy.completedMarker),
      "second run never completed — the reuse comparison would be vacuous")
    live.value = false
    await source.finalizeAtStop(rawSampleCount: capture.capturedSamples.count)

    #expect(count.value == 1)
    #expect(spy.prep.count == 2)
    #expect(spy.prep.first?.reused == false)
    #expect(spy.prep.last?.reused == true)
  }

  @Test("failed preparation still emits the marker with ready false")
  func failedPreparationEmitsReadyFalse() async throws {
    let spy = SinkSpy()
    let capture = FakeAudioCapture()
    capture.routeOverride = "r"
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let source = Self.makeSource(spy: spy, vad: { OpenVad() }, prepFails: true)

    Self.begin(source, capture: capture, sid: SessionID(), backend: "bk", live: live)
    try #require(
      await Self.awaitSignal(spy.prepMarker),
      "preparation marker never fired — the test would be vacuous")
    live.value = false

    #expect(spy.prep.count == 1)
    #expect(spy.prep.first?.ready == false)
    #expect(spy.prep.first?.reused == false)
    #expect(spy.prep.first?.backend == "bk")
    #expect(spy.prep.first?.route == "r")
    #expect(spy.started.isEmpty)
    #expect(spy.completed.isEmpty)
  }

  /// Builds a source whose DETECTOR PREPARATION suspends on `gate`, so the run
  /// can be interrupted while sitting inside `prepare()`.
  private static func makeGatedPrepSource(
    spy: SinkSpy, gate: Gate
  ) -> CaptureVADSignalSource {
    CaptureVADSignalSource(
      makeDetector: { timeout, cfg in
        SilenceDetector(
          silenceTimeout: timeout, vadConfig: cfg,
          makeStreamingVad: {
            gate.markEntered()
            await gate.wait()
            return OpenVad()
          })
      },
      recordStartTelemetry: spy.makeSink())
  }

  /// Suspended at PREPARATION, interrupted three ways. In every case the run
  /// resumes afterwards and must emit nothing.
  private static func assertPreparationSuspendedRunIsSilenced(
    invalidate: @MainActor (CaptureVADSignalSource, FakeAudioCapture, SessionID) -> Void
  ) async throws -> SinkSpy {
    let spy = SinkSpy()
    let gate = Gate()
    let capture = FakeAudioCapture()
    feedChunks(capture, 1)
    let live = Box(true)
    let source = makeGatedPrepSource(spy: spy, gate: gate)
    let sid = SessionID()

    begin(source, capture: capture, sid: sid, backend: "b", live: live)
    try #require(
      await awaitSignal(gate),
      "preparation never suspended — the test would be vacuous")

    let base = baseline(spy, backend: "b")
    try #require(
      base == MarkerBaseline(),
      "preparation-suspended run should hold no markers yet")

    invalidate(source, capture, sid)

    // The recording stays LIVE across the whole absence window on purpose. If
    // it were ended here, the guard's liveness term alone would suppress the
    // superseded run and this test would stop proving the GENERATION term —
    // it would pass with the generation check deleted.
    gate.release()  // resume the superseded run
    await settleAwaitingNoLeak(spy, oldBackend: "b", baseline: base)
    #expect(
      baseline(spy, backend: "b") == base,
      "superseded run emitted after invalidation")
    live.value = false  // cleanup only, after the assertion
    return spy
  }

  @Test("configureSession silences a run suspended in preparation")
  func prepSuspendedInvalidatedByConfigureSession() async throws {
    let spy = try await Self.assertPreparationSuspendedRunIsSilenced { source, capture, _ in
      source.configureSession(config: .testDefault(), audioCapture: capture)
    }
    #expect(spy.prep.contains { $0.backend == "b" } == false)
    #expect(spy.started.contains { $0.backend == "b" } == false)
    #expect(spy.completed.contains { $0.backend == "b" } == false)
  }

  @Test("same-session startMonitoring replacement silences a run suspended in preparation")
  func prepSuspendedInvalidatedByReplacement() async throws {
    // SAME SessionID on purpose: only the generation can catch this.
    let spy = try await Self.assertPreparationSuspendedRunIsSilenced { source, _, sid in
      source.setCurrentSessionID(sid)
      source.startMonitoring(
        recordingStartTime: Date(), backend: "replacement", isRecording: { false })
    }
    #expect(spy.prep.contains { $0.backend == "b" } == false)
    #expect(spy.started.contains { $0.backend == "b" } == false)
    #expect(spy.completed.contains { $0.backend == "b" } == false)
  }

  @Test("finalizeAtStop silences a run suspended in preparation")
  func prepSuspendedInvalidatedByFinalize() async throws {
    let spy = SinkSpy()
    let gate = Gate()
    let capture = FakeAudioCapture()
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let source = Self.makeGatedPrepSource(spy: spy, gate: gate)

    Self.begin(source, capture: capture, sid: SessionID(), backend: "b", live: live)
    try #require(
      await Self.awaitSignal(gate),
      "preparation never suspended — the test would be vacuous")

    // `directDetectorPrepared` is still false while preparation is suspended,
    // so finalize does not await the detector actor and can be awaited directly.
    // No task, no yield count.
    let base = Self.baseline(spy, backend: "b")
    try #require(
      base == MarkerBaseline(),
      "preparation-suspended run should hold no markers yet")
    await source.finalizeAtStop(rawSampleCount: 0)
    // Recording stays LIVE across the absence window so this proves the
    // GENERATION term, not the liveness term.
    gate.release()
    await Self.settleAwaitingNoLeak(spy, oldBackend: "b", baseline: base)
    #expect(Self.baseline(spy, backend: "b") == base, "emitted after finalizeAtStop")
    live.value = false  // cleanup only, after the assertion

    #expect(spy.prep.contains { $0.backend == "b" } == false)
    #expect(spy.started.contains { $0.backend == "b" } == false)
    #expect(spy.completed.contains { $0.backend == "b" } == false)
  }

  /// Suspended inside the FIRST CHUNK. Preparation and `started` have already
  /// legitimately emitted; only `completed` must be suppressed.
  private static func assertFirstChunkSuspendedRunIsSilenced(
    invalidate: @MainActor (CaptureVADSignalSource, FakeAudioCapture, SessionID) -> Void
  ) async throws -> SinkSpy {
    let spy = SinkSpy()
    let gate = Gate()
    let capture = FakeAudioCapture()
    feedChunks(capture, 1)
    let live = Box(true)
    let source = makeSource(spy: spy, vad: { GatedChunkVad(gate: gate) })
    let sid = SessionID()

    begin(source, capture: capture, sid: sid, backend: "b", live: live)
    try #require(
      await awaitSignal(gate),
      "first chunk never suspended — the test would be vacuous")

    // The full baseline subsumes the individual pre-checks: it asserts the
    // valid prep+started already fired AND that `completed` has not.
    let base = baseline(spy, backend: "b")
    try #require(
      base == MarkerBaseline(prep: 1, started: 1, completed: 0),
      "first-chunk-suspended run should hold exactly its valid prep+started")

    invalidate(source, capture, sid)

    // Recording stays LIVE across the absence window — see the preparation
    // harness: ending it here would mask the generation term.
    gate.release()
    await settleAwaitingNoLeak(spy, oldBackend: "b", baseline: base)
    #expect(
      baseline(spy, backend: "b") == base,
      "superseded run emitted after invalidation")
    live.value = false  // cleanup only, after the assertion
    return spy
  }

  @Test("configureSession silences a run suspended in first-chunk processing")
  func chunkSuspendedInvalidatedByConfigureSession() async throws {
    let spy = try await Self.assertFirstChunkSuspendedRunIsSilenced { source, capture, _ in
      source.configureSession(config: .testDefault(), audioCapture: capture)
    }
    #expect(
      spy.completed.contains { $0.backend == "b" } == false,
      "stale completed marker escaped after invalidation")
  }

  @Test("same-session startMonitoring replacement silences a first-chunk-suspended run")
  func chunkSuspendedInvalidatedByReplacement() async throws {
    // SAME SessionID: this is the test that fails if the generation guard is
    // dropped and only the session is compared.
    let spy = try await Self.assertFirstChunkSuspendedRunIsSilenced { source, _, sid in
      source.setCurrentSessionID(sid)
      source.startMonitoring(
        recordingStartTime: Date(), backend: "replacement", isRecording: { false })
    }
    #expect(
      spy.completed.contains { $0.backend == "b" } == false,
      "old generation emitted into a same-session replacement")
  }

  @Test("finalizeAtStop silences a run suspended in first-chunk processing")
  func chunkSuspendedInvalidatedByFinalize() async throws {
    let spy = SinkSpy()
    let gate = Gate()
    let capture = FakeAudioCapture()
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let cancelSeen = Gate()
    let source = Self.makeSource(
      spy: spy, vad: { GatedChunkVad(gate: gate, cancelSeen: cancelSeen) })

    Self.begin(source, capture: capture, sid: SessionID(), backend: "b", live: live)
    try #require(
      await Self.awaitSignal(gate),
      "first chunk never suspended — the test would be vacuous")

    // finalizeAtStop awaits the detector actor here, so run it concurrently and
    // wait on the fake's CANCELLATION signal — deterministic proof that
    // invalidateMonitor() ran, not a guessed number of yields.
    let finalizeTask = Task { await source.finalizeAtStop(rawSampleCount: 0) }
    try #require(
      await Self.awaitSignal(cancelSeen),
      "monitor was never cancelled — the test would be vacuous")

    // Subsumes the pre-checks: valid prep+started present, `completed` absent.
    let base = Self.baseline(spy, backend: "b")
    try #require(
      base == MarkerBaseline(prep: 1, started: 1, completed: 0),
      "first-chunk-suspended run should hold exactly its valid prep+started")
    // Recording stays LIVE across the absence window so this proves the
    // GENERATION term, not the liveness term.
    gate.release()
    _ = await finalizeTask.value
    await Self.settleAwaitingNoLeak(spy, oldBackend: "b", baseline: base)

    #expect(
      Self.baseline(spy, backend: "b") == base,
      "superseded run emitted after finalizeAtStop")
    live.value = false  // cleanup only, after the assertion
    #expect(
      spy.completed.contains { $0.backend == "b" } == false,
      "stale completed marker escaped after finalizeAtStop")
  }

  // MARK: - Terminal paths that never reach finalizeAtStop (#1780, whole-diff review)
  //
  // `RecordingSessionKernel` concludes a session through ~40 `finishTerminal`
  // sites — cancellation, capture-start failure, model wedge, capture stall,
  // ASR failure — and ONLY the normal stop path reaches `finalizeAtStop`. On all
  // the others the session id and the monitor generation are both unchanged, so
  // a session-plus-generation guard alone would let a task suspended in
  // preparation or in first-chunk processing wake up and emit into a recording
  // that has already ended. These two freeze the liveness term that closes it.

  @Test("a terminal that never calls finalizeAtStop silences a preparation-suspended run")
  func prepSuspendedSilencedByRecordingEnding() async throws {
    let spy = SinkSpy()
    let gate = Gate()
    let capture = FakeAudioCapture()
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let source = Self.makeGatedPrepSource(spy: spy, gate: gate)

    Self.begin(source, capture: capture, sid: SessionID(), backend: "b", live: live)
    try #require(
      await Self.awaitSignal(gate),
      "preparation never suspended — the test would be vacuous")

    let base = Self.baseline(spy, backend: "b")
    try #require(
      base == MarkerBaseline(),
      "preparation-suspended run should hold no markers yet")

    // The ONLY thing that happens is the recording ending. No configureSession,
    // no new SessionID, no startMonitoring replacement, no finalizeAtStop —
    // exactly what a cancel or a capture-start failure looks like to this source.
    live.value = false

    gate.release()
    await Self.settleAwaitingNoLeak(spy, oldBackend: "b", baseline: base)

    #expect(
      Self.baseline(spy, backend: "b") == base,
      "a concluded recording still emitted a preparation marker")
  }

  @Test("a terminal that never calls finalizeAtStop silences a first-chunk-suspended run")
  func chunkSuspendedSilencedByRecordingEnding() async throws {
    let spy = SinkSpy()
    let gate = Gate()
    let capture = FakeAudioCapture()
    Self.feedChunks(capture, 1)
    let live = Box(true)
    let source = Self.makeSource(spy: spy, vad: { GatedChunkVad(gate: gate) })

    Self.begin(source, capture: capture, sid: SessionID(), backend: "b", live: live)
    try #require(
      await Self.awaitSignal(gate),
      "first chunk never suspended — the test would be vacuous")

    let base = Self.baseline(spy, backend: "b")
    try #require(
      base == MarkerBaseline(prep: 1, started: 1, completed: 0),
      "first-chunk-suspended run should hold exactly its valid prep+started")

    live.value = false

    gate.release()
    await Self.settleAwaitingNoLeak(spy, oldBackend: "b", baseline: base)

    #expect(
      Self.baseline(spy, backend: "b") == base,
      "a concluded recording still emitted a first-chunk completion marker")
  }

}
