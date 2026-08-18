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

/// `RecordingFinalizer` admitting an abandonment end to end (#2087, chunk 7b).
///
/// The policy tests next door prove the two halves of the rule AGREE. They
/// cannot prove the finalizer acts on it, and that gap is where this feature
/// would fail silently: the shortcut stays armed through `.transcribing`, the
/// user presses Escape, and the finalizer's own state guard — which admits only
/// `.recording` and `.loadingModel` — drops it on the floor. An armed, inert
/// key is worse than no key, because nothing tells the user it did nothing.
///
/// Driven against both backends, because the finalizer picks its driver from
/// `asrManager.activeBackendType` and a rule applied to one is a rule missing
/// from the other.
///
/// **What these do NOT cover, stated rather than implied:** that an abandonment
/// leaves the overlay up. `RecordingOverlayPanel.show(...)` traps on an
/// implicitly-unwrapped nil in a unit context, so the overlay cannot be put into
/// a non-hidden state to observe, and asserting `.hidden` afterwards would be
/// vacuous — it starts hidden. The skip is one `if !abandoning` around three
/// calls; proving it needs the panel behind a seam, which is not this chunk's
/// scope.
@MainActor
/// Class: `.productOutcome` — an abandoned recovery keeps its overlay, or loses it while still working.
@Suite("RecordingFinalizer — abandonment (#2087)", .tags(.productOutcome))
struct RecordingFinalizerAbandonmentTests {

  #if DEBUG

    @Test(
      "a shortcut cancel during a live recovery is admitted as an abandonment",
      arguments: [ASRBackendType.parakeet, .whisperKit])
    func shortcutDuringRecoveryIsAdmitted(backend: ASRBackendType) async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = backend
      Self.enterEscapeRecoveryTranscription(Self.driver(fx, backend))

      let abandoned = await fx.finalizer.cancel(trigger: .shortcut)

      #expect(abandoned, "\(backend) must admit the abandonment its shortcut stayed armed for")
    }

    /// The control, and the founder-settled boundary: a click on a control
    /// labelled Cancel says exactly one thing. In the same state, the button is
    /// not an abandonment — and the finalizer's state guard then rejects it, so
    /// nothing happens at all.
    @Test(
      "the cancel button in the same state is not an abandonment",
      arguments: [ASRBackendType.parakeet, .whisperKit])
    func buttonInTheSameStateIsNotAbandonment(backend: ASRBackendType) async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = backend
      Self.enterEscapeRecoveryTranscription(Self.driver(fx, backend))

      let abandoned = await fx.finalizer.cancel(trigger: .cancelButton)

      #expect(abandoned == false)
    }

    /// The other control: an ORDINARY cancel is not an abandonment either, so
    /// its teardown still runs. Without this the three tests above would pass
    /// against a finalizer that called every cancel an abandonment.
    @Test("an ordinary shortcut cancel while recording is not an abandonment")
    func ordinaryCancelIsNotAbandonment() async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      let kernel = fx.kernelDriver.kernelForTesting
      kernel.start(config: .testDefault())
      kernel.testForceState(.live)

      let abandoned = await fx.finalizer.cancel(trigger: .shortcut)

      #expect(abandoned == false)
    }

    /// **The test the whole disarm depends on.** `cancelRecording` awaits a
    /// kernel terminal, and an abandonment deliberately has none until its
    /// decode returns — so routing an abandonment through it would return the
    /// answer only AFTER the danger window the caller's disarm exists to close,
    /// and a third press could fire inside it. The finalizer therefore uses
    /// `requestCancelWithoutAwaitingTerminal`.
    ///
    /// Asserted against a session that is genuinely still non-terminal when the
    /// call returns: `recordingOutcome` is nil afterwards, which is only true if
    /// nothing waited.
    @Test("an abandonment returns while the session is still running")
    func abandonmentReturnsBeforeAnyTerminal() async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      Self.enterEscapeRecoveryTranscription(fx.kernelDriver)
      let kernel = fx.kernelDriver.kernelForTesting

      let abandoned = await fx.finalizer.cancel(trigger: .shortcut)

      #expect(abandoned)
      #expect(
        kernel.recordingOutcome == nil,
        "returning here means nothing awaited a terminal that has not happened")
      guard case .abandonedEscapeRecovery = kernel.finalizationDisposition else {
        Issue.record("the request did not reach the kernel")
        return
      }
    }

    /// The prologue runs whatever the guard decides, including for an
    /// abandonment. Pinned because #2087's first attempt moved it behind the
    /// guard and broke the ignored-cancel case that
    /// `RecordingFinalizerCancelPathTests` already covered.
    @Test("the hands-free lock is cleared even when the cancel is an abandonment")
    func prologueStillRunsForAnAbandonment() async {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      Self.enterEscapeRecoveryTranscription(fx.kernelDriver)
      fx.lockBox.isLocked = true

      _ = await fx.finalizer.cancel(trigger: .shortcut)

      #expect(fx.lockBox.isLocked == false)
    }

    /// The driver's own boundary check, exercised through MISUSE. Dropping the
    /// method's argument narrowed intent but not behaviour: a package caller
    /// could still have asked an ordinary recording to cancel without waiting
    /// for its terminal, which is the one thing the ordinary path must never do.
    ///
    /// Asserted on provenance as well as outcome, because a cancel that reached
    /// the kernel and was then ignored elsewhere would leave the outcome nil and
    /// still have latched an origin.
    @Test("asking an ordinary recording to abandon does nothing at all")
    func abandonmentRequestIsInertOutsideARecovery() async {
      let fx = Self.makeFixture()
      let kernel = fx.kernelDriver.kernelForTesting
      kernel.start(config: .testDefault())
      kernel.testForceState(.live)
      #expect(fx.kernelDriver.isEscapeRecoveryTranscribing == false)

      fx.kernelDriver.requestEscapeRecoveryAbandonment()

      #expect(kernel.recordingOutcome == nil, "an ordinary recording must not be cancelled")
      #expect(
        kernel.lastCancelOrigin == .systemOrFault,
        "and nothing may be latched — the request must not reach the kernel at all")
      #expect(kernel.state == .live)
    }

    // MARK: Helpers

    private static func driver(_ fx: Fixture, _ backend: ASRBackendType)
      -> KernelDictationDriver
    {
      backend == .whisperKit ? fx.whisperKitKernelDriver : fx.kernelDriver
    }

    /// Park a driver's kernel where an Escape Recovery is transcribing. Nothing
    /// in production reaches this yet — the cancel routing that would set the
    /// disposition is chunk 12's activation — so the DEBUG seam is the only way
    /// to put the finalizer in front of the case it exists to handle.
    private static func enterEscapeRecoveryTranscription(_ driver: KernelDictationDriver) {
      let kernel = driver.kernelForTesting
      kernel.start(config: .testDefault())
      kernel.testForceState(.delivering)
      kernel.testSetDeliveringPhase(.transcribing)
      kernel.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      precondition(
        driver.isEscapeRecoveryTranscribing,
        "the fixture must actually be in the state under test, or every assertion below is vacuous")
    }

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
        get: { lockBox.isLocked }, set: { lockBox.isLocked = $0 })
      let hcr = HeartControlRecovery(
        hideOverlay: { overlay.show(intent: .hidden) },
        setLocked: { locked in lockAccess.set(locked) },
        backend: { asr.activeBackendType.rawValue })
      let finalizer = RecordingFinalizer(
        kernelDriver: pipeline,
        whisperKitKernelDriver: whisperKitKernelDriver,
        asrManager: asr,
        recordingOverlay: overlay,
        heartControlRecovery: hcr,
        recordingLockedAccess: lockAccess,
        languageSuggestionPresenter: nil)
      return Fixture(
        finalizer: finalizer,
        kernelDriver: pipeline,
        whisperKitKernelDriver: whisperKitKernelDriver,
        asr: asr,
        lockBox: lockBox,
        overlay: overlay)
    }
  #endif
}
