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
    zeroSignalDeviceEligible: @escaping @MainActor () -> Bool = { true }
  ) -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
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

  @Test("reactive allZeroFromStart → the honest zero-signal terminal, no salvage")
  func reactiveAllZeroFromStartFinishesHonestly() async {
    let ctx = makeContext()
    await startToRecording(ctx)

    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .allZeroFromStart))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.zeroSignal))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == nil)
  }

  @Test("reactive noBuffers is UNCHANGED — still the existing captureStall terminal")
  func reactiveNoBuffersUnaffected() async {
    let ctx = makeContext()
    await startToRecording(ctx)

    ctx.wrapper.testKernel.externalCaptureStalled(stallContext(ctx, failureMode: .noBuffers))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.state == .failed(.captureStalled))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
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
  }
}
