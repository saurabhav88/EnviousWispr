import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1317 zero-signal (mic-harness all-zero glitch) kernel routing
//
// Drives the REAL `RecordingSessionKernel` through the simulator fakes.
// #4841: STOP is the only zero-signal classifier — capture never ends a take on
// exact zeros, so the kernel classifies the complete `captureResult.samples` at
// stop time (§3.6). A whole-zero take keeps today's outcome; a speech-then-zero
// take completes on every route with no stamp, no refusal and no retire.
//
// `zeroSignalDecisionSnapshot` is injected per-scenario (deterministic — never
// depends on the test machine's real microphone or device state).

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
      ZeroSignalDecisionSnapshot(eligibility: .eligible)
    },
    zeroSignalRefusalSink: @escaping @MainActor ([ZeroSignalRefusalContext]) -> Void = { _ in },
    minimumRecordingTicks: Int = 0,
    microphonePermissionIsDenied: @escaping @MainActor () -> Bool = { false },
    engineBehavior: FakeEngineBehavior = .batchSuccess(text: "hello")
  ) -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: engineBehavior, clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
      minimumRecordingTicks: minimumRecordingTicks,
      zeroSignalDecisionSnapshot: zeroSignalDecisionSnapshot,
      zeroSignalRefusalSink: zeroSignalRefusalSink,
      microphonePermissionIsDenied: microphonePermissionIsDenied)
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

  // MARK: - No-buffer stalls (the only capture stall that ends a take)

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
    await ctx.wrapper.drainUntilConcluded()

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
    await a.wrapper.drainUntilConcluded()
    #expect(a.wrapper.testKernel.recordingOutcome == .noTransport)

    // Ordering B — stop first: the stop latches the recording exit; the later
    // no-buffer bails on `!recordingExitLatched`, so the stop wins (a no-audio stop
    // is a discard tap, NOT `.noTransport`).
    let b = makeContext()
    await startToRecording(b)
    await b.wrapper.apply(.stop)
    b.wrapper.testKernel.externalCaptureStalled(stallContext(b, failureMode: .noBuffers))
    await b.wrapper.drainUntilConcluded()
    if case .discarded = b.wrapper.testKernel.recordingOutcome {
      // stop won — correct
    } else {
      let got = String(describing: b.wrapper.testKernel.recordingOutcome)
      Issue.record("stop-first must win with a discard, got \(got)")
    }
  }

  // MARK: - STOP: the only zero-signal classifier (#4841)

  // MARK: - #3960 access turned off while recording

  @MainActor private final class AccessBox { var denied = false }

  /// Access is granted when the take starts (the kernel's pre-start check
  /// passes), then reads denied by the time the take is judged: the zeros are
  /// the missing permission, so the user is told that, not to check hardware.
  /// The retire still runs; only the ending changes.
  @Test("STOP-win all-zero with access now off ends permissionDenied")
  func stopWinAllZeroWithAccessOffEndsPermissionDenied() async {
    let access = AccessBox()
    let ctx = makeContext(microphonePermissionIsDenied: { access.denied })
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech
    await ctx.wrapper.drainReadyWork()
    access.denied = true

    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.permissionDenied))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
  }

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
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(
      ctx.wrapper.stopTimeZeroSignalTelemetryFired.first?.failureMode == .allZeroFromStart)
    // Heartpath 5b: the STOP-time backstop retires the source once, no rebuild.
    #expect(ctx.capture.retireCapturingSourceCallCount == 1)
    #expect(ctx.capture.rebuildEngineCallCount == 0)
  }

  /// #4841: when this fails, a user who paused after speaking gets an
  /// "interrupted" ending or a retired microphone instead of their words.
  @Test("STOP: meaningful prefix then zero suffix completes with no stamp, telemetry or retire")
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
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
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
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
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
    // An OPEN segment that never resolved to silence before the take ended —
    // its end still references the ORIGINAL (pre-trim) full sample count.
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 8_000 + threshold)]

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()

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
        // #1578: "ineligible" is a NAMED reason, not a bare false.
        ZeroSignalDecisionSnapshot(eligibility: .deviceMuted)
      })
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech

    // #1548 D1: commit the first buffer (Arming -> Live) before stopping;
    // otherwise the stop aborts a still-Arming session.
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()

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
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome.kind == .noSpeech)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    // The false-alarm guard that matters most: a healthy mic in a silent room
    // (tiny non-zero noise, never exact zero) must never be retired or rebuilt.
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
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
    await ctx.wrapper.drainUntilConcluded()

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
    await ctx.wrapper.drainUntilConcluded()

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
      await ctx.wrapper.drainUntilConcluded()

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
    await ctx.wrapper.drainUntil(
      { ctx.wrapper.deadMicRetireAttempts.count == 1 }, what: "retire attempt reported")

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
        // #1578: "ineligible" is a NAMED reason, not a bare false.
        ZeroSignalDecisionSnapshot(eligibility: .deviceMuted)
      })
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntil(
      { ctx.wrapper.deadMicRetireAttempts.count == 1 }, what: "retire attempt reported")

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
      await ctx.wrapper.drainUntilConcluded()
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
      await ctx.wrapper.drainUntilConcluded()
      await ctx.wrapper.apply(.reset)
      await ctx.wrapper.drainReadyWork()
    }

    // Press 1 armed a watch; press 2's real retire arms over it, resolving press
    // 1's watch as a NON-recovery (the mic stayed broken).
    #expect(ctx.wrapper.deadMicRecoveries.count == 1)
    #expect(ctx.wrapper.deadMicRecoveries.first?.recovered == false)
    #expect(ctx.wrapper.deadMicRecoveries.first?.resolution == "later_retire")
  }

  // MARK: - #4841 — the suffix rule on every route (widening #4154's USB rule)

  /// A speech prefix at least the conditioner's minimum length, so ASR input is
  /// never padded and its length shows whether the zero suffix was trimmed.
  private let prefix = 24_000

  /// A frozen route for the take. `helper_reported` means the bound source itself
  /// reported the transport; `app_derived` is the app's own guess.
  private static func route(_ effective: String, source: String = "helper_reported")
    -> ResolvedRouteTransports
  {
    ResolvedRouteTransports(
      selected: "unknown", effective: effective, routeReason: "system_default",
      routeFallbackReason: nil, inputSelectionMode: "auto", outputTransport: "display_port",
      routeResolutionSource: source)
  }

  /// Start a take on `route`, deliver `buffers` (frames, amplitude), commit Live,
  /// then stop and wait for the terminal. Asserts the frozen route first.
  private func runTake(
    _ ctx: Context, route: ResolvedRouteTransports, buffers: [(Int, Float)],
    beforeStop: () -> Void = {}
  ) async throws {
    ctx.capture.liveResolvedRoute = route
    await startToRecording(ctx)
    for (frames, amplitude) in buffers {
      ctx.capture.deliverBuffer(frameCount: frames, amplitude: amplitude)
    }
    await ctx.wrapper.drainReadyWork()
    try #require(ctx.wrapper.testKernel.lastResolvedRoute == route, "precondition: route frozen")
    beforeStop()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()
  }

  /// When this fails, a user who stops talking a second before releasing the key
  /// sees a false "interrupted" notice and the next press opens cold (#4841: on
  /// every route, not only a confirmed USB one).
  @Test(
    "every route: a qualifying zero suffix completes normally, trimmed, with no retire",
    arguments: [
      ("usb", "helper_reported"), ("built_in", "helper_reported"),
      ("bluetooth", "helper_reported"), ("usb", "app_derived"), ("unknown", "app_derived"),
    ]
  )
  func suffixCompletesNormallyWithoutRetire(effective: String, source: String) async throws {
    let ctx = makeContext()
    ctx.vad.evidence = .voiced  // no segments: ASR receives the whole buffer
    try await runTake(
      ctx, route: Self.route(effective, source: source), buffers: [(prefix, 0.2), (threshold, 0)])

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
    #expect(ctx.wrapper.deadMicRetireAttempts.isEmpty)
    let asrInput = try #require(ctx.engine.lastFinalizeBatchSamples)
    #expect(asrInput.count == prefix, "the qualifying zero suffix is trimmed before ASR")
  }

  /// The streaming route gets the same trimmed buffer for its final rescue pass:
  /// the trim sits on the capture result before the batch/streaming split.
  @Test("streaming: a qualifying zero suffix is trimmed from the buffer handed to finalize")
  func streamingSuffixIsTrimmedBeforeFinalize() async throws {
    let ctx = makeContext(engineBehavior: .streamingSuccess(partials: ["hel"], final: "hello"))
    ctx.vad.evidence = .voiced
    try await runTake(ctx, route: Self.route("bluetooth"), buffers: [(prefix, 0.2), (threshold, 0)])

    #expect(ctx.engine.lastStreamingRequested == true, "precondition: the streaming route ran")
    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
    #expect(try #require(ctx.engine.lastFinalizeBatchSamples).count == prefix)
  }

  /// The trim is sample-qualified: an ineligible device must not leave the zero
  /// suffix in place, and the device snapshot is never consulted.
  @Test("the suffix trim does not need device eligibility, and eligibility is never read")
  func suffixTrimDoesNotRequireEligibility() async throws {
    var snapshotReads = 0
    let ctx = makeContext(zeroSignalDecisionSnapshot: {
      snapshotReads += 1
      return ZeroSignalDecisionSnapshot(eligibility: .deviceMuted)
    })
    ctx.vad.evidence = .voiced  // no segments: ASR receives the whole buffer
    try await runTake(ctx, route: Self.route("usb"), buffers: [(prefix, 0.2), (threshold, 0)])

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(snapshotReads == 0)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
    #expect(try #require(ctx.engine.lastFinalizeBatchSamples).count == prefix)
  }

  /// A whole-zero USB take keeps today's stop-time handling: eligible → the
  /// zero-signal terminal, access off → permission terminal, ineligible → the
  /// ordinary no-speech outcome. The sample-fact retire still runs in all three.
  @Test("USB: a whole-zero take keeps today's stop-time handling")
  func usbAllZeroPreservesStopHandling() async throws {
    let eligible = makeContext()
    try await runTake(eligible, route: Self.route("usb"), buffers: [(threshold * 2, 0)])
    #expect(eligible.wrapper.testKernel.recordingOutcome == .failed(.zeroSignal))
    #expect(eligible.wrapper.testKernel.zeroSignalFailureMode == .allZeroFromStart)
    #expect(eligible.capture.retireCapturingSourceCallCount == 1)
    // §6 row 12: the stop-time context the emitter's no-audio dedup latches on.
    #expect(eligible.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    let stopContext = try #require(eligible.wrapper.stopTimeZeroSignalTelemetryFired.first)
    #expect(stopContext.failureMode == .allZeroFromStart)
    #expect(stopContext.sourceType == "stop_time_classification")
    #expect(stopContext.effectiveTransport == "usb")
    #expect(stopContext.routeResolutionSource == "helper_reported")
    #expect(eligible.wrapper.deadMicRetireAttempts.count == 1)
    #expect(eligible.wrapper.deadMicRetireAttempts.first?.transport == "usb")

    let access = AccessBox()
    let denied = makeContext(microphonePermissionIsDenied: { access.denied })
    try await runTake(
      denied, route: Self.route("usb"), buffers: [(threshold * 2, 0)],
      beforeStop: { access.denied = true })
    #expect(denied.wrapper.testKernel.recordingOutcome == .failed(.permissionDenied))
    #expect(denied.capture.retireCapturingSourceCallCount == 1)

    let ineligible = makeContext(zeroSignalDecisionSnapshot: {
      ZeroSignalDecisionSnapshot(eligibility: .deviceMuted)
    })
    ineligible.vad.evidence = .confirmedNoSpeech
    try await runTake(ineligible, route: Self.route("usb"), buffers: [(threshold * 2, 0)])
    #expect(ineligible.wrapper.testKernel.recordingOutcome.kind == .noSpeech)
    #expect(ineligible.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ineligible.capture.retireCapturingSourceCallCount == 1)
  }

  /// A too-short USB tap still discards before any zero-signal handling, exactly
  /// as on every other route: no stamp, no retire.
  @Test("USB: a too-short dead tap still discards first and is never retired")
  func usbEarlyTerminalsStillWin() async throws {
    let ctx = makeContext(minimumRecordingTicks: 5)
    ctx.vad.evidence = .confirmedNoSpeech
    try await runTake(ctx, route: Self.route("usb"), buffers: [(threshold, 0)])

    #expect(ctx.wrapper.testKernel.recordingOutcome.kind == .discarded)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
  }

  /// When this fails, a user's quiet sentence with a long pause in the middle is
  /// discarded as "no speech" (D-Q, every route since #4841). The full take
  /// reaches ASR.
  @Test(
    "every route: quiet speech around a long interior pause reaches ASR",
    arguments: [("usb", "helper_reported"), ("built_in", "helper_reported"), ("usb", "app_derived")]
  )
  func quietInteriorPauseReachesASR(effective: String, source: String) async throws {
    let ctx = makeContext()
    ctx.vad.evidence = .confirmedNoSpeech
    try await runTake(
      ctx, route: Self.route(effective, source: source),
      buffers: [(threshold, 0.0013), (threshold * 5, 0), (threshold, 0.0013)])

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(try #require(ctx.engine.lastFinalizeBatchSamples).count == threshold * 7)
  }

  /// With a trailing zero run too: the diluted prefix does not qualify the
  /// classifier's trim, so ASR gets the whole buffer, timing intact.
  @Test("USB: quiet interior pause plus trailing zeros reaches ASR untrimmed")
  func usbQuietInteriorPauseWithTrailingZerosReachesASR() async throws {
    let ctx = makeContext()
    ctx.vad.evidence = .confirmedNoSpeech
    try await runTake(
      ctx, route: Self.route("usb"),
      buffers: [(threshold, 0.0013), (threshold * 5, 0), (threshold, 0.0013), (threshold, 0)])

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(try #require(ctx.engine.lastFinalizeBatchSamples).count == threshold * 8)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
  }

  /// D-Q admits the take; an empty decode then maps to the quiet no-speech
  /// outcome (#964 R2), not a failure. This pins the mapping only; it does not
  /// claim the engine always returns empty on non-speech.
  @Test("USB: an energy-admitted take with an empty decode ends as quiet no-speech")
  func usbEnergyAdmittedEmptyDecodeBecomesNoSpeech() async throws {
    let ctx = makeContext(engineBehavior: .empty(hadSpeechEvidence: false))
    ctx.vad.evidence = .confirmedNoSpeech
    try await runTake(
      ctx, route: Self.route("usb"),
      buffers: [(threshold, 0.0013), (threshold * 5, 0), (threshold, 0.0013)])

    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(ctx.wrapper.testKernel.recordingOutcome == .noSpeech(.asrEmptyNoSpeech))
  }

  /// The open-segment clamp still applies after the sample-qualified trim.
  @Test("USB: an open VAD segment past the trim boundary is clamped")
  func usbQualifiedSuffixClampsVADSegments() async throws {
    let ctx = makeContext()
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: prefix + threshold)]
    try await runTake(ctx, route: Self.route("usb"), buffers: [(prefix, 0.2), (threshold, 0)])

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == "hello")
    #expect(try #require(ctx.engine.lastFinalizeBatchSamples).count == prefix)
    let observed = try #require(ctx.engine.lastObservedSpeechSegments)
    #expect(observed.map { [$0.startSample, $0.endSample] } == [[0, prefix]])
  }

  // MARK: - #4154 chunk 4 — downstream checks on a USB take

  /// VAD auto-stop and the hard cap own the exit on a take that went quiet (the
  /// zero run never wins first), and it completes normally.
  @Test(
    "USB: VAD auto-stop and the cap own the exit and complete without a retire",
    arguments: ["vad_auto_stop", "max_duration"]
  )
  func usbAutomaticExitsOwnTheTake(exit: String) async throws {
    let ctx = makeContext()
    ctx.vad.evidence = .voiced  // no segments: ASR receives the whole buffer
    ctx.capture.liveResolvedRoute = Self.route("usb")
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: prefix, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    await ctx.wrapper.drainReadyWork()
    ctx.vad.emit(exit == "vad_auto_stop" ? .autoStopTriggered : .maxDurationReached)
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.lastStopReason == exit)
    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
    #expect(ctx.engine.finalizeCallCount == 1)
  }

  /// Cancel still wins on a USB take that went quiet: nothing is delivered,
  /// classified or retired.
  @Test("USB: cancel still ends a quiet take as cancelled")
  func usbCancelStillWins() async throws {
    let ctx = makeContext()
    ctx.capture.liveResolvedRoute = Self.route("usb")
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: prefix, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .cancelled)
    #expect(ctx.wrapper.testKernel.deliveredTranscript == nil)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.capture.retireCapturingSourceCallCount == 0)
  }

  /// A genuine device removal on a USB take still carries its own cause, so the
  /// completion disclosure says the microphone disconnected; the suffix rule only
  /// removes the zero-mode override, never a real interruption.
  @Test("USB: a real device removal keeps its cause and no zero-mode override")
  func usbDeviceRemovalKeepsItsCause() async throws {
    let ctx = makeContext()
    ctx.vad.evidence = .voiced
    ctx.capture.liveResolvedRoute = Self.route("usb")
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: prefix, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    await ctx.wrapper.drainReadyWork()
    // The simulator has no app-side router for engine interruptions, so the
    // test calls the kernel entry the router calls.
    ctx.wrapper.testKernel.externalEngineInterrupted(.deviceRemoved)
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.lastAudioInterruptionCause == .deviceRemoved)
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
  }

  /// The legacy zombie fallback stays silent on a suffix completion (the prefix
  /// has real energy), and the observation is live: an unclassified whole-zero
  /// take on a refused device still emits it.
  @Test("a suffix completion emits no zombie fallback; a refused whole-zero take does")
  func usbSuffixEmitsNoZombieFallback() async throws {
    let usb = makeContext()
    usb.vad.evidence = .voiced
    try await runTake(usb, route: Self.route("usb"), buffers: [(prefix, 0.2), (threshold, 0)])
    #expect(usb.wrapper.testKernel.recordingOutcome == .completed)
    #expect(usb.wrapper.zombieZeroPeaks.isEmpty)

    let control = makeContext(zeroSignalDecisionSnapshot: {
      ZeroSignalDecisionSnapshot(eligibility: .deviceMuted)
    })
    control.vad.evidence = .confirmedNoSpeech
    try await runTake(
      control, route: Self.route("built_in"), buffers: [(threshold * 2, 0)])
    #expect(control.wrapper.zombieZeroPeaks.count == 1, "control: the observation is wired")
  }

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
    await ctx.wrapper.drainUntilConcluded()
  }

  @Test("#1578 STOP: an ELIGIBLE whole-zero take keeps today's stall behaviour exactly")
  func stopEligibleUnclassifiedPreservesStallPath() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(eligibility: .eligible)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode != nil, "the stamp regressed")
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.count == 1)
    #expect(log.flattened.isEmpty, "an eligible run must produce no refusal")
  }

  @Test("#1578 STOP: a NON-ELIGIBLE whole-zero take emits one refusal and no stall")
  func stopNonEligibleUnclassifiedEmitsOneRefusal() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(eligibility: .notAlive)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(log.flattened.count == 1)
    #expect(log.flattened.first?.reason == .notAlive)
    #expect(log.flattened.first?.failureShape == .allZeroFromStart)
    // A refusal is an observation, never a stall confirmation.
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
  }

  // MARK: - #1578 group 4: refusal and retire CO-FIRE
  //
  // These are not mutually exclusive, and a test asserting exclusivity would
  // enforce a contract the code does not have. A refused FINAL run legitimately
  // produces both.

  /// #4841: a speech-then-zero take on a refused device emits neither a refusal
  /// nor a retire — the suffix is not a zero-signal shape any more.
  @Test("#4841: a refused device's suffix take emits no refusal and no retire")
  func refusedSuffixTakeEmitsNothing() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: { ZeroSignalDecisionSnapshot(eligibility: .deviceMuted) }, log: log)
    await startToRecording(ctx)
    ctx.capture.deliverBuffer(frameCount: 8_000, amplitude: 0.2)
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .voiced
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()

    #expect(ctx.wrapper.testKernel.recordingOutcome == .completed)
    #expect(log.flattened.isEmpty)
    #expect(ctx.wrapper.deadMicRetireAttempts.isEmpty)
  }

  @Test("#1578 co-fire: a refused FINAL run emits one refusal AND one refused retire")
  func refusedFinalRunCoFiresRefusalAndRetire() async {
    let log = RefusalSinkLog()
    let ctx = makeRefusalContext(
      snapshot: {
        ZeroSignalDecisionSnapshot(eligibility: .deviceMuted)
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
        ZeroSignalDecisionSnapshot(eligibility: .eligible)
      }, log: log)

    await driveZeroSignalStop(ctx)

    #expect(log.flattened.isEmpty)
    #expect(ctx.wrapper.deadMicRetireAttempts.count == 1)
    #expect(ctx.wrapper.deadMicRetireAttempts.first?.healthGuessRefused == false)
  }
}
