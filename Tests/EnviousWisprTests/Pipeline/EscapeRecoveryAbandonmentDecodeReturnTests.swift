import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// The abandonment checks at the points where a decode actually returns
/// (#2087, chunk 7).
///
/// The suite above this one exercises the disposition and the second cancel
/// against a forced state. This one drives the REAL kernel through the
/// simulator, because the thing most likely to be wrong is not the rule but
/// WHERE it is checked: a single check before finalization would cover the
/// successful-transcript path and silently miss the empty, no-speech and failed
/// routes, each of which would then either run more ASR work after the user
/// asked for none, or conclude under an outcome that reports a deliberate
/// abandonment as a fault.
///
/// **The outcome alone is the wrong assertion, and mutation testing is what
/// showed it.** The four checks are redundant nets: remove any one and a later
/// one still ends the session `.cancelled`, so an outcome-only test passes
/// against three of the four sites being deleted. What each site uniquely buys
/// is that no FURTHER work runs after the user disowned it — no retry decode, no
/// salvage ladder, no polish. So each test below asserts work NOT DONE, which is
/// the only assertion a single missing net can fail.
@MainActor
@Suite("Escape Recovery abandonment at decode return points (#2087)")
struct EscapeRecoveryAbandonmentDecodeReturnTests {

  #if DEBUG

    /// Abandon while the decode is genuinely suspended, then let it fail. The
    /// engine's answer is `.failed(.engineCrashed)`; the session's answer must be
    /// `.cancelled`, because the user disowned the work before it returned.
    @Test("an abandoned recovery ends cancelled, not under the decode's own failure")
    func abandonedDecodeEndsCancelledNotFailed() async {
      let ctx = makeContext(behavior: .heldFinalize)
      await stopIntoHeldFinalize(ctx)
      let kernel = ctx.wrapper.testKernel
      #expect(kernel.deliveringPhase == .transcribing)

      kernel.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      kernel.cancel(origin: .user(.shortcut))
      #expect(kernel.recordingOutcome == nil, "abandonment must not conclude on its own")

      ctx.engine.resolveHeldFinalizeAsHelperDeath()
      await ctx.wrapper.drainUntilConcluded()

      #expect(kernel.recordingOutcome == .cancelled)
      // The site-specific assertion. A helper death normally routes into the one
      // Phase-2 retry; catching the abandonment at the PRIMARY return is what
      // stops that second decode from ever starting. Without this line the test
      // passes with the primary check deleted, because a later net still ends
      // the session `.cancelled` — after burning a retry the user did not want.
      #expect(
        ctx.engine.retryDecodeCallCount == 0,
        "no second decode may start after the user disowned the first")
      #expect(ctx.wrapper.storedTexts.isEmpty, "no row for a take the user discarded")
      #expect(ctx.paste.pasteAttempts.isEmpty, "and nothing pasted")
    }

    /// The control. Same script, no abandonment: the session must reach the
    /// outcome its decode produces. Without this, the test above would pass
    /// against a kernel that concluded `.cancelled` for every held finalize.
    @Test("without abandonment the same decode reaches its own outcome")
    func unabandonedDecodeKeepsItsOwnOutcome() async {
      let ctx = makeContext(behavior: .heldFinalize)
      ctx.engine.retryDecodeResult = .transcript(
        ASRResult(
          text: "kept", language: nil, duration: 0, processingTime: 0, backendType: .parakeet))
      await stopIntoHeldFinalize(ctx)
      let kernel = ctx.wrapper.testKernel

      ctx.engine.resolveHeldFinalizeAsHelperDeath()
      await ctx.wrapper.drainUntilConcluded()

      #expect(kernel.recordingOutcome != .cancelled)
      #expect(
        ctx.wrapper.asrTimingEndCount > 0,
        "the timing the abandoned case must not stamp does get stamped when nobody abandoned")
      #expect(
        ctx.engine.retryDecodeCallCount == 1,
        "the retry the abandoned case must skip does run when nobody abandoned")
      #expect(ctx.wrapper.storedTexts == ["kept"])
    }

    /// The Phase-2 retry is a SECOND decode return, and it needs its own check.
    ///
    /// Sequencing is the whole test. The primary decode must return FIRST, while
    /// the session is still ordinary, so the primary net passes and this is
    /// genuinely the retry's net being exercised. Abandonment lands afterwards,
    /// while the retry is still dwelling on the fake clock. An earlier version of
    /// this test set the disposition before resolving the primary decode and was
    /// therefore testing the primary net under a name claiming otherwise —
    /// mutation testing is what exposed it.
    @Test("abandoning while the Phase-2 retry is in flight ends cancelled and stores nothing")
    func abandonedDuringRetryEndsCancelled() async {
      let ctx = makeContext(behavior: .heldFinalize)
      ctx.engine.retryDecodeDelayTicks = 4
      ctx.engine.retryDecodeResult = .transcript(
        ASRResult(
          text: "rescued", language: nil, duration: 0, processingTime: 0, backendType: .parakeet))
      await stopIntoHeldFinalize(ctx)
      let kernel = ctx.wrapper.testKernel

      // Primary decode fails while the session is ORDINARY — the primary net
      // sees nothing, and the helper death routes into the one Phase-2 retry.
      ctx.engine.resolveHeldFinalizeAsHelperDeath()
      await ctx.wrapper.drainReadyWork()
      #expect(ctx.engine.retryDecodeCallCount == 1, "the retry must be in flight to abandon it")
      #expect(kernel.recordingOutcome == nil)

      kernel.testSetFinalizationDisposition(
        .abandonedEscapeRecovery(triggeredAt: Date()))
      ctx.clock.advance(by: 8)
      await ctx.wrapper.drainUntilConcluded()

      #expect(kernel.recordingOutcome == .cancelled)
      // The site-specific assertion, and the only one that separates the retry's
      // net from the finalizing net downstream of it: without the retry check
      // the session still ends `.cancelled`, but it first records the retry as a
      // SUCCESS — a rescue counted for a take nobody wanted rescued.
      #expect(
        ctx.wrapper.telemetryState.asrRetryOutcome != .retrySucceeded,
        "an abandoned session must not book a retry success")
      #expect(
        ctx.wrapper.storedTexts.isEmpty,
        "a retry that SUCCEEDS is the case that looks fine and is not")
      #expect(ctx.paste.pasteAttempts.isEmpty)
    }

    /// A session abandoned BEFORE its decode returns must not be classified by
    /// what the decode then says. This one is already abandoned when the primary
    /// decode resolves, so no ASR timing is stamped and no outcome switch runs.
    ///
    /// (An earlier version of this test reassigned the fake's `behavior` to
    /// `.empty` after the decode was already suspended, which changes nothing —
    /// a held finalize resolves as a helper death regardless. It was named for
    /// the no-speech path and never went near it.)
    @Test("a session abandoned before its decode returns stamps no ASR timing")
    func abandonedBeforeReturnStampsNoTiming() async {
      let ctx = makeContext(behavior: .heldFinalize)
      await stopIntoHeldFinalize(ctx)
      let kernel = ctx.wrapper.testKernel

      kernel.testSetFinalizationDisposition(
        .abandonedEscapeRecovery(triggeredAt: Date()))
      ctx.engine.resolveHeldFinalizeAsHelperDeath()
      await ctx.wrapper.drainUntilConcluded()

      #expect(kernel.recordingOutcome == .cancelled)
      #expect(
        ctx.wrapper.asrTimingEndCount == 0,
        "a session already disowned records no ASR latency for the decode it disowned")
      #expect(
        ctx.engine.retryDecodeCallCount == 0,
        "no retry may run for a session the user had already disowned")
      #expect(ctx.wrapper.storedTexts.isEmpty)
    }

    /// The salvage ladder's own check, which is the one net whose value is not
    /// about the terminal at all: it stops the NEXT candidate decode from being
    /// dispatched after the user abandoned. Every other net runs once a decode
    /// has already returned; this one runs between decodes, so without it an
    /// abandoned session keeps burning candidates against the single engine.
    ///
    /// The ladder is also where a successful candidate must still be thrown
    /// away, and where the abort reason has to distinguish a user's choice from
    /// a race — `"superseded"` would file this under "something went wrong".
    @Test("abandoning mid-ladder stops the next candidate and records the user's choice")
    func abandonMidLadderStopsFurtherCandidates() async {
      // Every decode empty, so the ladder walks its whole candidate list unless
      // something stops it.
      let ctx = makeContext(behavior: .empty(hadSpeechEvidence: true))
      let kernel = ctx.wrapper.testKernel
      // Abandon during the FIRST ladder candidate — call 1 is the primary
      // decode, so call 2 is the ladder's first.
      ctx.engine.onFinalizeCall = { call in
        if call == 2 {
          kernel.testSetFinalizationDisposition(
            .abandonedEscapeRecovery(triggeredAt: Date()))
        }
      }

      await runToTerminal(ctx)

      #expect(
        ctx.engine.finalizeCallCount == 2,
        "the ladder must stop dead: one primary decode, one candidate, no more")
      #expect(
        ctx.wrapper.telemetryState.asrEmptyDiagnostics?.salvageAbortedReason
          == "user_abandoned",
        "a user's choice must not be filed as a race")
      // Pins the ORDER of the three statements at the ladder's return: currency
      // guard, then abandonment check, then `markASRTimingEnd()`. Exactly one
      // stamp means only the primary decode's — moving the abandonment check
      // below the stamp makes this 2, which is the salvage stamp being written
      // for work the user disowned.
      #expect(
        ctx.wrapper.asrTimingEndCount == 1,
        "only the primary decode's stamp: the salvage stamp is downstream of the check")
      #expect(kernel.recordingOutcome == .cancelled)
      #expect(ctx.wrapper.storedTexts.isEmpty)
    }

    /// The control for the ladder test: with nobody abandoning, the same script
    /// walks MORE than one candidate. Without this, the assertion above passes
    /// against a ladder that only ever tried one.
    @Test("the same ladder tries several candidates when nobody abandons")
    func ladderWalksSeveralCandidatesNormally() async {
      let ctx = makeContext(behavior: .empty(hadSpeechEvidence: true))

      await runToTerminal(ctx)

      #expect(
        ctx.engine.finalizeCallCount > 2,
        "the abandoned run's stop-at-2 means nothing unless this run goes further")
      #expect(
        ctx.wrapper.telemetryState.asrEmptyDiagnostics?.salvageAbortedReason
          != "user_abandoned")
      // The other half of the ordering pin: an un-abandoned ladder DOES reach
      // the salvage stamp, so the abandoned run's count of 1 is the check
      // working rather than the stamp never firing on this path at all.
      #expect(
        ctx.wrapper.asrTimingEndCount == 2,
        "primary stamp plus the ladder's own, when nobody abandoned")
    }

    // MARK: Helpers (mirroring `KernelPhase2RetryTests`, which owns the pattern)

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

    /// The salvage ladder only runs on a DEGRADED LEAD, so a uniform buffer
    /// never reaches it — a first attempt at the two tests below used
    /// `deliverVoicedCapture` and asserted against a ladder that had not run.
    /// Its control caught that, and then caught a second version too: the
    /// single-dead-run shape `KernelSalvageRetryTests` uses yields exactly ONE
    /// candidate, so "the ladder stopped after one" was true of the control as
    /// well and proved nothing. TWO dead runs, each over the 0.4 s minimum and
    /// far enough apart to survive dedupe, so an unabandoned ladder genuinely
    /// walks more than one candidate. One VAD segment covers the take so the
    /// conditioner passes the buffer through with its geometry intact.
    private func deliverDegradedLeadCapture(_ ctx: Context) {
      ctx.capture.deliverBuffer(frameCount: 4000, amplitude: 0.3)
      ctx.capture.deliverBuffer(frameCount: 9600, amplitude: 0.002)
      ctx.capture.deliverBuffer(frameCount: 8000, amplitude: 0.3)
      ctx.capture.deliverBuffer(frameCount: 9600, amplitude: 0.002)
      ctx.capture.deliverBuffer(frameCount: 32000, amplitude: 0.25)
      ctx.vad.evidence = .voiced
      ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 63200)]
    }

    private func runToTerminal(_ ctx: Context) async {
      await ctx.wrapper.apply(.start)
      await ctx.wrapper.drainReadyWork()
      deliverDegradedLeadCapture(ctx)
      await ctx.wrapper.drainReadyWork()
      await ctx.wrapper.apply(.stop)
      await ctx.wrapper.drainUntilConcluded()
    }

    private func deliverVoicedCapture(_ ctx: Context) {
      ctx.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
      ctx.vad.evidence = .voiced
      ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
    }

    /// Park the kernel in `.delivering(.transcribing)` with the decode genuinely
    /// suspended, waiting on the fake's own registration signal rather than on
    /// scheduler timing.
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
  #endif
}
