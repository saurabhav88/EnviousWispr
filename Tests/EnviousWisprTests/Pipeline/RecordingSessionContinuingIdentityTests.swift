import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

// MARK: - RecordingSessionContinuingIdentityTests (#1631)
//
// `continuingSessionID` is the authority the hands-free publication gate asks
// before showing a lock. It answers ONE question — "is a session still genuinely
// continuing, and which one" — and its `nil` deliberately covers both "no
// session" and "a session whose exit is already latched".
//
// The case that matters most is the last one: a recording exit is latched
// SYNCHRONOUSLY by `deliverRecordingExit`, and the state advance happens
// afterwards on the forward path. So there is a real window where the raw state
// still reads `.live` while the session is already committed to leaving capture.
// The presentation-facing `PipelineState` cannot express that window, which is
// exactly why publication does not use it.

#if DEBUG

  @MainActor
  @Suite struct RecordingSessionContinuingIdentityTests {

    private func makeKernel() -> RecordingSessionKernel {
      RecordingSessionKernel(
        adapter: FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock()),
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 },
        sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _, _, _ in },
        deliver: { _, _ in .pasted },
        engineMutationScope: .alwaysAllowedForTesting,
        minimumRecordingTicks: 0,
        telemetryState: KernelTelemetryState())
    }

    @Test("a clean arming session reports its own id")
    func armingReportsID() {
      let kernel = makeKernel()
      kernel.testForceState(.arming)
      #expect(kernel.continuingSessionID == kernel.currentSessionID.raw.uuidString)
    }

    @Test("a clean live session reports its own id")
    func liveReportsID() {
      let kernel = makeKernel()
      kernel.testForceState(.live)
      #expect(kernel.continuingSessionID == kernel.currentSessionID.raw.uuidString)
    }

    @Test(
      "no session is continuing at idle, stopping or delivering",
      arguments: [RecordingSessionState.idle, .stopping, .delivering])
    func nonContinuingStatesReportNil(state: RecordingSessionState) {
      let kernel = makeKernel()
      kernel.testForceState(state)
      #expect(kernel.continuingSessionID == nil)
    }

    @Test("a stop latched while arming stops the session continuing")
    func stopLatchedWhileArming() {
      let kernel = makeKernel()
      kernel.testForceState(.arming)
      #expect(kernel.continuingSessionID != nil, "control: continuing before the stop")
      kernel.requestStop()
      #expect(kernel.continuingSessionID == nil)
    }

    @Test("a cancel while arming stops the session continuing")
    func cancelWhileArming() {
      let kernel = makeKernel()
      kernel.testForceState(.arming)
      #expect(kernel.continuingSessionID != nil, "control: continuing before the cancel")
      kernel.cancel()
      #expect(kernel.continuingSessionID == nil)
    }

    /// The window `PipelineState` cannot express, and the reason this accessor
    /// exists rather than a state check.
    @Test("a latched recording exit stops the session continuing while state is still live")
    func recordingExitLatchedWhileStillLive() {
      let kernel = makeKernel()
      kernel.testForceState(.live)
      #expect(kernel.continuingSessionID != nil, "control: continuing before the exit")
      kernel.requestStop()  // `.live` → deliverRecordingExit latches synchronously
      #expect(
        kernel.state == .live,
        "precondition: the raw state has NOT advanced yet — this is the whole window")
      #expect(
        kernel.continuingSessionID == nil,
        "a session committed to exiting must not be publishable as hands-free")
    }

    @Test("a reported id always equals the kernel's current session id")
    func reportedIDMatchesCurrentSession() {
      let kernel = makeKernel()
      kernel.testForceState(.live)
      let reported = kernel.continuingSessionID
      #expect(reported != nil)
      #expect(reported == kernel.currentSessionID.raw.uuidString)
    }
  }

#endif
