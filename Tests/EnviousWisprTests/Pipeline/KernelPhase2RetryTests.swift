import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

// MARK: - #1707 Phase 2 — one live post-capture decode retry (kernel routing)
//
// Drives the REAL `RecordingSessionKernel` through the simulator fakes.
// `FakeEngine.crashOnFinalize` scripts the first decode attempt to fail
// (`.failed(.engineCrashed)`); `retryDecodeResult`/`retryDecodeDelayTicks`
// script the Phase-2 retry's own outcome and timing. Assertions cover the
// retry gate, telemetry, the pre-capture exclusion, Phase-1 composition, and
// the kernel-level staleness guard against a late-arriving abandoned retry.

@MainActor
@Suite("RecordingSessionKernel — Phase 2 post-capture decode retry (#1707)")
struct KernelPhase2RetryTests {

  private struct Context {
    let wrapper: KernelRecordingSession
    let engine: FakeEngine
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
    let paste: FakePasteTarget
    let clock: FakeClock
  }

  private func makeContext(behavior: FakeEngineBehavior) -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return Context(
      wrapper: wrapper, engine: engine, capture: capture, vad: vad, paste: paste, clock: clock)
  }

  private func deliverVoicedCapture(_ ctx: Context) {
    ctx.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
  }

  /// #1857: the post-`stop` wait is on the kernel's own conclusion signal, not
  /// on epoch quiescence — a resumed-but-unscheduled continuation could settle
  /// the epoch while the session was still in flight, so every terminal
  /// assertion read `nil` (`retryRescuedCompletionSurvivesClipboardFallback`,
  /// one failure in 4344 tests, never reproducible on demand).
  ///
  /// `awaitTerminal: false` is for the one scenario whose terminal is published
  /// by a REAL wall-clock deadline the fake clock never advances. Yields alone
  /// can never satisfy that, so it keeps its own declared deadline poll.
  private func runToTerminal(_ ctx: Context, awaitTerminal: Bool = true) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    // #1548 D1: the first converted buffer flips Arming -> Live via an async
    // @MainActor hop — drain so the commit lands before stop.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    if awaitTerminal {
      await ctx.wrapper.drainUntilConcluded()
    } else {
      await ctx.wrapper.drainReadyWork()
    }
  }

  /// #1755 chunk 3 helper: stop with the held finalize suspended, await the
  /// fake's registration signal (never scheduler timing), and return once the
  /// kernel is genuinely parked in `.delivering(.transcribing)`.
  private func stopIntoHeldFinalize(_ ctx: Context) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    var pendingSignal: CheckedContinuation<Void, Never>?
    ctx.engine.onHeldFinalizePending = { pendingSignal?.resume() }
    await ctx.wrapper.apply(.stop)
    if !ctx.engine.heldFinalizePending {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        pendingSignal = c
        if ctx.engine.heldFinalizePending { c.resume() }
      }
    }
    ctx.engine.onHeldFinalizePending = nil
  }

  // MARK: #1755 chunk 3 — transcribe-phase helper death enters the SAME retry

  @Test(
    "helper death mid-decode routes into the one Phase-2 retry, and a successful retry delivers")
  func helperDeathMidDecodeRetriesAndDelivers() async {
    let ctx = makeContext(behavior: .heldFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued after death", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    await stopIntoHeldFinalize(ctx)
    let kernel = ctx.wrapper.testKernel
    #expect(ctx.engine.heldFinalizePending, "the initial finalize must be genuinely suspended")
    #expect(ctx.engine.finalizeCallCount == 1)

    // Helper death arrives while the decode is suspended.
    // #1908: `kernel.externalASRInterrupted()` (the App-routed XPC-crash
    // entry point) was deleted along with the XPC path it bridged; drive the
    // SAME `routeASRInterruption(sid:)` internal path through its other live
    // production caller instead — `adapter.onEngineInterrupted`
    // (`RecordingSessionKernel.bindCaptureCallbacks`), which `FakeEngine`
    // exposes via `fireEngineInterrupted()` for exactly this purpose.
    ctx.engine.fireEngineInterrupted()
    await ctx.wrapper.drainReadyWork()

    // No early terminal: the session keeps waiting for its own decode to fail.
    #expect(kernel.recordingOutcome == nil, "no terminal may be published before finalize resolves")
    #expect(kernel.state == .delivering)
    #expect(kernel.deliveringPhase == .transcribing)
    #expect(ctx.engine.retryDecodeCallCount == 0, "the retry must not start early")

    // Chunk 1's drained continuation: the suspended decode now fails.
    ctx.engine.resolveHeldFinalizeAsHelperDeath()
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.engine.finalizeCallCount == 1, "the initial decode ran exactly once")
    #expect(
      ctx.engine.recoverFromASRInterruptionCallCount == 0,
      "this is NOT the .live Phase-1 rewarm path")
    #expect(ctx.engine.retryDecodeCallCount == 1, "exactly one Phase-2 retry")
    #expect(
      !(ctx.engine.lastRetryDecodeInputSamples?.isEmpty ?? true),
      "the retry decodes the captured audio, not an empty buffer")
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .retrySucceeded)
    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "rescued after death")
    #expect(ctx.wrapper.storedTexts == ["rescued after death"])
    #expect(ctx.paste.pasteAttempts == ["rescued after death"])
    #expect(ctx.paste.pasteCount == 1)
    #expect(kernel.recordingOutcome != .asrInterrupted(wasRecording: false))
  }

  @Test(
    "helper death mid-decode with an exhausted retry ends .asrFailed and projects .asrRetryExhausted"
  )
  func helperDeathMidDecodeExhaustsOnce() async {
    let ctx = makeContext(behavior: .heldFinalize)
    ctx.engine.retryDecodeResult = .failed(.decodeFailed)
    await stopIntoHeldFinalize(ctx)
    let kernel = ctx.wrapper.testKernel
    #expect(ctx.engine.heldFinalizePending, "the initial finalize must be genuinely suspended")

    // #1908: `kernel.externalASRInterrupted()` (the App-routed XPC-crash
    // entry point) was deleted along with the XPC path it bridged; drive the
    // SAME `routeASRInterruption(sid:)` internal path through its other live
    // production caller instead — `adapter.onEngineInterrupted`
    // (`RecordingSessionKernel.bindCaptureCallbacks`), which `FakeEngine`
    // exposes via `fireEngineInterrupted()` for exactly this purpose.
    ctx.engine.fireEngineInterrupted()
    await ctx.wrapper.drainReadyWork()
    #expect(kernel.recordingOutcome == nil, "no terminal may be published before finalize resolves")
    #expect(kernel.state == .delivering)
    #expect(kernel.deliveringPhase == .transcribing)
    #expect(ctx.engine.retryDecodeCallCount == 0)

    ctx.engine.resolveHeldFinalizeAsHelperDeath()
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(ctx.engine.recoverFromASRInterruptionCallCount == 0)
    #expect(ctx.engine.retryDecodeCallCount == 1, "one retry, no second budget")
    #expect(!(ctx.engine.lastRetryDecodeInputSamples?.isEmpty ?? true))
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .retryExhausted)
    #expect(kernel.recordingOutcome == .failed(.asrFailed))
    #expect(
      KernelDictationDriver.recoveryEnding(for: .failed(.asrFailed), retryOutcome: .retryExhausted)
        == .asrRetryExhausted)
    #expect(ctx.wrapper.storedTexts.isEmpty, "storage receives zero calls")
    #expect(ctx.paste.pasteAttempts.isEmpty, "the delivery seam is never called")
    #expect(kernel.deliveredTranscript == nil)
    #expect(kernel.pasteCount == 0)
  }

  #if DEBUG
    // MARK: - #1755 chunk 6 — crash-boundary hook lockstep (kernel side)

    private static func makeIsolatedBoundaryController() -> CrashBoundaryFaultController {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-cb-kernel-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return CrashBoundaryFaultController(
        armFilePath: dir.appendingPathComponent("arm").path,
        reachedFilePath: dir.appendingPathComponent("reached").path)
    }

    /// Snapshot box the publication callback (fires on the hook's own thread,
    /// before the park) writes into; the callback releases the hold immediately
    /// so the flow completes — deterministic, no polling.
    private final class BoundarySnapshot: @unchecked Sendable {
      private let lock = NSLock()
      private var _fired = 0
      private var _outcomeWasNil: Bool?
      var fired: Int { lock.withLock { _fired } }
      var outcomeWasNil: Bool? { lock.withLock { _outcomeWasNil } }
      func record(outcomeWasNil: Bool) {
        lock.withLock {
          _fired += 1
          if _outcomeWasNil == nil { _outcomeWasNil = outcomeWasNil }
        }
      }
    }

    @Test("retry_exhaustion_decided fires after the diagnostic stamp, before terminal publication")
    func retryExhaustionBoundaryHook() async {
      let ctx = makeContext(behavior: .crashOnFinalize)
      ctx.engine.retryDecodeResult = .failed(.decodeFailed)
      let controller = Self.makeIsolatedBoundaryController()
      ctx.wrapper.testKernel.crashBoundaryController = controller
      defer { controller.clear() }
      let snapshot = BoundarySnapshot()
      let kernel = ctx.wrapper.testKernel
      controller.onPublishForTesting = { _ in
        // The hook fires on the kernel's MainActor context, synchronously.
        MainActor.assumeIsolated {
          snapshot.record(outcomeWasNil: kernel.recordingOutcome == nil)
        }
        controller.releaseHeldForTesting()
      }
      #expect(controller.arm(trialID: "kb1", boundary: .retryExhaustionDecided))

      await runToTerminal(ctx)

      #expect(snapshot.fired == 1, "the boundary published exactly once")
      #expect(
        snapshot.outcomeWasNil == true,
        "at the boundary the terminal was NOT yet published (hook sits before finishTerminal)")
      #expect(controller.isReached(trialID: "kb1", boundary: .retryExhaustionDecided))
      #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .retryExhausted, "after the stamp")
      #expect(kernel.recordingOutcome == .failed(.asrFailed))
    }

    @Test("live_terminal_published fires exactly once, after the set-once outcome write")
    func liveTerminalBoundaryHook() async {
      let ctx = makeContext(behavior: .batchSuccess(text: "hello"))
      let controller = Self.makeIsolatedBoundaryController()
      ctx.wrapper.testKernel.crashBoundaryController = controller
      defer { controller.clear() }
      let snapshot = BoundarySnapshot()
      let kernel = ctx.wrapper.testKernel
      controller.onPublishForTesting = { _ in
        MainActor.assumeIsolated {
          snapshot.record(outcomeWasNil: kernel.recordingOutcome == nil)
        }
        controller.releaseHeldForTesting()
      }
      #expect(controller.arm(trialID: "kb2", boundary: .liveTerminalPublished))

      await runToTerminal(ctx)

      #expect(snapshot.fired == 1, "one-shot: fired exactly once")
      #expect(
        snapshot.outcomeWasNil == false,
        "at the boundary recordingOutcome was ALREADY set (hook sits after the set-once write)")
      #expect(controller.isReached(trialID: "kb2", boundary: .liveTerminalPublished))
      #expect(!controller.hasLiveArmForTesting, "consumed exactly once")
    }

    @Test("unarmed sessions retain the exact pre-chunk behavior and never block")
    func unarmedBoundaryControllerIsInert() async {
      let ctx = makeContext(behavior: .batchSuccess(text: "hello"))
      ctx.wrapper.testKernel.crashBoundaryController = Self.makeIsolatedBoundaryController()
      await runToTerminal(ctx)
      #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
      #expect(ctx.paste.pasteCount == 1)
    }

  #endif

  @Test("a decode failure spends exactly one retry, and a successful retry delivers its own text")
  func decodeFailureRetriesOnceAndDelivers() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued text", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "rescued text")
    #expect(kernel.pasteCount == 1)
    #expect(ctx.engine.retryDecodeCallCount == 1)
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .retrySucceeded)
  }

  @Test("an exhausted retry still terminates as .asrFailed and spends exactly one retry")
  func exhaustedRetryStillFailsOnce() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .failed(.decodeFailed)
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.recordingOutcome == .failed(.asrFailed))
    #expect(kernel.deliveredTranscript == nil)
    #expect(kernel.pasteCount == 0)
    #expect(ctx.engine.retryDecodeCallCount == 1)
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .retryExhausted)
  }

  @Test(
    "#1755 founder override: a retry that resolves .cancelled still terminates .asrFailed, stays diagnostically .attempted, and now DELETES"
  )
  func cancelledRetryTerminatesAndDeletes() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .cancelled
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.recordingOutcome == .failed(.asrFailed))
    #expect(kernel.deliveredTranscript == nil)
    #expect(ctx.wrapper.storedTexts.isEmpty)
    #expect(ctx.paste.pasteAttempts.isEmpty)
    #expect(ctx.engine.retryDecodeCallCount == 1, "retry budget unchanged: exactly one")
    // `.attempted` remains the honest diagnostic that no decode conclusion
    // was accepted (late-result fencing unchanged); the founder's Gate 2
    // decision makes the DISPOSITION delete anyway — the user watched the
    // retry fail and re-dictates.
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .attempted)
    let ending = KernelDictationDriver.recoveryEnding(
      for: .failed(.asrFailed), retryOutcome: .attempted)
    #expect(ending == .failed, "projects to plain .failed")
    #expect(
      RecoveryCoordinator.shouldDeleteOnLiveEnding(.failed),
      "#1755: the composed authorities delete")
  }

  @Test(
    "#1755 founder override: a retry that times out still terminates .asrFailed, stays diagnostically .attempted, and now DELETES"
  )
  func timedOutRetryTerminatesAndDeletes() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    // A real, tiny wall-clock deadline — the retry never resolves within it
    // (the fake-clock delay is never advanced during this test), so
    // `withMainActorOrderedDeadline`'s `onTimeout` fires for real.
    ctx.engine.retryDecodeTimeoutSeconds = 0.05
    ctx.engine.retryDecodeDelayTicks = 1
    // #1857: the ONLY caller that opts out of the conclusion wait. This
    // terminal is published by the real 50ms deadline above, which no number
    // of `Task.yield()`s can advance, so a yield-only wait would exhaust the
    // livelock cap and report a false give-up.
    await runToTerminal(ctx, awaitTerminal: false)
    let kernel = ctx.wrapper.testKernel

    // `drainReadyWork()`'s epoch-stability heuristic settles immediately
    // here since nothing in the kernel produces work while it awaits a REAL
    // wall-clock sleep — poll the real signal (recordingOutcome actually
    // publishing) instead, bounded well past the 50ms deadline configured
    // above.
    for _ in 0..<200 where kernel.recordingOutcome == nil {
      try? await Task.sleep(for: .milliseconds(5))  // settle: poll recordingOutcome around the real 50ms deadline configured above
    }

    #expect(kernel.recordingOutcome == .failed(.asrFailed))
    #expect(kernel.deliveredTranscript == nil)
    #expect(ctx.wrapper.storedTexts.isEmpty, "zero storage")
    #expect(ctx.paste.pasteAttempts.isEmpty, "zero delivery")
    #expect(kernel.pasteCount == 0, "zero paste")
    #expect(ctx.engine.retryDecodeCallCount == 1, "exactly one retry, no second budget")
    #expect(ctx.engine.bumpRetryGenerationCallCount == 1, "late-result fencing unchanged")
    // `.attempted` (not .retryExhausted) remains the honest diagnostic: we
    // stopped waiting, no conclusion was accepted. The founder's Gate 2
    // decision deletes anyway — the visible live rescue failed.
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .attempted)
    let ending = KernelDictationDriver.recoveryEnding(
      for: .failed(.asrFailed), retryOutcome: .attempted)
    #expect(ending == .failed, "projects to plain .failed")
    #expect(
      RecoveryCoordinator.shouldDeleteOnLiveEnding(.failed),
      "#1755: the composed authorities delete")
  }

  @Test(
    "retry succeeds but polish then empties the result -> falls through to the noSpeech empty path")
  func retrySucceedsThenPolishEmpties() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued text", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    ctx.wrapper.testForceEmptyAfterProcessing()
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.recordingOutcome.kind == .noSpeech)
    #expect(kernel.deliveredTranscript == nil)
    #expect(kernel.pasteCount == 0)
    // The retry itself still ran and was accepted — polish is what collapsed
    // the result, not the decode.
    #expect(ctx.engine.retryDecodeCallCount == 1)
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .retrySucceeded)
  }

  @Test("a pre-capture load failure never consults the Phase-2 retry at all")
  func preCaptureFailureNeverConsultsRetry() async {
    let ctx = makeContext(behavior: .failLoad(ASREngineError.loadFailed))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainUntilConcluded()
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.recordingOutcome == .failed(.modelLoadFailed))
    #expect(ctx.engine.retryDecodeCallCount == 0)
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == nil)
  }

  @Test(
    "#1707 Phase 1 ∘ Phase 2 composition: an interruption-recovered decode that then fails gets exactly one Phase-2 retry, not a second budget"
  )
  func phase1RecoveredSessionGetsExactlyOnePhase2Retry() async {
    // The session starts streaming (config default; the fake reports
    // `supportsStreaming` for `.streamingSuccess`).
    let ctx = makeContext(behavior: .streamingSuccess(partials: ["hel"], final: "hello"))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    let kernel = ctx.wrapper.testKernel
    #expect(kernel.isStreamingSession, "precondition: this session must start streaming")

    // The XPC helper crashes mid-recording. Recovery (FakeEngine's default
    // `.readyForBatchDecode`) forces the decode down the batch path, scripted
    // here to fail (an engine crash) — Phase 2's own retry must engage
    // exactly once on top of this Phase-1 recovery, not stack a second
    // parallel retry budget.
    ctx.engine.behavior = .crashOnFinalize
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued after recovery", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    // #1908: `kernel.externalASRInterrupted()` (the App-routed XPC-crash
    // entry point) was deleted along with the XPC path it bridged; drive the
    // SAME `routeASRInterruption(sid:)` internal path through its other live
    // production caller instead — `adapter.onEngineInterrupted`
    // (`RecordingSessionKernel.bindCaptureCallbacks`), which `FakeEngine`
    // exposes via `fireEngineInterrupted()` for exactly this purpose.
    ctx.engine.fireEngineInterrupted()
    await ctx.wrapper.drainUntilConcluded()

    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "rescued after recovery")
    // Exactly one finalize (the recovery-forced batch decode) and exactly one
    // Phase-2 retry on top of it — never two retry budgets.
    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(ctx.engine.retryDecodeCallCount == 1)
  }

  @Test(
    "a retry that resolves after a NEW session has already started does not corrupt the new session"
  )
  func lateAbandonedRetryDoesNotCorruptNewSession() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    // Park the retry on the fake clock — it will not resolve until this test
    // explicitly advances it, regardless of any real-wall-clock deadline or
    // outer task cancellation (FakeClock.sleep never checks cancellation).
    ctx.engine.retryDecodeDelayTicks = 3
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "stale retry text", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
    let kernel = ctx.wrapper.testKernel

    // Session A's retry is in flight (parked), so A has not concluded yet.
    #expect(ctx.engine.retryDecodeCallCount == 1)
    #expect(kernel.recordingOutcome == nil, "session A must still be in-flight (retry pending)")

    // A superseding user action concludes session A while its retry is
    // still parked — mirrors the kernel's own documented "Concurrent" class
    // (§5): a cancel landing while the retry awaits.
    kernel.cancel()
    await ctx.wrapper.drainUntilConcluded()
    #expect(kernel.recordingOutcome == .cancelled)

    // Session B starts and completes normally before A's abandoned retry
    // ever resolves.
    ctx.engine.behavior = .batchSuccess(text: "session B text")
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()
    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "session B text")

    // NOW let A's abandoned retry finally resolve. The kernel's own
    // `isCurrent(sid)` guard must drop it without touching B's state.
    ctx.clock.advance(by: 3)
    await ctx.wrapper.drainReadyWork()
    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "session B text")
    #expect(kernel.pasteCount == 1)
  }

  @Test(
    "a retry-rescued completion stamps the SAME accepted-transcript telemetry as a first-attempt success"
  )
  func retrySuccessTelemetryUsesSharedHelper() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued telemetry text", language: "en", duration: 1.5, processingTime: 0.4,
        backendType: .parakeet))
    await runToTerminal(ctx)

    let completed = ctx.wrapper.telemetryState.asrCompletedTelemetry
    #expect(completed?.mode == "batch")
    #expect(completed?.language == "en")
    #expect(completed?.charCount == "rescued telemetry text".count)
    #expect(completed?.durationSeconds == 0.4)
  }

  // MARK: Completion-owner validation cases (§11.2)

  @Test(
    "a retry-rescued completion whose History save fails still completes exactly once and delivers")
  func retryRescuedCompletionSurvivesStorageFailure() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued text", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    ctx.wrapper.inject(.storageWriteFails)
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    // #1167: the store failure is best-effort absorbed — the kernel still
    // proceeds to deliver, exactly one terminal, exactly one delivery.
    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "rescued text")
    #expect(kernel.pasteCount == 1)
    #expect(ctx.engine.retryDecodeCallCount == 1)
  }

  @Test(
    "a retry-rescued completion whose paste falls back to clipboard still completes exactly once")
  func retryRescuedCompletionSurvivesClipboardFallback() async {
    let ctx = makeContext(behavior: .crashOnFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued text", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    ctx.paste.shouldFailPaste = true
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.recordingOutcome == .completed)
    #expect(kernel.deliveredTranscript == "rescued text")
    #expect(kernel.deliveryOutcome == .clipboardOnly)
    // A clipboard-only delivery counts 0 real pastes (SessionEffects/kernel
    // convention — a real paste is what pasteCount tracks).
    #expect(kernel.pasteCount == 0)
    #expect(ctx.engine.retryDecodeCallCount == 1)
  }

  // MARK: - #1946 chunk 2 — the retry deadline's own observation
  //
  // The founder deferred moving the three remaining main-actor deadline call
  // sites until this path is measured, so these cases guard the measurement
  // itself. The load-bearing field is `acceptedAfterCutoff`: a decode that
  // returned past its own budget AND was accepted. An off-actor timer would
  // reject exactly those, so the count is what makes the deferred half a
  // decision with a falsification condition rather than another judgement call.
  //
  // Each case asserts what the KERNEL computed, through the kernel's own
  // observation seam. `TelemetryServiceRetryDeadlineTests` separately asserts
  // the payload that reaches PostHog, through the existing telemetry test hook.

  /// One resolved observation, exactly as the kernel handed it over.
  @MainActor
  private final class RetryDeadlineLog {
    private(set) var starts: [(takeID: String, backend: String, budgetMs: Int)] = []
    private(set) var resolutions:
      [(
        takeID: String, backend: String, budgetMs: Int,
        resolution: ASRRetryDeadlineResolution, disposition: ASRRetryDeadlineDisposition,
        operationReturnMs: Int?, callerResumeMs: Int, acceptedAfterCutoff: Bool
      )] = []

    func recordStart(_ takeID: String, _ backend: String, _ budgetMs: Int) {
      starts.append((takeID, backend, budgetMs))
    }
    func recordResolution(
      _ takeID: String, _ backend: String, _ budgetMs: Int,
      _ resolution: ASRRetryDeadlineResolution, _ disposition: ASRRetryDeadlineDisposition,
      _ operationReturnMs: Int?, _ callerResumeMs: Int, _ acceptedAfterCutoff: Bool
    ) {
      resolutions.append(
        (takeID, backend, budgetMs, resolution, disposition, operationReturnMs, callerResumeMs,
          acceptedAfterCutoff))
    }
  }

  private func makeObservedContext(
    behavior: FakeEngineBehavior,
    log: RetryDeadlineLog,
    prepareEscapeRecovery: @escaping PrepareEscapeRecovery = { _, _, _ in false }
  ) -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
      prepareEscapeRecovery: prepareEscapeRecovery,
      onRetryDeadlineStarted: { takeID, backend, budgetMs in
        log.recordStart(takeID, backend, budgetMs)
      },
      onRetryDeadlineResolved: {
        takeID, backend, budgetMs, resolution, disposition, operationReturnMs, callerResumeMs,
        accepted in
        log.recordResolution(
          takeID, backend, budgetMs, resolution, disposition, operationReturnMs, callerResumeMs,
          accepted)
      })
    return Context(
      wrapper: wrapper, engine: engine, capture: capture, vad: vad, paste: paste, clock: clock)
  }

  @Test("#1946 An on-time accepted retry is observed as on time")
  func retryDeadlineObservationOnTimeSuccess() async {
    let log = RetryDeadlineLog()
    let ctx = makeObservedContext(behavior: .crashOnFinalize, log: log)
    ctx.engine.retryDecodeTimeoutSeconds = 20.0
    await runToTerminal(ctx)

    #expect(log.starts.count == 1, "every attempt must be counted, or unresolved starts are guesswork")
    let resolved = log.resolutions
    #expect(resolved.count == 1)
    guard let observation = resolved.first else { return }
    #expect(observation.takeID == log.starts.first?.takeID, "the two halves must join")
    #expect(observation.budgetMs == 20_000)
    #expect(observation.resolution == .operationReturned)
    #expect(observation.disposition == .accepted)
    let returnMs = observation.operationReturnMs ?? -1
    #expect(returnMs >= 0, "a decode that returned must carry a return time")
    #expect(
      returnMs <= observation.budgetMs,
      "the fixture is an on-time decode; it returned in \(returnMs)ms against \(observation.budgetMs)ms")
    #expect(
      observation.acceptedAfterCutoff == false,
      "an on-time accepted decode is not exposure to a stricter cutoff")
  }

  @Test("#1946 A retry accepted AFTER its own budget is counted as such")
  func retryDeadlineObservationLateAcceptedSuccess() async {
    // The whole reason this measurement exists. The decode blocks the main
    // actor for longer than the budget, so the main-actor timer cannot fire and
    // the decode wins late — which is the field schedule an off-actor timer
    // would turn into a rejection.
    let log = RetryDeadlineLog()
    let ctx = makeObservedContext(behavior: .crashOnFinalize, log: log)
    ctx.engine.retryDecodeTimeoutSeconds = 0.05
    // Blocking, not a cooperative wait: the decode must genuinely occupy the
    // main actor so the main-actor timer cannot run while it does. A
    // cooperative wait would let that timer fire and stage a timeout instead —
    // the wrong case, silently. `usleep` because the blocking alternative is
    // unavailable from an async context.
    ctx.engine.onRetryDecodeReturning = { usleep(250_000) }
    await runToTerminal(ctx)

    let resolved = log.resolutions
    #expect(resolved.count == 1)
    guard let observation = resolved.first else { return }
    #expect(
      observation.resolution == .operationReturned,
      "staging: the decode must have won the race, or this measures a timeout instead")
    #expect(observation.disposition == .accepted)
    let returnMs = observation.operationReturnMs ?? -1
    #expect(
      returnMs > observation.budgetMs,
      "staging: the decode must return past \(observation.budgetMs)ms, saw \(returnMs)ms")
    #expect(
      observation.acceptedAfterCutoff,
      "a decode accepted past its own budget is exactly the exposure being counted")
  }

  @Test("#1946 A timed-out retry carries no return time and is never counted as late-accepted")
  func retryDeadlineObservationTimeout() async {
    let log = RetryDeadlineLog()
    let ctx = makeObservedContext(behavior: .crashOnFinalize, log: log)
    ctx.engine.retryDecodeTimeoutSeconds = 0.05
    ctx.engine.retryDecodeDelayTicks = 1
    await runToTerminal(ctx, awaitTerminal: false)
    let kernel = ctx.wrapper.testKernel
    for _ in 0..<200 where kernel.recordingOutcome == nil {
      try? await Task.sleep(for: .milliseconds(5))  // settle: poll the real 50ms deadline above
    }

    let resolved = log.resolutions
    #expect(resolved.count == 1)
    guard let observation = resolved.first else { return }
    #expect(observation.resolution == .timedOut)
    #expect(observation.disposition == .rejected, "no transcript reached the acceptance point")
    #expect(
      observation.operationReturnMs == nil,
      "the decode had not returned, and an absent time must stay absent rather than become a zero")
    #expect(observation.acceptedAfterCutoff == false)
  }

  @Test("#1946 A retry resolving after a new session started is observed as stale")
  func retryDeadlineObservationStaleSession() async {
    let log = RetryDeadlineLog()
    let ctx = makeObservedContext(behavior: .crashOnFinalize, log: log)
    ctx.engine.retryDecodeDelayTicks = 3
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "stale retry text", language: nil, duration: 0, processingTime: 0,
        backendType: .parakeet))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
    let kernel = ctx.wrapper.testKernel
    #expect(log.starts.count == 1, "the attempt is counted at the start, not at the resolution")
    #expect(log.resolutions.isEmpty, "staging: the retry must still be parked")

    kernel.cancel()
    await ctx.wrapper.drainUntilConcluded()
    ctx.engine.behavior = .batchSuccess(text: "session B text")
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()

    ctx.clock.advance(by: 3)
    await ctx.wrapper.drainReadyWork()

    let resolved = log.resolutions
    #expect(resolved.count == 1, "an abandoned resolution must still be reported, not dropped")
    guard let observation = resolved.first else { return }
    #expect(observation.disposition == .stale)
    #expect(
      observation.acceptedAfterCutoff == false,
      "nothing was accepted, so no exposure to a stricter cutoff was created")
  }

  @Test("#1946 A late CALLER resume is not counted as a late DECODE")
  func retryDeadlineObservationSeparatesTheTwoClocks() async throws {
    // The separator. A blocked main actor delays the caller's resume without
    // delaying the decode, and only the decode is evidence about the cutoff.
    // Reading the wrong clock here would inflate `accepted_after_cutoff` with
    // main-actor contention and send the deferred decision the wrong way.
    let log = RetryDeadlineLog()
    let ctx = makeObservedContext(behavior: .crashOnFinalize, log: log)
    // A budget the CALLER's resume exceeds and the DECODE does not. At 20 s
    // both readings sat under budget, so swapping the production comparison to
    // the caller's clock changed nothing and the case proved only that a fast
    // decode is not late.
    ctx.engine.retryDecodeTimeoutSeconds = 0.100
    ctx.engine.onRetryDecodeReturning = {
      DispatchQueue.main.async {
        Thread.sleep(forTimeInterval: 0.3)  // occupies the main actor for the caller's resume only
      }
    }
    await runToTerminal(ctx)

    let resolved = log.resolutions
    #expect(resolved.count == 1)
    let observation = try #require(resolved.first)
    #expect(observation.resolution == .operationReturned)
    #expect(observation.disposition == .accepted)
    // The distinguishing schedule, REQUIRED rather than expected: without both
    // halves the final assertion holds for a reason that is not the subject.
    let returnMs = try #require(observation.operationReturnMs)
    try #require(returnMs <= observation.budgetMs)
    try #require(observation.callerResumeMs > observation.budgetMs)
    #expect(
      observation.acceptedAfterCutoff == false,
      """
      a late caller resume is a blocked main actor, not a late decode; counting it \
      would attribute main-actor contention to the retry budget
      """)
  }


  @Test("#1946 A retry resolving after the take was abandoned is observed as abandoned")
  func retryDeadlineObservationAbandonedTake() async {
    let log = RetryDeadlineLog()
    let ctx = makeObservedContext(
      behavior: .crashOnFinalize, log: log, prepareEscapeRecovery: { _, _, _ in true })
    ctx.wrapper.sessionConfigForTesting = .testDefault(escapeRecoveryEnabled: true)
    ctx.wrapper.cancelOriginForTesting = .user(.shortcut)
    // Park the retry so the take can be abandoned while it is still in flight.
    ctx.engine.retryDecodeDelayTicks = 3
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    // Cancel once: Escape Recovery KEEPS the take and runs the ordinary
    // pipeline, so the decode fails and the one retry is spent and parked.
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainReadyWork()
    #expect(log.starts.count == 1, "staging: the retry must have been attempted")
    #expect(log.resolutions.isEmpty, "staging: the retry must still be parked")

    // Cancel again: the user abandons the recovery while its retry is parked.
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainReadyWork()
    ctx.clock.advance(by: 3)
    await ctx.wrapper.drainReadyWork()

    let resolved = log.resolutions
    #expect(resolved.count == 1, "an abandoned resolution must still be reported, not dropped")
    guard let observation = resolved.first else { return }
    #expect(observation.disposition == .abandoned)
    #expect(
      observation.acceptedAfterCutoff == false,
      "nothing was accepted, so no exposure to a stricter cutoff was created")
  }

}
