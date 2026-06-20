@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// V2 fault-injection — Lane C invariant C3 (issue #291).
///
/// Asserts that `PipelineSettingsSync` rejects backend switches while either
/// pipeline is active. Current behavior at
/// `Sources/EnviousWisprAppKit/App/PipelineSettingsSync.swift:86-98`: when
/// `pipeline.state.isActive || whisperKitKernelDriver.state.isActive`, the
/// `.selectedBackend` change is logged and dropped, and the active recording
/// continues uninterrupted. This test guards that contract: a future change
/// that drops the guard would silently abort active dictations on every
/// backend toggle.
///
/// The test does NOT assert what happens when the user attempts a switch
/// while idle — that's the supported path and is covered elsewhere.
@MainActor
@Suite("V2 Lane C — backend switch deferred while recording active")
struct BackendSwitchGuardTests {

  @Test("backend-switch setting change while .recording leaves recording uninterrupted")
  func testBackendSwitchDeferredWhileRecording() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "v2-c3-backend-switch-guard.wav",
      pattern: .toneBurst
    )

    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "should never be used",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.01,
          backendType: .parakeet
        )
      )
    )

    let transcriptStore = TranscriptStore()

    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audioCapture, asrManager: asrManager, store: transcriptStore)
    let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audioCapture, store: transcriptStore)
    let hotkeyService = HotkeyService()
    let whisperKitSetup = WhisperKitSetupService()

    let sync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      whisperKitSetup: whisperKitSetup
    )

    // Drive Parakeet pipeline to .recording.
    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )
    try await pipeline.handle(event: .toggleRecording(config))

    let reachedRecording = await pollUntil(timeout: .seconds(1)) {
      pipeline.state == .recording
    }
    #expect(reachedRecording, "Parakeet pipeline must reach .recording")
    #expect(pipeline.state.isActive, "guard precondition: pipeline.state.isActive must be true")

    // Flip the setting and fire the handler. Production wiring is via
    // SettingsManager.didSet → the former root state observer → sync.handleSettingChanged;
    // the guard logic under test lives in `handleSettingChanged`.
    let settings = SettingsManager()
    settings.selectedBackend = .whisperKit

    sync.handleSettingChanged(.selectedBackend, settings: settings)

    // Give any spawned Task one run-loop hop to surface a regression where
    // the switch is performed asynchronously instead of dropped.
    try? await Task.sleep(for: .milliseconds(50))

    // Recording must continue exactly as it was. Not .error, not .idle.
    #expect(
      pipeline.state == .recording,
      "backend switch must NOT cancel an active recording (got \(pipeline.state))")
    #expect(asrManager.transcribeCallCount == 0, "no transcribe call should have been made")

    await pipeline.cancelRecording()
  }

  /// #1063 PR2: a Speech-Engine switch while crash recovery is replaying on the
  /// shared engine must be BLOCKED — otherwise the switch unloads/resets the model
  /// mid-recovery, throws the in-flight transcribe, and (one attempt) deletes the
  /// spool. Both pipelines are IDLE here, so ONLY the recovery guard can block it.
  @Test("backend switch is blocked while crash recovery is replaying")
  func testBackendSwitchBlockedDuringRecovery() async throws {
    let audioCapture = FakeAudioCapture()
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "unused", language: "en", duration: 1, processingTime: 0.01,
          backendType: .parakeet)))
    let store = TranscriptStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audioCapture, asrManager: asrManager, store: store)
    let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audioCapture, store: store)
    let sync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: HotkeyService(),
      whisperKitSetup: WhisperKitSetupService()
    )
    #expect(!pipeline.state.isActive && !whisperKitKernelDriver.state.isActive)
    // Simulate recovery in progress.
    sync.isRecovering = { true }

    let settings = SettingsManager()
    settings.selectedBackend = .whisperKit
    sync.handleSettingChanged(.selectedBackend, settings: settings)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(
      asrManager.activeBackendType == .parakeet,
      "the switch must be dropped while recovery holds the engine (got \(asrManager.activeBackendType))"
    )
  }
}

@MainActor
private func pollUntil(
  timeout: Duration,
  interval: Duration = .milliseconds(10),
  condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: interval)
  }
  return condition()
}
