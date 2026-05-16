@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprPipeline

/// Regression test for #728.
///
/// Before the fix, `AppLogger.shared.setDebugMode` was only called inside
/// `PipelineSettingsSync.handleSettingChanged`'s `.isDebugModeEnabled` case,
/// which fires on toggle changes — not on initial settings load. The result:
/// an app launched with the persisted toggle ON never opened the file sink
/// until the user toggled OFF then back ON.
///
/// `PipelineSettingsSync.applyInitialSettings` now seeds AppLogger's debug
/// mode and log level once at launch. This test exercises that path.
@MainActor
@Suite("AppLogger launch-time sync")
struct AppLoggerLaunchSyncTests {

  @Test("applyInitialSettings seeds AppLogger debug mode + log level from persisted settings")
  func applyInitialSettingsSeedsAppLogger() async throws {
    // Save prior AppLogger state so suite ordering does not leak.
    let priorMode = await AppLogger.shared.isDebugModeEnabled
    let priorLevel = await AppLogger.shared.logLevel

    // Save prior UserDefaults — SettingsManager setters below write through to
    // `UserDefaults.standard`, so we must restore them in defer or other tests
    // (and the developer's persisted state) would see the leak.
    let defaults = UserDefaults.standard
    let priorIsDebugModeEnabled = defaults.object(forKey: "isDebugModeEnabled")
    let priorDebugLogLevel = defaults.object(forKey: "debugLogLevel")

    // Force the logger to a known baseline that differs from the test target.
    await AppLogger.shared.setDebugMode(false)
    await AppLogger.shared.setLogLevel(.info)

    let fixture = try SyntheticAudioFixture.make(
      fileName: "issue-728-applogger-launch.wav",
      pattern: .toneBurst
    )
    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "unused",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.01,
          backendType: .parakeet
        )
      )
    )
    let transcriptStore = TranscriptStore()
    let keychain = KeychainManager()
    let pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: transcriptStore
    )
    let whisperKitPipeline = WhisperKitPipeline(
      audioCapture: audioCapture,
      backend: WhisperKitBackend(),
      transcriptStore: transcriptStore,
      keychainManager: keychain
    )
    let polishService = TranscriptPolishService(
      keychainManager: keychain,
      transcriptStore: transcriptStore
    )
    let hotkeyService = HotkeyService()
    let whisperKitSetup = WhisperKitSetupService()

    let sync = PipelineSettingsSync(
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
      polishService: polishService,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      whisperKitSetup: whisperKitSetup
    )

    // Configure persisted state: debug=on, level=.debug (the values that should
    // be reflected on the global logger after applyInitialSettings).
    let settings = SettingsManager()
    settings.isDebugModeEnabled = true
    settings.debugLogLevel = .debug

    sync.applyInitialSettings(settings)

    // applyInitialSettings spawns a Task to call into the AppLogger actor.
    // Poll up to 1s for the state to settle before asserting.
    let modeSettled = await pollAsync(timeout: .seconds(1)) {
      await AppLogger.shared.isDebugModeEnabled == true
    }
    let levelSettled = await pollAsync(timeout: .seconds(1)) {
      await AppLogger.shared.logLevel == .debug
    }

    #expect(
      modeSettled,
      "AppLogger.isDebugModeEnabled must reflect persisted setting after launch sync")
    #expect(
      levelSettled,
      "AppLogger.logLevel must reflect persisted setting after launch sync")

    // Restore prior AppLogger state — never assume default false, so suite
    // ordering does not depend on this test.
    await AppLogger.shared.setDebugMode(priorMode)
    await AppLogger.shared.setLogLevel(priorLevel)

    // Restore prior UserDefaults.
    if let priorIsDebugModeEnabled {
      defaults.set(priorIsDebugModeEnabled, forKey: "isDebugModeEnabled")
    } else {
      defaults.removeObject(forKey: "isDebugModeEnabled")
    }
    if let priorDebugLogLevel {
      defaults.set(priorDebugLogLevel, forKey: "debugLogLevel")
    } else {
      defaults.removeObject(forKey: "debugLogLevel")
    }
  }
}

@MainActor
private func pollAsync(
  timeout: Duration,
  interval: Duration = .milliseconds(10),
  condition: @escaping () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: interval)
  }
  return await condition()
}
