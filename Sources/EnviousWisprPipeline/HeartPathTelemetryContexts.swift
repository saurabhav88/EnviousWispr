import EnviousWisprAudio
import Foundation

/// Per-call context for `HeartPathTelemetryEmitter.noAudioCaptured(...)`.
///
/// The shape mirrors the parameters previously threaded into
/// `TranscriptionPipeline.emitNoAudioCapturedEvent(wasStreaming:)` and
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
}
