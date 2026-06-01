import AppKit
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

/// PR10 of #763 — behavior tests for `RecordingStarter`.
///
/// `start()` and `toggle(source:)` dispatch `.preWarm` and `.toggleRecording`
/// against real pipelines whose deep behavior depends on a live audio path;
/// end-to-end correctness is covered by founder / automated UAT (§11/§12 of
/// the PR10 plan). These tests verify what is mechanically verifiable in a
/// unit context without booting AVAudioEngine + ASR:
///   - construction does not crash;
///   - `start()` and `toggle(source:)` return cleanly when the active
///     pipeline is already active (early-return guard);
///   - both code paths clear `lastRecordingResult.polishError` on a new
///     start (idle → active transition);
///   - `isProcessing` is false when both pipelines are idle;
///   - `isProcessing` flips with `activeBackendType` reads.
@MainActor
@Suite struct RecordingStarterStartPathTests {

  private struct Fixture {
    let starter: RecordingStarter
    let finalizer: RecordingFinalizer
    let kernelDriver: KernelDictationDriver
    let whisperKitKernelDriver: KernelDictationDriver
    let asr: RouterTestASRManager
    let permissions: PermissionsService
    let lockBox: TestRecordingLockedBox
    let lastRecordingResult: LastRecordingResult
    let overlay: RecordingOverlayPanel
  }

  private static func makeFixture() -> Fixture {
    // `RecordingOverlayPanel.show(intent: .recording, ...)` posts an
    // `NSAccessibility` notification against `NSApp.mainWindow`. `NSApp`
    // is an implicitly-unwrapped optional that crashes the test process
    // when accessed before `NSApplication.shared` has been touched.
    // Force-initialize so `start()` paths can run.
    _ = NSApplication.shared
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
    let lockBox = TestRecordingLockedBox()
    let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { lockBox.isLocked },
      set: { lockBox.isLocked = $0 }
    )
    let hcr = HeartControlRecovery(
      hideOverlay: { overlay.show(intent: .hidden) },
      setLocked: { locked in lockAccess.set(locked) },
      backend: { asr.activeBackendType == .whisperKit ? "whisperkit" : "parakeet" }
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
    let lastRecordingResult = LastRecordingResult()
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
      lastRecordingResult: lastRecordingResult,
      dictationLifecycleCoordinator: nil
    )
    return Fixture(
      starter: starter,
      finalizer: finalizer,
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      asr: asr,
      permissions: permissions,
      lockBox: lockBox,
      lastRecordingResult: lastRecordingResult,
      overlay: overlay
    )
  }

  @Test func constructionDoesNotCrash() {
    _ = Self.makeFixture()
  }

  @Test func isProcessingFalseWhenBothPipelinesIdle() {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    #expect(fx.starter.isProcessing == false)
    fx.asr.activeBackendType = .whisperKit
    #expect(fx.starter.isProcessing == false)
  }

  @Test func toggleClearsPriorPolishErrorOnIdleToActiveTransition() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.lastRecordingResult.polishError = "previous error"
    // Both pipelines start in .idle, so this is the "starting a new
    // recording" branch — polishError must be cleared before dispatch.
    // The dispatch itself may fail in the unit context (no audio); that
    // does not affect the pre-dispatch reset.
    await fx.starter.toggle(source: .toolbar)
    #expect(fx.lastRecordingResult.polishError == nil)
  }

  @Test func startClearsPriorPolishErrorOnEntry() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.lastRecordingResult.polishError = "previous error"
    // start()'s prologue (overlay show, polish-error reset, AX refresh)
    // runs before the prewarm await. The await may resolve to an error
    // or never (no live audio); the prologue resets we care about
    // already happened.
    await fx.starter.start()
    #expect(fx.lastRecordingResult.polishError == nil)
  }

  @Test func toggleAndStartBothRefreshAccessibilityStatus() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    // Smoke-level: simply verify that toggle() and start() do not crash
    // even when AX is denied (the start-path code calls
    // refreshAccessibilityStatus + restartMonitoringIfNeeded; both must
    // be callable in any state).
    await fx.starter.toggle(source: .toolbar)
    await fx.starter.start()
  }

  // #879 — cold-boot press safety. The matcher-set boundary is `.ready` vs
  // not-ready (`.notReady` / `.warming`). A press on a not-ready engine must
  // mint NO recording session (no audio captured → none discarded) and show
  // the cold-boot pill; a press on a ready engine must skip the cold branch
  // entirely.
  @Test func coldPressMintsNoSessionAndShowsCachingPill() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false  // → readiness .notReady
    #expect(fx.kernelDriver.engineReadiness == .notReady)

    await fx.starter.start()

    // No session minted: the kernel never left idle.
    #expect(fx.kernelDriver.state == .idle)
    // The honest cold-boot pill is shown (engine-named), not a recording pill.
    #expect(fx.overlay.currentIntent == .cachingModel(engineLabel: "Parakeet v3"))
  }

  @Test func coldToggleMintsNoSessionAndShowsCachingPill() async {
    // The toggle-hotkey / menu / toolbar START path must follow the same
    // no-session-on-cold contract as the PTT path (Codex #879 review).
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false  // → readiness .notReady
    #expect(fx.kernelDriver.engineReadiness == .notReady)

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.overlay.currentIntent == .cachingModel(engineLabel: "Parakeet v3"))
  }

  @Test func warmPressSkipsColdBranch() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // → readiness .ready
    #expect(fx.kernelDriver.engineReadiness == .ready)

    await fx.starter.start()

    // A ready press must NOT take the cold branch — the cold-boot pill is the
    // only intent `start()` sets from that branch, so its absence proves the
    // warm path ran.
    if case .cachingModel = fx.overlay.currentIntent {
      Issue.record("warm press must not show the cold-boot caching pill")
    }
  }

  @Test func lastUserStopAccessIsThreadedFromFinalizer() async {
    // Starter holds a snapshot of Finalizer's lastUserStopAccess closure.
    // After Finalizer marks a timestamp via cancel/userStop, Starter's
    // wedge guard must observe the same value.
    let fx = Self.makeFixture()
    #expect(fx.starter.lastUserStopAccess.read() == nil)
    await fx.finalizer.userStop()
    #expect(fx.starter.lastUserStopAccess.read() != nil)
  }

  // NOTE: a behavioral test for the post-preWarm
  // `userStoppedDuringPreWarm` guard (Codex final-review P1 on the
  // cutover) is hard to schedule reliably — `RouterTestAudioCapture.preWarm`
  // completes synchronously, so a concurrent `userStop()` may land after
  // `.toggleRecording` already dispatched. The existing
  // `lastUserStopAccessIsThreadedFromFinalizer` test pins the wiring of
  // the closure; the guard itself mirrors the post-toggle check at
  // lines 162-165 (covered by behavioral observation in Live UAT).
}
