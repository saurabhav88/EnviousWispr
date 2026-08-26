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
    let overlay = OverlayTestDouble.headlessDirector()
    let permissions = PermissionsService()
    let hotkey = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    let settingsSync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: hotkey,
      // #1914: required, no default. These suites do not exercise eviction, so
      // "absent from the catalog" is the honest answer — and it is the
      // fail-open one, preserving today's local-eviction behaviour.
      ollamaRemotenessLookup: { _ in nil }
    )
    let lockBox = TestRecordingLockedBox()
    let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { lockBox.isLocked },
      set: { lockBox.isLocked = $0 }
    )
    let hcr = HeartControlRecovery(
      hideOverlay: { overlay.dismissCurrent(.announced) },
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
      dictationLifecycleCoordinator: nil,
      recovery: .disabled
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
    #expect(fx.hotkeyService.onLockRequested == nil)

    fx.controller.install()

    #expect(fx.hotkeyService.onToggleRecording != nil)
    #expect(fx.hotkeyService.onStartRecording != nil)
    #expect(fx.hotkeyService.onStopRecording != nil)
    #expect(fx.hotkeyService.onCancelRecording != nil)
    #expect(fx.hotkeyService.onIsProcessing != nil)
    #expect(fx.hotkeyService.onLockRequested != nil)
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

  @Test func suspendAndResumeAreIdempotentAndObservable() {
    // #1592: the prior version of this test called suspend()/resume() with
    // zero #expect calls, and after only install() (never startIfEnabled()),
    // isEnabled stayed false — HotkeyService.suspend()/resume() both guard on
    // isEnabled, so every call silently no-op'd. It passed regardless of
    // whether suspend/resume worked, were inverted, or were deleted.
    let fx = Self.makeFixture()
    fx.settings.hotkeyEnabled = true
    fx.controller.startIfEnabled()
    #expect(fx.hotkeyService.isEnabled == true)
    #expect(fx.hotkeyService.isSuspended == false)

    fx.controller.suspend()
    #expect(fx.hotkeyService.isSuspended == true)
    fx.controller.suspend()  // idempotent: already suspended, must stay suspended
    #expect(fx.hotkeyService.isSuspended == true)

    fx.controller.resume()
    #expect(fx.hotkeyService.isSuspended == false)
    fx.controller.resume()  // idempotent: already resumed, must stay resumed
    #expect(fx.hotkeyService.isSuspended == false)

    fx.hotkeyService.stop()
  }

  // MARK: - #1631 publication contract

  /// The identity comparison is the whole design: publication happens only when
  /// the session the press started is still the running one. It lives in the
  /// REAL installed closure, so it is driven here rather than through an injected
  /// double — an injected closure would prove only that the test can return a
  /// value it chose itself.
  @Test("the installed publication callback publishes only for the running session")
  func publicationRequiresTheStartedSession() throws {
    let fx = Self.makeFixture()
    fx.controller.install()
    let request = try #require(fx.hotkeyService.onLockRequested)

    // Both drivers are idle in this fixture, so no session is continuing and any
    // id must be refused. This is the negative side of the two-way control.
    #expect(fx.starter.activeDriver.continuingSessionID == nil)
    if case .notLockable = request("some-session-that-is-not-running") {
      // Expected.
    } else {
      Issue.record("expected .notLockable when no session is continuing")
    }
    #expect(
      fx.finalizer.recordingLockedAccess.get() == false,
      "a refused publication must not have written the shared lock")
  }

  #if DEBUG

    /// Positive control: with a session genuinely continuing, the SAME closure
    /// publishes. Without this the negative test above would also pass for a
    /// callback that refuses unconditionally, which would silently disable
    /// hands-free for everyone.
    ///
    /// The WHOLE test is `#if DEBUG`, not just its body: a Release build would
    /// otherwise still register it and pass it having asserted nothing, which is
    /// a green that means less than no test at all.
    @Test("the installed publication callback publishes for the continuing session")
    func publicationSucceedsForTheRunningSession() throws {
      let fx = Self.makeFixture()
      fx.controller.install()
      let request = try #require(fx.hotkeyService.onLockRequested)

      fx.starter.activeDriver.kernelForTesting.testForceState(.live)
      let running = try #require(
        fx.starter.activeDriver.continuingSessionID,
        "precondition: a live session must report a continuing id")

      if case .published = request(running) {
        #expect(
          fx.finalizer.recordingLockedAccess.get(),
          "a published lock must have written the shared lock")
      } else {
        Issue.record("expected .published for the continuing session")
      }

      // And the same closure still refuses a DIFFERENT id while that session runs.
      if case .notLockable = request("a-different-session") {
        // Expected.
      } else {
        Issue.record("expected .notLockable for a different session")
      }
    }

  #endif

}
