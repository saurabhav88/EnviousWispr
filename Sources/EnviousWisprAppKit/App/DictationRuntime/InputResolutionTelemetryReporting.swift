import EnviousWisprAudio
import EnviousWisprServices

/// #1714: the sole mapper from the Audio module's cold-attempt projection to
/// `TelemetryService`.
///
/// Exists so `EnviousWisprAudio` never imports `EnviousWisprServices`. The
/// manager owns the fact and publishes a flat value; the composition root wires
/// this function to it; nothing in between reinterprets anything.
///
/// Pure argument mapping — no state, no defaulting, no recomputation. Every
/// field is passed through unchanged, including the two counts whose `nil`
/// means NOT KNOWN rather than zero. Deriving or defaulting anything here would
/// put a second opinion between the resolver's decision and the recorded event.
///
/// It lives in its own file rather than inside `WisprBootstrapper` because that
/// file is at its architecture-test line ceiling (1330,
/// `EnviousWisprAppCeilingsTests.swift:432`).
@MainActor
enum InputResolutionTelemetryReporting {
  /// Install this observer on the manager and hand it back, so the composition
  /// root wires it in one line.
  ///
  /// The installation lives here rather than inline in `WisprBootstrapper`
  /// because that file is AT its architecture-test ceiling: the inline
  /// three-line form measured 1331 against a limit of 1330, and the ceiling is
  /// not ours to raise for a telemetry wire.
  static func observing(_ manager: AudioCaptureManager) -> AudioCaptureManager {
    manager.onFinalizedInputResolutionAttempt = report
    return manager
  }

  static func report(_ attempt: InputResolutionAttemptTelemetry) {
    TelemetryService.shared.audioInputResolution(
      defaultPresent: attempt.defaultPresent,
      enumerationOutcome: attempt.enumerationOutcome,
      inputDeviceCount: attempt.inputDeviceCount,
      eligibleDeviceCount: attempt.eligibleDeviceCount,
      inputResolutionSource: attempt.inputResolutionSource,
      selectedTransport: attempt.selectedTransport,
      bindOutcome: attempt.bindOutcome,
      prepareOutcome: attempt.prepareOutcome
    )
  }
}
