import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #1525 PR E — `LLMError`'s Sentry identity is PINNED, mirroring
/// `HeartPathError`'s shipped pattern (#1524), `ModelLoadWatchdog.WedgeError`'s
/// (PR B), `RecoveryReplayError`/`RecoveryArmError`'s (PR C), and
/// `OutputClassifierError`'s (PR D).
///
/// The 13 descriptors are not re-derived here: they were MEASURED against
/// shipping code (both raw `swift test` and the canonical
/// `scripts/xcode-test.sh` Xcode-engine run agree) and cross-checked against
/// live Sentry issue titles (`docs/audits/2026-07-14-1525-pr-e-preflight.md`).
/// This suite is the lock — any drift in the shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the
/// bundle identifier, and a test runner's bundle is not production.
@Suite("LLMError Sentry stable identity (#1525 PR E)")
struct LLMErrorSentryIdentityTests {

  private static let env = "production"

  /// One representative instance per case, paired with its measured
  /// descriptor number. Associated values are arbitrary — the descriptor is
  /// a function of case identity alone, never the payload.
  private static let allCases: [(LLMError, Int)] = [
    (.requestFailed("x"), 0),
    (.modelNotFound("x"), 1),
    (.frameworkUnavailable("x"), 2),
    (.modelNotReady("x"), 3),
    (.unsupportedInputLanguage("de"), 4),
    (.outputLanguageDrift(expected: "de", actual: "en"), 5),
    (.egOneSkipped(.crashed), 6),
    (.localPolishNotReady(.providerUnreachable), 7),
    (.classified(.apiKeyMissing), 8),
    (.invalidAPIKey, 9),
    (.rateLimited, 10),
    (.emptyResponse, 11),
    (.providerUnavailable, 12),
  ]

  // MARK: - A. Pin lock

  @Test("every case keeps its exact measured production descriptor")
  func pinLock() {
    for (error, ordinal) in Self.allCases {
      #expect(
        SentryBreadcrumb.structuredDescriptor(error) == "EnviousWisprLLM.LLMError#\(ordinal)")
    }
  }

  @Test("all 13 descriptors and semantic IDs are unique")
  func identitiesAreUnique() {
    let errors = Self.allCases.map(\.0)
    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 13)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 13)
  }

  // MARK: - B. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 20 }
    let sentryFingerprintDescriptor = "fixture.pinned#llmerror"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 20)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#llmerror")
  }

  // MARK: - C. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = LLMError.classified(.badRequest)
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: error, detail: "bad_request", environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: error, detail: "bad_request", environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - D. Event-construction contract

  @MainActor
  @Test(
    "a pinned providerUnavailable event carries the production title, fingerprint, and identity tag"
  )
  func providerUnavailableEventShape() {
    let error = LLMError.providerUnavailable
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .providerInitFailed, stage: "polish", environment: Self.env)

    #expect(event.message?.formatted == "provider_init_failed: EnviousWisprLLM.LLMError#12")
    #expect(
      event.fingerprint
        == ["handled_error", "provider_init_failed", "EnviousWisprLLM.LLMError#12", Self.env])
    #expect(event.tags?["pipeline.stage"] == "polish")
    #expect(event.tags?["error.category"] == "provider_init_failed")
    #expect(event.tags?["error.identity"] == "llm.provider_unavailable")
  }

  @MainActor
  @Test("a pinned classified event carries the reason as fingerprintDetail, distinct per reason")
  func classifiedEventShape() {
    let error = LLMError.classified(.badRequest)
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .polishProviderFailed, stage: "polish", fingerprintDetail: "bad_request",
      environment: Self.env)

    #expect(event.message?.formatted == "polish_provider_failed: EnviousWisprLLM.LLMError#8")
    #expect(
      event.fingerprint
        == [
          "handled_error", "polish_provider_failed", "EnviousWisprLLM.LLMError#8", "bad_request",
          Self.env,
        ])
    #expect(event.tags?["error.identity"] == "llm.classified")

    // A different reason on the SAME case shares the descriptor but splits
    // via fingerprintDetail — proves the conformance never collapses #945's
    // per-reason Sentry issue split.
    let otherEvent = SentryBreadcrumb.makeHandledErrorEvent(
      LLMError.classified(.timedOut), category: .polishProviderFailed, stage: "polish",
      fingerprintDetail: "timed_out", environment: Self.env)
    #expect(otherEvent.fingerprint != event.fingerprint)
    #expect(otherEvent.fingerprint?.dropLast(2) == event.fingerprint?.dropLast(2))
  }

  @MainActor
  @Test("a non-conforming error's event is unchanged and carries no identity tag")
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .polishProviderFailed, stage: "polish", environment: Self.env)

    #expect(
      event.fingerprint
        == ["handled_error", "polish_provider_failed", "EnviousWispr#-3", Self.env])
    #expect(event.tags?["error.identity"] == nil)
  }
}
