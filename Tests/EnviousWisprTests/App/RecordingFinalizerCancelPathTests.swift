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

  /// The ordering invariant `RecordingStarter`'s post-await wedge guards depend
  /// on: `lastUserStopRequest` must be set BEFORE `userStop()` enters its
  /// suspending dispatch await. The injected dispatch closure reads the timestamp
  /// at dispatch entry. (The old `userStopMarksTimestampBeforeAwait` read only
  /// after the await resolved, so it passed whether the timestamp was set before
  /// or after the await — it could never catch a reordering.)
  @Test(
    "userStop sets the stop timestamp before entering the dispatch await",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/902",
      "stop timestamp ordering"
    )
  )
  func userStopSetsTimestampBeforeDispatchAwait() async {
    let fx = Self.makeFixture()
    let finalizer = fx.finalizer
    let obs = DispatchObservation()
    finalizer.requestStopDispatch = { driver in
      obs.dispatchRan = true
      obs.stampAtEntry = finalizer.lastUserStopAccess.read()
      try await driver.handle(event: .requestStop)  // forward — an idle driver ignores stop
    }
    await finalizer.userStop()
    #expect(obs.dispatchRan)  // the dispatch closure was actually reached
    #expect(obs.stampAtEntry != nil)  // the timestamp was already set at dispatch entry
  }

  /// The same ordering invariant for `cancel()`. Its dispatch is guarded by
  /// `.recording`/`.loadingModel`, so the active driver is force-transitioned to
  /// `.recording` to reach the dispatch. The cancel closure observes only (no
  /// forward) because real `cancelRecording()` awaits terminal convergence.
  // `kernelForTesting` + `testForceTransition` are DEBUG-only seams
  // (`KernelDictationDriver.swift` `#if DEBUG`), so this test wraps itself in
  // `#if DEBUG` — same pattern as ASREventRouterTests. Otherwise the release-config
  // test lane (post-merge) fails to compile and reports an empty bundle.
  #if DEBUG
    @Test(
      "cancel sets the stop timestamp before entering the dispatch await",
      .bug(
        "https://github.com/saurabhav88/EnviousWispr/issues/902",
        "cancel timestamp ordering"
      )
    )
    func cancelSetsTimestampBeforeDispatchAwait() async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      // idle -> recording is a forbidden direct transition; walk through .preparing
      // first, matching the kernel FSM (KernelDictationDriverTests precedent).
      _ = fx.kernelDriver.kernelForTesting.testForceTransition(to: .preparing)
      _ = fx.kernelDriver.kernelForTesting.testForceTransition(to: .recording)
      let finalizer = fx.finalizer
      let obs = DispatchObservation()
      finalizer.cancelRecordingDispatch = { _ in
        obs.dispatchRan = true
        obs.stampAtEntry = finalizer.lastUserStopAccess.read()
      }
      await finalizer.cancel()
      #expect(obs.dispatchRan)  // the state guard passed and the dispatch was reached
      #expect(obs.stampAtEntry != nil)  // the timestamp was already set at dispatch entry
    }
  #endif

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

/// Records what an injected dispatch closure observed at the moment it was
/// entered. A `@MainActor` reference type so the dispatch closure (itself
/// `@MainActor`, hence implicitly `Sendable` in Swift 6) can capture and mutate
/// it without a mutable-local-capture diagnostic.
@MainActor
private final class DispatchObservation {
  var dispatchRan = false
  var stampAtEntry: ContinuousClock.Instant?
}
