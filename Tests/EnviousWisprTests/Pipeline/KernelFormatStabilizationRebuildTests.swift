import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1445 kernel format-stabilization rebuild + diagnostic re-verify
//
// Change B of #1445: on the pre-capture stabilization site, a non-settled
// result triggers EXACTLY ONE `rebuildEngine()` + `startEnginePhase()`, and
// then ONE diagnostic re-verify `waitForFormatStabilization` whose result is
// written to the session's `formatStabilized` telemetry WITHOUT triggering a
// second rebuild. These tests drive the real kernel through the injected
// `FakeAudioCapture` and assert the call counts + the telemetry the observer
// reads (`captureStabilizationTelemetry`). Deterministic — scripted
// stabilization results + a continuation gate, never a wall-clock sleep
// (`test-timing`).

@MainActor
@Suite("RecordingSessionKernel — #1445 format-stabilization rebuild + re-verify")
struct KernelFormatStabilizationRebuildTests {

  private func makeWrapper() -> (FakeAudioCapture, KernelRecordingSession) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return (capture, wrapper)
  }

  private func startAndSettle(_ wrapper: KernelRecordingSession) async {
    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
  }

  // Case 1 — a stable device settles on the first check: no rebuild, no re-verify.
  @Test("stable device: one stabilization check, zero rebuilds")
  func stableDeviceNoRebuild() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [true]

    await startAndSettle(wrapper)

    #expect(capture.stabilizationCallCount == 1)
    #expect(capture.rebuildEngineCallCount == 0)
    let tel = wrapper.testKernel.captureStabilizationTelemetry
    #expect(tel.formatStabilized == true)
    #expect(tel.rebuiltForFormat == false)
  }

  // Case 2 — unstable then stable: one rebuild, one re-verify that succeeds.
  @Test("unstable-then-stable: exactly one rebuild, re-verify succeeds, capture proceeds")
  func unstableThenStableOneRebuild() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [false, true]

    await startAndSettle(wrapper)

    #expect(capture.stabilizationCallCount == 2)
    #expect(capture.rebuildEngineCallCount == 1)
    #expect(capture.startEnginePhaseCallCount == 2)  // initial + the one rebuild
    #expect(capture.beginCapturePhaseCallCount == 1)  // capture proceeded
    let tel = wrapper.testKernel.captureStabilizationTelemetry
    #expect(tel.formatStabilized == true)  // truer POST-rebuild value
    #expect(tel.rebuiltForFormat == true)  // a rebuild stays visible
  }

  // Case 3 — still-unstable after the rebuild: NO second rebuild, honest telemetry.
  @Test("still-unstable after rebuild: no second rebuild, formatStabilized=false, capture proceeds")
  func stillUnstableNoSecondRebuild() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [false, false]

    await startAndSettle(wrapper)

    #expect(capture.stabilizationCallCount == 2)  // one initial + one re-verify
    #expect(capture.rebuildEngineCallCount == 1)  // exactly one rebuild, never two
    #expect(capture.beginCapturePhaseCallCount == 1)  // best-effort: capture still proceeds
    let tel = wrapper.testKernel.captureStabilizationTelemetry
    #expect(tel.formatStabilized == false)  // honest post-rebuild failure
    #expect(tel.rebuiltForFormat == true)  // the rebuild remains recorded
  }

  // Case 4 — cancel WHILE the diagnostic re-verify is in flight: the existing
  // stop/cancel latch after the new await prevents capture from beginning.
  @Test("cancel during the post-rebuild re-verify: capture never begins, session cancels")
  func cancelDuringReverify() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [false, true]
    capture.gateStabilizationCall = 2  // park the re-verify

    await wrapper.apply(.start)  // spawns the forward path (synchronous)
    await capture.awaitStabilizationGateReached()  // forward path parked at the re-verify
    #expect(wrapper.testKernel.state == .arming)  // not yet .live

    wrapper.testKernel.cancel()  // cancelRequested latched pre-recording
    capture.releaseStabilizationGate()
    await wrapper.drainReadyWork()

    #expect(wrapper.testKernel.recordingOutcome == .cancelled)
    #expect(capture.rebuildEngineCallCount == 1)  // rebuild had already happened
    #expect(capture.stabilizationCallCount == 2)  // the re-verify ran to completion
    #expect(capture.beginCapturePhaseCallCount == 0)  // the cancel latch stopped capture
  }
}
