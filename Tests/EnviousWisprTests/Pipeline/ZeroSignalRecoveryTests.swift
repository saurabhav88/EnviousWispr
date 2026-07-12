import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1317 zero-signal (mic-harness all-zero glitch) kernel routing
//
// Drives the REAL `RecordingSessionKernel` through the simulator fakes.
// Covers both classification paths the plan names: the REACTIVE exit (the
// app-side detector already fired, delivered via `externalCaptureStalled`)
// and the STOP-win backstop (the detector never fired — capture ended before
// its own confidence threshold, or STOP raced it — so the kernel classifies
// the complete `captureResult.samples` itself at stop time, §3.6).
//
// `zeroSignalDeviceEligible` is injected per-scenario (deterministic — never
// depends on the test machine's real microphone/mute state).

@MainActor
@Suite("RecordingSessionKernel — zero-signal recovery (#1317)")
struct ZeroSignalRecoveryTests {

  private let threshold = AudioConstants.minimumTranscriptionSamples  // 16_000

  private struct Context {
    let wrapper: KernelRecordingSession
    let engine: FakeEngine
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
  }

  private func makeContext(
    zeroSignalDeviceEligible: @escaping @MainActor () -> Bool = { true },
    minimumRecordingTicks: Int = 0
  ) -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
      minimumRecordingTicks: minimumRecordingTicks,
      zeroSignalDeviceEligible: zeroSignalDeviceEligible)
    return Context(wrapper: wrapper, engine: engine, capture: capture, vad: vad)
  }

  private func stallContext(
    _ ctx: Context, failureMode: CaptureStallFailureMode
  ) -> CaptureStallContext {
    CaptureStallContext(
      sessionID: ctx.capture.currentCaptureSessionID,
      armedAtUptimeNs: 0,
      firedAtUptimeNs: 0,
      route: "fake",
      sourceType: ctx.capture.captureSourceType,
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: failureMode)
  }

  private func startToRecording(_ ctx: Context) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
  }

  // MARK: - Reactive exit: allZeroFromStart

  @Test("reactive allZeroFromStart → the honest zero-signal terminal, no salvage, ONE rebuild")
  func reactiveAllZeroFromStartFinishesHonestly() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    // The all-zero buffers the app-side detector fired ON. Production always
    // has these — the detector's whole trigger is zero-valued audio ARRIVING —
    // so the kernel's own buffer counter is non-zero by the time the reactive
    // exit lands. (PR3: without them this session would legitimately discard
    // as `.tooShort` on the zero-buffer branch of the duration gate, which is
    // exactly what `shortDeadTapDiscardsAndNeverRebuilds` below pins.)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)

    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .allZeroFromStart))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.zeroSignal))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == nil)
    // PR3: the poisoned capture pipeline is reset exactly once.
    #expect(ctx.capture.rebuildEngineCallCount == 1)
  }

  @Test("reactive noBuffers is UNCHANGED — still the existing captureStall terminal, NO rebuild")
  func reactiveNoBuffersUnaffected() async {
    let ctx = makeContext()
    await startToRecording(ctx)

    ctx.wrapper.testKernel.externalCaptureStalled(stallContext(ctx, failureMode: .noBuffers))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.captureStalled))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    // An ordinary capture stall is NOT the mic-harness glitch — the stall
    // watchdog owns it, and PR3 must never reset the engine for it.
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  // MARK: - Reactive exit: becameZeroMidCapture — normal-stop-path salvage

  @Test("reactive becameZeroMidCapture completes normally, transcribing the captured prefix")
  func reactiveBecameZeroMidCaptureSalvagesPrefix() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: 8_000, amplitude: 0.2)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 8_000)]

    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .becameZeroMidCapture))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
    // PR3: the mic is reset AND the user still keeps the words they said.
    #expect(ctx.capture.rebuildEngineCallCount == 1)
  }

  // MARK: - STOP-win: the detector never fired, classify at stop

  @Test("STOP-win: an all-zero capture at stop classifies as zeroSignal, not ordinary no-speech")
  func stopWinAllZeroClassifies() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.zeroSignal))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(
      ctx.wrapper.stopTimeZeroSignalTelemetryFired.first?.failureMode == .allZeroFromStart)
    // PR3: the STOP-time backstop reaches the same single rebuild site.
    #expect(ctx.capture.rebuildEngineCallCount == 1)
  }

  @Test("STOP-win: meaningful prefix then zero suffix at stop salvages and completes")
  func stopWinBecameZeroCompletesWithSalvage() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: 8_000, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 8_000)]

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 1)
  }

  // MARK: - Fast-follow: the zero-suffix trim (#1317, cloud review + live UAT repro)
  //
  // Reported bug: without the trim, a QUIET (but real) prefix's whole-buffer
  // RMS clears the dead-air floor on its own, but gets diluted below it once
  // the mic-glitch's zero suffix is averaged in — so the no-speech gate
  // discards real words instead of transcribing them. Live UAT reproduced
  // this with real speech ("saffron comet velvet anchor") on 2026-07-11.
  // `0.0013` is the exact amplitude from the cloud reviewer's own example
  // (see RecordingSessionKernelDeadAirFloorTests for the pure-math proof).

  @Test(
    "STOP-win: a quiet prefix that would be diluted below the dead-air floor by the zero suffix is trimmed and survives"
  )
  func stopWinQuietPrefixSurvivesZeroSuffixDilution() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.0013)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech  // Silero abstains on the quiet prefix

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
  }

  @Test(
    "reactive becameZeroMidCapture: a quiet prefix that would be diluted below the dead-air floor by the zero suffix is trimmed and survives"
  )
  func reactiveQuietPrefixSurvivesZeroSuffixDilution() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.0013)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .becameZeroMidCapture))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
    // The reactive win must still suppress STOP-time re-classification (§3.6 N4).
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
  }

  @Test(
    "STOP-win: an open VAD segment reaching past the trim boundary is clamped, not left dangling"
  )
  func stopWinClampsOpenSegmentPastTrimBoundary() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: 8_000, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .voiced
    // An OPEN segment that never resolved to silence before the zero-signal
    // detector fired — its end still references the ORIGINAL (pre-trim)
    // full sample count (Grounded Review r1).
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 8_000 + threshold)]

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
  }

  // MARK: - Fail-closed: muted / mute-unknown device never runs recovery

  @Test(
    "STOP-win: an all-zero capture on an ineligible device (muted or unverified) stays ordinary no-speech"
  )
  func stopWinFailsClosedWhenDeviceNotEligible() async {
    let ctx = makeContext(zeroSignalDeviceEligible: { false })
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .noSpeech)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // A genuinely MUTED mic is a hardware state, not a harness glitch. Resetting
    // the engine would not unmute it — fail closed, never rebuild (§3.0).
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  // MARK: - No false alarm: a genuine quiet room stays no-speech

  @Test("quiet-room tiny non-zero noise at stop is untouched — still ordinary no-speech")
  func quietRoomNoiseStaysNoSpeech() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    // Below every dead-air floor, but never exactly zero.
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.001)
    ctx.vad.evidence = .confirmedNoSpeech

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .noSpeech)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // The false-alarm guard that matters most: a healthy mic in a silent room
    // must never trigger a capture-pipeline reset.
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  // MARK: - Exactly one classified event (Set-dedup, §3.6 N4)

  @Test("a reactive win before stop means STOP-time classification never re-submits")
  func reactiveWinSuppressesStopTimeResubmission() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    // The reactive exit already stamped the side-channel; feed the SAME
    // shape of samples so, if the STOP-time guard were missing, it would
    // also confidently classify — proving the `telemetryState
    // .zeroSignalFailureMode == nil` guard is what suppresses the second
    // submission, not an accidental sample-shape mismatch.
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .allZeroFromStart))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.zeroSignal))
    // STOP-time telemetry never fires for a reactive win — the reactive
    // path's own event rides the WedgeRecoveryRouter funnel instead (§3.6).
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // Both confirmation routes converge on ONE site, so a session confirmed by
    // BOTH (had the guard been missing) still rebuilds exactly once.
    #expect(ctx.capture.rebuildEngineCallCount == 1)
  }

  // MARK: - PR3: the discard gates keep precedence over recovery

  @Test(
    "a dead tap too short to clear the duration gate still discards as too-short and NEVER resets the mic"
  )
  func shortDeadTapDiscardsAndNeverRebuilds() async {
    // Capture samples include PRE-ROLL, so a sub-minimum VISIBLE tap can still
    // carry a full second of (zero) audio — enough for the classifier's
    // threshold. `minimumRecordingTicks: 5` + a FakeClock that does not advance
    // between start and stop reproduces exactly that: the samples qualify, the
    // visible recording does not. Founder-locked (plan §14): very short dead
    // taps keep today's honest behaviour — no reset message, no engine reset.
    let ctx = makeContext(minimumRecordingTicks: 5)
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .discarded)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  // MARK: - PR3: the zero-signal rebuild is independent of the format rebuild

  @Test(
    "a session that ALSO rebuilt for an unstable format still issues exactly one zero-signal rebuild"
  )
  func formatRebuildAndZeroSignalRebuildAreIndependent() async {
    // Two different failures at two different lifecycle phases: the capture
    // START phase rebuilds once for a format that never stabilised
    // (RecordingSessionKernel:966), and the POST-STOP phase rebuilds once more
    // because the harness then delivered dead audio. The PR3 invariant is
    // exactly one ZERO-SIGNAL rebuild — not one rebuild of every kind per
    // session — so the correct total here is 2.
    let ctx = makeContext()
    ctx.capture.stabilizationResults = [false, true]
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.zeroSignal))
    #expect(ctx.capture.rebuildEngineCallCount == 2)  // 1 format + 1 zero-signal
  }

  // MARK: - PR3: a poisoned source is never silently reused across presses

  @Test("each consecutive dead press resets the mic again — the poisoned source is never reused")
  func consecutiveDeadPressesEachRebuild() async {
    let ctx = makeContext()

    for press in 1...3 {
      await startToRecording(ctx)
      ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
      ctx.vad.evidence = .confirmedNoSpeech

      await ctx.wrapper.apply(.stop)
      await ctx.wrapper.drainReadyWork()

      #expect(ctx.wrapper.testKernel.state == .failed(.zeroSignal))
      // Best-effort convergence (§3.3): the rebuild is fire-and-forget, so a
      // still-poisoned source on the next press must re-fire recovery rather
      // than silently hand the user another dead take.
      #expect(ctx.capture.rebuildEngineCallCount == press)

      await ctx.wrapper.apply(.reset)
      await ctx.wrapper.drainReadyWork()
    }
  }
}
