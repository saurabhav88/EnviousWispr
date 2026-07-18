import EnviousWisprCore
import Foundation
import Testing
import WhisperKit

@testable import EnviousWisprASR
@testable import EnviousWisprServices

/// #1525 PR I-B — `WhisperKitModelLoadSentryError`'s Sentry identity is PINNED,
/// mirroring `KeyStoreError`'s shipped pattern (PR F). No live Sentry history found
/// for a "WhisperError"-identified descriptor in a 90-day search — every case is a
/// defensive pin.
@Suite("WhisperKitModelLoadSentryError Sentry stable identity (#1525 PR I-B)")
struct WhisperKitModelLoadSentryErrorTests {

  private static let env = "production"
  private static let category = SentryBreadcrumb.ErrorCategory.modelLoadFailed

  private static let pins: [(WhisperKitModelLoadSentryError, String, String)] = [
    (
      .tokenizerUnavailable("x"), "WhisperKit.WhisperError#0",
      "whisperkit_load.tokenizer_unavailable"
    ),
    (.modelsUnavailable("x"), "WhisperKit.WhisperError#1", "whisperkit_load.models_unavailable"),
    (
      .audioProcessingFailed("x"), "WhisperKit.WhisperError#2",
      "whisperkit_load.audio_processing_failed"
    ),
    (
      .decodingLogitsFailed("x"), "WhisperKit.WhisperError#3",
      "whisperkit_load.decoding_logits_failed"
    ),
    (.segmentingFailed("x"), "WhisperKit.WhisperError#4", "whisperkit_load.segmenting_failed"),
    (.loadAudioFailed("x"), "WhisperKit.WhisperError#5", "whisperkit_load.load_audio_failed"),
    (
      .prepareDecoderInputsFailed("x"), "WhisperKit.WhisperError#6",
      "whisperkit_load.prepare_decoder_inputs_failed"
    ),
    (
      .transcriptionFailed("x"), "WhisperKit.WhisperError#7", "whisperkit_load.transcription_failed"
    ),
    (.decodingFailed("x"), "WhisperKit.WhisperError#8", "whisperkit_load.decoding_failed"),
    (
      .microphoneUnavailable("x"), "WhisperKit.WhisperError#9",
      "whisperkit_load.microphone_unavailable"
    ),
    (
      .initializationError("x"), "WhisperKit.WhisperError#10",
      "whisperkit_load.initialization_error"
    ),
    (
      .unknownLoadFailure("x"),
      "EnviousWisprASR.WhisperKitModelLoadSentryError.unknownLoadFailure",
      "whisperkit_load.unknown_load_failure"
    ),
  ]

  // MARK: - A. Pin lock

  @Test("every case keeps its exact pinned fingerprint")
  func pinLock() {
    for (error, descriptor, semanticID) in Self.pins {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(error.sentrySemanticID == semanticID)
    }
  }

  @Test("all 12 declared identities are unique")
  func identitiesAreUnique() {
    let errors = Self.pins.map(\.0)
    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 12)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 12)
  }

  // MARK: - B. Mapping completeness — the real production normalizer

  @Test(
    "init(normalizingLoadError:) maps every real WhisperError case, preserving its description"
  )
  func mappingCompletenessForRealWhisperErrors() {
    let cases: [(WhisperError, WhisperKitModelLoadSentryError)] = [
      (
        .tokenizerUnavailable("a"),
        .tokenizerUnavailable(WhisperError.tokenizerUnavailable("a").localizedDescription)
      ),
      (
        .modelsUnavailable("b"),
        .modelsUnavailable(WhisperError.modelsUnavailable("b").localizedDescription)
      ),
      (
        .audioProcessingFailed("c"),
        .audioProcessingFailed(WhisperError.audioProcessingFailed("c").localizedDescription)
      ),
      (
        .decodingLogitsFailed("d"),
        .decodingLogitsFailed(WhisperError.decodingLogitsFailed("d").localizedDescription)
      ),
      (
        .segmentingFailed("e"),
        .segmentingFailed(WhisperError.segmentingFailed("e").localizedDescription)
      ),
      (
        .loadAudioFailed("f"),
        .loadAudioFailed(WhisperError.loadAudioFailed("f").localizedDescription)
      ),
      (
        .prepareDecoderInputsFailed("g"),
        .prepareDecoderInputsFailed(
          WhisperError.prepareDecoderInputsFailed("g").localizedDescription)
      ),
      (
        .transcriptionFailed("h"),
        .transcriptionFailed(WhisperError.transcriptionFailed("h").localizedDescription)
      ),
      (
        .decodingFailed("i"), .decodingFailed(WhisperError.decodingFailed("i").localizedDescription)
      ),
      (
        .microphoneUnavailable("j"),
        .microphoneUnavailable(WhisperError.microphoneUnavailable("j").localizedDescription)
      ),
      (
        .initializationError("k"),
        .initializationError(WhisperError.initializationError("k").localizedDescription)
      ),
    ]
    for (vendorError, expected) in cases {
      #expect(WhisperKitModelLoadSentryError(normalizingLoadError: vendorError) == expected)
    }
  }

  /// A genuinely non-`WhisperError` throw (e.g. a CoreML/filesystem error) normalizes
  /// to `.unknownLoadFailure`, preserving `localizedDescription` exactly — Codex r5
  /// finding: NOT `String(describing:)`, which can produce debug-formatted output.
  @Test(
    "a non-WhisperError throw normalizes to unknownLoadFailure with its exact localizedDescription")
  func nonWhisperErrorNormalizesToUnknownLoadFailure() {
    struct SyntheticNonVendorError: Error, LocalizedError {
      var errorDescription: String? { "a synthetic CoreML-shaped failure" }
    }
    let result = WhisperKitModelLoadSentryError(normalizingLoadError: SyntheticNonVendorError())
    #expect(result == .unknownLoadFailure("a synthetic CoreML-shaped failure"))
  }

  // MARK: - C. Event-construction contract

  @MainActor
  @Test("a WhisperKit load-failure event carries the pinned fingerprint and identity tag")
  func whisperKitLoadFailureEventShape() {
    let error = WhisperKitModelLoadSentryError.initializationError("boom")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "asr", environment: Self.env)

    #expect(
      event.fingerprint
        == ["handled_error", "model_load_failed", "WhisperKit.WhisperError#10", Self.env])
    #expect(event.tags?["error.identity"] == "whisperkit_load.initialization_error")
  }
}
