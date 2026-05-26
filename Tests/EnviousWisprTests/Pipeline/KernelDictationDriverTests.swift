import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelDictationDriverTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `KernelDictationDriver` — the state / overlay maps, the
// PipelineEvent dispatch, the external-error surface, and the no-op contracts.

@MainActor
@Suite struct KernelDictationDriverTests {

  // MARK: RecordingSessionState -> PipelineState map (pure, total)

  @Test("the state map is total and isActive holds for every active kernel state")
  func stateMapIsTotal() {
    func mapped(_ s: RecordingSessionState) -> PipelineState {
      KernelDictationDriver.pipelineState(for: s, externalError: nil)
    }
    // Idle-class terminals collapse to idle (silent — no error surface).
    #expect(mapped(.idle) == .idle)
    #expect(mapped(.cancelled) == .idle)
    #expect(mapped(.discarded) == .idle)
    #expect(mapped(.noSpeech) == .idle)
    // Active states — every one must report `isActive` so the backend-switch
    // guard (`PipelineSettingsSync`, §3.13) sees the kernel session as active.
    for s: RecordingSessionState in [
      .preparing, .warmingUp, .recording, .stopping, .transcribing, .finalizing,
    ] {
      #expect(mapped(s).isActive, "\(s) must map to an active PipelineState")
    }
    #expect(mapped(.recording) == .recording)
    #expect(mapped(.completed) == .complete)
    // Error-surface terminals.
    if case .error = mapped(.failed(.asrEmpty)) {
    } else {
      Issue.record("failed should map to .error")
    }
    if case .error = mapped(.audioInterrupted) {
    } else {
      Issue.record("audioInterrupted should map to .error")
    }
    if case .error = mapped(.asrInterrupted) {
    } else {
      Issue.record("asrInterrupted should map to .error")
    }
  }

  @Test("an external error overrides the mapped state")
  func externalErrorOverridesState() {
    #expect(
      KernelDictationDriver.pipelineState(for: .idle, externalError: "boom") == .error("boom"))
    #expect(
      KernelDictationDriver.pipelineState(for: .recording, externalError: "boom")
        == .error("boom"))
  }

  @Test("failureMessage mirrors the shipped strings for the equivalent failures")
  func failureMessages() {
    #expect(KernelDictationDriver.failureMessage(.asrEmpty) == "Couldn't catch that -- try again")
    #expect(KernelDictationDriver.failureMessage(.noAudioCaptured) == "No audio captured")
    #expect(KernelDictationDriver.failureMessage(.storageFailed) == "Failed to save transcript")
    #expect(
      KernelDictationDriver.failureMessage(.emptyAfterProcessing)
        == "No speech detected. Your clipboard is unchanged. Try again.")
  }

  @Test("failureMessage embeds error detail for the three TP-parity reasons (Div 4)")
  func failureMessagesWithDetail() {
    // Parity with the old Parakeet pipeline at TP:440-445 / TP:577-588 / TP:1045-1051:
    // include `error.localizedDescription` when present.
    #expect(
      KernelDictationDriver.failureMessage(.modelLoadFailed, detail: "out of memory")
        == "Model load failed: out of memory")
    #expect(
      KernelDictationDriver.failureMessage(.captureStartFailed, detail: "device busy")
        == "Recording failed: device busy")
    #expect(
      KernelDictationDriver.failureMessage(.asrFailed, detail: "stream closed")
        == "Transcription failed: stream closed")
    // No detail → byte-parity with the bare strings.
    #expect(KernelDictationDriver.failureMessage(.modelLoadFailed) == "Model load failed.")
    #expect(KernelDictationDriver.failureMessage(.captureStartFailed) == "Recording failed.")
    #expect(KernelDictationDriver.failureMessage(.asrFailed) == "Transcription failed.")
    // Other reasons ignore the detail (out-of-scope for parity).
    #expect(
      KernelDictationDriver.failureMessage(.asrEmpty, detail: "irrelevant")
        == "Couldn't catch that -- try again")
  }

  // MARK: handle(event:) -> kernel triggers

  @Test("handle(.toggleRecording) from idle starts a kernel session")
  func toggleRecordingStarts() async throws {
    let h = makeDriver()
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state == .recording }
    #expect(h.kernel.state == .recording)
    #expect(h.driver.state == .recording)
  }

  @Test("handle(.toggleRecording) while recording requests a stop")
  func toggleRecordingWhileActiveStops() async throws {
    let h = makeDriver()
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state == .recording }
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state.isTerminal }
    #expect(h.kernel.state.isTerminal, "the second toggle drove the session to a terminal")
  }

  // MARK: External-error surface

  @Test("setExternalError surfaces .error on state and overlay")
  func setExternalErrorSurfaces() {
    let h = makeDriver()
    h.driver.setExternalError("device unplugged")
    #expect(h.driver.state == .error("device unplugged"))
    #expect(h.driver.overlayIntent == .error(message: "device unplugged"))
  }

  @Test("a new start clears the external error")
  func startClearsExternalError() async throws {
    let h = makeDriver()
    h.driver.setExternalError("device unplugged")
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state == .recording }
    #expect(h.driver.state != .error("device unplugged"))
  }

  @Test("clearPendingStallRecovery is an inert no-op")
  func clearPendingStallRecoveryIsNoOp() {
    let h = makeDriver()
    let before = h.driver.state
    h.driver.clearPendingStallRecovery()
    #expect(h.driver.state == before)
  }

  // MARK: currentTranscript / lastPolishError side-channel

  @Test("currentTranscript and lastPolishError read the finalization side-channel")
  func sideChannelReads() {
    let h = makeDriver()
    #expect(h.driver.currentTranscript == nil)
    h.outcome.transcript = Transcript(text: "hello world")
    h.outcome.polishError = "polish timed out"
    #expect(h.driver.currentTranscript?.text == "hello world")
    #expect(h.driver.lastPolishError == "polish timed out")
  }

  @Test("reset() clears currentTranscript (sync entry — parity with TP:1081-1102)")
  func syncResetClearsTranscript() {
    let h = makeDriver()
    h.outcome.transcript = Transcript(text: "old session")
    #expect(h.driver.currentTranscript?.text == "old session")
    h.driver.reset()
    #expect(h.driver.currentTranscript == nil)
  }

  @Test("handle(.reset) clears currentTranscript (event entry — parity with TP:1081-1102)")
  func eventResetClearsTranscript() async throws {
    let h = makeDriver()
    h.outcome.transcript = Transcript(text: "old session")
    #expect(h.driver.currentTranscript?.text == "old session")
    try await h.driver.handle(event: .reset)
    #expect(h.driver.currentTranscript == nil)
  }

  #if DEBUG
    @Test(
      "reset() preserves the transcript when the kernel is in the finalizing safe-point"
    )
    func resetDuringFinalizingPreservesTranscript() {
      let h = makeDriver()
      // Walk to .finalizing — the safe-point window where the in-flight
      // session may still legitimately reach `.completed` and history +
      // completion telemetry must see the saved transcript.
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .recording))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .transcribing))
      #expect(h.kernel.testForceTransition(to: .finalizing))
      h.outcome.transcript = Transcript(text: "in-flight save")
      h.driver.reset()
      #expect(h.driver.currentTranscript?.text == "in-flight save")
    }
  #endif

  // MARK: Helpers

  private struct Harness {
    let driver: KernelDictationDriver
    let kernel: RecordingSessionKernel
    let outcome: KernelFinalizationOutcome
  }

  private func makeDriver() -> Harness {
    let kernel = RecordingSessionKernel(
      adapter: FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock()),
      audioCapture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      currentTick: { 0 },
      sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _ in },
      deliver: { _ in .pasted },
      minimumRecordingTicks: 0)  // PR-4.5 #4: clock never advances; opt out of the gate
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(), emitLifecycleEvent: { _ in })
    let outcome = KernelFinalizationOutcome()
    let steps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()))
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: outcome,
      context: KernelSessionContext(), steps: steps)
    driver.start()
    return Harness(driver: driver, kernel: kernel, outcome: outcome)
  }

  private func drainUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
      if condition() { return }
      await Task.yield()
    }
  }
}
