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
