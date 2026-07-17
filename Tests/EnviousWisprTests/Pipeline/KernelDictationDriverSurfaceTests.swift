import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelDictationDriverSurfaceTests (epic #827, PR-4b.2 §11)
//
// Coverage for `reset()` and `currentSessionConfig`'s initial-nil contract.
//
// #1594 (2026-07-17): this file originally also carried one test each for
// cancelRecording, stopAndTranscribe-at-terminal, handleEngineInterruption,
// and handleASRServiceInterruption. All 4 called the method and asserted
// nothing beyond "didn't crash/hang" — every one of them would have stayed
// green even if the method were deleted. Removed rather than kept as
// always-passing duplicates; real coverage for each already exists:
//   - cancelRecording: `CancellationSilentUnwindTests.swift` drives an ACTIVE
//     recording session into cancel and asserts state == .idle, zero ASR
//     calls, and zero Sentry error breadcrumbs — strictly stronger than the
//     idle-state no-op case this file used to check.
//   - stopAndTranscribe / handleEngineInterruption / handleASRServiceInterruption:
//     `KernelDictationDriverBridgeMatrixTests` freezes the exact no-op-at-idle
//     case (plus the active-state bridging behavior this file never touched)
//     with real state assertions, per that file's own "existing
//     KernelDictationDriverSurfaceTests" coverage-scope comment — this was
//     the half of that split that never actually landed.
//
// Each remaining test constructs the driver via the public
// `KernelDictationDriverFactory.makeForParakeet(inputs:)` and exercises the
// method, then observes the kernel side-effect.
//
// `#if DEBUG`-gated: factory uses the real kernel, and one test drives state
// through `testForceTransition` (a `#if DEBUG`-only hook).

#if DEBUG

  @MainActor
  @Suite struct KernelDictationDriverSurfaceTests {

    // MARK: Helpers

    private func makeDriver() -> KernelDictationDriver {
      let audio = FakeAudioCapture()
      let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(audioCapture: audio)
      let inputs = KernelDictationDriverFactory.ParakeetInputs(
        audioCapture: audio,
        asrManager: StubParakeetASRManager(),
        vadSignalSource: vad,
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry())
      return KernelDictationDriverFactory.makeForParakeet(inputs: inputs)
    }

    // MARK: 1. reset clears external error + forwards to kernel.reset

    @Test("reset() clears the external-error surface")
    func resetClearsExternalError() {
      let driver = makeDriver()
      driver.setTerminalReason(.modelWedged)
      if case .error = driver.state {
      } else {
        Issue.record("setTerminalReason should park driver in .error")
      }
      driver.reset()
      // The state mapper returns .idle from the kernel's resting state once
      // the external error is cleared.
      #expect(driver.state == .idle)
    }

    // MARK: 2. currentSessionConfig reads context.config

    @Test("currentSessionConfig returns nil before any session")
    func currentSessionConfigNilBeforeSession() {
      let driver = makeDriver()
      #expect(driver.currentSessionConfig == nil)
      // Post-toggle set/clear behavior is covered by
      // KernelDictationDriverConfigBindingTests, which drains to a
      // deterministic state instead of accepting either nil or non-nil.
    }
  }

#endif  // DEBUG
