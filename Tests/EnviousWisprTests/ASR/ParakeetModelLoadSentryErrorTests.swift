import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprFluidAudioBridge
@testable import EnviousWisprServices

/// #1525 PR I-B — `ParakeetModelLoadSentryError`'s Sentry identity is PINNED,
/// mirroring `KeyStoreError`'s shipped pattern (PR F). No live Sentry measurement
/// has been run against these case-level descriptors (§3.5's "remaining work") —
/// every case is a fresh, defensive pin.
@Suite("ParakeetModelLoadSentryError Sentry stable identity (#1525 PR I-B)")
struct ParakeetModelLoadSentryErrorTests {

  private static let env = "production"
  private static let category = SentryBreadcrumb.ErrorCategory.modelLoadFailed

  private static let pins: [(ParakeetModelLoadSentryError, String, String)] = [
    (
      .modelsModelNotFound("x"), "FluidAudio.AsrModelsError#0",
      "parakeet_load.models_model_not_found"
    ),
    (
      .modelsDownloadFailed("x"), "FluidAudio.AsrModelsError#1",
      "parakeet_load.models_download_failed"
    ),
    (
      .modelsLoadingFailed("x"), "FluidAudio.AsrModelsError#2",
      "parakeet_load.models_loading_failed"
    ),
    (
      .modelsCompilationFailed("x"), "FluidAudio.AsrModelsError#3",
      "parakeet_load.models_compilation_failed"
    ),
    (
      .offlineNetworkDisabled("x"), "FluidAudio.DownloadUtils.OfflineError#0",
      "parakeet_load.offline_network_disabled"
    ),
    (
      .offlineModelMissing("x"), "FluidAudio.DownloadUtils.OfflineError#1",
      "parakeet_load.offline_model_missing"
    ),
    (
      .hfInvalidResponse("x"), "FluidAudio.DownloadUtils.HuggingFaceDownloadError#0",
      "parakeet_load.hf_invalid_response"
    ),
    (
      .hfRateLimited("x"), "FluidAudio.DownloadUtils.HuggingFaceDownloadError#1",
      "parakeet_load.hf_rate_limited"
    ),
    (
      .hfDownloadFailed("x"), "FluidAudio.DownloadUtils.HuggingFaceDownloadError#2",
      "parakeet_load.hf_download_failed"
    ),
    (
      .hfModelNotFound("x"), "FluidAudio.DownloadUtils.HuggingFaceDownloadError#3",
      "parakeet_load.hf_model_not_found"
    ),
    (
      .hfHtmlErrorResponse("x"), "FluidAudio.DownloadUtils.HuggingFaceDownloadError#4",
      "parakeet_load.hf_html_error_response"
    ),
    (
      .unknownLoadFailure("x"), "EnviousWisprASR.ParakeetModelLoadSentryError.unknownLoadFailure",
      "parakeet_load.unknown_load_failure"
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

  // MARK: - B. Mapping completeness — built from FluidAudioModelLoadErrorKind

  @Test(
    "init(mapping:) maps every FluidAudioModelLoadErrorKind case, preserving its description"
  )
  func mappingCompleteness() {
    let cases: [(FluidAudioModelLoadErrorKind, ParakeetModelLoadSentryError)] = [
      (.modelsModelNotFound("a"), .modelsModelNotFound("a")),
      (.modelsDownloadFailed("b"), .modelsDownloadFailed("b")),
      (.modelsLoadingFailed("c"), .modelsLoadingFailed("c")),
      (.modelsCompilationFailed("d"), .modelsCompilationFailed("d")),
      (.offlineNetworkDisabled("e"), .offlineNetworkDisabled("e")),
      (.offlineModelMissing("f"), .offlineModelMissing("f")),
      (.hfInvalidResponse("g"), .hfInvalidResponse("g")),
      (.hfRateLimited("h"), .hfRateLimited("h")),
      (.hfDownloadFailed("i"), .hfDownloadFailed("i")),
      (.hfModelNotFound("j"), .hfModelNotFound("j")),
      (.hfHtmlErrorResponse("k"), .hfHtmlErrorResponse("k")),
      (.unknownLoadFailure("l"), .unknownLoadFailure("l")),
    ]
    for (kind, expected) in cases {
      #expect(ParakeetModelLoadSentryError(mapping: kind) == expected)
    }
  }

  // MARK: - C. Mapping completeness — the real production normalizer

  @Test(
    "init(normalizingLoadError:) recognizes a real FluidAudio model-load vendor error"
  )
  func normalizingLoadErrorRecognizesVendorError() {
    // classifyFluidAudioModelLoadError only recognizes AsrModelsError/OfflineError/
    // HuggingFaceDownloadError — a genuinely non-vendor error normalizes to
    // .unknownLoadFailure, tested below.
    struct SyntheticNonVendorError: Error, LocalizedError {
      var errorDescription: String? { "a synthetic CoreML-shaped model-load failure" }
    }
    let result = ParakeetModelLoadSentryError(normalizingLoadError: SyntheticNonVendorError())
    #expect(result == .unknownLoadFailure("a synthetic CoreML-shaped model-load failure"))
  }

  // MARK: - D. NSError round-trip (survives the XPC boundary)

  @Test("ParakeetModelLoadSentryError round-trips through its NSError bridge for every case")
  func nsErrorRoundTrip() {
    for (error, _, _) in Self.pins {
      let bridged = error as NSError
      #expect(bridged.domain == ParakeetModelLoadSentryError.errorDomain)
      guard let reconstructed = ParakeetModelLoadSentryError(reconstructingFrom: bridged) else {
        Issue.record("reconstruction failed for \(error)")
        continue
      }
      #expect(reconstructed == error)
    }
  }

  @Test("reconstructingFrom returns nil for an unrelated NSError domain")
  func reconstructionRejectsForeignDomain() {
    let foreign = NSError(domain: "SomeOtherDomain", code: 0)
    #expect(ParakeetModelLoadSentryError(reconstructingFrom: foreign) == nil)
  }

  /// #1525 PR I-B (Codex cloud review): a plain `as NSError` cast is not enough —
  /// Foundation's special "boxed Swift LocalizedError" bridging survives a same-
  /// process cast but NOT an actual XPC-style archive round-trip (confirmed via a
  /// direct `NSKeyedArchiver`/`NSKeyedUnarchiver` probe this session). Only
  /// `errorUserInfo` populating `NSLocalizedDescriptionKey` survives that.
  @Test("localizedDescription survives an actual NSSecureCoding archive round-trip")
  func localizedDescriptionSurvivesArchiveRoundTrip() throws {
    let error = ParakeetModelLoadSentryError.hfRateLimited("a real vendor description")
    let bridged = error as NSError
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: bridged, requiringSecureCoding: true)
    let decoded = try #require(
      try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
    #expect(decoded.localizedDescription == "a real vendor description")
  }

  // MARK: - E. Event-construction contract

  @MainActor
  @Test("a Parakeet model-load-failure event carries the pinned fingerprint and identity tag")
  func parakeetModelLoadFailureEventShape() {
    let error = ParakeetModelLoadSentryError.hfRateLimited("boom")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "asr", environment: Self.env)

    #expect(
      event.fingerprint
        == [
          "handled_error", "model_load_failed",
          "FluidAudio.DownloadUtils.HuggingFaceDownloadError#1", Self.env,
        ])
    #expect(event.tags?["error.identity"] == "parakeet_load.hf_rate_limited")
  }
}
