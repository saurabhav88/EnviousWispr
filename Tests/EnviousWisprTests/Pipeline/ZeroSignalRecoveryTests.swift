import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
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
// `zeroSignalDecisionSnapshot` is injected per-scenario (deterministic — never
// depends on the test machine's real microphone or device state). #1578 widened
// it from a Boolean to a categorical reason plus the reactively-classified flag.

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
    zeroSignalDecisionSnapshot: @escaping @MainActor () -> ZeroSignalDecisionSnapshot = {
      ZeroSignalDecisionSnapshot(eligibility: .eligible, currentRunWasClassifiedReactively: false)
    },
    zeroSignalRefusalSink: @escaping @MainActor ([ZeroSignalRefusalContext]) -> Void = { _ in },
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
      zeroSignalDecisionSnapshot: zeroSignalDecisionSnapshot,
      zeroSignalRefusalSink: zeroSignalRefusalSink)
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

  @Test("reactive allZeroFromStart → the honest zero-signal terminal, no salvage, ONE retire")
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

    #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == nil)
    // Heartpath 5b: the poisoned source is RETIRED exactly once (fenced signal-only
    // path); the old eligibility-gated rebuild route is gone.
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  @Test(
    "noBuffers with no audio received concludes noTransport (dead mic, not captureStall), NO rebuild"
  )
  func reactiveNoBuffersWithNoAudioConcludesNoTransport() async {
    // #1548 D2: reaching `.live` no longer needs a buffer (sequential transition),
    // so a `.noBuffers` stall with `bufferCountThisSession == 0` is the dead-mic
    // case → `.noTransport` ("No audio captured"; #1755: best-effort deletion), NOT the live
    // `.captureStall` exit. (The `.captureStall` path — `.noBuffers` AFTER a buffer
    // arrived — is covered by `captureStalledRoutes` in the external-entry suite.)
    let ctx = makeContext()
    await startToRecording(ctx)
    #expect(ctx.wrapper.testKernel.state == .live)

    ctx.wrapper.testKernel.externalCaptureStalled(stallContext(ctx, failureMode: .noBuffers))
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .noTransport)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    // A dead mic is NOT the mic-harness glitch — it never enters the zero-signal
    // recovery / engine-rebuild path.
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  @Test(
    "dead-mic noTransport and a racing stop honor the first winner (both orderings, Codex r2 P2)")
  func deadMicAndRacingStopHonorFirstWinner() async {
    // #1548 D2 first-wins (§3.3): `externalCaptureStalled`'s dead-mic `.noTransport`
    // must not override a stop that already owns the exit, and a stop must not
    // override a `.noTransport` that already concluded. `finishTerminal` is
    // set-once; the no-buffer branch bails on `!recordingExitLatched`.

    // Ordering A — no-buffer first: it concludes `.noTransport` immediately; the
    // later stop is inert (the session is already idle). "No audio captured" wins.
    let a = makeContext()
    await startToRecording(a)
    a.wrapper.testKernel.externalCaptureStalled(stallContext(a, failureMode: .noBuffers))
    await a.wrapper.apply(.stop)
    await a.wrapper.drainReadyWork()
    #expect(a.wrapper.testKernel.recordingOutcome == .noTransport)

    // Ordering B — stop first: the stop latches the recording exit; the later
    // no-buffer bails on `!recordingExitLatched`, so the stop wins (a no-audio stop
    // is a discard tap, NOT `.noTransport`).
    let b = makeContext()
    await startToRecording(b)
    await b.wrapper.apply(.stop)
    b.wrapper.testKernel.externalCaptureStalled(stallContext(b, failureMode: .noBuffers))
    await b.wrapper.drainReadyWork()
    if case .discarded = b.wrapper.testKernel.recordingOutcome {
      // stop won — correct
    } else {
      let got = String(describing: b.wrapper.testKernel.recordingOutcome)
      Issue.record("stop-first must win with a discard, got \(got)")
    }
  }

  @Test(
    "a mid-capture zero-signal latched while Arming is honored over a stop before Live, not overwritten by discard/cancel (Codex code-diff P2)"
  )
  func armingZeroSignalWinsOverLaterStop() async {
    // #1548 D2 first-wins: a `.becameZeroMidCapture` latches a recording exit while
    // `beginCapturePhase` is suspended (parked at stabilization). A stop pressed
    // BEFORE the forward path reaches Live must be FULLY inert — not even
    // `detachedAdapterCancel()`, which would mark the adapter cancelled and drop a
    // salvageable prefix (Codex r2). The exit is consumed at the post-establish
    // checkpoint. (This harness cannot stage a pre-Live prefix — `beginCapturePhase`
    // clears the fake's samples and pre-`beginSession` buffers are not counted — so
    // we assert the exit is honored and the outcome is neither the stop's discard
    // nor a `.cancelled` from a prematurely cancelled adapter.)
    let ctx = makeContext()
    ctx.capture.gateStabilizationCall = 1  // park the forward path in `.arming`
    await ctx.wrapper.apply(.start)
    await ctx.capture.awaitStabilizationGateReached()
    #expect(ctx.wrapper.testKernel.state == .arming)

    // Zero-signal latches a recording exit, THEN the user stops — both before Live.
    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .becameZeroMidCapture))
    await ctx.wrapper.apply(.stop)
    ctx.capture.releaseStabilizationGate()
    await ctx.wrapper.drainReadyWork()

    // The zero-signal exit was consumed and processed (its failure mode is
    // stamped), NOT overwritten by the later stop's discard or a cancelled adapter.
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
    #expect(ctx.wrapper.testKernel.recordingOutcome != .discarded(.releasedBeforeRecording))
    #expect(ctx.wrapper.testKernel.recordingOutcome != .cancelled)
  }

  @Test(
    "a zero-signal queued while still Arming preserves a non-nil recording duration (Codex r2 defect 4)"
  )
  func preLiveZeroSignalPreservesDuration() async {
    // #1548 D2 §3.4: a `.becameZeroMidCapture` can fire while still `.arming` (a
    // pre-roll signal during a suspended establish). It is queued via the
    // recording-exit pending slot BEFORE `beginLiveRecording` stamps the
    // recording-start date, so `deliverRecordingExit` cannot record the length.
    // `awaitRecordingExit` stamps it on consume, after Live timing exists — so the
    // duration must NOT be nil.
    let ctx = makeContext()
    ctx.capture.gateStabilizationCall = 1  // park the forward path in `.arming`
    await ctx.wrapper.apply(.start)
    await ctx.capture.awaitStabilizationGateReached()
    #expect(ctx.wrapper.testKernel.state == .arming)

    // Zero-signal arrives before Live — queued into the pending recording-exit slot.
    ctx.wrapper.testKernel.externalCaptureStalled(
      stallContext(ctx, failureMode: .becameZeroMidCapture))
    ctx.capture.releaseStabilizationGate()
    await ctx.wrapper.drainReadyWork()

    #expect(
      ctx.wrapper.testKernel.lastRecordingDurationSeconds != nil,
      "a pre-Live zero exit must still report a recording duration once Live timing exists")
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

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
    // Heartpath 5b: the mic is RETIRED AND the user still keeps the words they said.
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  // MARK: - STOP-win: the detector never fired, classify at stop

  @Test("STOP-win: an all-zero capture at stop classifies as zeroSignal, not ordinary no-speech")
  func stopWinAllZeroClassifies() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(
      ctx.wrapper.stopTimeZeroSignalTelemetryFired.first?.failureMode == .allZeroFromStart)
    // Heartpath 5b: the STOP-time backstop retires the source once, no rebuild.
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  @Test("STOP-win: meaningful prefix then zero suffix at stop salvages and completes")
  func stopWinBecameZeroCompletesWithSalvage() async {
    let ctx = makeContext()
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: 8_000, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 8_000)]

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .becameZeroMidCapture)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
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

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
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

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
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

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
  }

  // MARK: - Fail-closed: muted / mute-unknown device never runs recovery

  @Test(
    "STOP-win: an all-zero capture on an ineligible device (muted or unverified) stays ordinary no-speech"
  )
  func stopWinFailsClosedWhenDeviceNotEligible() async {
    let ctx = makeContext(
      zeroSignalDecisionSnapshot: {
        // #1578: "ineligible" is now a NAMED reason, not a bare false.
        ZeroSignalDecisionSnapshot(
          eligibility: .deviceMuted, currentRunWasClassifiedReactively: false)
      })
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome.kind == .noSpeech)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // Heartpath 5b (#1520): the terminal stays honest `.noSpeech` (we never accuse
    // the mic for a quiet/muted user), but we DO retire the source — a muted mic and
    // a dead Bluetooth link are indistinguishable, and retiring is a cheap
    // one-cold-reopen swap that rescues the dead-link-misreported-as-muted case. The
    // OLD eligibility-gated rebuild never fired here — the #1520 propagation gap.
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.retiredCaptureSessionIDs == [ctx.capture.currentCaptureSessionID])
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

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome.kind == .noSpeech)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // The false-alarm guard that matters most: a healthy mic in a silent room
    // (tiny non-zero noise, never exact zero) must never be retired or rebuilt.
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
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

    #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
    // STOP-time telemetry never fires for a reactive win — the reactive
    // path's own event rides the WedgeRecoveryRouter funnel instead (§3.6).
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // Both confirmation routes converge on ONE retire, so a session confirmed by
    // BOTH (had the guard been missing) still retires exactly once, no rebuild.
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
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

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome.kind == .discarded)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // Discarded as too-short BEFORE the zero-signal region — never retired.
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  // MARK: - PR3: the zero-signal rebuild is independent of the format rebuild

  @Test(
    "a session that ALSO rebuilt for an unstable format still issues exactly one zero-signal retire"
  )
  func formatRebuildAndZeroSignalRebuildAreIndependent() async {
    // Two different failures at two different lifecycle phases, now via two
    // DIFFERENT methods: the capture START phase REBUILDS once for a format that
    // never stabilised (RecordingSessionKernel:966), and the POST-STOP phase
    // RETIRES the source once because the harness then delivered dead audio.
    // Heartpath 5b makes them even more clearly independent — different call sites,
    // different methods.
    let ctx = makeContext()
    ctx.capture.stabilizationResults = [false, true]
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
    #expect(ctx.capture.rebuildEngineCallCount == 1)  // format-stabilization only
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)  // zero-signal
  }

  // MARK: - PR3: a poisoned source is never silently reused across presses

  @Test("each consecutive dead press resets the mic again — the poisoned source is never reused")
  func consecutiveDeadPressesEachRebuild() async {
    let ctx = makeContext()

    for press in 1...3 {
      await startToRecording(ctx)
      ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
      ctx.vad.evidence = .confirmedNoSpeech

      // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
      // otherwise the stop aborts a still-Arming session.
      await ctx.wrapper.drainReadyWork()
      await ctx.wrapper.apply(.stop)
      await ctx.wrapper.drainReadyWork()

      #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
      // Best-effort convergence (§3.3): the retire is fire-and-forget, so a
      // still-poisoned source on the next press must re-fire recovery rather
      // than silently hand the user another dead take.
      #expect(ctx.capture.retireCapturingSourceCallCount == press)
      #expect(ctx.capture.rebuildEngineCallCount == 0)

      await ctx.wrapper.apply(.reset)
      await ctx.wrapper.drainReadyWork()
    }
  }

  // MARK: - Heartpath 5b (#1520): dead-mic retire/recovery telemetry

  @Test("eligible all-zero emits a retire-attempt: action=retired, health_guess_refused=false")
  func deadMicTelemetryEligibleAllZero() async {
    let ctx = makeContext()  // eligible by default
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.deadMicRetireAttempts.count == 1)
    let attempt = ctx.wrapper.deadMicRetireAttempts.first
    #expect(attempt?.retireAction == "retired")
    #expect(attempt?.failureShape == "all_zero_from_start")
    // Eligible: the eligibility-gated stamp fired, so the retire did NOT run on
    // the sample fact alone.
    #expect(attempt?.healthGuessRefused == false)
  }

  @Test("ineligible all-zero (the #1520 gap) emits a retire-attempt with health_guess_refused=true")
  func deadMicTelemetryIneligibleAllZero() async {
    let ctx = makeContext(
      zeroSignalDecisionSnapshot: {
        // #1578: "ineligible" is now a NAMED reason, not a bare false.
        ZeroSignalDecisionSnapshot(
          eligibility: .deviceMuted, currentRunWasClassifiedReactively: false)
      })
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(ctx.wrapper.deadMicRetireAttempts.count == 1)
    // The retire ran on the sample fact alone — the eligibility-gated stamp never
    // fired. This is exactly the case 5b uniquely fixes.
    #expect(ctx.wrapper.deadMicRetireAttempts.first?.healthGuessRefused == true)
  }

  @Test("a fenced no-op retire still emits the attempt but arms no recovery watch")
  func deadMicTelemetryNoOpRetireDoesNotArm() async {
    let ctx = makeContext()
    ctx.capture.retireCapturingSourceResult = .sourceNotRunning  // fenced no-op

    for _ in 1...2 {
      await startToRecording(ctx)
      ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
      ctx.vad.evidence = .confirmedNoSpeech
      await ctx.wrapper.drainReadyWork()
      await ctx.wrapper.apply(.stop)
      await ctx.wrapper.drainReadyWork()
      await ctx.wrapper.apply(.reset)
      await ctx.wrapper.drainReadyWork()
    }

    #expect(ctx.wrapper.deadMicRetireAttempts.count == 2)  // both dead takes emit
    #expect(
      ctx.wrapper.deadMicRetireAttempts.allSatisfy { $0.retireAction == "source_not_running" })
    // A no-op teardown is never armed, so a later retire can never be credited a
    // recovery.
    #expect(ctx.wrapper.deadMicRecoveries.isEmpty)
  }

  @Test("two consecutive real retires resolve the first as recovered=false, later_retire")
  func deadMicTelemetryConsecutiveRetiresResolveLaterRetire() async {
    let ctx = makeContext()  // default fake result is .retired

    for _ in 1...2 {
      await startToRecording(ctx)
      ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
      ctx.vad.evidence = .confirmedNoSpeech
      await ctx.wrapper.drainReadyWork()
      await ctx.wrapper.apply(.stop)
      await ctx.wrapper.drainReadyWork()
      await ctx.wrapper.apply(.reset)
      await ctx.wrapper.drainReadyWork()
    }

    // Press 1 armed a watch; press 2's real retire arms over it, resolving press
    // 1's watch as a NON-recovery (the mic stayed broken).
    #expect(ctx.wrapper.deadMicRecoveries.count == 1)
    #expect(ctx.wrapper.deadMicRecoveries.first?.recovered == false)
    #expect(ctx.wrapper.deadMicRecoveries.first?.resolution == "later_retire")
  }

  // MARK: - #1578 group 1: STOP snapshot cardinality
  //
  // STOP reads the snapshot ONCE and splits three ways. These four rows pin every
  // reachable combination, and the two reactive-true rows matter most: whether the
  // reactive forward was ACCEPTED (empty backlog) or REJECTED (a pending context)
  // must make no difference to STOP. If it ever did, a rejected refusal would be
  // emitted from the backlog AND re-emitted here.

  private static func refusal(
    _ sessionID: UInt64, _ reason: ZeroSignalEligibility = .deviceMuted,
    _ transport: String = "usb", _ shape: CaptureStallFailureMode = .becameZeroMidCapture
  ) -> ZeroSignalRefusalContext {
    ZeroSignalRefusalContext(
      sessionID: sessionID, reason: reason, transport: transport, failureShape: shape)
  }

  /// Collects everything the kernel hands the refusal sink, flattened in order.
  private final class RefusalSinkLog {
    var batches: [[ZeroSignalRefusalContext]] = []
    var flattened: [ZeroSignalRefusalContext] { batches.flatMap { $0 } }
  }

  private func makeRefusalContext(
    snapshot: @escaping @MainActor () -> ZeroSignalDecisionSnapshot,
    log: RefusalSinkLog
  ) -> Context {
    makeContext(
      zeroSignalDecisionSnapshot: snapshot,
      zeroSignalRefusalSink: { contexts in log.batches.append(contexts) })
  }

  private func driveZeroSignalStop(_ ctx: Context) async {
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
  }

  @Test("#1578 STOP: a run already classified reactively and ACCEPTED adds nothing")
  func stopAddsNothingWhenReactivelyClassifiedAndAccepted() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .deviceMuted, currentRunWasClassifiedReactively: true)
      }, log: log)
    // Accepted forward ⇒ nothing left pending.
    ctx.capture.stubbedPendingZeroSignalRefusals = []

    await driveZeroSignalStop(ctx)

    #expect(log.flattened.isEmpty, "STOP re-emitted a run the reactive path already owned")
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
  }

  @Test("#1578 STOP: a run classified reactively but REJECTED emits only from the backlog")
  func stopEmitsOnlyBacklogWhenReactivelyClassifiedAndRejected() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .deviceMuted, currentRunWasClassifiedReactively: true)
      }, log: log)
    ctx.capture.stubbedPendingZeroSignalRefusals = [Self.refusal(1)]

    await driveZeroSignalStop(ctx)

    // Exactly one — the drained one. STOP must not add a second for the same run,
    // which is why forwarding success never controls suppression.
    #expect(log.flattened.count == 1)
    #expect(log.flattened.first == Self.refusal(1))
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
  }

  @Test("#1578 STOP: an unclassified ELIGIBLE run keeps today's stall behaviour exactly")
  func stopEligibleUnclassifiedPreservesStallPath() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: false)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode != nil, "the stamp regressed")
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(log.flattened.isEmpty, "an eligible run must produce no refusal")
  }

  @Test("#1578 STOP: an unclassified NON-ELIGIBLE run emits one refusal and no stall")
  func stopNonEligibleUnclassifiedEmitsOneRefusal() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .notAlive, currentRunWasClassifiedReactively: false)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(log.flattened.count == 1)
    #expect(log.flattened.first?.reason == .notAlive)
    #expect(log.flattened.first?.failureShape == .allZeroFromStart)
    // A refusal is an observation, never a stall confirmation.
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
  }

  // MARK: - #1578 group 2: terminal × backlog cross-product
  //
  // Three terminals reach a drain point, each with an empty and a non-empty
  // backlog. The non-empty cells use TWO distinct contexts so order and
  // completeness are observable, not just "something arrived".

  private static let twoPending: [ZeroSignalRefusalContext] = [
    refusal(7, .deviceMuted, "usb", .becameZeroMidCapture),
    refusal(7, .notAlive, "bluetooth", .allZeroFromStart),
  ]

  private func assertDrainedExactlyOnce(_ ctx: Context, _ log: RefusalSinkLog) {
    #expect(log.flattened == Self.twoPending, "contexts lost, reordered, or duplicated")
    #expect(
      ctx.capture.stubbedPendingZeroSignalRefusals.isEmpty,
      "the backlog was not cleared by the take")
  }

  @Test("#1578 terminal: normal STOP drains a non-empty backlog exactly once, in order")
  func normalStopDrainsBacklogInOrder() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)
    ctx.capture.stubbedPendingZeroSignalRefusals = Self.twoPending

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    assertDrainedExactlyOnce(ctx, log)
  }

  @Test("#1578 terminal: normal STOP with an empty backlog emits nothing")
  func normalStopEmptyBacklogEmitsNothing() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    // The paired control: without it, a sink that fired unconditionally would
    // satisfy every positive cell above.
    #expect(log.batches.isEmpty)
  }

  @Test("#1578 terminal: cancel drains a non-empty backlog exactly once, in order")
  func cancelDrainsBacklogInOrder() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)
    ctx.capture.stubbedPendingZeroSignalRefusals = Self.twoPending

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainReadyWork()

    assertDrainedExactlyOnce(ctx, log)
  }

  @Test("#1578 terminal: cancel with an empty backlog emits nothing")
  func cancelEmptyBacklogEmitsNothing() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainReadyWork()

    #expect(log.batches.isEmpty)
  }

  @Test("#1578 terminal: a recoverable device-removed interruption drains the backlog")
  func deviceRemovedInterruptionDrainsBacklog() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)
    ctx.capture.stubbedPendingZeroSignalRefusals = Self.twoPending

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    // Both current causes are RECOVERABLE, so both fall through the normal stop
    // tail rather than a direct terminal — that is the #1408 salvage design, and
    // it is why the normal-STOP drain point covers interruption too.
    ctx.wrapper.testKernel.externalEngineInterrupted(.deviceRemoved)
    await ctx.wrapper.drainReadyWork()

    assertDrainedExactlyOnce(ctx, log)
  }

  @Test("#1578 terminal: a recoverable engine-lost interruption with an empty backlog is silent")
  func engineLostInterruptionEmptyBacklogEmitsNothing() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    ctx.wrapper.testKernel.externalEngineInterrupted(.engineLost)
    await ctx.wrapper.drainReadyWork()

    #expect(log.batches.isEmpty)
  }

  // MARK: - #1578 group 3: cancel landing while STOP is suspended
  //
  // THE hardest case in the plan, and the reason the drain sits BEFORE the await.
  // Normal STOP claims the backlog, then suspends inside `stopCapture()`. A cancel
  // concludes the session and drains again — finding nothing, because the take was
  // atomic. A new session then starts and queues its OWN context. When the stale
  // continuation finally resumes it must consume none of it.

  @Test("#1578 interleaving: a cancel during a suspended STOP double-drains nothing")
  func cancelDuringSuspendedStopConsumesNothingTwice() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)
    ctx.capture.stubbedPendingZeroSignalRefusals = Self.twoPending
    ctx.capture.gateStopCaptureCall = 1  // park the first stop

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    await ctx.wrapper.apply(.stop)
    // Signal-based, never a sleep: resume only once the stop has genuinely parked.
    await ctx.capture.awaitStopCaptureGateReached()

    // The drain ran BEFORE the suspension, so the old contexts are already out.
    #expect(log.flattened == Self.twoPending)
    #expect(ctx.capture.stubbedPendingZeroSignalRefusals.isEmpty)
    #expect(ctx.capture.takePendingZeroSignalRefusalsCallCount == 1)

    // The cancel concludes while the stop is still suspended. Its second drain
    // genuinely runs but atomically finds nothing — the take counter is what
    // distinguishes "ran and found nothing" from "never ran at all".
    await ctx.wrapper.apply(.cancel)
    #expect(ctx.wrapper.testKernel.state == .idle)
    #expect(log.flattened == Self.twoPending, "the cancel duplicated an already-drained context")
    #expect(ctx.capture.takePendingZeroSignalRefusalsCallCount == 2)

    // Start a GENUINELY new session while the old STOP continuation is parked.
    // Inserting a context without starting one would model a window production
    // never reaches, and would not exercise the stale continuation's fence.
    await startToRecording(ctx)
    #expect(ctx.wrapper.testKernel.state == .live)

    let newSessionContext = Self.refusal(
      ctx.capture.currentCaptureSessionID,
      .identityMismatch,
      "built_in",
      .allZeroFromStart)
    ctx.capture.stubbedPendingZeroSignalRefusals = [newSessionContext]

    ctx.capture.releaseStopCaptureGate()
    await ctx.wrapper.drainReadyWork()

    // The stale continuation returned through its session fence without taking
    // anything owned by the new session.
    #expect(
      log.flattened == Self.twoPending,
      "a stale STOP continuation consumed a later session's refusal")
    #expect(ctx.capture.stubbedPendingZeroSignalRefusals == [newSessionContext])
    #expect(ctx.capture.takePendingZeroSignalRefusalsCallCount == 2)

    // Clean up the new session and prove its OWN terminal is the consumer.
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainReadyWork()
    #expect(ctx.capture.takePendingZeroSignalRefusalsCallCount == 3)
    #expect(log.flattened == Self.twoPending + [newSessionContext])
  }

  // MARK: - #1578 group 4: refusal and retire CO-FIRE
  //
  // These are not mutually exclusive, and a test asserting exclusivity would
  // enforce a contract the code does not have. A refused FINAL run legitimately
  // produces both.

  @Test("#1578 co-fire: a refused FINAL run emits one refusal AND one refused retire")
  func refusedFinalRunCoFiresRefusalAndRetire() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .deviceMuted, currentRunWasClassifiedReactively: false)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(log.flattened.count == 1)
    #expect(log.flattened.first?.reason == .deviceMuted)
    #expect(ctx.wrapper.deadMicRetireAttempts.count == 1)
    #expect(
      ctx.wrapper.deadMicRetireAttempts.first?.healthGuessRefused == true,
      "the retire must record that the health guess refused")
  }

  @Test("#1578 co-fire: an ELIGIBLE final run emits no refusal and an unrefused retire")
  func eligibleFinalRunEmitsRetireWithoutRefusal() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: false)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(log.flattened.isEmpty)
    #expect(ctx.wrapper.deadMicRetireAttempts.count == 1)
    #expect(ctx.wrapper.deadMicRetireAttempts.first?.healthGuessRefused == false)
  }

  @Test("#1578 co-fire: a refused RECOVERED run emits its refusal and no retire")
  func refusedRecoveredRunEmitsRefusalWithoutRetire() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(
          eligibility: .eligible, currentRunWasClassifiedReactively: true)
      }, log: log)
    // The refusal happened earlier in the take and was rejected; the microphone
    // then recovered, so the take ends with real audio and never retires.
    ctx.capture.stubbedPendingZeroSignalRefusals = [Self.refusal(3, .muteUnverified)]

    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0.5)
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()

    #expect(log.flattened.count == 1)
    #expect(log.flattened.first?.reason == .muteUnverified)
    #expect(ctx.wrapper.deadMicRetireAttempts.isEmpty, "a recovered take must not retire")
  }
}
