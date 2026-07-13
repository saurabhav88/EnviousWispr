import Foundation

/// Per-call context for `HeartPathTelemetryEmitter.noAudioCaptured(...)`.
///
/// The shape mirrors the parameters previously threaded into
/// the old Parakeet pipeline's `emitNoAudioCapturedEvent(wasStreaming:)` and
/// `WhisperKitPipeline.emitNoAudioCapturedEvent()`.
struct NoAudioContext: Sendable {
  let sessionID: UInt64
  let durationMs: Int
  let wasStreaming: Bool
  let route: String
  let isActivelyCapturing: Bool
  let captureSourceType: String
  let inputDeviceUIDPreferred: String?
  let inputDeviceUIDSystemDefault: String?
  // #1376: resolved-route transports so the "app-derived effective=built_in +
  // empty transcript" join (CO4) is queryable on the no-audio terminal.
  var selectedTransport: String? = nil
  var effectiveTransport: String? = nil
  var routeReason: String? = nil
  var routeFallbackReason: String? = nil
  var inputSelectionMode: String? = nil
  var outputTransport: String? = nil
  var routeResolutionSource: String? = nil
  // #1434: capture-health facts at the no-audio terminal — populated from the
  // kernel's post-stop capture-health record (no-audio fires AFTER
  // `stopCapture()` returned empty, so the record exists).
  var captureNativeRateHz: Double? = nil
  var captureRingDropCount: Int? = nil
  var captureConverterErrorCount: Int? = nil
  var captureZeroOutputCount: Int? = nil
  var captureRateDivergenceDetected: Bool? = nil
  var captureFormatStabilized: Bool? = nil
  var captureRebuiltForFormat: Bool? = nil
  // #1523: bound device's total native input channel count at the no-audio terminal.
  var captureNativeChannelCount: Int? = nil
}

/// Per-call context for `HeartPathTelemetryEmitter.zombieZeroPeakIfNeeded(...)`.
///
/// Mirrors the parameters previously consumed by
/// `emitZombieEngineEventIfNeeded(rawSamples:peakAudioLevel:)` in both
/// pipelines.
struct ZeroPeakContext: Sendable {
  let sessionID: UInt64
  let durationMs: Int
  let route: String
  let sampleCount: Int
  let isActivelyCapturing: Bool
  let captureSourceType: String
  let inputDeviceUIDPreferred: String?
  let inputDeviceUIDSystemDefault: String?
  // #1376: resolved-route transports so a zero-peak (silent) terminal carries
  // the same route context as the success + no-audio events (CO4).
  var selectedTransport: String? = nil
  var effectiveTransport: String? = nil
  var routeReason: String? = nil
  var routeFallbackReason: String? = nil
  var inputSelectionMode: String? = nil
  var outputTransport: String? = nil
  var routeResolutionSource: String? = nil
}
