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
      routeResolutionSource: resolvedRoute?.routeResolutionSource,
      // #1714: read from the interface this builder already receives — no new
      // argument, no downcast to the concrete manager.
      inputResolutionSource: audioCapture.currentInputResolutionSource
    )

    if let source = (error as? AudioError)?.diagnosticSource {
      extras["capture.error_source"] = source
    }
    // #1851: the Mac's own answer at the failing step, a signed Int as a number.
    // Absent when the step has none: nil is NOT KNOWN, never zero. The Sentry
    // fingerprint is unchanged (it reads the domain and the fixed code 1).
    if let status = (error as? AudioError)?.diagnosticOSStatus {
      extras["capture.os_status"] = Int(status)
      if let fourCC = AudioStatusFormatting.fourCharacterCode(status) {
        extras["capture.os_status_fourcc"] = fourCC
      }
    }
    if let backend {
      extras["backend"] = backend
    }
    return extras
  }
}
