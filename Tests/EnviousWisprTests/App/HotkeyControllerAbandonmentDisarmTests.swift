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

/// The cancel shortcut disarming itself after an abandonment (#2087, chunk 7b).
///
/// This is the last link in the chain and the one with no safety net. Every
/// other participant is covered next door — the policy's truth table, the
/// finalizer admitting an abandonment and returning before any terminal — and
/// all of them stay green if the disarm is simply deleted. No LIFECYCLE
/// transition takes the key down here: an abandonment publishes no state change,
/// so the affordance policy never re-runs, and a third press would land on a
/// session that already granted the request.
///
/// Scoped deliberately: `HotkeyService`'s bare-modifier dispatch disarms
/// synchronously before invoking this callback, for its own two-key-release
/// reason, so on that path the disarm is a no-op. It is load-bearing for the
/// Carbon chord path, which is what invoking the callback directly models.
///
/// Driven through the INSTALLED callback rather than by calling the finalizer,
/// because the thing under test is the wiring `install()` performs.
@MainActor
/// Class: `.productOutcome` — a third press lands on a session that already granted the request.
@Suite("Cancel shortcut disarms after an abandonment (#2087)", .tags(.productOutcome))
struct HotkeyControllerAbandonmentDisarmTests {

  #if DEBUG

    @Test("the installed cancel callback disarms the key on an abandonment")
    func abandonmentDisarmsTheShortcut() async {
      let fx = Self.makeFixture()
      fx.controller.install()
      Self.enterEscapeRecoveryTranscription(fx.kernelDriver)
      fx.hotkeyService.registerCancelHotkey()
      #expect(
        fx.hotkeyService.isCancelArmed, "the key must be armed for disarming to mean anything")

      await fx.hotkeyService.onCancelRecording?()

      #expect(
        fx.hotkeyService.isCancelArmed == false,
        "no lifecycle transition would take it down on this path")
      #expect(
        fx.kernelDriver.kernelForTesting.recordingOutcome == nil,
        "and it came down while the session was still running, not after it ended")
    }

    /// The control. An ordinary cancel must NOT be disarmed by this path — the
    /// state transition it causes is what disarms it, via the affordance policy.
    /// Without this, returning `true` unconditionally from the finalizer would
    /// pass the test above.
    @Test("an ordinary cancel does not disarm through this path")
    func ordinaryCancelDoesNotDisarmHere() async {
      let fx = Self.makeFixture()
      fx.controller.install()
      let kernel = fx.kernelDriver.kernelForTesting
      kernel.start(config: .testDefault())
      kernel.testForceState(.live)
      fx.hotkeyService.registerCancelHotkey()

      await fx.hotkeyService.onCancelRecording?()

      #expect(
        fx.hotkeyService.isCancelArmed,
        "an ending cancel's own state transition disarms it, and that path is not this one")
    }

    // MARK: Helpers

    private static func enterEscapeRecoveryTranscription(_ driver: KernelDictationDriver) {
      let kernel = driver.kernelForTesting
      kernel.start(config: .testDefault())
      kernel.testForceState(.delivering)
      kernel.testSetDeliveringPhase(.transcribing)
      kernel.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      precondition(
        driver.isEscapeRecoveryTranscribing,
        "the fixture must reach the state under test, or every assertion below is vacuous")
    }

    private struct Fixture {
      let controller: HotkeyController
      let hotkeyService: HotkeyService
      let kernelDriver: KernelDictationDriver
    }

    private static func makeFixture() -> Fixture {
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      asr.activeBackendType = .parakeet
      let store = DictationRuntimeFixtures.tempStore()
      let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store)
      let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store)
      let settings = SettingsManager()
      let overlay = RecordingOverlayPanel()
      let permissions = PermissionsService()
      let hotkey = HotkeyService()
      let lockBox = TestRecordingLockedBox()
      let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
        get: { lockBox.isLocked }, set: { lockBox.isLocked = $0 })
      let hcr = HeartControlRecovery(
        hideOverlay: { overlay.show(intent: .hidden) },
        setLocked: { locked in lockAccess.set(locked) },
        backend: { "parakeet" })
      let finalizer = RecordingFinalizer(
        kernelDriver: pipeline,
        whisperKitKernelDriver: whisperKitKernelDriver,
        asrManager: asr,
        recordingOverlay: overlay,
        heartControlRecovery: hcr,
        recordingLockedAccess: lockAccess,
        languageSuggestionPresenter: nil)
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
        dictationLifecycleCoordinator: nil)
      let controller = HotkeyController(
        hotkeyService: hotkey, starter: starter, finalizer: finalizer, settings: settings)
      return Fixture(controller: controller, hotkeyService: hotkey, kernelDriver: pipeline)
    }
  #endif
}
