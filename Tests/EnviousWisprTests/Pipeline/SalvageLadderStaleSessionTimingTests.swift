import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// The degraded-lead salvage ladder must not stamp ASR timing once its session
/// has stopped being the live one.
///
/// `markASRTimingEnd()` writes into the kernel's single shared
/// `KernelFinalizationOutcome`, not a per-session value. The ladder AWAITS, so a
/// session can be superseded or concluded while it runs — and the stamp sat
/// ahead of any currency guard, with the only guard living inside the
/// `salvaged != nil` arm. A stale ladder therefore overwrote the LIVE session's
/// `asrEndedAtSeconds`, corrupting the NEXT dictation's reported ASR latency
/// while leaving both sessions' own terminals correct, which is why nothing
/// caught it.
///
/// #1725's cloud review fixed exactly this on the Phase-2 retry path. This is
/// the one place that fix did not reach.
@MainActor
@Suite("Degraded-lead salvage: no timing stamp for a stale session")
struct SalvageLadderStaleSessionTimingTests {

  #if DEBUG

    /// The regression. The ladder is interrupted mid-run by its session
    /// concluding; only the primary decode's stamp may survive.
    @Test("a ladder whose session concluded mid-run stamps no salvage timing")
    func staleLadderDoesNotStampTiming() async {
      let ctx = makeContext()
      let kernel = ctx.wrapper.testKernel
      // Call 1 is the primary decode; call 2 is the ladder's first candidate.
      // Conclude the session while that candidate is in flight.
      ctx.engine.onFinalizeCall = { call in
        if call == 2 { kernel.testForceConclude(.completed) }
      }

      await runToTerminal(ctx)

      #expect(
        ctx.wrapper.asrTimingEndCount == 1,
        "the primary decode's stamp only — a concluded session must not write again")
    }

    /// The control. Without the interruption the same script reaches the
    /// ladder's own stamp, so the assertion above is the guard working rather
    /// than the salvage stamp never firing on this path.
    @Test("an uninterrupted ladder does stamp its own timing")
    func liveLadderStampsItsOwnTiming() async {
      let ctx = makeContext()

      await runToTerminal(ctx)

      #expect(
        ctx.wrapper.asrTimingEndCount == 2,
        "primary decode plus the ladder's own stamp")
    }

    // MARK: Helpers

    private struct Context {
      let wrapper: KernelRecordingSession
      let engine: FakeEngine
      let capture: FakeAudioCapture
      let vad: FakeVADSignalSource
      let paste: FakePasteTarget
    }

    private func makeContext() -> Context {
      let clock = FakeClock()
      // Every decode empty, so the ladder walks its candidates.
      let engine = FakeEngine(behavior: .empty(hadSpeechEvidence: true), clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let paste = FakePasteTarget()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      return Context(wrapper: wrapper, engine: engine, capture: capture, vad: vad, paste: paste)
    }

    /// The ladder only runs on a DEGRADED LEAD, so a uniform buffer never
    /// reaches it. Two dead runs, each over the 0.4 s minimum and spaced beyond
    /// dedupe, so the ladder has more than one candidate to walk.
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
      await ctx.wrapper.drainReadyWork()
    }
  #endif
}
