import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// PR10 of #763 — behavior tests for `HotkeyController`.
///
/// Most callback-firing paths require driving real Carbon hotkey events
/// through the live `HotkeyService`, which isn't possible in a unit test.
/// These tests verify what is mechanically verifiable:
///   - `install()` wires all six callbacks on the shared `HotkeyService`.
///   - `install()` pushes the initial recordingMode + key codes + modifiers.
///   - Live `PipelineSettingsSync` updates flow through to the same shared
///     `HotkeyService` instance that HotkeyController wired (the SHARED-INSTANCE
///     premise from Codex grounded review round 1).
@MainActor
@Suite struct HotkeyControllerInstallTests {

  private static func makeFixture() -> (
    controller: HotkeyController,
    hotkeyService: HotkeyService,
    starter: RecordingStarter,
    finalizer: RecordingFinalizer,
    settings: SettingsManager,
    settingsSync: PipelineSettingsSync
  ) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = SettingsManager()
    let overlay = RecordingOverlayPanel()
    let permissions = PermissionsService()
    let hotkey = HotkeyService()
    let settingsSync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: hotkey
    )
    let lockBox = TestRecordingLockedBox()
    let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { lockBox.isLocked },
      set: { lockBox.isLocked = $0 }
    )
    let hcr = HeartControlRecovery(
      hideOverlay: { overlay.show(intent: .hidden) },
      setLocked: { locked in lockAccess.set(locked) },
      backend: { "parakeet" }
    )
    let finalizer = RecordingFinalizer(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      asrManager: asr,
      recordingOverlay: overlay,
      heartControlRecovery: hcr,
      recordingLockedAccess: lockAccess,
      languageSuggestionPresenter: nil
    )
    let starter = RecordingStarter(
      audioCapture: audio,
      asrManager: asr,
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      settings: settings,
      permissions: permissions,
      recordingOverlay: overlay,
      heartControlRecovery: hcr,
      recordingLockedAccess: lockAccess,
      lastUserStopAccess: finalizer.lastUserStopAccess,
      lastRecordingResult: LastRecordingResult(),
      dictationLifecycleCoordinator: nil
    )
    let controller = HotkeyController(
      hotkeyService: hotkey,
      starter: starter,
      finalizer: finalizer,
      settings: settings
    )
    return (controller, hotkey, starter, finalizer, settings, settingsSync)
  }

  @Test func installWiresAllSixCallbacks() {
    let fx = Self.makeFixture()
    // No callbacks installed pre-install.
    #expect(fx.hotkeyService.onToggleRecording == nil)
    #expect(fx.hotkeyService.onStartRecording == nil)
    #expect(fx.hotkeyService.onStopRecording == nil)
    #expect(fx.hotkeyService.onCancelRecording == nil)
    #expect(fx.hotkeyService.onIsProcessing == nil)
    #expect(fx.hotkeyService.onLocked == nil)

    fx.controller.install()

    #expect(fx.hotkeyService.onToggleRecording != nil)
    #expect(fx.hotkeyService.onStartRecording != nil)
    #expect(fx.hotkeyService.onStopRecording != nil)
    #expect(fx.hotkeyService.onCancelRecording != nil)
    #expect(fx.hotkeyService.onIsProcessing != nil)
    #expect(fx.hotkeyService.onLocked != nil)
  }

  @Test func installPushesInitialRecordingModeAndKeyConfiguration() {
    let fx = Self.makeFixture()
    fx.settings.recordingMode = .pushToTalk
    fx.settings.cancelKeyCode = 53
    fx.settings.toggleKeyCode = 100
    fx.controller.install()
    #expect(fx.hotkeyService.recordingMode == .pushToTalk)
    #expect(fx.hotkeyService.cancelKeyCode == 53)
    #expect(fx.hotkeyService.toggleKeyCode == 100)
  }

  @Test func onIsProcessingDelegatesToStarter() {
    let fx = Self.makeFixture()
    fx.controller.install()
    // Pipelines are .idle → starter.isProcessing == false.
    #expect(fx.hotkeyService.onIsProcessing?() == false)
  }

  @Test func liveSettingsUpdatesFlowThroughSharedHotkeyServiceInstance() {
    // Shared-instance premise: HotkeyController wires the same HotkeyService
    // instance that PipelineSettingsSync mutates. A live settings change
    // routed through PSS must show up on the service HotkeyController wired.
    let fx = Self.makeFixture()
    fx.controller.install()
    let originalMode = fx.hotkeyService.recordingMode
    let newMode: RecordingMode = originalMode == .pushToTalk ? .toggle : .pushToTalk
    fx.settings.recordingMode = newMode
    fx.settingsSync.handleSettingChanged(.recordingMode, settings: fx.settings)
    #expect(fx.hotkeyService.recordingMode == newMode)
  }

  @Test func startIfEnabledHonorsSettingsHotkeyFlag() {
    let fx = Self.makeFixture()
    // #881 TO-3: assert the gate is actually honored via the observable
    // `isEnabled` flag (set synchronously by HotkeyService.start()), not just
    // that the call doesn't crash. The prior test had zero #expect, so it
    // stayed green under gate-inverted, gate-removed, and gate-never-starts
    // regressions.
    fx.settings.hotkeyEnabled = false
    fx.controller.startIfEnabled()  // gate closed → start() must NOT run
    #expect(fx.hotkeyService.isEnabled == false)
    fx.settings.hotkeyEnabled = true
    fx.controller.startIfEnabled()  // gate open → start() runs
    #expect(fx.hotkeyService.isEnabled == true)
    fx.hotkeyService.stop()
  }

  @Test func suspendAndResumeAreSafeToCallRepeatedly() {
    let fx = Self.makeFixture()
    fx.controller.install()
    fx.controller.suspend()
    fx.controller.suspend()
    fx.controller.resume()
    fx.controller.resume()
  }
}
