import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #2787 — the kernel marks every stop→decode stage, in order, and clears the
/// checkpoint at the terminal.
///
/// **Observability contract:** when this fails, the launch-time report names
/// the wrong stage (or none) for a take the app died in the middle of, and the
/// fleet groups a hang under the wrong step. The customer's four takes reached
/// us as `app_phase=transcribing` with no stage at all; these marks are what
/// would have said "stuck inside the decode" versus "stuck stopping capture".
@MainActor
@Suite("Transcription checkpoint stages (#2787)", .tags(.observabilityContract))
struct TranscriptionCheckpointStagesTests {

  private func makeContext() -> (SimulatorContext, KernelRecordingSession) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return (
      SimulatorContext(
        sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste),
      wrapper
    )
  }

  private func stages(_ events: [TranscriptionCheckpointEvent]) -> [TranscriptionStage] {
    events.compactMap {
      if case .mark(_, _, let stage, _) = $0 { return stage }
      return nil
    }
  }

  @Test("a successful batch take marks the five stages in order and then clears")
  func happyPathMarksAllStagesThenClears() async {
    let (context, wrapper) = makeContext()
    let scenario = Scenario(
      id: "CK1", name: "checkpoint stages on a batch success",
      steps: [
        .engine(.setBehavior(.batchSuccess(text: "hello world"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted, transcript: .nonEmpty))
    let result = await ScenarioRunner().run(scenario, context: context)
    #expect(result.passed, "\(result.failures)")

    let events = wrapper.transcriptionCheckpointEvents
    #expect(
      stages(events) == [
        .captureStopped, .vadConditioned, .tailChecked, .decodeStarted, .decodeReturned,
      ])
    #expect(events.last == .clear, "the terminal must clear the checkpoint")
    // Every mark names the take and the engine, never text.
    for event in events {
      if case .mark(let takeID, let backend, _, let chunks) = event {
        #expect(UUID(uuidString: takeID) != nil, "take id must be the session UUID")
        #expect(backend == "parakeet")
        #expect(chunks == 0, "no vendor chunk progress is wired in this revision")
      }
    }
  }

  @Test("a cancel during the decode leaves decodeStarted as the last mark before the clear")
  func cancelDuringDecodeLeavesDecodeStartedAsLastMark() async {
    let (context, wrapper) = makeContext()
    // A decode that dwells (inventory A8's shape): the cancel lands inside
    // `transcribing`, with the finalize genuinely in flight.
    let scenario = Scenario(
      id: "CK2", name: "checkpoint stages when the decode is abandoned",
      steps: [
        .engine(.setBehavior(.slowFinalize(ticksToFinal: 3, text: "in flight"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .trigger(.cancel), .expectState(.cancelled),
      ],
      expected: ExpectedOutcome(
        terminalState: .cancelled, pasteCount: 0, pasteOutcome: .none, transcript: .none))
    let result = await ScenarioRunner().run(scenario, context: context)
    #expect(result.passed, "\(result.failures)")
    let events = wrapper.transcriptionCheckpointEvents
    #expect(stages(events).last == .decodeStarted, "the decode never returned")
    #expect(events.last == .clear, "the app lived to see the cancel; nothing to report later")
  }

  /// #2787 chunk 4: an OBSERVATION tick lands on the checkpoint as
  /// `decode_chunk_scheduled` with a running count, and does NOT arm the
  /// finalize-wedge detector. The discriminator: the kernel's test wedge window
  /// is 2 ticks and `slowFinalize` dwells 3, so an armed detector would tear the
  /// decode down (`.failed(.wedged)`) before it returned. `.completed` proves
  /// the tick was observed and nothing more.
  @Test("observation ticks are recorded with a count and never arm the wedge detector")
  func observationTicksAreRecordedAndNeverArmTheDetector() async {
    let (context, wrapper) = makeContext()
    let scenario = Scenario(
      id: "CK5", name: "observation ticks during a dwelling decode",
      steps: [
        .engine(.setBehavior(.slowFinalize(ticksToFinal: 3, text: "long take"))),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
        .engine(.emitObservationTick), .engine(.emitObservationTick),
        // The wedge detector's stall window is 2 ticks (`wedgeStallTicks`);
        // the decode dwells 3. Advancing 3 at once lets a wrongly armed
        // detector and the decode race (second-pass review), so the window is
        // supplied first and the session must STILL be transcribing.
        .advanceClock(ticks: 2),
        .expectState(.transcribing),
        .advanceClock(ticks: 1),
        .expectState(.completed),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .exact("long take")))
    let result = await ScenarioRunner().run(scenario, context: context)
    #expect(result.passed, "\(result.failures)")
    let events = wrapper.transcriptionCheckpointEvents
    let chunkMarks = events.compactMap { event -> Int? in
      if case .mark(_, _, .decodeChunkScheduled, let chunks) = event { return chunks }
      return nil
    }
    #expect(chunkMarks == [1, 2], "each observation tick carries the running chunk count")
    #expect(stages(events).last == .decodeReturned)
    #expect(events.last == .clear)
  }

  /// #2787 chunk 4 (Codex P1): a tick that arrives on a PREVIOUS decode
  /// attempt's stream — the failed first decode, after the retry has started
  /// — must not count against the retry. `crashOnFinalize` fails the first
  /// decode synchronously and the retry (`slow` is not needed: the fake's
  /// retry returns immediately) reads a fresh stream; the late tick is yielded
  /// on the OLD stream after that, and the count must stay at zero.
  @Test("a late tick from a previous decode attempt is not counted against the retry")
  func lateTickFromPreviousAttemptIsRejected() async throws {
    let (context, wrapper) = makeContext()
    context.engine.behavior = .crashOnFinalize
    // The retry must be ACTIVE when the stale tick lands, or `recordingOutcome`
    // rejects it on its own and the attempt-identity guard is untested.
    context.engine.retryDecodeDelayTicks = 3

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    context.capture.deliverBuffer(frameCount: 16_000, amplitude: 0.5)
    await wrapper.apply(.stop)
    await wrapper.drainReadyWork()

    try #require(context.engine.retryDecodeCallCount == 1, "the retry must be in flight")
    try #require(wrapper.testKernel.recordingOutcome == nil)

    // Stale tick on the failed first attempt's stream, then a genuine one on
    // the retry's stream: the positive control. Removing the identity guard
    // would admit both.
    context.engine.emitObservationTickOnPreviousStream()
    context.engine.emitObservationTick()
    await wrapper.drainReadyWork()

    let counts = wrapper.transcriptionCheckpointEvents.compactMap { event -> Int? in
      if case .mark(_, _, .decodeChunkScheduled, let count) = event { return count }
      return nil
    }
    #expect(counts == [1], "only the current attempt's tick may count: \(counts)")

    context.clock.advance(by: 3)
    await wrapper.drainUntilConcluded()
    #expect(wrapper.testKernel.recordingOutcome == .completed)
  }

  /// Codex chunk-3 P1: the Phase-2 retry is a decode too. A hang INSIDE the
  /// retry must read `decode_started`, never a stale `decode_returned` left by
  /// the first (failed) decode — so the marks go started/returned/started/returned.
  @Test("a failed decode rescued by the Phase-2 retry marks both decodes")
  func retryMarksBothDecodes() async {
    let (context, wrapper) = makeContext()
    let scenario = Scenario(
      id: "CK3", name: "checkpoint stages across a Phase-2 retry",
      steps: [
        .engine(.setBehavior(.crashOnFinalize)),
        .trigger(.start), .capture(.deliverBuffer), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .exact("retried transcript")))
    let result = await ScenarioRunner().run(scenario, context: context)
    #expect(result.passed, "\(result.failures)")
    let events = wrapper.transcriptionCheckpointEvents
    #expect(
      stages(events) == [
        .captureStopped, .vadConditioned, .tailChecked,
        .decodeStarted, .decodeReturned,  // the first decode, which failed
        .decodeStarted, .decodeReturned,  // the retry, which returned text
      ])
    #expect(events.last == .clear)
  }

  /// Codex chunk-3 P1: a cancel accepted while `stopCapture` is suspended has
  /// already cleared the checkpoint; the late stop return must not recreate
  /// it, or the next launch reports a false interruption. The fake capture's
  /// stop gate parks the first `stopCapture` so the cancel lands INSIDE the
  /// suspension, with the same session still current when the stop returns —
  /// the exact precondition the repaired guard exists for.
  @Test("a late stop return cannot recreate a cleared checkpoint")
  func nothingAfterTheClear() async throws {
    let (context, wrapper) = makeContext()
    context.capture.gateStopCaptureCall = 1

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    try #require(wrapper.testKernel.state == .live)

    context.capture.deliverBuffer(frameCount: 16_000, amplitude: 0.5)
    await wrapper.apply(.stop)
    // Signal-based: resume only once the stop has genuinely parked.
    await context.capture.awaitStopCaptureGateReached()
    try #require(wrapper.testKernel.state == .stopping)

    await wrapper.apply(.cancel)
    try #require(wrapper.testKernel.recordingOutcome == .cancelled)
    try #require(wrapper.transcriptionCheckpointEvents.last == .clear)
    let terminalEvents = wrapper.transcriptionCheckpointEvents

    // The suspended stop now returns for the cancelled session.
    context.capture.releaseStopCaptureGate()
    await wrapper.drainReadyWork()

    #expect(wrapper.effects.resourcesReleased, "the late stop return did run")
    #expect(
      wrapper.transcriptionCheckpointEvents == terminalEvents,
      "a mark after the clear would be a false report next launch: \(wrapper.transcriptionCheckpointEvents)")
  }
}
