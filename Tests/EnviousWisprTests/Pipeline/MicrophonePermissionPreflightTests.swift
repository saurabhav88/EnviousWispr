import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - MicrophonePermissionPreflightTests (#2549)
//
// Before this fix, a denied-mic take reached the zero-signal/VAD terminals
// instead of `.permissionDenied`, because the engine-start step had no live
// permission check of its own — only a thrown-error text match that a denied
// mic does not reliably trigger. These tests drive the REAL
// `RecordingSessionKernel` through the simulator fakes and assert the new
// preflight fires before the capture engine is ever asked to start.

@MainActor
@Suite("RecordingSessionKernel — microphone-permission preflight (#2549)", .tags(.productOutcome))
struct MicrophonePermissionPreflightTests {

  private func makeSession(microphonePermissionIsDenied: @escaping @MainActor () -> Bool) -> (
    wrapper: KernelRecordingSession, capture: FakeAudioCapture
  ) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
      microphonePermissionIsDenied: microphonePermissionIsDenied)
    return (wrapper, capture)
  }

  @Test("denied mic ends .failed(.permissionDenied) without ever starting the engine")
  func deniedMicSkipsEngineStart() async {
    let (wrapper, capture) = makeSession(microphonePermissionIsDenied: { true })
    await wrapper.apply(.start)
    await wrapper.drainUntilConcluded()

    let kernel = wrapper.testKernel
    #expect(kernel.recordingOutcome == .failed(.permissionDenied))
    #expect(
      capture.startEnginePhaseCallCount == 0,
      "a denied-mic take must never reach the capture engine at all")
  }

  @Test("granted mic is unaffected — defaulted behavior is byte-identical to before #2549")
  func grantedMicUnaffected() async {
    let (wrapper, capture) = makeSession(microphonePermissionIsDenied: { false })
    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
    await wrapper.drainReadyWork()
    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()

    #expect(capture.startEnginePhaseCallCount == 1)
    #expect(wrapper.testKernel.recordingOutcome == .completed)
  }
}
