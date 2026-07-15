@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// Progress callback shape: (fractionCompleted, phaseString, detailString).
/// Lives at the protocol scope so any backend with download progress can
/// surface it through the shared `prepare(progressCallback:)` entry point.
public typealias ProgressCallback = @Sendable (Double, String, String) -> Void

/// Unified protocol for all ASR backends.
///
/// Both WhisperKit and Parakeet/FluidAudio conform to this protocol,
/// enabling seamless backend switching at runtime.
public protocol ASRBackend: Actor {
  /// Whether the backend is initialized and ready to transcribe.
  var isReady: Bool { get }

  /// Load/initialize the model. Call once before transcription.
  func prepare() async throws

  /// Load/initialize the model with optional progress reporting.
  /// Default implementation delegates to `prepare()`; backends that report
  /// progress (Parakeet via FluidAudio download) override directly.
  func prepare(progressCallback: ProgressCallback?) async throws

  /// Batch transcription from raw Float32 samples (16kHz mono).
  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult

  /// Release model resources.
  func unload() async

  // MARK: - Streaming ASR (optional)

  /// Whether this backend supports streaming transcription during recording.
  var supportsStreaming: Bool { get }

  /// Start streaming ASR session. Audio buffers will be fed via `feedAudio(_:)`.
  func startStreaming(options: TranscriptionOptions) async throws

  /// Feed an audio buffer to the streaming ASR session.
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws

  /// Finalize the streaming session and return the complete transcript.
  func finalizeStreaming() async throws -> ASRResult

  /// Cancel an active streaming session, discarding partial results.
  func cancelStreaming() async
}

/// Default implementations for optional protocol members.
extension ASRBackend {
  public var supportsStreaming: Bool { false }

  public func startStreaming(options _: TranscriptionOptions) async throws {
    throw ASRError.streamingNotSupported
  }

  public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    throw ASRError.streamingNotSupported
  }

  public func finalizeStreaming() async throws -> ASRResult {
    throw ASRError.streamingNotSupported
  }

  public func cancelStreaming() async {}

  /// Default delegates to plain `prepare()` — backends without progress
  /// reporting ignore the callback. ParakeetBackend overrides directly to
  /// report FluidAudio download progress.
  public func prepare(progressCallback: ProgressCallback?) async throws {
    try await prepare()
  }
}

/// Errors that can occur during ASR operations.
enum ASRError: LocalizedError, Sendable {
  case notReady
  case streamingNotSupported
  case streamingTimeout
  case transcriptionFailed(String)

  var errorDescription: String? {
    switch self {
    case .notReady: return "ASR backend is not ready. Call prepare() first."
    case .streamingNotSupported: return "This ASR backend does not support streaming transcription."
    case .streamingTimeout: return "Streaming ASR finalization timed out."
    case .transcriptionFailed(let message): return "Transcription failed: \(message)"
    }
  }
}

/// #1525 PR G. Pins each case's exact measured current wire identity
/// (`docs/audits/2026-07-14-1525-pr-g-preflight.md` §1) — never re-derive.
/// `.transcriptionFailed` measured as `#0` despite being declared fourth.
/// Treat that as observed wire behavior, not a rule to re-derive from
/// payload shape or declaration order. `internal` (bare `var`) matches this
/// type's own internal visibility. NEVER change any of these strings once
/// shipped.
extension ASRError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .notReady: return "EnviousWisprASR.ASRError#1"
    case .streamingNotSupported: return "EnviousWisprASR.ASRError#2"
    case .streamingTimeout: return "EnviousWisprASR.ASRError#3"
    case .transcriptionFailed: return "EnviousWisprASR.ASRError#0"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .notReady: return "asr.not_ready"
    case .streamingNotSupported: return "asr.streaming_not_supported"
    case .streamingTimeout: return "asr.streaming_timeout"
    case .transcriptionFailed: return "asr.transcription_failed"
    }
  }
}
