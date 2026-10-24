import SwiftUI

/// Dims a view while a dictation records (#4001 step 2a). The recording state is read HERE,
/// in this modifier's own body, so a view that applies it does not observe the pipeline state
/// and is not evaluated again each time that state moves; only this modifier is.
struct RecordingDimmed: ViewModifier {
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState

  func body(content: Content) -> some View {
    let isRecording = liveRecordingState.pipelineState == .recording
    content
      .opacity(isRecording ? 0.4 : 1.0)
      .animation(.easeInOut(duration: 0.3), value: isRecording)
  }
}

extension View {
  /// Dims this view to 40% while a dictation records, with the History list's 0.3 s fade.
  func recordingDimmed() -> some View { modifier(RecordingDimmed()) }
}
