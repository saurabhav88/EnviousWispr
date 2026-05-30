import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprASR
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// PR10 of #763 — behavior tests for `RecordingFinalizer`.
///
/// Deep dispatch paths (Parakeet `await pipeline.cancelRecording()` /
/// WhisperKit `try await whisperKitKernelDriver.handle(event: .cancelRecording)`)
/// require real pipeline state and are exercised end-to-end via founder /
/// automated UAT. These tests verify what is mechanically verifiable in a
/// unit context:
///   - `cancel()` is a no-op when both pipelines are idle (state guards).
///   - `userStop()` and `cancel()` mark `lastUserStopRequest` BEFORE the
///     await (timing invariant — Starter's wedge guard reads it after).
///   - `markLocked()` flips the shared lock-state setter to true and
///     updates the overlay.
///   - `resetActive()` calls the active backend's `reset()` (Parakeet vs
///     WhisperKit branching).
///   - Construction does not crash.
@MainActor
@Suite struct RecordingFinalizerCancelPathTests {

  private struct Fixture {
    let finalizer: RecordingFinalizer
    let kernelDriver: KernelDictationDriver
    let whisperKitKernelDriver: KernelDictationDriver
    let asr: RouterTestASRManager
    let lockBox: TestRecordingLockedBox
    let overlay: RecordingOverlayPanel
  }

  private static func makeFixture() -> Fixture {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let overlay = RecordingOverlayPanel()
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
    return Fixture(
      finalizer: finalizer,
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      asr: asr,
      lockBox: lockBox,
      overlay: overlay
    )
  }

  @Test func constructionDoesNotCrash() {
    _ = Self.makeFixture()
  }

  @Test func cancelIsNoOpWhenParakeetIdle() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.lockBox.isLocked = true  // prove cancel still clears the lock before bailing
    await fx.finalizer.cancel()
    // Lock cleared (cancel's prologue runs regardless of state-guard outcome).
    #expect(fx.lockBox.isLocked == false)
  }

  @Test func cancelIsNoOpWhenWhisperKitIdle() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .whisperKit
    fx.lockBox.isLocked = true
    await fx.finalizer.cancel()
    #expect(fx.lockBox.isLocked == false)
  }

  @Test func userStopMarksTimestampBeforeAwait() async {
    // Timing invariant: the timestamp must be visible to Starter's wedge
    // guard immediately after userStop() begins. With pipelines idle, the
    // dispatch await returns quickly; after userStop() resolves, the
    // accessor must read a non-nil value.
    let fx = Self.makeFixture()
    #expect(fx.finalizer.lastUserStopAccess.read() == nil)
    await fx.finalizer.userStop()
    #expect(fx.finalizer.lastUserStopAccess.read() != nil)
  }

  @Test func cancelMarksTimestampBeforeAwait() async {
    let fx = Self.makeFixture()
    #expect(fx.finalizer.lastUserStopAccess.read() == nil)
    await fx.finalizer.cancel()
    #expect(fx.finalizer.lastUserStopAccess.read() != nil)
  }

  @Test func markLockedFlipsTheLockAndUpdatesOverlay() {
    let fx = Self.makeFixture()
    #expect(fx.lockBox.isLocked == false)
    fx.finalizer.markLocked()
    #expect(fx.lockBox.isLocked == true)
  }

  @Test func userStopClearsLockBeforeDispatch() async {
    let fx = Self.makeFixture()
    fx.lockBox.isLocked = true
    await fx.finalizer.userStop()
    #expect(fx.lockBox.isLocked == false)
  }

  @Test func resetActiveCallsCorrectBackend() {
    // #881 TO-3: seed BOTH drivers with a distinct external error so each
    // driver's state getter reports `.error(...)`. resetActive() must clear
    // ONLY the active backend's driver (reset() nils lastExternalError) and
    // leave the other backend's error intact — proving the branch routes to
    // exactly the active backend. The prior test asserted nothing ("does not
    // crash"), so it stayed green under always-reset-parakeet, inverted-branch,
    // and reset-neither regressions alike.
    do {  // Parakeet active.
      let fx = Self.makeFixture()
      fx.kernelDriver.setExternalError("parakeet-err")
      fx.whisperKitKernelDriver.setExternalError("whisperkit-err")
      fx.asr.activeBackendType = .parakeet
      fx.finalizer.resetActive()
      #expect(fx.kernelDriver.state == .idle)
      #expect(fx.whisperKitKernelDriver.state == .error("whisperkit-err"))
    }
    do {  // WhisperKit active.
      let fx = Self.makeFixture()
      fx.kernelDriver.setExternalError("parakeet-err")
      fx.whisperKitKernelDriver.setExternalError("whisperkit-err")
      fx.asr.activeBackendType = .whisperKit
      fx.finalizer.resetActive()
      #expect(fx.whisperKitKernelDriver.state == .idle)
      #expect(fx.kernelDriver.state == .error("parakeet-err"))
    }
  }
}
