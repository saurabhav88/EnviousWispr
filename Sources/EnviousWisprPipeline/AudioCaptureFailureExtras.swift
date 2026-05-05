import EnviousWisprAudio
import EnviousWisprServices

@MainActor
enum AudioCaptureFailureExtras {
  static func build(
    error: Error,
    audioCapture: any AudioCaptureInterface,
    failureMode: String,
    backend: String? = nil
  ) -> [String: Any] {
    var extras = SentryAudioExtras.buildCaptureExtras(
      route: audioCapture.currentAudioRoute,
      sourceType: audioCapture.captureSourceType,
      sessionID: audioCapture.currentCaptureSessionID,
      isActivelyCapturing: audioCapture.isActivelyCapturing,
      inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
        ? nil : audioCapture.preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      failureMode: failureMode
    )

    if let source = (error as? AudioError)?.diagnosticSource {
      extras["capture.error_source"] = source
    }
    if let backend {
      extras["backend"] = backend
    }
    return extras
  }
}
