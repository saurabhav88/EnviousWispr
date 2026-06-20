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
/// (`kernelDriver`, `whisperKitKernelDriver`, `audioCapture`, `asrManager`)
/// reflect real root-state code; bundling them into a lens value-type would
/// hide the count rather than reduce coupling. Bible §30 entry filed.
/// PR-5 Rung 5 (#827) replaced the legacy WhisperKit pipeline class with a
/// second `KernelDictationDriver`; both backends now share the same
/// `PipelineState` vocabulary natively, so the prior state-bridge file is
/// gone.
@Observable @MainActor
final class LiveRecordingState {
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver
  let audioCapture: any AudioCaptureInterface
  let asrManager: any ASRManagerInterface

  /// True when recording is in hands-free (locked) mode via double-press.
  /// Read by the overlay, written through PR9's `RecordingLockedAccess` get/set
  /// seam. PR-C.3 of #763 rehomed this off the former root state.
  var isRecordingLocked: Bool = false

  init(
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface
  ) {
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.audioCapture = audioCapture
    self.asrManager = asrManager
  }

  /// Current pipeline phase. Routes through whichever backend is active per
  /// `asrManager.activeBackendType`. Both drivers expose `PipelineState`
  /// natively post-Rung 5, so no bridge is needed.
  var pipelineState: PipelineState {
    if asrManager.activeBackendType == .whisperKit {
      return whisperKitKernelDriver.state
    }
    return kernelDriver.state
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
      return whisperKitKernelDriver.currentTranscript
    }
    return kernelDriver.currentTranscript
  }
}

// MARK: - Dictation activity signal

/// `LiveRecordingState` owns both pipelines, so it exposes whether dictation is
/// in flight. Read by the menu bar and the auto-open guard. (The
/// `DictationActivityProviding` protocol conformance was dropped in #1106 with
/// its only consumer, the re-polish service; this is now a plain computed read.)
extension LiveRecordingState {
  /// True when either pipeline is recording, transcribing, or polishing.
  var isDictationActive: Bool {
    kernelDriver.state.isActive || whisperKitKernelDriver.state.isActive
  }
}
