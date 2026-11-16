import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

/// #4601 §3a: one press has ONE microphone-start budget. When these fail, a stuck audio driver
/// can hold the app's start past five seconds, because a later step (the take's own start or its
/// one rebuild) silently began a fresh budget. Drives the real kernel through `FakeAudioCapture`.
@MainActor
@Suite("RecordingSessionKernel — #4601 microphone start budget", .tags(.productOutcome))
struct KernelMicrophoneStartBudgetTests {

  private func makeWrapper(modelLoaded: Bool = false) async -> (
    FakeAudioCapture, KernelRecordingSession
  ) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    if modelLoaded { try? await engine.warmUp(modelReceipt: nil) }
    let capture = FakeAudioCapture()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: FakeVADSignalSource(), clock: clock,
      paste: FakePasteTarget())
    return (capture, wrapper)
  }

  @Test("the take's start and its one rebuild both spend the press's deadline")
  func startAndRebuildShareTheDeadline() async {
    let (capture, wrapper) = await makeWrapper()
    capture.stabilizationResults = [false, true]
    let deadline = ContinuousClock.now + .seconds(3)
    wrapper.microphoneStartDeadlineForTesting = deadline

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()

    #expect(capture.rebuildEngineCallCount == 1)
    // The fake engine starts cold, so the model load moved the deadline later once; the rebuild
    // spends the same (moved) instant, never a fresh budget.
    #expect(capture.startEnginePhaseDeadlines.count == 2)
    #expect(Set(capture.startEnginePhaseDeadlines).count == 1)
    #expect(capture.startEnginePhaseDeadlines.allSatisfy { $0 > deadline })
  }

  /// #4601 whole-diff review: a cold speech model can take longer than the whole budget to load
  /// before the microphone is even asked. When this fails, a healthy first dictation after launch
  /// tells the user their microphone cannot be reached.
  @Test("model loading does not spend the microphone budget; a warm model leaves it unchanged")
  func modelLoadIsNotMicrophoneWork() async {
    let deadline = ContinuousClock.now + .seconds(3)

    let (cold, coldWrapper) = await makeWrapper()
    coldWrapper.microphoneStartDeadlineForTesting = deadline
    await coldWrapper.apply(.start)
    await coldWrapper.drainReadyWork()
    #expect(cold.startEnginePhaseDeadlines.count == 1)
    #expect(cold.startEnginePhaseDeadlines.allSatisfy { $0 > deadline })

    // An already loaded model: no load, so the press's deadline reaches capture untouched.
    let (warm, warmWrapper) = await makeWrapper(modelLoaded: true)
    warmWrapper.microphoneStartDeadlineForTesting = deadline
    await warmWrapper.apply(.start)
    await warmWrapper.drainReadyWork()
    #expect(warm.startEnginePhaseDeadlines == [deadline])
  }

  /// #4601 §5: a press given up before its session existed keeps its press-time deadline, so the
  /// capture manager's abandonment check (which reads the press from the deadline) still refuses it.
  @Test("a start already given up keeps its press-time deadline through a model load")
  func abandonedStartKeepsItsDeadline() async {
    let (capture, wrapper) = await makeWrapper()
    capture.startAbandoned = true
    let deadline = ContinuousClock.now + .seconds(3)
    wrapper.microphoneStartDeadlineForTesting = deadline

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()

    #expect(capture.startEnginePhaseDeadlines == [deadline])
  }

  /// #4601 §3.7: a take whose own start was not answered ends with the not-responding reason,
  /// projected to the notice the user sees (not the generic capture error).
  @Test("an in-session start that was not answered ends with its own reason and notice")
  func notRespondingInSessionStart() async {
    let (capture, wrapper) = await makeWrapper()
    capture.startEnginePhaseError = AudioError.microphoneNotResponding(
      source: "HALDeviceInputSource.prepare.lane_wedged")

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()

    #expect(wrapper.testKernel.recordingOutcome == .failed(.micNotResponding))
    #expect(RecordingFailureReason.micNotResponding.terminalNoticeReason == .micNotResponding)
  }

  @Test("pre-warm spends the press's deadline")
  func preWarmUsesThePressDeadline() async throws {
    let (capture, wrapper) = await makeWrapper()
    let deadline = ContinuousClock.now + .seconds(2)

    try await wrapper.testKernel.preWarm(microphoneStartDeadline: deadline)

    #expect(capture.preWarmDeadlines == [deadline])
  }
}
