import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #1144 — Sentry grouping fingerprints. Handled errors group by
/// `[namespace, category, domain#code, environment]` so distinct defects that share
/// a broad category get their own stable, release-independent issue instead of
/// merging under one stacktrace bin (the `ENVIOUSWISPR-8` pollution behind the #440
/// false-reopen churn), AND so dev-machine and real-user occurrences of the same
/// defect stay separate, individually-alerting issues (#1229). The helpers are pure
/// + `nonisolated`, so this suite is not `@MainActor` and calls them directly — no
/// spy/delegate, no actor hop. Tests below pass `environment:` explicitly so
/// assertions stay deterministic regardless of the test bundle's own identifier.
@Suite("Sentry grouping fingerprints (#1144)")
struct SentryFingerprintTests {

  /// Fixed env value for tests that aren't specifically about env separation —
  /// keeps the rest of the fingerprint assertions independent of the test bundle ID.
  private static let testEnv = "production"

  // MARK: - handled-error fingerprint

  @Test("handled-error fingerprint is namespace + category + domain#code + environment")
  func handledErrorShape() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let fp = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, environment: Self.testEnv)
    #expect(fp == ["handled_error", "xpc_service_error", "EnviousWispr#-3", Self.testEnv])
  }

  @Test("distinct categories produce distinct fingerprints")
  func distinctCategoriesSplit() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let paste = SentryBreadcrumb.handledErrorFingerprint(
      for: .pasteFailed, error: err, environment: Self.testEnv)
    let audio = SentryBreadcrumb.handledErrorFingerprint(
      for: .audioCaptureFailed, error: err, environment: Self.testEnv)
    #expect(paste != audio)
  }

  /// The core property: a broad category must NOT merge two distinct root causes.
  /// This is the masking the council reviewers + Codex flagged that category-only
  /// grouping would reintroduce one level down.
  @Test("same category with different underlying errors splits (masking prevention)")
  func sameCategoryDifferentErrorSplits() {
    let asrCrash = NSError(domain: "EnviousWispr", code: -3)
    let replyFail = NSError(domain: "HeartPathError", code: 6)
    let fpA = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: asrCrash, environment: Self.testEnv)
    let fpB = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: replyFail, environment: Self.testEnv)
    #expect(fpA != fpB)
    #expect(fpA == ["handled_error", "xpc_service_error", "EnviousWispr#-3", Self.testEnv])
    #expect(fpB == ["handled_error", "xpc_service_error", "HeartPathError#6", Self.testEnv])
  }

  @Test("same category and same error is stable across calls")
  func stableForSameInputs() {
    let err = NSError(domain: "EnviousWispr", code: -10)
    let first = SentryBreadcrumb.handledErrorFingerprint(
      for: .modelLoadFailed, error: err, environment: Self.testEnv)
    let second = SentryBreadcrumb.handledErrorFingerprint(
      for: .modelLoadFailed, error: err, environment: Self.testEnv)
    #expect(first == second)
  }

  @Test("fingerprint signature excludes localizedDescription / user content")
  func signatureIsContentFree() {
    let secret = "PURPLE ELEPHANT SEVENTEEN"
    let err = NSError(
      domain: "AVFoundationErrorDomain", code: -11800,
      userInfo: [NSLocalizedDescriptionKey: secret])
    let fp = SentryBreadcrumb.handledErrorFingerprint(
      for: .audioCaptureFailed, error: err, environment: Self.testEnv)
    #expect(
      fp == [
        "handled_error", "audio_capture_failed", "AVFoundationErrorDomain#-11800", Self.testEnv,
      ]
    )
    #expect(fp.contains { $0.contains(secret) } == false)
  }

  // MARK: - environment separation (#1229)

  /// The property PR-B exists to guarantee: stabilizing `structuredDescriptor`
  /// (killing the per-launch pointer) must not merge dev and prod into one issue —
  /// that would suppress the first real-user alert, since the triage worker only
  /// fires on "issue created".
  @Test("dev and prod fingerprints for the same error differ only in the trailing environment")
  func devAndProdSplit() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, environment: "development")
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, environment: "production")
    #expect(dev != prod)
    #expect(dev.dropLast() == prod.dropLast())
    #expect(dev.last == "development")
    #expect(prod.last == "production")
  }

  @Test("same environment across two calls is byte-identical")
  func sameEnvironmentIsStable() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let first = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, environment: "development")
    let second = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, environment: "development")
    #expect(first == second)
  }

  // MARK: - detail discriminator (#945)

  @Test("optional detail appends an extra fingerprint component before the trailing environment")
  func detailAppends() {
    let err = NSError(domain: "EnviousWisprLLM.LLMError", code: 10)
    let fp = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: err, detail: "out_of_credits", environment: Self.testEnv)
    #expect(
      fp == [
        "handled_error", "polish_provider_failed", "EnviousWisprLLM.LLMError#10", "out_of_credits",
        Self.testEnv,
      ]
    )
  }

  /// The #945 property: `LLMError.classified` bridges every reason to ONE NSError
  /// code, so without the detail these would merge into one issue. The detail
  /// must split them.
  @Test("same category + same domain#code but different detail splits the issue")
  func detailSplitsSharedCode() {
    let err = NSError(domain: "EnviousWisprLLM.LLMError", code: 10)
    let credits = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: err, detail: "out_of_credits", environment: Self.testEnv)
    let rate = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: err, detail: "rate_limited", environment: Self.testEnv)
    #expect(credits != rate)
  }

  @Test("nil detail leaves the base fingerprint unchanged")
  func nilDetailIsBackwardCompatible() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let withNil = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, detail: nil, environment: Self.testEnv)
    let legacy = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: err, environment: Self.testEnv)
    #expect(withNil == legacy)
    #expect(withNil == ["handled_error", "xpc_service_error", "EnviousWispr#-3", Self.testEnv])
  }

  // MARK: - AI-failure fingerprint

  @Test("AI-failure fingerprint is namespace + sorted reason rawValues")
  func aiFailureSorted() {
    let reasons: [AIFailureReason] = [.unsupportedOS, .modelNotReady]
    let fp = SentryBreadcrumb.aiFailureFingerprint(for: reasons)
    #expect(fp == ["ai_failure", "modelNotReady", "unsupportedOS"])
  }

  @Test("AI-failure fingerprint is order-independent")
  func aiFailureOrderIndependent() {
    let a = SentryBreadcrumb.aiFailureFingerprint(for: [.unsupportedOS, .modelNotReady])
    let b = SentryBreadcrumb.aiFailureFingerprint(for: [.modelNotReady, .unsupportedOS])
    #expect(a == b)
  }

  @Test("AI-failure fingerprint falls back to bare namespace when empty")
  func aiFailureEmpty() {
    let fp = SentryBreadcrumb.aiFailureFingerprint(for: [])
    #expect(fp == ["ai_failure"])
  }

  // MARK: - redaction passthrough

  @Test("sanitizeSentryEvent preserves a set fingerprint unchanged")
  func sanitizePreservesFingerprint() {
    let event = Event(level: .error)
    let fingerprint = ["handled_error", "paste_failed", "HeartPathError#2"]
    event.fingerprint = fingerprint
    let sanitized = ObservabilityBootstrap.sanitizeSentryEvent(event)
    #expect(sanitized.fingerprint == fingerprint)
  }
}
