import SwiftUI

/// Read-only capture evidence. The capture manager remains the sole state owner.
/// The diagnostic bind survives stop for the pipeline's stop-time checks, so a
/// matching UID alone never establishes that a microphone is currently in use.
struct MicrophoneCapturePresentation: Equatable, Sendable {
  let isCapturing: Bool
  let boundDeviceUID: String?

  static let unknown = Self(isCapturing: false, boundDeviceUID: nil)

  func isInUse(displayedUID: String?) -> Bool {
    guard isCapturing, let displayedUID, !displayedUID.isEmpty,
      let boundDeviceUID, !boundDeviceUID.isEmpty
    else { return false }
    return boundDeviceUID == displayedUID
  }
}

private struct MicrophoneCapturePresentationKey: EnvironmentKey {
  static let defaultValue:
    @MainActor @Sendable () -> MicrophoneCapturePresentation = { .unknown }
}

extension EnvironmentValues {
  var microphoneCapturePresentation:
    @MainActor @Sendable () -> MicrophoneCapturePresentation {
    get { self[MicrophoneCapturePresentationKey.self] }
    set { self[MicrophoneCapturePresentationKey.self] = newValue }
  }
}

/// The Input device row's status slot, separate from its menu. Only this small
/// view invokes the deferred reader, so capture changes do not observe the page.
struct MicrophoneInUseStatus: View {
  let displayedUID: String?
  @Environment(\.microphoneCapturePresentation)
  private var readCapturePresentation

  /// Explicit snapshots keep render fixtures independent of live capture observation.
  var snapshot: MicrophoneCapturePresentation? = nil

  var body: some View {
    let capturePresentation = snapshot ?? readCapturePresentation()
    if capturePresentation.isInUse(displayedUID: displayedUID) {
      HStack(spacing: 5) {
        Circle().fill(Color.stSuccess).frame(width: 6, height: 6)
          .accessibilityHidden(true)
        // The semantic green marks the dot; the standard text token stays readable
        // on the light card too, without changing the shared status palette.
        Text(MicrophoneChoiceCopy.inUse).font(.stHelper).foregroundStyle(Color.stTextSecondary)
      }
    }
  }
}
