import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #1144 — Sentry grouping fingerprints. Handled errors group by
/// `[namespace, category, domain#code]` so distinct defects that share a broad
/// category get their own stable, release-independent issue instead of merging
/// under one stacktrace bin (the `ENVIOUSWISPR-8` pollution behind the #440
/// false-reopen churn). The helpers are pure + `nonisolated`, so this suite is
/// not `@MainActor` and calls them directly — no spy/delegate, no actor hop.
@Suite("Sentry grouping fingerprints (#1144)")
struct SentryFingerprintTests {

  // MARK: - handled-error fingerprint

  @Test("handled-error fingerprint is namespace + category + domain#code")
  func handledErrorShape() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let fp = SentryBreadcrumb.handledErrorFingerprint(for: .xpcServiceError, error: err)
    #expect(fp == ["handled_error", "xpc_service_error", "EnviousWispr#-3"])
  }

  @Test("distinct categories produce distinct fingerprints")
  func distinctCategoriesSplit() {
    let err = NSError(domain: "EnviousWispr", code: -3)
    let paste = SentryBreadcrumb.handledErrorFingerprint(for: .pasteFailed, error: err)
    let audio = SentryBreadcrumb.handledErrorFingerprint(for: .audioCaptureFailed, error: err)
    #expect(paste != audio)
  }

  /// The core property: a broad category must NOT merge two distinct root causes.
  /// This is the masking the council reviewers + Codex flagged that category-only
  /// grouping would reintroduce one level down.
  @Test("same category with different underlying errors splits (masking prevention)")
  func sameCategoryDifferentErrorSplits() {
    let asrCrash = NSError(domain: "EnviousWispr", code: -3)
    let replyFail = NSError(domain: "HeartPathError", code: 6)
    let fpA = SentryBreadcrumb.handledErrorFingerprint(for: .xpcServiceError, error: asrCrash)
    let fpB = SentryBreadcrumb.handledErrorFingerprint(for: .xpcServiceError, error: replyFail)
    #expect(fpA != fpB)
    #expect(fpA == ["handled_error", "xpc_service_error", "EnviousWispr#-3"])
    #expect(fpB == ["handled_error", "xpc_service_error", "HeartPathError#6"])
  }

  @Test("same category and same error is stable across calls")
  func stableForSameInputs() {
    let err = NSError(domain: "EnviousWispr", code: -10)
    let first = SentryBreadcrumb.handledErrorFingerprint(for: .modelLoadFailed, error: err)
    let second = SentryBreadcrumb.handledErrorFingerprint(for: .modelLoadFailed, error: err)
    #expect(first == second)
  }

  @Test("fingerprint signature excludes localizedDescription / user content")
  func signatureIsContentFree() {
    let secret = "PURPLE ELEPHANT SEVENTEEN"
    let err = NSError(
      domain: "AVFoundationErrorDomain", code: -11800,
      userInfo: [NSLocalizedDescriptionKey: secret])
    let fp = SentryBreadcrumb.handledErrorFingerprint(for: .audioCaptureFailed, error: err)
    #expect(fp == ["handled_error", "audio_capture_failed", "AVFoundationErrorDomain#-11800"])
    #expect(fp.contains { $0.contains(secret) } == false)
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
