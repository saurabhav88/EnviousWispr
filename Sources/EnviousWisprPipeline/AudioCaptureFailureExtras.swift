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
    let resolvedRoute = audioCapture.currentResolvedRoute
    var extras = SentryAudioExtras.buildCaptureExtras(
      route: audioCapture.currentAudioRoute,
      sourceType: audioCapture.captureSourceType,
      sessionID: audioCapture.currentCaptureSessionID,
      isActivelyCapturing: audioCapture.isActivelyCapturing,
      inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
        ? nil : audioCapture.preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      failureMode: failureMode,
      selectedTransport: resolvedRoute?.selected,
      effectiveTransport: resolvedRoute?.effective,
      routeReason: resolvedRoute?.routeReason,
      routeFallbackReason: resolvedRoute?.routeFallbackReason,
      inputSelectionMode: resolvedRoute?.inputSelectionMode,
      outputTransport: resolvedRoute?.outputTransport,
      routeResolutionSource: resolvedRoute?.routeResolutionSource
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
