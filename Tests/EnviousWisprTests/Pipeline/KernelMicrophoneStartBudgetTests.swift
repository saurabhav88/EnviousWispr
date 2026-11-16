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

  private func makeWrapper() -> (FakeAudioCapture, KernelRecordingSession) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: FakeVADSignalSource(), clock: clock,
      paste: FakePasteTarget())
    return (capture, wrapper)
  }

  @Test("the take's start and its one rebuild both spend the press's deadline")
  func startAndRebuildShareTheDeadline() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [false, true]
    let deadline = ContinuousClock.now + .seconds(3)
    wrapper.microphoneStartDeadlineForTesting = deadline

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()

    #expect(capture.rebuildEngineCallCount == 1)
    #expect(capture.startEnginePhaseDeadlines == [deadline, deadline])
  }

  @Test("pre-warm spends the press's deadline")
  func preWarmUsesThePressDeadline() async throws {
    let (capture, wrapper) = makeWrapper()
    let deadline = ContinuousClock.now + .seconds(2)

    try await wrapper.testKernel.preWarm(microphoneStartDeadline: deadline)

    #expect(capture.preWarmDeadlines == [deadline])
  }
}
