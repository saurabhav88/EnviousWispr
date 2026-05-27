import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

// MARK: - KernelDictationDriverPublicSurfaceTests (epic #827, PR-4b.2 §11)
//
// COMPILE-TIME architecture test. Imports `EnviousWisprPipeline` WITHOUT
// `@testable` to prove that an App-layer consumer can:
//   1. Construct `KernelDictationDriverFactory.ParakeetInputs` from purely public types.
//   2. Call `KernelDictationDriverFactory.makeForParakeet(inputs:)` and receive the
//      public `KernelDictationDriver`.
//   3. Read every App-consumed member from the returned driver (state,
//      overlayIntent, currentTranscript, lastPolishError, four limb-step
//      accessors, onStateChange, the 5 new methods, currentSessionConfig).
//
// If a `public` modifier was missed on the driver, factory, or `Inputs`, this
// file fails to COMPILE — earlier than any runtime test could detect.

@MainActor
@Suite struct KernelDictationDriverPublicSurfaceTests {

  @Test("the driver's full App-consumed surface is reachable without @testable")
  func publicSurfaceCompiles() {
    // FakeAudioCapture + StubParakeetASRManager live in the same test target
    // so they are accessible without `@testable import EnviousWisprPipeline`.
    // The point of this file is to prove the PIPELINE's public surface is
    // reachable, not the test target's own internals.
    let inputs = KernelDictationDriverFactory.ParakeetInputs(
      audioCapture: FakeAudioCapture(),
      asrManager: StubParakeetASRManager(),
      transcriptStore: TranscriptStore(),
      keychainManager: KeychainManager(),
      captureTelemetry: CaptureTelemetryState(),
      pasteCompletionRegistry: PasteCompletionRegistry())
    let driver = KernelDictationDriverFactory.makeForParakeet(inputs: inputs)

    // Read every member named in PR-4b.2 §3.2's table. The point is that
    // each line below TYPECHECKS without `@testable` access. Runtime values
    // are not asserted here (behavioral tests live in the other PR-4b.2 test
    // files); the gate is whether the symbols are publicly visible.
    _ = driver.state
    _ = driver.overlayIntent
    _ = driver.currentTranscript
    _ = driver.lastPolishError
    _ = driver.wordCorrection
    _ = driver.fillerRemoval
    _ = driver.emojiFormatter
    _ = driver.llmPolish
    _ = driver.currentSessionConfig
    driver.onStateChange = { _ in }
    driver.setExternalError("probe")
    driver.clearPendingStallRecovery()
    driver.handleEngineInterruption()
    driver.handleASRServiceInterruption()
    driver.reset()
    #expect(true, "reaching this line means the public surface compiled")
  }
}
