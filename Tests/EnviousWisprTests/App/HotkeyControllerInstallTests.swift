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

  private static func makeFixture(
    settings: SettingsManager = SettingsManager(),
    duringRecoveryArm: (@MainActor () async -> Void)? = nil
  ) -> (
    controller: HotkeyController,
    hotkeyService: HotkeyService,
    starter: RecordingStarter,
    finalizer: RecordingFinalizer,
    settings: SettingsManager,
    settingsSync: PipelineSettingsSync,
    engineLease: EngineLease,
    turnLog: TurnLogSink,
    asr: RouterTestASRManager,
    kernelDriver: KernelDictationDriver
  ) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKernelDriver = DictationRuntimeFixtures.makeWhisperPipeline(
      audioCapture: audio, store: store)
    let overlay = OverlayTestDouble.headlessDirector()
    // #3973 C1: an answered microphone, so a start press is not turned into macOS's prompt.
    let permissions = PermissionsService(microphoneReader: { .authorized })
    let hotkey = HotkeyService(effects: RecordingDesktopHotkeyEffects())
    let settingsSync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKernelDriver: whisperKernelDriver,
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
    // #3973 C1: a real lease and one shared request owner, so the waiting-press rows can hold
    // the engine as a meeting and reach the owner through the installed callbacks.
    let engineLease = EngineLease()
    let engineAdmission = EngineAdmissionAccess.live(lease: engineLease, as: .dictation)
    let turnLog = TurnLogSink()
    let pendingRequests = PendingDictationRequests(
      access: engineAdmission, log: { turnLog.append($0) })
    let finalizer = RecordingFinalizer(
      kernelDriver: pipeline,
      whisperKernelDriver: whisperKernelDriver,
      asrManager: asr,
      recordingOverlay: overlay,
      heartControlRecovery: hcr,
      recordingLockedAccess: lockAccess,
      languageSuggestionPresenter: nil,
      pendingRequests: pendingRequests
    )
    let starter = RecordingStarter(
      audioCapture: audio,
      asrManager: asr,
      kernelDriver: pipeline,
      whisperKernelDriver: whisperKernelDriver,
      settings: settings,
      permissions: permissions,
      recordingOverlay: overlay,
      heartControlRecovery: hcr,
      recordingLockedAccess: lockAccess,
      lastUserStopAccess: finalizer.lastUserStopAccess,
      lastRecordingResult: LastRecordingResult(),
      dictationLifecycleCoordinator: nil,
      // #3973 C1: a recovery arm that lets a row act while start-up is parked after the wait.
      recovery: RecordingStarter.RecoveryAccess(
        makeDirective: { _, _, _ in
          await duringRecoveryArm?()
          return nil
        },
        cleanupArm: { _ in }, isRecovering: { false }, signalPendingLiveStart: {},
        discardActive: {}),
      engineAdmission: engineAdmission,
      pendingRequests: pendingRequests
    )
    let controller = HotkeyController(
      hotkeyService: hotkey,
      starter: starter,
      finalizer: finalizer,
      settings: settings
    )
    return (
      controller, hotkey, starter, finalizer, settings, settingsSync, engineLease, turnLog, asr,
      pipeline
    )
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

  /// #3973 C1: while a press waits for a meeting's engine turn, the INSTALLED callbacks reach
  /// the one request owner: the cancel shortcut is armed for the wait, and stop, cancel and a
  /// second toggle each end it and disarm cancel again.
  @Test(arguments: ["stop", "cancel", "toggle"])
  func installedCallbacksEndAWaitingPress(route: String) async {
    let fx = Self.makeFixture()
    fx.controller.install()
    guard case .granted(let meeting) = fx.engineLease.admit(.meeting) else {
      Issue.record("the fixture's lease was already held")
      return
    }
    let startPress =
      route == "toggle" ? fx.hotkeyService.onToggleRecording : nil
    let start = fx.hotkeyService.onStartRecording
    let press = Task { @MainActor in
      if let startPress { await startPress() } else { _ = await start?() }
    }
    guard await fx.turnLog.waitFor(containing: "event=waiting", after: 0) else {
      Issue.record("the press never parked")
      return
    }
    #expect(fx.hotkeyService.isCancelArmed, "cancel is armed while the press waits")

    switch route {
    case "stop": await fx.hotkeyService.onStopRecording?()
    case "cancel": await fx.hotkeyService.onCancelRecording?()
    default: await fx.hotkeyService.onToggleRecording?()
    }
    await press.value

    #expect(fx.turnLog.outcomes.count == 1)
    #expect(fx.turnLog.outcomes.first?.hasPrefix("cancelled") == true)
    #expect(!fx.hotkeyService.isCancelArmed, "cancel is disarmed once nothing waits")
    #expect(fx.engineLease.release(meeting))
    #expect(fx.engineLease.isBusy == false, "the ended press took no turn")
  }

  /// #3973 C1: after the wait, while the admitted press is still starting up (parked in its
  /// recovery arm), the cancel shortcut stays armed and the INSTALLED cancel callback ends the
  /// press: no recording, and the engine goes back.
  @Test func theCancelShortcutStaysArmedThroughStartUpAfterTheWait() async {
    @MainActor final class Box { var hotkey: HotkeyService? }
    let box = Box()
    var armedDuringStartUp: Bool?
    let fx = Self.makeFixture(
      settings: SettingsManager(defaults: TestDefaults.suite("ew-hotkey-\(UUID().uuidString)")!),
      duringRecoveryArm: {
      guard let hotkey = box.hotkey else { return }
      armedDuringStartUp = hotkey.isCancelArmed
      await hotkey.onCancelRecording?()
    })
    box.hotkey = fx.hotkeyService
    fx.controller.install()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard case .granted(let meeting) = fx.engineLease.admit(.meeting) else {
      Issue.record("the fixture's lease was already held")
      return
    }
    let start = fx.hotkeyService.onStartRecording
    let press = Task { @MainActor in _ = await start?() }
    guard await fx.turnLog.waitFor(containing: "event=waiting", after: 0) else {
      Issue.record("the press never parked")
      return
    }
    #expect(fx.engineLease.release(meeting))
    await press.value

    #expect(armedDuringStartUp == true, "cancel was off while the admitted press started up")
    #expect(fx.turnLog.count(containing: "event=ended_during_start") == 1)
    #expect(fx.kernelDriver.state == .idle, "a cancelled press recorded")
    #expect(fx.engineLease.isBusy == false)
    #expect(!fx.hotkeyService.isCancelArmed, "cancel is disarmed once nothing waits or starts")
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

  /// #3106: the two new shortcuts are hydrated from settings at install, not left on the service's
  /// shipped fallback until the user happens to edit them.
  @Test func installPushesTheLastDictationBindings() {
    // An isolated store: these four keys must not leak into the shared defaults other suites read.
    let name = "ew.hotkeyControllerInstall." + UUID().uuidString
    let suite = TestDefaults.suite(name)!
    suite.removePersistentDomain(forName: name)
    defer { suite.removePersistentDomain(forName: name) }
    let fx = Self.makeFixture(settings: SettingsManager(defaults: suite))
    fx.settings.pasteLastKeyCode = 2
    fx.settings.pasteLastModifiers = [.command, .shift]
    fx.settings.copyLastKeyCode = 3
    fx.settings.copyLastModifiers = [.option, .shift]
    fx.controller.install()
    #expect(
      fx.hotkeyService.binding(for: .pasteLast)
        == .keyboard(keyCode: 2, modifiers: [.command, .shift]))
    #expect(
      fx.hotkeyService.binding(for: .copyLast)
        == .keyboard(keyCode: 3, modifiers: [.option, .shift]))
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
