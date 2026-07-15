import AVFoundation
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
    let audio: RouterTestAudioCapture
    let permissions: PermissionsService
    let lockBox: TestRecordingLockedBox
    let lastRecordingResult: LastRecordingResult
    let overlay: RecordingOverlayPanel
    let settings: SettingsManager
  }

  private static func makeFixture(
    accessibilityRefresh: (@MainActor () -> Void)? = nil,
    releaseDuringRecoveryArm: Bool = false,
    isRecovering: Bool = false,
    recoveringDuringArm: Bool = false,
    micStatus: AVAuthorizationStatus = .authorized
  ) -> Fixture {
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
    // #959: isolate each fixture's settings in its own UserDefaults suite so a
    // test that changes `modelUnloadPolicy` (e.g. `warmRespawnRequiresNeverPolicy`)
    // cannot pollute `UserDefaults.standard` for sibling tests. A fresh suite has
    // no `modelUnloadPolicy` key, so it defaults to `.never` (SettingsDefaultValues).
    let settings = SettingsManager(
      defaults: UserDefaults(suiteName: "ew-test-\(UUID().uuidString)")!)
    let overlay = RecordingOverlayPanel()
    let permissions = PermissionsService(microphoneReader: { micStatus })
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
    // `recovering` is a captured var both the arm closure (mutates) and the gate
    // closure (reads) share — lets a test flip recovery ON during the arm await
    // (#1063 PR2: the post-arm re-check). Both run on the MainActor.
    var recovering = isRecovering
    // #1063 PR1: when asked, the injected recovery-arm closure simulates the
    // user RELEASING PTT while the key store is being awaited — it records a
    // user-stop on the finalizer (so `lastUserStopAccess.read() > pttStart`)
    // and returns no directive. The default closure is the recovery-off no-op.
    // #1063 PR2: when `recoveringDuringArm`, it flips recovery ON during the arm
    // and returns a directive (so `config.recoverySessionID` is set), simulating
    // launch recovery starting mid-`start()`.
    let makeRecoveryDirective:
      @MainActor (SettingsManager, ASRBackendType, Bool) async -> (
        recoverySessionID: String, payload: Data
      )? = { _, _, _ in
        if releaseDuringRecoveryArm { await finalizer.userStop() }
        if recoveringDuringArm {
          recovering = true
          return (UUID().uuidString, Data())
        }
        return nil
      }
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
      dictationLifecycleCoordinator: nil,
      accessibilityRefresh: accessibilityRefresh,
      makeRecoveryDirective: makeRecoveryDirective,
      isRecovering: { recovering }
    )
    return Fixture(
      starter: starter,
      finalizer: finalizer,
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      asr: asr,
      audio: audio,
      permissions: permissions,
      lockBox: lockBox,
      lastRecordingResult: lastRecordingResult,
      overlay: overlay,
      settings: settings
    )
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

  @Test("raw no-microphone prewarm error surfaces distinct copy")
  func rawNoMicrophonePrewarmErrorSurfacesDistinctCopy() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.audio.preWarmError = AudioError.noBuiltInMicrophoneFound

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .error(.noMicrophoneFound))
  }

  @Test("XPC-sanitized no-microphone prewarm error surfaces distinct copy")
  func sanitizedNoMicrophonePrewarmErrorSurfacesDistinctCopy() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.audio.preWarmError = XPCErrorSanitizer.sanitizeForXPC(
      AudioError.noBuiltInMicrophoneFound)

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .error(.noMicrophoneFound))
  }

  @Test(
    "a prewarm failure while mic permission is denied surfaces the actionable permission notice, not the generic capture error (cloud review P2 #1563)"
  )
  func permissionDeniedPrewarmSurfacesPermissionNotice() async {
    // Mic permission is denied; the prewarm error itself is a generic capture
    // failure (not a no-device error). #1558: permission is the real,
    // user-actionable cause and must win — the user should see "Microphone
    // access is off.", never the generic "Audio capture error. Try again."
    let fx = Self.makeFixture(micStatus: .denied)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.audio.preWarmError = NSError(domain: "SomeGenericCapture", code: 99)

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .error(.permissionDenied))
  }

  /// The old `toggleAndStartBothRefreshAccessibilityStatus` had ZERO `#expect` —
  /// it only checked crash-freedom, so deleting the AX re-arm block from
  /// `start()`/`toggle()` left it green. This injects a counting spy and asserts
  /// each path refreshes accessibility exactly once. The engine MUST be marked
  /// ready (`isModelLoaded = true`) — otherwise both paths return at the
  /// cold-engine guard BEFORE the AX block and the spy never increments.
  @Test(
    "start() and toggle() each refresh accessibility exactly once",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/904",
      "AX re-arm on start/toggle was unverified (zero-assertion test)"
    )
  )
  func startAndToggleEachRefreshAccessibilityOnce() async {
    let counter = AXRefreshCounter()
    let fx = Self.makeFixture(accessibilityRefresh: { counter.count += 1 })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // → readiness .ready, so start/toggle pass the cold-engine guard
    #expect(fx.kernelDriver.engineReadiness == .ready)

    await fx.starter.start()
    #expect(counter.count == 1)  // start() refreshed once

    await fx.starter.toggle(source: .toolbar)
    #expect(counter.count == 2)  // toggle() refreshed once more
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

  // #1063 PR2 — the recovery hold. A press (PTT or toggle) while the crash-recovery
  // limb backfills behind the blocking pill mints NO session and shows the
  // "recovering" pill instead, mirroring the cold-press contract.
  @Test func pressWhileRecoveringMintsNoSessionAndShowsRecoveringPill() async {
    // The engine is not-ready by default; the recovery gate must still win over
    // the cold-press gate (it is checked first), so the pill is the recovery one.
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle, "no session minted while recovering")
    #expect(
      fx.overlay.currentIntent == .recoveringLastRecording,
      "recovery hold takes precedence over the cold-engine pill")
  }

  @Test func toggleWhileRecoveringMintsNoSessionAndShowsRecoveringPill() async {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.overlay.currentIntent == .recoveringLastRecording)
  }

  // #1063 PR2 (Codex code-diff r2 P2) — recovery can START during `start()`'s
  // prewarm/arm awaits (the top-of-method gate read false). The post-arm re-check
  // must catch it and mint no session, so a new recording can't contend with the
  // recovery replay on the shared engine.
  @Test func startRechecksRecoveryAfterArmAndBails() async {
    let fx = Self.makeFixture(recoveringDuringArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // ready → top gate passes, recovery flips on during arm

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle, "no session minted — recovery started during the arm")
    #expect(fx.overlay.currentIntent == .recoveringLastRecording)
  }

  @Test func toggleRechecksRecoveryAfterArmAndBails() async {
    let fx = Self.makeFixture(recoveringDuringArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.overlay.currentIntent == .recoveringLastRecording)
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

    // A ready press must take the WARM path, which shows the recording overlay.
    // The old test only checked the cold-boot pill's ABSENCE — a broken warm
    // path that returned early without recording also has no cold pill and
    // stayed green. Asserting the positive recording intent reddens that
    // early-return mutation while still proving the cold branch was skipped.
    guard case .recording = fx.overlay.currentIntent else {
      Issue.record(
        "warm press must show the recording overlay; got \(fx.overlay.currentIntent)")
      return
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

  /// #1063 PR1 (Codex code-diff r2 P2): the recovery-arm `await` widened the
  /// pre-session window in `start()`. Unlike the pre-warm guard above, this one
  /// IS deterministically schedulable — the arm closure is injected, so it can
  /// record the user-stop mid-arm. A release landing in that window must tear
  /// down the prewarmed engine (`abortPreWarm`), not merely hide the overlay,
  /// and must mint no session. A bare hide/unlock would leave the mic engine hot.
  @Test func pttReleaseDuringRecoveryArmAbortsPrewarmAndMintsNoSession() async {
    let fx = Self.makeFixture(releaseDuringRecoveryArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // ready → passes cold + pre-warm guards, reaches the arm
    #expect(fx.kernelDriver.engineReadiness == .ready)

    await fx.starter.start()

    // The prewarmed engine was torn down (not just the overlay hidden).
    #expect(fx.audio.abortPreWarmCallCount >= 1)
    // No session minted — the kernel never left idle.
    #expect(fx.kernelDriver.state == .idle)
    // Lock released so a subsequent press is not wedged.
    #expect(fx.lockBox.isLocked == false)
  }

  /// #1063 PR1 (Codex code-diff r3 P1): the toggle path also awaits the recovery
  /// arm. A stop/cancel landing in that window must NOT start a fresh recording —
  /// the post-arm guard reads the user-stop timestamp and bails before
  /// dispatching `.toggleRecording`, so the kernel never leaves idle.
  @Test func toggleStopDuringRecoveryArmMintsNoSession() async {
    let fx = Self.makeFixture(releaseDuringRecoveryArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // ready → passes the cold guard, reaches the arm
    #expect(fx.kernelDriver.engineReadiness == .ready)

    await fx.starter.toggle(source: .toggleHotkey)

    // No session minted — the kernel never left idle.
    #expect(fx.kernelDriver.state == .idle)
  }

  // MARK: - #959 warm-respawn (idle XPC reclaim) press routing

  /// A press on a not-ready engine whose model was reaped while idle
  /// (`residentModelLostWhileIdle`) under the default `.never` policy must NOT
  /// show the cold pill — it consumes the marker and falls through to the normal
  /// start (which shows the recording overlay), so the user's press records.
  @Test func warmRespawnStartConsumesMarkerAndSkipsColdPill() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false  // → readiness .notReady
    fx.kernelDriver.residentModelLostWhileIdle = true
    fx.settings.modelUnloadPolicy = .never  // explicit: user keeps the model resident

    await fx.starter.start()

    // Marker consumed (single press) and NO cold pill — the PTT fall-through
    // shows the recording overlay instead.
    #expect(fx.kernelDriver.residentModelLostWhileIdle == false)
    #expect(fx.overlay.currentIntent != .cachingModel(engineLabel: "Parakeet v3"))
    guard case .recording = fx.overlay.currentIntent else {
      Issue.record("warm-respawn must show the recording overlay; got \(fx.overlay.currentIntent)")
      return
    }
  }

  @Test func warmRespawnToggleConsumesMarkerAndSkipsColdPill() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false
    fx.kernelDriver.residentModelLostWhileIdle = true
    fx.settings.modelUnloadPolicy = .never

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.residentModelLostWhileIdle == false)
    #expect(fx.overlay.currentIntent != .cachingModel(engineLabel: "Parakeet v3"))
  }

  /// The marker only short-circuits the pill when the user keeps the model
  /// resident (`.never`). Under a timed unload policy the user WANTS the model
  /// gone, so a not-ready press is a genuine cold start: show the pill, keep the
  /// marker (the cold branch does not consume it), mint no session.
  @Test func warmRespawnRequiresNeverPolicy() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false
    fx.kernelDriver.residentModelLostWhileIdle = true
    fx.settings.modelUnloadPolicy = .fiveMinutes

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.overlay.currentIntent == .cachingModel(engineLabel: "Parakeet v3"))
    #expect(fx.kernelDriver.residentModelLostWhileIdle == true)  // not consumed on cold branch
  }

  /// Adversarial (`matcher-set-adversarial-tests`): the marker in its
  /// NON-intended class. A genuine cold boot (marker false) must STILL block —
  /// the warm-respawn path must never fire for a never-loaded engine.
  @Test func genuineColdWithMarkerUnsetStillBlocks() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false
    #expect(fx.kernelDriver.residentModelLostWhileIdle == false)  // never reaped

    await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.overlay.currentIntent == .cachingModel(engineLabel: "Parakeet v3"))
  }

  /// Driver-level: the overlay latch is set by `beginWarmRespawnOverlay()`, and a
  /// successful load (`ensureEngineWarm` reaching `.ready`) drops a stale marker
  /// so a later genuine cold boot still shows the pill.
  @Test func driverLatchSetAndMarkerClearedOnWarm() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet

    #expect(fx.kernelDriver.warmRespawnInFlight == false)
    fx.kernelDriver.beginWarmRespawnOverlay()
    #expect(fx.kernelDriver.warmRespawnInFlight == true)

    fx.kernelDriver.residentModelLostWhileIdle = true
    fx.asr.isModelLoaded = true  // ensureEngineWarm sees readiness .ready
    _ = await fx.kernelDriver.ensureEngineWarm(reason: .coldPress)
    #expect(fx.kernelDriver.residentModelLostWhileIdle == false)
  }
}

/// Counts accessibility-refresh invocations for #904. A `@MainActor` reference
/// type because the seam closure is `@MainActor` (implicitly `Sendable` in
/// Swift 6) and the `@MainActor` suite supplies it.
@MainActor
private final class AXRefreshCounter {
  var count = 0
}
