import EnviousWisprCore
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

  private func runToTerminal(_ ctx: Context) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    // #1548 D1: the first converted buffer flips Arming -> Live via an async
    // @MainActor hop — drain so the commit lands before stop.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
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

  @Test("helper death mid-decode routes into the one Phase-2 retry, and a successful retry delivers")
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
    kernel.externalASRInterrupted()
    await ctx.wrapper.drainReadyWork()

    // No early terminal: the session keeps waiting for its own decode to fail.
    #expect(kernel.recordingOutcome == nil, "no terminal may be published before finalize resolves")
    #expect(kernel.state == .delivering)
    #expect(kernel.deliveringPhase == .transcribing)
    #expect(ctx.engine.retryDecodeCallCount == 0, "the retry must not start early")

    // Chunk 1's drained continuation: the suspended decode now fails.
    ctx.engine.resolveHeldFinalizeAsHelperDeath()
    await ctx.wrapper.drainReadyWork()

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

  @Test("helper death mid-decode with an exhausted retry ends .asrFailed and projects .asrRetryExhausted")
  func helperDeathMidDecodeExhaustsOnce() async {
    let ctx = makeContext(behavior: .heldFinalize)
    ctx.engine.retryDecodeResult = .failed(.decodeFailed)
    await stopIntoHeldFinalize(ctx)
    let kernel = ctx.wrapper.testKernel
    #expect(ctx.engine.heldFinalizePending, "the initial finalize must be genuinely suspended")

    kernel.externalASRInterrupted()
    await ctx.wrapper.drainReadyWork()
    #expect(kernel.recordingOutcome == nil, "no terminal may be published before finalize resolves")
    #expect(kernel.state == .delivering)
    #expect(kernel.deliveringPhase == .transcribing)
    #expect(ctx.engine.retryDecodeCallCount == 0)

    ctx.engine.resolveHeldFinalizeAsHelperDeath()
    await ctx.wrapper.drainReadyWork()

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
    // `withOrderedDeadline`'s `onTimeout` fires for real.
    ctx.engine.retryDecodeTimeoutSeconds = 0.05
    ctx.engine.retryDecodeDelayTicks = 1
    await runToTerminal(ctx)
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
    await ctx.wrapper.drainReadyWork()
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
    kernel.externalASRInterrupted()
    await ctx.wrapper.drainReadyWork()

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
    await ctx.wrapper.drainReadyWork()
    #expect(kernel.recordingOutcome == .cancelled)

    // Session B starts and completes normally before A's abandoned retry
    // ever resolves.
    ctx.engine.behavior = .batchSuccess(text: "session B text")
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverVoicedCapture(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
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
}
