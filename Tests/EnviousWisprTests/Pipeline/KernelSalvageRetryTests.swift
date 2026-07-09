import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1434 degraded-lead salvage ladder (kernel routing)
//
// Drives the REAL `RecordingSessionKernel` through the simulator fakes with a
// buffer shaped like the measured AirPods failure (burst → near-dead window →
// recovered speech). `FakeEngine.emptyThenScripted` scripts the primary decode
// empty and the retry outcome; assertions cover delivery, terminal choice,
// retry bounds, telemetry stamping, and the only-consumed-post-empty contract.

@MainActor
@Suite("RecordingSessionKernel — degraded-lead salvage (#1434)")
struct KernelSalvageRetryTests {

  private struct Context {
    let wrapper: KernelRecordingSession
    let engine: FakeEngine
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
    let paste: FakePasteTarget
  }

  private func makeContext(behavior: FakeEngineBehavior) -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return Context(wrapper: wrapper, engine: engine, capture: capture, vad: vad, paste: paste)
  }

  /// Deliver the measured failure shape: 0.5 s healthy speech, 1.0 s near-dead
  /// window (well below −24 dB of the speech level), 1.5 s recovered speech.
  /// One VAD segment covers the whole take so the conditioner passes the raw
  /// buffer through and `asrSamples` keeps the dead-run geometry.
  private func deliverFailureShapedCapture(_ ctx: Context) {
    ctx.capture.deliverBuffer(frameCount: 8000, amplitude: 0.3)
    ctx.capture.deliverBuffer(frameCount: 16000, amplitude: 0.002)
    ctx.capture.deliverBuffer(frameCount: 24000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
  }

  private func runToTerminal(_ ctx: Context) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    deliverFailureShapedCapture(ctx)
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
  }

  @Test("empty primary decode + non-empty retry → salvaged completion delivers the retry text")
  func salvageSucceedsAndDelivers() async throws {
    let ctx = makeContext(behavior: .emptyThenScripted(text: "salvaged text", emptyCalls: 1))
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.state == .completed)
    #expect(kernel.deliveredTranscript == "salvaged text")
    #expect(kernel.pasteCount == 1)
    // Exactly one retry fired (one candidate from this shape): primary + 1.
    #expect(ctx.engine.finalizeCallCount == 2)
    // The retry received a TRIMMED buffer — strictly smaller than the
    // conditioned capture, still larger than the recovered-speech region
    // alone (the trim lands at the dead run's wake, not inside speech).
    let retrySamples = try #require(ctx.engine.lastFinalizeBatchSamples)
    #expect(retrySamples.count < 48000)
    #expect(retrySamples.count >= 24000)
    // The salvage marker the App layer reads for the disclosure pill +
    // telemetry is set and plausible (trim inside the dead window's span).
    let trimMs = try #require(kernel.lastSalvagedLeadTrimMs)
    #expect((500...1600).contains(trimMs))
  }

  @Test("all retries empty → today's asrEmpty terminal, ladder bounded by the candidate count")
  func allRetriesEmptyFallsThrough() async {
    let ctx = makeContext(behavior: .emptyThenScripted(text: "never", emptyCalls: 99))
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.state == .failed(.asrEmpty))
    #expect(kernel.deliveredTranscript == nil)
    #expect(kernel.pasteCount == 0)
    #expect(kernel.lastSalvagedLeadTrimMs == nil)
    // Bounded: primary + ≤ maxCandidates retries, and ≥ one retry ran.
    #expect(ctx.engine.finalizeCallCount >= 2)
    #expect(ctx.engine.finalizeCallCount <= 1 + DegradedLeadDiagnostics.maxCandidates)
  }

  @Test("retry returning .failed aborts the ladder without upgrading the terminal")
  func retryFailureAbortsToASREmpty() async {
    let ctx = makeContext(
      behavior: .emptyThenScripted(text: "never", emptyCalls: 1, thenFailure: true))
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    // The primary decode classified the session as empty; a retry-path error
    // must not surface as `.asrFailed`.
    #expect(kernel.state == .failed(.asrEmpty))
    #expect(ctx.engine.finalizeCallCount == 2)
    #expect(kernel.lastSalvagedLeadTrimMs == nil)
  }

  @Test("no candidates (healthy-shaped capture) → no retry, terminal unchanged from A11")
  func noCandidatesMeansNoRetry() async {
    let ctx = makeContext(behavior: .emptyThenScripted(text: "never", emptyCalls: 99))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    // Continuously loud capture — no dead run, detector yields nothing.
    ctx.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.state == .failed(.asrEmpty))
    // Exactly the primary decode — the ladder never dispatched.
    #expect(ctx.engine.finalizeCallCount == 1)
  }

  @Test("successful decode never consults the detector — happy path untouched")
  func happyPathNeverRetries() async {
    // The failure-shaped capture WOULD produce candidates; a successful decode
    // must never use them (only-consumed-post-empty contract, the pair to the
    // detector's adversarial legit-pause test).
    let ctx = makeContext(behavior: .batchSuccess(text: "normal text"))
    await runToTerminal(ctx)
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.state == .completed)
    #expect(kernel.deliveredTranscript == "normal text")
    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(kernel.lastSalvagedLeadTrimMs == nil)
  }

  @Test("energy-only no-segments path keeps its quiet noSpeech routing (#964) — no salvage")
  func energyOnlyPathExcluded() async {
    let ctx = makeContext(behavior: .emptyThenScripted(text: "never", emptyCalls: 99))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    // Audible energy but ZERO VAD segments → the kernel reaches ASR on the
    // energy path; an empty decode must stay `.noSpeech` and must not retry.
    deliverFailureShapedCapture(ctx)
    ctx.vad.evidence = .confirmedNoSpeech
    ctx.vad.segments = []
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.state == .noSpeech)
    #expect(ctx.engine.finalizeCallCount == 1)
    #expect(kernel.lastSalvagedLeadTrimMs == nil)
  }

  @Test("a fresh session after a salvaged completion starts clean")
  func sessionAfterSalvageStartsClean() async {
    let ctx = makeContext(behavior: .emptyThenScripted(text: "salvaged text", emptyCalls: 1))
    await runToTerminal(ctx)
    #expect(ctx.wrapper.testKernel.lastSalvagedLeadTrimMs != nil)

    // Second session: normal success. The salvage marker must clear at the
    // `→ recording` transition (the App layer reads it per-completion), and
    // the adapter-session bookkeeping from the retry must not leak.
    ctx.engine.behavior = .batchSuccess(text: "second take")
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    ctx.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
    let kernel = ctx.wrapper.testKernel

    #expect(kernel.state == .completed)
    #expect(kernel.deliveredTranscript == "second take")
    #expect(kernel.lastSalvagedLeadTrimMs == nil)
  }
}
