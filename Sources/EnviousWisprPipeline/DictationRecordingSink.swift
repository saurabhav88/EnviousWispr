import EnviousWisprCore
import Foundation

/// What produced the delivered text of one dictation (#3147 §3.1, §3.2), frozen at the decode that
/// actually delivered it: the primary decode, a batch rescue, a lead-trim salvage or a Phase 2
/// retry. Never the primary attempt when a later attempt delivered.
public struct DictationASREvidence: Sendable, Equatable {
  /// Which decode delivered the text.
  public enum Source: String, Sendable, Equatable {
    case batch
    case streaming
    case batchRescue
    case leadSalvage
    case phase2Retry
  }

  /// The audio that decode read, relative to the raw capture handed over beside it.
  public enum DecodeInput: Sendable, Equatable {
    /// The raw capture itself (a Parakeet streaming win).
    case rawCapture
    /// The raw capture padded to the engine's minimum length (Whisper).
    case paddedRawCapture
    /// The conditioned batch buffer (Parakeet batch, batch rescue).
    case conditionedBatch
    /// The conditioned batch buffer without its first `leadSamples` (lead-trim salvage).
    case conditionedBatchTrimmed(leadSamples: Int)
  }

  /// The untouched speech-engine text of the delivering decode (before any text processing).
  public let text: String
  public let backend: ASRBackendType
  public let source: Source
  public let input: DecodeInput
  /// Whether that decode returned word timings with any timed text. Always false for Whisper
  /// (segment timing only) and for a Parakeet streaming win; only Parakeet batch evidence can
  /// carry word timings. Availability only: no timing is converted or stored here.
  public let wordTimingsAvailable: Bool
  /// The delivering decode's real word timings and its map onto the recording, when that decode
  /// produced any. `nil` means untimed: History shows no times rather than guessing them.
  public let timing: DictationTimingEvidence?

  public init(
    text: String, backend: ASRBackendType, source: Source, input: DecodeInput,
    wordTimingsAvailable: Bool, timing: DictationTimingEvidence? = nil
  ) {
    self.text = text
    self.backend = backend
    self.source = source
    self.input = input
    self.wordTimingsAvailable = wordTimingsAvailable
    self.timing = timing
  }
}

/// One finished dictation's audio, handed over for History's saved recordings (#3147 §3.1).
///
/// Frozen when the take concludes: the History row the take saved, the audio the user spoke
/// (the raw capture at 16 kHz mono, the timeline playback uses), and whether recordings were on
/// when the take STARTED. A later take never supplies any of these values.
public struct DictationRecordingRequest: Sendable, Equatable {
  /// The permanent History row this take saved (its `Transcript.id`).
  public let rowID: UUID
  /// The captured audio, Float32 16 kHz mono.
  public let samples: [Float]
  /// The recording preference read once when the take started. Off: nothing is encoded and the
  /// row records `recordingsOff`.
  public let recordingsOn: Bool
  /// What produced the delivered text.
  public let asr: DictationASREvidence

  public init(rowID: UUID, samples: [Float], recordingsOn: Bool, asr: DictationASREvidence) {
    self.rowID = rowID
    self.samples = samples
    self.recordingsOn = recordingsOn
    self.asr = asr
  }
}

/// Receives finished dictations for saved recordings. Implemented by the app (AppKit); the
/// pipeline never imports Storage or AppKit.
///
/// The kernel calls `submit` once per take, after delivery, and only when this take's ordinary
/// permanent History save returned successfully. `submit` must return at once: encoding and file
/// work happen on the receiver's own tasks and never delay capture or paste.
@MainActor
public protocol DictationRecordingSink: AnyObject {
  func submit(_ request: DictationRecordingRequest)
}
