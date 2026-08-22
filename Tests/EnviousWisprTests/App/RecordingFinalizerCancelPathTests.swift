#if DEBUG
// **DEBUG-only because it reads a `*ForTesting` accessor**, which lives inside
// `#if DEBUG` on the type it belongs to. Without the guard the RELEASE build of
// the test target does not compile — which a Debug-only local run cannot see, by
// construction, and which CI's `build-release` job catches instead.
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
      let overlay: OverlayDirector
    }

    private static func makeFixture() -> Fixture {
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      let store = DictationRuntimeFixtures.tempStore()
      let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store)
      let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store)
      let overlay = OverlayTestDouble.headlessDirector()
      let lockBox = TestRecordingLockedBox()
      let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
        get: { lockBox.isLocked },
        set: { lockBox.isLocked = $0 }
      )
      let hcr = HeartControlRecovery(
        hideOverlay: { overlay.send(.pipeline(.hidden), actions: nil) },
        setLocked: { locked in lockAccess.set(locked) },
        backend: { asr.activeBackendType.rawValue }
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

    @Test func cancelIsNoOpWhenParakeetIdle() async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      fx.lockBox.isLocked = true  // prove cancel still clears the lock before bailing
      await fx.finalizer.cancel(trigger: .shortcut)
      // Lock cleared (cancel's prologue runs regardless of state-guard outcome).
      #expect(fx.lockBox.isLocked == false)
    }

    @Test func cancelIsNoOpWhenWhisperKitIdle() async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .whisperKit
      fx.lockBox.isLocked = true
      await fx.finalizer.cancel(trigger: .shortcut)
      #expect(fx.lockBox.isLocked == false)
    }

    /// The ordering invariant `RecordingStarter`'s post-await wedge guards depend
    /// on: `lastUserStopRequest` must be set BEFORE `userStop()` enters its
    /// suspending dispatch await. The injected dispatch closure reads the timestamp
    /// at dispatch entry. (The old userStopMarksTimestampBeforeAwait read only
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
    // (`KernelDictationDriver.swift` `#if DEBUG`), so EVERY test needing them lives
    // in this one block — same pattern as ASREventRouterTests. Otherwise the
    // release-config test lane (post-merge) fails to compile and reports an empty
    // bundle, which a Debug-only local run cannot see by construction. Add new
    // seam-using tests HERE rather than starting a second guarded region.
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
        _ = fx.kernelDriver.kernelForTesting.testForceTransition(to: .arming)
        _ = fx.kernelDriver.kernelForTesting.testForceTransition(to: .live)
        let finalizer = fx.finalizer
        let obs = DispatchObservation()
        finalizer.cancelRecordingDispatch = { _, _ in
          obs.dispatchRan = true
          obs.stampAtEntry = finalizer.lastUserStopAccess.read()
        }
        await finalizer.cancel(trigger: .shortcut)
        #expect(obs.dispatchRan)  // the state guard passed and the dispatch was reached
        #expect(obs.stampAtEntry != nil)  // the timestamp was already set at dispatch entry
      }
      /// #2087: the trigger must survive the whole chain, not merely be accepted.
      ///
      /// The earlier version of the dispatch-seam test ignored both closure
      /// arguments (`{ _, _ in }`), so replacing the forwarded trigger with a
      /// hard-coded constant would have left the suite green. These capture the
      /// value and assert BOTH cases, so a constant fails one of them.
      @Test("the trigger reaches the dispatch seam unchanged, for both controls")
      func triggerSurvivesToTheDispatchSeam() async {
        for expected in [UserCancelTrigger.shortcut, .cancelButton] {
          let fx = Self.makeFixture()
          fx.asr.activeBackendType = .parakeet
          _ = fx.kernelDriver.kernelForTesting.testForceTransition(to: .arming)
          _ = fx.kernelDriver.kernelForTesting.testForceTransition(to: .live)
          let seen = TriggerBox()
          fx.finalizer.cancelRecordingDispatch = { _, trigger in seen.value = trigger }
          await fx.finalizer.cancel(trigger: expected)
          #expect(seen.value == expected, "the seam must receive the trigger it was given")
        }
      }

      /// The provenance must reach the KERNEL, not stop at the driver. Chunk 7
      /// branches inside the kernel, so a value that only ever lands on the driver
      /// would look correct here and be unavailable where it is actually needed.
      ///
      /// SYNCHRONOUS on purpose. The first version of this test drove the real
      /// `cancelRecording` path, which ends in `await awaitKernelTerminal()`. With
      /// the kernel force-transitioned to `.live` and no forward path running, that
      /// terminal never arrives and the test hangs forever — precisely the shape
      /// `swift-patterns.md` RULE: tests-no-unconditional-continuation-await
      /// exists to forbid. `cancel(origin:)` sets the value synchronously, so read
      /// the accessor instead of awaiting a future that may never resume.
      @Test("the kernel records the origin it was cancelled with, for both controls")
      func kernelRecordsTheOrigin() {
        for trigger in [UserCancelTrigger.shortcut, .cancelButton] {
          let fx = Self.makeFixture()
          let kernel = fx.kernelDriver.kernelForTesting
          _ = kernel.testForceTransition(to: .arming)
          _ = kernel.testForceTransition(to: .live)
          kernel.cancel(origin: .user(trigger))
          #expect(kernel.lastCancelOrigin == .user(trigger))
        }
      }

      /// The default dispatch seam forwards the trigger into the driver as
      /// `.user(trigger)`. Asserted by invoking the production closure against a
      /// kernel parked in `.stopping`, where `cancel` concludes SYNCHRONOUSLY, so
      /// the driver's terminal await resolves immediately instead of hanging.
      @Test("the production dispatch seam forwards the trigger to the driver")
      func defaultDispatchForwardsTheTrigger() async {
        let fx = Self.makeFixture()
        let kernel = fx.kernelDriver.kernelForTesting
        _ = kernel.testForceTransition(to: .arming)
        _ = kernel.testForceTransition(to: .live)
        _ = kernel.testForceTransition(to: .stopping)
        await fx.finalizer.cancelRecordingDispatch(fx.kernelDriver, .cancelButton)
        #expect(kernel.lastCancelOrigin == .user(.cancelButton))
      }

      /// A cancel the kernel IGNORES must not claim provenance. `.idle` is the
      /// unambiguous ignore case: nothing is in flight, so recording the request
      /// would attribute a session that never ended this way.
      @Test("an ignored cancel records no provenance")
      func ignoredCancelRecordsNothing() {
        let fx = Self.makeFixture()
        let kernel = fx.kernelDriver.kernelForTesting
        kernel.cancel(origin: .user(.shortcut))
        #expect(
          kernel.lastCancelOrigin == .systemOrFault,
          "an ignored cancel must leave the default in place, not record .user")
      }

      /// First-wins. The hazard is specific: internal teardown paths call
      /// `cancel()` with the `.systemOrFault` default, and in `.live` that lands
      /// in an ACCEPTING arm. Without the latch it would overwrite the user's real
      /// shortcut cancel, and chunk 7 would decline to offer recovery for a take
      /// the user genuinely escaped out of.
      @Test("a later system cancel cannot overwrite the accepted user cancel")
      func firstAcceptedCancelWins() {
        let fx = Self.makeFixture()
        let kernel = fx.kernelDriver.kernelForTesting
        _ = kernel.testForceTransition(to: .arming)
        _ = kernel.testForceTransition(to: .live)
        kernel.cancel(origin: .user(.shortcut))
        #expect(kernel.lastCancelOrigin == .user(.shortcut))
        kernel.cancel()  // the fault-path default, arriving behind the real one
        #expect(
          kernel.lastCancelOrigin == .user(.shortcut),
          "the first accepted cancel owns the provenance for the rest of the session")
      }

    #endif

    @Test func markLockedFlipsTheLockAndUpdatesOverlay() {
      let fx = Self.makeFixture()
      #expect(fx.lockBox.isLocked == false)
      #expect(fx.overlay.isRecordingLockedForTesting == false)
      fx.finalizer.markLocked()
      #expect(fx.lockBox.isLocked == true)
      // The test name promises the overlay is updated too — markLocked() calls
      // recordingOverlay.updateLockState(true). The old test asserted only the
      // shared lock setter, so deleting the overlay update left it green.
      #expect(fx.overlay.isRecordingLockedForTesting == true)
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
        fx.kernelDriver.setTerminalReason(.modelWedged)
        fx.whisperKitKernelDriver.setTerminalReason(.asrFailed)
        fx.asr.activeBackendType = .parakeet
        fx.finalizer.resetActive()
        #expect(fx.kernelDriver.state == .idle)
        #expect(fx.whisperKitKernelDriver.state == .error(.asrFailed))
      }
      do {  // WhisperKit active.
        let fx = Self.makeFixture()
        fx.kernelDriver.setTerminalReason(.modelWedged)
        fx.whisperKitKernelDriver.setTerminalReason(.asrFailed)
        fx.asr.activeBackendType = .whisperKit
        fx.finalizer.resetActive()
        #expect(fx.whisperKitKernelDriver.state == .idle)
        #expect(fx.kernelDriver.state == .error(.modelWedged))
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

  /// Minimal reference cell for capturing a value out of a `@MainActor` closure.
  @MainActor private final class TriggerBox {
    var value: UserCancelTrigger?
  }
#endif
