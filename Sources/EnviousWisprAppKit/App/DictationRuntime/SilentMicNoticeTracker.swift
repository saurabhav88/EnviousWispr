import EnviousWisprAudio
import EnviousWisprCore

/// #4841: which silent-mic notice the pill should show while recording.
enum MicSilenceLevel: Equatable, Sendable {
  /// No notice: sound is arriving, the run is too short, or warnings are off.
  case none
  /// "We're not hearing anything from your microphone."
  case calm
  /// "Your microphone isn't sending sound. Stop and check it in Settings."
  case strong
}

/// #4841: the pure silent-mic notice policy. One owner for the thresholds; the
/// run length and the since-start test come only from the capture layer's
/// `ExactZeroRun` (drained pre-roll already excluded there). It never ends a take
/// and knows nothing about the recording lifecycle or the overlay.
enum SilentMicNoticePolicy {
  static func level(for run: ExactZeroRun?, warningsEnabled: Bool) -> MicSilenceLevel {
    guard warningsEnabled, let run, run.sampleCount > 0 else { return .none }
    if run.sampleCount >= AudioConstants.silentMicStrongSamples { return .strong }
    let calmThreshold =
      run.sinceTakeStart
      ? AudioConstants.silentMicCalmSinceStartSamples
      : AudioConstants.silentMicCalmMidTakeSamples
    return run.sampleCount >= calmThreshold ? .calm : .none
  }
}
