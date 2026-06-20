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

/// PR9 of #763 — smoke + behavior tests for `DictationLifecycleCoordinator`.
///
/// Most lifecycle behavior is exercised end-to-end by the founder/automated
/// UAT (real audio drives real pipeline state transitions through the
/// installed `onStateChange` closures). These unit tests verify the
/// stand-alone helpers + construction + idempotent operations that don't
/// require driving pipeline state transitions from the test:
///   - construction does not crash
///   - `cancelPendingWarning()` is safe to call when no task is pending
///   - `activeCaptureBackend()` returns nil when both pipelines are idle
///   - `isCurrentSession(_:)` matches `audioCapture.currentCaptureSessionID`
@MainActor
@Suite struct DictationLifecycleCoordinatorTests {

  private static func makeCoordinator() -> (
    coordinator: DictationLifecycleCoordinator,
    audio: RouterTestAudioCapture,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    recordingLocked: TestRecordingLockedBox
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
    let hotkey = HotkeyService()
    let settingsSync = PipelineSettingsSync(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: hotkey,
      whisperKitSetup: WhisperKitSetupService()
    )
    let transcriptCoordinator = TranscriptCoordinator(store: store)
    let lastRecordingResult = LastRecordingResult()
    let lockBox = TestRecordingLockedBox()
    let coordinator = DictationLifecycleCoordinator(
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      recordingOverlay: overlay,
      hotkeyService: hotkey,
      settingsSync: settingsSync,
      audioCapture: audio,
      transcriptCoordinator: transcriptCoordinator,
      settings: settings,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: nil,
      recordingLockedAccess: .init(
        get: { lockBox.isLocked },
        set: { lockBox.isLocked = $0 }
      )
    )
    return (coordinator, audio, pipeline, whisperKitKernelDriver, lockBox)
  }

  @Test func constructionDoesNotCrash() {
    _ = Self.makeCoordinator()
  }

  @Test func cancelPendingWarningIsSafeWhenNoTaskPending() {
    let fixtures = Self.makeCoordinator()
    // No `install()`, no recording — nothing scheduled a warning Task.
    // Cancel should be a clean no-op.
    fixtures.coordinator.cancelPendingWarning()
    fixtures.coordinator.cancelPendingWarning()  // repeated calls also fine
  }

  @Test func activeCaptureBackendReturnsNilWhenBothPipelinesIdle() {
    let fixtures = Self.makeCoordinator()
    // Both pipelines start in `.idle`; no `install()` so no transitions fired.
    #expect(fixtures.kernelDriver.state.isActive == false)
    #expect(fixtures.whisperKitKernelDriver.state.isActive == false)
    #expect(fixtures.coordinator.activeCaptureBackend() == nil)
  }

  @Test func activeTelemetryTargetReturnsParakeetByDefaultWhenIdle() {
    let fixtures = Self.makeCoordinator()
    // Initial `lastCapturingBackend = .parakeet`; both pipelines idle →
    // helper resolves to "the backend that most recently owned a session,"
    // which is parakeet at first launch.
    let target = fixtures.coordinator.activeTelemetryTarget()
    #expect(target != nil)
    #expect(target as AnyObject === fixtures.kernelDriver as AnyObject)
  }

  @Test func isCurrentSessionMatchesAudioCaptureSessionID() {
    let fixtures = Self.makeCoordinator()
    fixtures.audio.currentCaptureSessionID = 42
    #expect(fixtures.coordinator.isCurrentSession(42) == true)
    #expect(fixtures.coordinator.isCurrentSession(7) == false)
    #expect(fixtures.coordinator.isCurrentSession(0) == false)
  }

  @Test func installSetsBothPipelineCallbacks() {
    let fixtures = Self.makeCoordinator()
    #expect(fixtures.kernelDriver.onStateChange == nil)
    #expect(fixtures.whisperKitKernelDriver.onStateChange == nil)
    fixtures.coordinator.install()
    #expect(fixtures.kernelDriver.onStateChange != nil)
    #expect(fixtures.whisperKitKernelDriver.onStateChange != nil)
  }

  /// V2 Lane C invariant C4 (#291), relocated from `HandsFreeLockTests` as a
  /// behavioral test (#881 TO-2): the hands-free lock must clear on every
  /// terminal pipeline state so the next recording starts in normal PTT mode.
  /// The prior test only scanned the coordinator's source text for the
  /// `recordingLockedAccess.set(false)` literal — it stayed green if the call
  /// were guarded out, moved behind an early return, or no-op'd. This drives
  /// the real `install()`-wired `onStateChange` and asserts the lock actually
  /// flips false at runtime.
  @Test func parakeetTerminalStatesClearRecordingLock() {
    let fx = Self.makeCoordinator()
    fx.coordinator.install()
    for terminal in [PipelineState.idle, .complete, .error("boom")] {
      fx.recordingLocked.isLocked = true
      fx.kernelDriver.onStateChange?(terminal)
      #expect(
        fx.recordingLocked.isLocked == false,
        "Parakeet terminal state \(terminal) must clear the hands-free lock")
    }
  }

  @Test func whisperKitTerminalStatesClearRecordingLock() {
    let fx = Self.makeCoordinator()
    fx.coordinator.install()
    for terminal in [PipelineState.idle, .complete, .error("boom")] {
      fx.recordingLocked.isLocked = true
      fx.whisperKitKernelDriver.onStateChange?(terminal)
      #expect(
        fx.recordingLocked.isLocked == false,
        "WhisperKit terminal state \(terminal) must clear the hands-free lock")
    }
  }

  /// #1063 PR1 (Codex code-diff r3 P1): a recording that ends WITHOUT a durable
  /// save (`.idle` from cancel / no-speech / too-short, or `.error` from a
  /// pipeline failure / helper-crash-while-alive) must fire the recovery cleanup
  /// so the armed spool + key are deleted in-session — not left to accumulate
  /// until the next launch on a long-running menu-bar app. `.complete` must NOT
  /// fire it: its save path owns deletion via `onDurableSave`. Drives the real
  /// `install()`-wired `onStateChange` for BOTH backends.
  @Test func nonSavedTerminalsFireRecoveryCleanupButCompleteDoesNot() {
    for backend in ["parakeet", "whisperKit"] {
      let fx = Self.makeCoordinator()
      var cleanupCount = 0
      fx.coordinator.onRecordingEndedWithoutDurableSave = { cleanupCount += 1 }
      fx.coordinator.install()
      let driver = backend == "whisperKit" ? fx.whisperKitKernelDriver : fx.kernelDriver

      driver.onStateChange?(.idle)
      #expect(cleanupCount == 1, "\(backend): .idle (cancel/no-speech) must fire non-saved cleanup")
      driver.onStateChange?(.error("boom"))
      #expect(cleanupCount == 2, "\(backend): .error must fire non-saved cleanup")
      driver.onStateChange?(.complete)
      #expect(
        cleanupCount == 2, "\(backend): .complete must NOT fire (its save path owns deletion)")
    }
  }
}

/// PR9 of #763 — mutable lock-state stand-in used by the
/// `recordingLockedAccess` closure pair in tests. Lets the test verify both
/// the getter (read by `showOverlay`) and the setter (written by state-change
/// closures) round-trip through the same value.
@MainActor
final class TestRecordingLockedBox {
  var isLocked: Bool = false
}
