import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprFluidAudioBridge
@testable import EnviousWisprServices

/// #1525 PR I-B — `ParakeetTranscriptionSentryError`'s Sentry identity is PINNED,
/// mirroring `KeyStoreError`'s shipped pattern (PR F). No live Sentry history found
/// for a "FluidAudio.ASRError"-identified descriptor in a 90-day search — every
/// case is a defensive pin. `com.apple.CoreML#0` (a genuinely non-FluidAudio error)
/// is confirmed UNAFFECTED by this type (§3.5) — it stays raw, never reaches here.
@Suite("ParakeetTranscriptionSentryError Sentry stable identity (#1525 PR I-B)")
struct ParakeetTranscriptionSentryErrorTests {

  private static let env = "production"
  private static let category = SentryBreadcrumb.ErrorCategory.asrFailed

  private static let pins: [(ParakeetTranscriptionSentryError, String, String)] = [
    (.notInitialized("x"), "FluidAudio.ASRError#0", "parakeet_transcribe.not_initialized"),
    (.invalidAudioData("x"), "FluidAudio.ASRError#1", "parakeet_transcribe.invalid_audio_data"),
    (.modelLoadFailed("x"), "FluidAudio.ASRError#2", "parakeet_transcribe.model_load_failed"),
    (.processingFailed("x"), "FluidAudio.ASRError#3", "parakeet_transcribe.processing_failed"),
    (
      .modelCompilationFailed("x"), "FluidAudio.ASRError#4",
      "parakeet_transcribe.model_compilation_failed"
    ),
    (
      .unsupportedPlatform("x"), "FluidAudio.ASRError#5", "parakeet_transcribe.unsupported_platform"
    ),
    (
      .streamingConversionFailed("x"), "FluidAudio.ASRError#6",
      "parakeet_transcribe.streaming_conversion_failed"
    ),
    (.fileAccessFailed("x"), "FluidAudio.ASRError#7", "parakeet_transcribe.file_access_failed"),
    (
      .unknownTranscriptionFailure("x"),
      "EnviousWisprASR.ParakeetTranscriptionSentryError.unknownTranscriptionFailure",
      "parakeet_transcribe.unknown_transcription_failure"
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

  @Test("all 9 declared identities are unique")
  func identitiesAreUnique() {
    let errors = Self.pins.map(\.0)
    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 9)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 9)
  }

  // MARK: - B. Mapping completeness — built from FluidAudioASRErrorKind

  @Test("init(mapping:) maps every FluidAudioASRErrorKind case, preserving its description")
  func mappingCompleteness() {
    let cases: [(FluidAudioASRErrorKind, ParakeetTranscriptionSentryError)] = [
      (.notInitialized("a"), .notInitialized("a")),
      (.invalidAudioData("b"), .invalidAudioData("b")),
      (.modelLoadFailed("c"), .modelLoadFailed("c")),
      (.processingFailed("d"), .processingFailed("d")),
      (.modelCompilationFailed("e"), .modelCompilationFailed("e")),
      (.unsupportedPlatform("f"), .unsupportedPlatform("f")),
      (.streamingConversionFailed("g"), .streamingConversionFailed("g")),
      (.fileAccessFailed("h"), .fileAccessFailed("h")),
      (.unknownFutureCase("i"), .unknownTranscriptionFailure("i")),
    ]
    for (kind, expected) in cases {
      #expect(ParakeetTranscriptionSentryError(mapping: kind) == expected)
    }
  }

  // MARK: - C. NSError round-trip (survives the XPC boundary)

  @Test("ParakeetTranscriptionSentryError round-trips through its NSError bridge for every case")
  func nsErrorRoundTrip() {
    for (error, _, _) in Self.pins {
      let bridged = error as NSError
      #expect(bridged.domain == ParakeetTranscriptionSentryError.errorDomain)
      guard let reconstructed = ParakeetTranscriptionSentryError(reconstructingFrom: bridged)
      else {
        Issue.record("reconstruction failed for \(error)")
        continue
      }
      #expect(reconstructed == error)
    }
  }

  /// #1525 PR I-B (Codex cloud review): a plain `as NSError` cast is not enough —
  /// Foundation's special "boxed Swift LocalizedError" bridging survives a same-
  /// process cast but NOT an actual XPC-style archive round-trip (confirmed via a
  /// direct `NSKeyedArchiver`/`NSKeyedUnarchiver` probe this session). Only
  /// `errorUserInfo` populating `NSLocalizedDescriptionKey` survives that. This
  /// test proves the fix, not just the same-process cast.
  @Test("localizedDescription survives an actual NSSecureCoding archive round-trip")
  func localizedDescriptionSurvivesArchiveRoundTrip() throws {
    let error = ParakeetTranscriptionSentryError.processingFailed("a real vendor description")
    let bridged = error as NSError
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: bridged, requiringSecureCoding: true)
    let decoded = try #require(
      try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
    #expect(decoded.localizedDescription == "a real vendor description")
  }

  @Test("reconstructingFrom returns nil for an unrelated NSError domain")
  func reconstructionRejectsForeignDomain() {
    let foreign = NSError(domain: "SomeOtherDomain", code: 0)
    #expect(ParakeetTranscriptionSentryError(reconstructingFrom: foreign) == nil)
  }

  // MARK: - D. Event-construction contract

  @MainActor
  @Test("a Parakeet transcription-failure event carries the pinned fingerprint and identity tag")
  func parakeetTranscriptionFailureEventShape() {
    let error = ParakeetTranscriptionSentryError.processingFailed("boom")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "transcription", environment: Self.env)

    #expect(
      event.fingerprint == ["handled_error", "asr_failed", "FluidAudio.ASRError#3", Self.env])
    #expect(event.tags?["error.identity"] == "parakeet_transcribe.processing_failed")
  }
}
