import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelEngineHookCallSitesTests (epic #827, PR-5 Rung 2B)
//
// Asserts the kernel calls each of the three optional adapter hooks at the
// expected lifecycle moment with the expected count, lifecycle order, and
// argument values:
//   1. `cancelPendingUnload()` — in `preWarm()` and in `runForwardPath`
//      pre-`beginSession()` (idempotent per Rung 2A §4).
//   2. `warmUpFromCache()` — in `preWarm()` between `cancelPendingUnload()`
//      and the spawned `warmUp()`; awaited inline with `try?`.
//   3. `observeSpeechSegments(_:)` — in `runForwardPath` between VAD finalize
//      and `CapturedAudioConditioner.condition`, with the kernel's selected
//      `vadSegments` array verbatim.
//
// Twelve `@Test`s cover: counts (×2), event-trace lifecycle order (×3),
// VAD-source-precedence branches (×2), guard short-circuit (×1), cancel
// before VAD-finalize (×1), cache-preload failure-bypass (×1),
// post-await reentrancy guard (×1), and the single-preWarm baseline (×1).

@MainActor
@Suite("RecordingSessionKernel — optional adapter hook call sites (PR-5 Rung 2B)")
struct KernelEngineHookCallSitesTests {

  // MARK: Fixture

  @MainActor
  private struct Fixture {
    let context: SimulatorContext
    let wrapper: KernelRecordingSession

    var engine: FakeEngine { context.engine }
    var capture: FakeAudioCapture { context.capture }
    var vad: FakeVADSignalSource { context.vad }
    var clock: FakeClock { context.clock }
    var kernel: RecordingSessionKernel { wrapper.testKernel }
  }

  private func makeFixture(
    behavior: FakeEngineBehavior = .batchSuccess(text: "hello")
  ) -> Fixture {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    let context = SimulatorContext(
      sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return Fixture(context: context, wrapper: wrapper)
  }

  /// Drive the kernel through a complete PTT-mode session (preWarm + start +
  /// deliver one buffer + stop) and settle. The default `.batchSuccess`
  /// behavior produces a transcript so the kernel reaches `.completed`.
  /// `xpcSegments` (when non-empty) are added AFTER `beginCapturePhase` has
  /// run — FakeAudioCapture clears its segments at session boundary, so
  /// segments must be added between start and stop.
  private func driveCompletePTTSession(
    _ fx: Fixture, xpcSegments: [SpeechSegment]? = nil
  ) async {
    try? await fx.kernel.preWarm()
    await fx.wrapper.drainReadyWork()
    fx.kernel.start(config: .testDefault())
    await fx.wrapper.drainReadyWork()
    let segments = xpcSegments ?? [SpeechSegment(startSample: 0, endSample: 100)]
    for seg in segments {
      fx.capture.addSpeechSegment(
        startSample: seg.startSample, endSample: seg.endSample)
    }
    fx.capture.deliverBuffer()
    await fx.wrapper.drainReadyWork()
    fx.kernel.requestStop()
    await fx.wrapper.drainReadyWork()
  }

  /// Drive the kernel through a complete toggle-mode session (start + deliver
  /// one buffer + stop, no preWarm).
  private func driveCompleteToggleSession(
    _ fx: Fixture, xpcSegments: [SpeechSegment]? = nil
  ) async {
    fx.kernel.start(config: .testDefault())
    await fx.wrapper.drainReadyWork()
    let segments = xpcSegments ?? [SpeechSegment(startSample: 0, endSample: 100)]
    for seg in segments {
      fx.capture.addSpeechSegment(
        startSample: seg.startSample, endSample: seg.endSample)
    }
    fx.capture.deliverBuffer()
    await fx.wrapper.drainReadyWork()
    fx.kernel.requestStop()
    await fx.wrapper.drainReadyWork()
  }

  // MARK: 1. preWarm fires warmUpFromCache once and NOT cancelPendingUnload

  @Test("preWarm fires warmUpFromCache once and does not fire cancelPendingUnload")
  func preWarmFiresWarmUpFromCacheOnceAndNotCancelPendingUnload() async throws {
    let fx = makeFixture()
    try await fx.kernel.preWarm()
    await fx.wrapper.drainReadyWork()
    // Codex code-diff r3 P2: the preWarm-side cancelPendingUnload was
    // dropped — cancelling the idle-unload timer here would leak a loaded
    // model when PTT is abandoned (no terminal fires to re-apply the
    // unload policy).
    #expect(fx.engine.cancelPendingUnloadCallCount == 0)
    #expect(fx.engine.warmUpFromCacheCallCount == 1)
  }

  // MARK: 2. preWarm event-trace lifecycle order

  @Test("preWarm emits warmUpFromCache, then the spawned warmUp")
  func preWarmEventTraceIsCacheThenWarm() async throws {
    let fx = makeFixture()
    try await fx.kernel.preWarm()
    await fx.wrapper.drainReadyWork()
    // The spawned warmUp() may interleave with the await; the canonical
    // ordering is: warmUpFromCache await (instant on FakeEngine), then the
    // spawned warmUp(). The first two events observed on the engine MUST
    // be those two, in that order. No cancelPendingUnload from preWarm
    // (Codex r3 P2).
    let firstTwo = Array(fx.engine.eventLog.prefix(2))
    #expect(
      firstTwo == [.warmUpFromCache, .warmUp],
      "expected [warmUpFromCache, warmUp]; got \(firstTwo)")
  }

  // MARK: 3. runForwardPath emits cancelPendingUnload before beginSession

  @Test("runForwardPath emits cancelPendingUnload strictly before beginSession")
  func runForwardPathEventTraceCancelBeforeBeginSession() async throws {
    let fx = makeFixture()
    await driveCompleteToggleSession(fx)
    // No preWarm; the toggle-mode path is the only source of
    // cancelPendingUnload events.
    let log = fx.engine.eventLog
    guard let cancelIdx = log.firstIndex(of: .cancelPendingUnload) else {
      Issue.record("expected a .cancelPendingUnload event; got \(log)")
      return
    }
    guard let beginIdx = log.firstIndex(of: .beginSession) else {
      Issue.record("expected a .beginSession event; got \(log)")
      return
    }
    #expect(
      cancelIdx < beginIdx,
      "cancelPendingUnload must precede beginSession; got cancelIdx=\(cancelIdx) beginIdx=\(beginIdx)"
    )
  }

  // MARK: 4. runForwardPath emits observeSpeechSegments before finalize

  @Test("runForwardPath emits observeSpeechSegments strictly before finalize")
  func runForwardPathEventTraceObserveBeforeFinalize() async throws {
    let fx = makeFixture()
    await driveCompleteToggleSession(fx)
    let log = fx.engine.eventLog
    guard
      let observeIdx = log.firstIndex(where: {
        if case .observeSpeechSegments = $0 { return true } else { return false }
      })
    else {
      Issue.record("expected an .observeSpeechSegments event; got \(log)")
      return
    }
    guard let finalizeIdx = log.firstIndex(of: .finalize) else {
      Issue.record("expected a .finalize event; got \(log)")
      return
    }
    #expect(
      observeIdx < finalizeIdx,
      "observeSpeechSegments must precede finalize; got observeIdx=\(observeIdx) finalizeIdx=\(finalizeIdx)"
    )
  }

  // MARK: 5. Full PTT-mode session — expected counts

  @Test("PTT-mode session fires expected hook counts (1 cancel + 1 cache + 1 observe)")
  func preWarmAndRunFireExpectedHookCounts() async throws {
    let fx = makeFixture()
    await driveCompletePTTSession(fx)
    #expect(
      fx.engine.cancelPendingUnloadCallCount == 1,
      "expected 1 cancelPendingUnload (runForwardPath only — Codex r3 P2 dropped the preWarm-side call); got \(fx.engine.cancelPendingUnloadCallCount)"
    )
    #expect(
      fx.engine.warmUpFromCacheCallCount == 1,
      "expected 1 warmUpFromCache (preWarm only); got \(fx.engine.warmUpFromCacheCallCount)")
    #expect(
      fx.engine.observeSpeechSegmentsCallCount == 1,
      "expected 1 observeSpeechSegments (runForwardPath only); got \(fx.engine.observeSpeechSegmentsCallCount)"
    )
  }

  // MARK: 6. Toggle-mode session — only runForwardPath hooks fire

  @Test("toggle-mode session fires only runForwardPath hooks (1 cancel + 0 cache + 1 observe)")
  func toggleModeFiresOnlyRunForwardPathHooks() async throws {
    let fx = makeFixture()
    await driveCompleteToggleSession(fx)
    #expect(
      fx.engine.cancelPendingUnloadCallCount == 1,
      "expected 1 cancelPendingUnload (runForwardPath only); got \(fx.engine.cancelPendingUnloadCallCount)"
    )
    #expect(
      fx.engine.warmUpFromCacheCallCount == 0,
      "expected 0 warmUpFromCache (no preWarm); got \(fx.engine.warmUpFromCacheCallCount)")
    #expect(
      fx.engine.observeSpeechSegmentsCallCount == 1,
      "expected 1 observeSpeechSegments (runForwardPath only); got \(fx.engine.observeSpeechSegmentsCallCount)"
    )
  }

  // MARK: 7. observeSpeechSegments XPC-branch source

  @Test("observeSpeechSegments receives the XPC-bundled segments when non-empty")
  func observeSpeechSegmentsPassesKernelComputedSegmentsXPCBranch() async throws {
    let fx = makeFixture()
    // Two XPC-bundled segments populated on FakeAudioCapture; the kernel's
    // selection at line 990 prefers `captureResult.vadSegments` when
    // non-empty.
    let xpcSegments = [
      SpeechSegment(startSample: 0, endSample: 100),
      SpeechSegment(startSample: 200, endSample: 300),
    ]
    // Seed the fallback path with DIFFERENT segments so a regression that
    // reads the fallback instead of the XPC bundle would be caught.
    fx.vad.segments = [SpeechSegment(startSample: 999, endSample: 1000)]
    await driveCompleteToggleSession(fx, xpcSegments: xpcSegments)
    let observed = try #require(fx.engine.lastObservedSpeechSegments)
    let observedPairs = observed.map { ($0.startSample, $0.endSample) }
    let expectedPairs = xpcSegments.map { ($0.startSample, $0.endSample) }
    #expect(
      observedPairs.elementsEqual(expectedPairs, by: ==),
      "expected XPC-bundled segments \(expectedPairs); got \(observedPairs)")
  }

  // MARK: 8. observeSpeechSegments fallback-branch source

  @Test("observeSpeechSegments receives the vad seam segments when XPC bundle is empty")
  func observeSpeechSegmentsPassesKernelComputedSegmentsFallbackBranch() async throws {
    let fx = makeFixture()
    // FakeAudioCapture left empty -> XPC bundle is empty -> kernel falls
    // back to `vad.speechSegmentsAtStop()`.
    let fallbackSegments = [
      SpeechSegment(startSample: 50, endSample: 150),
      SpeechSegment(startSample: 250, endSample: 350),
    ]
    fx.vad.segments = fallbackSegments
    // XPC bundle stays empty -> kernel falls back to vad seam.
    await driveCompleteToggleSession(fx, xpcSegments: [])
    let observed = try #require(fx.engine.lastObservedSpeechSegments)
    let observedPairs = observed.map { ($0.startSample, $0.endSample) }
    let expectedPairs = fallbackSegments.map { ($0.startSample, $0.endSample) }
    #expect(
      observedPairs.elementsEqual(expectedPairs, by: ==),
      "expected fallback (vad seam) segments \(expectedPairs); got \(observedPairs)")
  }

  // MARK: 9. preWarm guarded out by active session — no hooks fire

  @Test("preWarm guarded out while recording fires no hooks")
  func preWarmGuardedOutFiresNoHooks() async throws {
    let fx = makeFixture()
    fx.kernel.start(config: .testDefault())
    await fx.wrapper.drainReadyWork()
    // Snapshot counters just before the guarded-out preWarm.
    let cancelBefore = fx.engine.cancelPendingUnloadCallCount
    let cacheBefore = fx.engine.warmUpFromCacheCallCount
    try await fx.kernel.preWarm()
    await fx.wrapper.drainReadyWork()
    #expect(
      fx.engine.cancelPendingUnloadCallCount == cancelBefore,
      "preWarm guarded out at active session must not fire cancelPendingUnload")
    #expect(
      fx.engine.warmUpFromCacheCallCount == cacheBefore,
      "preWarm guarded out at active session must not fire warmUpFromCache")
  }

  // MARK: 10. cancel before VAD-finalize skips observeSpeechSegments

  @Test("cancel before VAD-finalize phase skips observeSpeechSegments")
  func cancelMidWarmupSkipsObserveSpeechSegments() async throws {
    let fx = makeFixture()
    fx.kernel.start(config: .testDefault())
    await fx.wrapper.drainReadyWork()
    fx.kernel.cancel()
    await fx.wrapper.drainReadyWork()
    #expect(
      fx.engine.observeSpeechSegmentsCallCount == 0,
      "cancelled session must not reach observeSpeechSegments; got \(fx.engine.observeSpeechSegmentsCallCount)"
    )
  }

  // MARK: 11. warmUpFromCache throws does not block warmUp or recording

  @Test("warmUpFromCache throwing does not block the spawned warmUp or recording")
  func warmUpFromCacheThrowsDoesNotBlockWarmUpOrRecording() async throws {
    let fx = makeFixture()
    fx.engine.warmUpFromCacheThrows = true
    // preWarm must not throw — the kernel's `try?` swallows it.
    try await fx.kernel.preWarm()
    await fx.wrapper.drainReadyWork()
    #expect(
      fx.engine.warmUpFromCacheCallCount == 1,
      "warmUpFromCache must still have been called once")
    #expect(
      fx.engine.warmUpCallCount >= 1,
      "spawned warmUp() must still have run despite cache-preload throw")
    // The session must still complete normally.
    await driveCompleteToggleSession(fx)
    #expect(
      fx.kernel.deliveredTranscript == "hello",
      "recording must still deliver the transcript despite cache-preload throw")
  }

  // MARK: 12. preWarm post-await reentrancy guard

  @Test("preWarm post-await reentrancy guard aborts the stale continuation")
  func preWarmPostAwaitReentrancyGuardAbortsStaleContinuation() async throws {
    let fx = makeFixture()
    fx.engine.blockWarmUpFromCache = true
    // Capture the sid preWarm will hold; the guard checks against this.
    let staleSID = fx.kernel.currentSessionID
    // Spawn preWarm so it parks on warmUpFromCache.
    let preWarmTask = Task { @MainActor in
      try? await fx.kernel.preWarm()
    }
    // Signal-wait until the engine has entered warmUpFromCache (it then parks
    // on the blocker), rather than racing a fixed yield budget (#875).
    await fx.engine.waitForWarmUpFromCacheCount(1)
    #expect(
      fx.engine.warmUpFromCacheCallCount >= 1,
      "FakeEngine.warmUpFromCache must have been entered")
    // While preWarm is parked, mint a new session via start() — this bumps
    // the kernel's currentSessionID off staleSID and transitions state out
    // of .idle. The post-await guard MUST see this and short-circuit.
    fx.kernel.start(config: .testDefault())
    #expect(
      fx.kernel.currentSessionID != staleSID,
      "start() should have minted a fresh SessionID")
    // Release the cache-warm continuation so preWarm can resume.
    fx.engine.releaseWarmUpFromCacheBlocker()
    _ = await preWarmTask.value
    // Cancel the in-flight session to settle the kernel.
    fx.kernel.cancel()
    await fx.wrapper.drainReadyWork()
    // The stale preWarm continuation must not have crashed and must not
    // have driven the engine into an inconsistent state. The new session
    // owns whatever subsequent calls the engine recorded.
    #expect(
      fx.engine.warmUpFromCacheCallCount == 1,
      "warmUpFromCache must have been called exactly once (preWarm only)")
    // The new session called beginSession; ensure preWarm's stale
    // continuation did NOT race into the new session's lifecycle and
    // double-fire beginSession.
    #expect(
      fx.engine.beginSessionCallCount <= 1,
      "stale preWarm continuation must not double-fire beginSession; got \(fx.engine.beginSessionCallCount)"
    )
  }
}
