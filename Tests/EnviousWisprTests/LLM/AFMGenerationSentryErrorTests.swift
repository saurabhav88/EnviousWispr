import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprServices

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// #1525 PR I-B — `AFMGenerationSentryError`'s Sentry identity is PINNED, mirroring
/// `KeyStoreError`'s shipped pattern (PR F). `.unsupportedLanguageOrLocale`'s
/// descriptor is measured LIVE (ENVIOUSWISPR-2J, §3.5) — MUST NOT change. The
/// other 7 real cases + `.unknownFutureCase` are defensive pins (no confirmed
/// production trigger in a 90-day search).
@Suite("AFMGenerationSentryError Sentry stable identity (#1525 PR I-B)")
struct AFMGenerationSentryErrorTests {

  private static let env = "production"
  private static let category = SentryBreadcrumb.ErrorCategory.generationFailed

  private static let pins: [(AFMGenerationSentryError, String, String)] = [
    (
      .assetsUnavailable("x"), "FoundationModels.LanguageModelSession.GenerationError#1",
      "afm.assets_unavailable"
    ),
    (
      .guardrailViolation("x"), "FoundationModels.LanguageModelSession.GenerationError#2",
      "afm.guardrail_violation"
    ),
    (
      .unsupportedGuide("x"), "FoundationModels.LanguageModelSession.GenerationError#3",
      "afm.unsupported_guide"
    ),
    (
      .unsupportedLanguageOrLocale("x"), "FoundationModels.LanguageModelSession.GenerationError#4",
      "afm.unsupported_language_or_locale"
    ),
    (
      .decodingFailure("x"), "FoundationModels.LanguageModelSession.GenerationError#5",
      "afm.decoding_failure"
    ),
    (
      .rateLimited("x"), "FoundationModels.LanguageModelSession.GenerationError#6",
      "afm.rate_limited"
    ),
    (
      .concurrentRequests("x"), "FoundationModels.LanguageModelSession.GenerationError#7",
      "afm.concurrent_requests"
    ),
    (.refusal("x"), "FoundationModels.LanguageModelSession.GenerationError#8", "afm.refusal"),
    (
      .unknownFutureCase("x"), "EnviousWisprLLM.AFMGenerationSentryError.unknownFutureCase",
      "afm.unknown_future_case"
    ),
  ]

  // MARK: - A. Pin lock

  @Test("every case keeps its exact measured/pinned fingerprint")
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

  // MARK: - B. Description preservation

  @Test("errorDescription preserves the original error's description, never the fingerprint")
  func errorDescriptionPreservesOriginalText() {
    let error = AFMGenerationSentryError.unsupportedLanguageOrLocale(
      "The requested language is not supported.")
    #expect(error.errorDescription == "The requested language is not supported.")
  }

  #if canImport(FoundationModels)
    // MARK: - C. Mapping completeness (macOS 26+ only — needs the real vendor type)

    @available(macOS 26.0, *)
    @Test(
      "every real GenerationError case maps to its expected AFMGenerationSentryError case, preserving the description"
    )
    func mappingCompleteness() {
      // GenerationError's errorDescription returns Apple's OWN fixed per-case
      // message, NOT the Context's debugDescription — so the expected value is
      // derived from each constructed vendor error's own localizedDescription,
      // not a shared constant.
      let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "unused")
      let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
      let vendorErrors: [LanguageModelSession.GenerationError] = [
        .assetsUnavailable(ctx),
        .guardrailViolation(ctx),
        .unsupportedGuide(ctx),
        .unsupportedLanguageOrLocale(ctx),
        .decodingFailure(ctx),
        .rateLimited(ctx),
        .concurrentRequests(ctx),
        .refusal(refusal, ctx),
      ]
      let expectedMappers: [(String) -> AFMGenerationSentryError] = [
        { .assetsUnavailable($0) },
        { .guardrailViolation($0) },
        { .unsupportedGuide($0) },
        { .unsupportedLanguageOrLocale($0) },
        { .decodingFailure($0) },
        { .rateLimited($0) },
        { .concurrentRequests($0) },
        { .refusal($0) },
      ]
      for (vendor, makeExpected) in zip(vendorErrors, expectedMappers) {
        let expected = makeExpected(vendor.localizedDescription)
        #expect(AFMGenerationSentryError(mapping: vendor) == expected)
      }
    }

    @available(macOS 26.0, *)
    @Test("exceededContextWindowSize maps to unknownFutureCase (unreachable in practice)")
    func exceededContextWindowSizeMapsToUnknownFutureCase() {
      let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "x")
      let mapped = AFMGenerationSentryError(mapping: .exceededContextWindowSize(ctx))
      if case .unknownFutureCase = mapped {
        // expected
      } else {
        Issue.record("expected .unknownFutureCase, got \(mapped)")
      }
    }
  #endif

  // MARK: - D. Event-construction contract (the confirmed-live case)

  @MainActor
  @Test(
    "the confirmed-live .unsupportedLanguageOrLocale case's event carries the production fingerprint and identity tag"
  )
  func unsupportedLanguageOrLocaleEventShape() {
    let error = AFMGenerationSentryError.unsupportedLanguageOrLocale("x")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "polish", environment: Self.env)

    #expect(
      event.fingerprint
        == [
          "handled_error", "generation_failed",
          "FoundationModels.LanguageModelSession.GenerationError#4", Self.env,
        ])
    #expect(event.tags?["error.identity"] == "afm.unsupported_language_or_locale")
  }

  @Test(
    "a non-conforming error's descriptor and fingerprint are unchanged (#1525 PR J-1: makeHandledErrorEvent narrowed — structuredDescriptor/handledErrorFingerprint stay generic)"
  )
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    #expect(SentryBreadcrumb.structuredDescriptor(error) == "EnviousWispr#-3")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: Self.category, error: error, environment: Self.env)
        == ["handled_error", "generation_failed", "EnviousWispr#-3", Self.env])
  }
}
