import EnviousWisprCore
import Foundation
import Testing

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
    "#1707 Codex r5: a retry that times out (never resolves) still terminates as .asrFailed but retains the spool, distinct from a genuinely exhausted retry"
  )
  func timedOutRetryTerminatesButRetainsSpool() async {
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
    #expect(ctx.engine.bumpRetryGenerationCallCount == 1)
    // The distinguishing assertion (Codex r5): NOT .retryExhausted. A mere
    // timeout must never be conflated with a confirmed second failure — the
    // underlying decode call is still running with no genuine cancellation,
    // and deleting the spool now could discard audio a slower-but-healthy
    // retry would have recovered.
    #expect(ctx.wrapper.telemetryState.asrRetryOutcome == .attempted)
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
