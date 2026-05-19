import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprASR
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
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    recordingLocked: TestRecordingLockedBox
  ) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetPipeline(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKitPipeline = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = SettingsManager()
    let overlay = RecordingOverlayPanel()
    let hotkey = HotkeyService()
    let settingsSync = PipelineSettingsSync(
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
      polishService: TranscriptPolishService(
        keychainManager: KeychainManager(),
        transcriptStore: store),
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: hotkey,
      whisperKitSetup: WhisperKitSetupService()
    )
    let transcriptCoordinator = TranscriptCoordinator(store: store)
    let lastRecordingResult = LastRecordingResult()
    let lockBox = TestRecordingLockedBox()
    let coordinator = DictationLifecycleCoordinator(
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
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
    return (coordinator, audio, pipeline, whisperKitPipeline, lockBox)
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
    #expect(fixtures.pipeline.state.isActive == false)
    #expect(fixtures.whisperKitPipeline.state.isActive == false)
    #expect(fixtures.coordinator.activeCaptureBackend() == nil)
  }

  @Test func activeTelemetryTargetReturnsParakeetByDefaultWhenIdle() {
    let fixtures = Self.makeCoordinator()
    // Initial `lastCapturingBackend = .parakeet`; both pipelines idle →
    // helper resolves to "the backend that most recently owned a session,"
    // which is parakeet at first launch.
    let target = fixtures.coordinator.activeTelemetryTarget()
    #expect(target != nil)
    #expect(target as AnyObject === fixtures.pipeline as AnyObject)
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
    #expect(fixtures.pipeline.onStateChange == nil)
    #expect(fixtures.whisperKitPipeline.onStateChange == nil)
    fixtures.coordinator.install()
    #expect(fixtures.pipeline.onStateChange != nil)
    #expect(fixtures.whisperKitPipeline.onStateChange != nil)
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
