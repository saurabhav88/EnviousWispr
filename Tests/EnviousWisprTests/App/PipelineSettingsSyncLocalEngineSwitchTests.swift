import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// Switching between the two bundled engines (#2649). The coordinator orders
/// requests by an intent stamp, and the stamps are claimed synchronously while
/// the requests run in separate tasks. So the number of stamps a switch claims
/// IS the behaviour: a redundant stop after the start claims a later stamp
/// that, delivered first, refuses the start and leaves both engines off. When
/// this fails, the user switches back to EG-1 and polish silently stops until
/// they touch the setting again.
@MainActor
@Suite("PipelineSettingsSync local-engine switch (#2649)", .tags(.productOutcome))
struct PipelineSettingsSyncLocalEngineSwitchTests {

  private func makeSync() -> (PipelineSettingsSync, SettingsManager, LocalPolishServerCoordinator) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = SettingsManager(
      defaults: UserDefaults(suiteName: "SM-2649-switch-\(UUID().uuidString)")!)
    // One coordinator shared by both runtimes, exactly as the app wires it.
    // No manifest and no binary: `activateAndProbe` returns before claiming a
    // stamp, so every stamp counted below is a STOP.
    let coordinator = LocalPolishServerCoordinator()
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
      provider: .egOne)
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
      provider: .s1Mini)
    let sync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKit,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: HotkeyService(effects: RecordingDesktopHotkeyEffects()),
      egOneRuntime: egOne,
      s1MiniRuntime: s1Mini,
      ollamaRemotenessLookup: { _ in nil }
    )
    return (sync, settings, coordinator)
  }

  /// Stamps claimed by a switch, measured as the gap between two probe claims.
  private func stampsClaimed(
    by body: () -> Void, on coordinator: LocalPolishServerCoordinator
  ) -> Int {
    let before = coordinator.claimIntent()
    body()
    let after = coordinator.claimIntent()
    return after - before - 1
  }

  @Test("switching S1-mini to EG-1 stops S1-mini exactly once")
  func switchClaimsOneStop() {
    let (sync, settings, coordinator) = makeSync()
    settings.llmProvider = .s1Mini
    sync.applyInitialSettings(settings)

    let stamps = stampsClaimed(
      by: {
        settings.llmProvider = .egOne
        sync.handleSettingChanged(.llmProvider, settings: settings)
      }, on: coordinator)
    // One stop for the outgoing engine. Two would be the redundant second-pass
    // stop that can outrank the start; zero would mean nothing was stopped.
    #expect(stamps == 1)
  }

  @Test("switching EG-1 to S1-mini stops EG-1 exactly once")
  func switchBackClaimsOneStop() {
    let (sync, settings, coordinator) = makeSync()
    settings.llmProvider = .egOne
    sync.applyInitialSettings(settings)

    let stamps = stampsClaimed(
      by: {
        settings.llmProvider = .s1Mini
        sync.handleSettingChanged(.llmProvider, settings: settings)
      }, on: coordinator)
    #expect(stamps == 1)
  }

  /// Two-way control on the instrument: a switch to a NON-local provider stops
  /// both engines, one stamp each, so the counter is demonstrably counting stops.
  @Test("switching to a cloud provider stops both engines, one stamp each")
  func cloudSwitchStopsBoth() {
    let (sync, settings, coordinator) = makeSync()
    settings.llmProvider = .egOne
    sync.applyInitialSettings(settings)

    let stamps = stampsClaimed(
      by: {
        settings.llmProvider = .openAI
        sync.handleSettingChanged(.llmProvider, settings: settings)
      }, on: coordinator)
    #expect(stamps == 2)
  }
}
