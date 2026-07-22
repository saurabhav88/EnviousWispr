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
    let audio = FakeAudioCapture()
    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(audioCapture: audio)
    let inputs = KernelDictationDriverFactory.ParakeetInputs(
      audioCapture: audio,
      asrManager: StubParakeetASRManager(),
      vadSignalSource: vad,
      transcriptStore: TranscriptStore(),
      keychainManager: KeychainManager(),
      captureTelemetry: CaptureTelemetryState(),
      pasteCompletionRegistry: PasteCompletionRegistry(),
      // #1741 Chunk 9 — `EngineMutationScope` and `.live(...)` are both
      // `package`-level (not `internal`), so this stays reachable without
      // `@testable`, preserving this file's whole point: proving the public/
      // package surface compiles from outside the module. `.alwaysAllowedForTesting`
      // is deliberately `internal`-only and would defeat that.
      engineMutationScope: .live(
        tryBegin: { true }, end: { false }, wake: {}, onRefused: { _ in }))
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
    driver.onOverlayIntentChange = { _ in }  // #930 — App-consumed overlay channel
    driver.setTerminalReason(.modelWedged)
    driver.handleEngineInterruption(.engineLost)
    driver.handleASRServiceInterruption()
    driver.reset()
    #expect(true, "reaching this line means the public surface compiled")
  }
}
