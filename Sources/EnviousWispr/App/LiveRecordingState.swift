import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import Observation

/// PR7 of epic #763. Owns the "what is happening with dictation right now"
/// facts that were previously computed by the former root state getters. Three computed
/// properties — `pipelineState`, `audioLevel`, `currentTranscript` — route
/// through the active backend exactly as the old root-state getters did, with
/// no behavior change.
///
/// **Lifetime.** Constructed once at app launch as `@State` on
/// `EnviousWisprApp`; lives for the entire process lifetime. Read by views
/// and by `AppDelegate` (weak ref via `attach(...)` setter injection) to
/// drive menu-bar icon updates.
///
/// **Existential storage rationale.** `audioCapture` and `asrManager` are
/// stored as the same existential protocol types the former root state uses
/// (the former root-state file) so PR7 can be a pure facts-move with no shape
/// change. Both concrete conformers (`AudioCaptureManager`,
/// `AudioCaptureProxy`, `ASRManager`) are `@Observable`; SwiftUI body
/// tracking propagates through the existential. `LiveRecordingStateTests`
/// includes a focused `withObservationTracking` check to verify this; if
/// it fails, switch to concrete types before PR merge.
///
/// **Ceiling-raise note (3 → 4 stored).** The four sources of truth
/// (`pipeline`, `whisperKitPipeline`, `audioCapture`, `asrManager`) reflect
/// real root-state code; bundling them into a lens value-type would hide the
/// count rather than reduce coupling. Bible §30 entry filed.
@Observable @MainActor
final class LiveRecordingState {
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline
  let audioCapture: any AudioCaptureInterface
  let asrManager: any ASRManagerInterface

  /// True when recording is in hands-free (locked) mode via double-press.
  /// Read by the overlay, written through PR9's `RecordingLockedAccess` get/set
  /// seam. PR-C.3 of #763 rehomed this off the former root state.
  var isRecordingLocked: Bool = false

  init(
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface
  ) {
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline
    self.audioCapture = audioCapture
    self.asrManager = asrManager
  }

  /// Current pipeline phase. Routes through whichever backend is active per
  /// `asrManager.activeBackendType`; WhisperKit's distinct state enum is
  /// bridged via `WhisperKitPipelineState.asPipelineState`. Replaces the
  /// pre-PR7 root-state getter.
  var pipelineState: PipelineState {
    if asrManager.activeBackendType == .whisperKit {
      return whisperKitPipeline.state.asPipelineState
    }
    return pipeline.state
  }

  /// Audio capture level for waveform/level UI. Replaces the pre-PR7
  /// the former root state getter.
  var audioLevel: Float {
    audioCapture.audioLevel
  }

  /// In-flight transcript from the active pipeline. Used as the live
  /// fallback in `HistoryContentView` composition: selected-history else
  /// live. Replaces the live-fallback half of the pre-PR7
  /// the former root state getter.
  var currentTranscript: Transcript? {
    if asrManager.activeBackendType == .whisperKit {
      return whisperKitPipeline.currentTranscript
    }
    return pipeline.currentTranscript
  }
}

// MARK: - DictationActivityProviding

/// PR-C.3 of #763: `LiveRecordingState` provides the dictation-activity signal
/// (replaces the former root state's conformance). It already owns both pipelines.
extension LiveRecordingState: DictationActivityProviding {
  /// True when either pipeline is recording, transcribing, or polishing. Used
  /// by `TranscriptPolishService` to block a re-polish during live dictation.
  var isDictationActive: Bool {
    pipeline.state.isActive || whisperKitPipeline.state.isActive
  }
}
