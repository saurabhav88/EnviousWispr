import EnviousWisprCore
import Foundation
import WhisperKit

/// #1525 PR I-B: pinned Sentry identity for a raw throw out of `WhisperKitBackend
/// .performLoad`'s `WhisperKit(config)` call. Deliberately NOT an extension of
/// `EnviousWisprASR.ASRError` — WhisperKit's own `WhisperError` is an 11-case,
/// `@frozen` taxonomy distinct from the app-level `ASRError`, and `.transcriptionFailed`
/// already has a permanently pinned identity for the DECODE path (a different failure
/// class from model LOADING).
///
/// Mirrors `WhisperError`'s 11 cases plus `.unknownLoadFailure` for any non-`WhisperError`
/// throw from the init (e.g. a CoreML/filesystem error). Every case carries the original
/// error's description as an associated `String`.
enum WhisperKitModelLoadSentryError: Error, LocalizedError, Sendable, Equatable {
  case tokenizerUnavailable(String)
  case modelsUnavailable(String)
  case audioProcessingFailed(String)
  case decodingLogitsFailed(String)
  case segmentingFailed(String)
  case loadAudioFailed(String)
  case prepareDecoderInputsFailed(String)
  case transcriptionFailed(String)
  case decodingFailed(String)
  case microphoneUnavailable(String)
  case initializationError(String)
  case unknownLoadFailure(String)

  var errorDescription: String? {
    switch self {
    case .tokenizerUnavailable(let d), .modelsUnavailable(let d), .audioProcessingFailed(let d),
      .decodingLogitsFailed(let d), .segmentingFailed(let d), .loadAudioFailed(let d),
      .prepareDecoderInputsFailed(let d), .transcriptionFailed(let d), .decodingFailed(let d),
      .microphoneUnavailable(let d), .initializationError(let d), .unknownLoadFailure(let d):
      return d
    }
  }

  init(mapping error: WhisperError) {
    // WhisperError's own errorDescription logs each message as a side effect
    // (WhisperError.swift); localizedDescription route avoids double-logging.
    let d = error.localizedDescription
    switch error {
    case .tokenizerUnavailable: self = .tokenizerUnavailable(d)
    case .modelsUnavailable: self = .modelsUnavailable(d)
    case .audioProcessingFailed: self = .audioProcessingFailed(d)
    case .decodingLogitsFailed: self = .decodingLogitsFailed(d)
    case .segmentingFailed: self = .segmentingFailed(d)
    case .loadAudioFailed: self = .loadAudioFailed(d)
    case .prepareDecoderInputsFailed: self = .prepareDecoderInputsFailed(d)
    case .transcriptionFailed: self = .transcriptionFailed(d)
    case .decodingFailed: self = .decodingFailed(d)
    case .microphoneUnavailable: self = .microphoneUnavailable(d)
    case .initializationError: self = .initializationError(d)
    }
  }

  /// The production catch site's actual normalization logic, extracted so it is
  /// directly testable — `performLoad`'s `testSeams` early return makes the real
  /// catch unreachable from a unit test, so a test that "recreated the same catch
  /// pattern" inline would exercise copied test code, not production.
  init(normalizingLoadError error: any Error) {
    if let whisperError = error as? WhisperError {
      self.init(mapping: whisperError)
    } else {
      self = .unknownLoadFailure(error.localizedDescription)
    }
  }
}

extension WhisperKitModelLoadSentryError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    // No live Sentry history found for a "WhisperError"-identified descriptor
    // in a 90-day search — every case below is a defensive pin.
    switch self {
    case .tokenizerUnavailable: return "WhisperKit.WhisperError#0"
    case .modelsUnavailable: return "WhisperKit.WhisperError#1"
    case .audioProcessingFailed: return "WhisperKit.WhisperError#2"
    case .decodingLogitsFailed: return "WhisperKit.WhisperError#3"
    case .segmentingFailed: return "WhisperKit.WhisperError#4"
    case .loadAudioFailed: return "WhisperKit.WhisperError#5"
    case .prepareDecoderInputsFailed: return "WhisperKit.WhisperError#6"
    case .transcriptionFailed: return "WhisperKit.WhisperError#7"
    case .decodingFailed: return "WhisperKit.WhisperError#8"
    case .microphoneUnavailable: return "WhisperKit.WhisperError#9"
    case .initializationError: return "WhisperKit.WhisperError#10"
    case .unknownLoadFailure:
      return "EnviousWisprASR.WhisperKitModelLoadSentryError.unknownLoadFailure"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .tokenizerUnavailable: return "whisperkit_load.tokenizer_unavailable"
    case .modelsUnavailable: return "whisperkit_load.models_unavailable"
    case .audioProcessingFailed: return "whisperkit_load.audio_processing_failed"
    case .decodingLogitsFailed: return "whisperkit_load.decoding_logits_failed"
    case .segmentingFailed: return "whisperkit_load.segmenting_failed"
    case .loadAudioFailed: return "whisperkit_load.load_audio_failed"
    case .prepareDecoderInputsFailed: return "whisperkit_load.prepare_decoder_inputs_failed"
    case .transcriptionFailed: return "whisperkit_load.transcription_failed"
    case .decodingFailed: return "whisperkit_load.decoding_failed"
    case .microphoneUnavailable: return "whisperkit_load.microphone_unavailable"
    case .initializationError: return "whisperkit_load.initialization_error"
    case .unknownLoadFailure: return "whisperkit_load.unknown_load_failure"
    }
  }
}
