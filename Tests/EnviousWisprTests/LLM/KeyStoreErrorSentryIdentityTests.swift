import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #1525 PR F — `KeyStoreError`'s Sentry identity is PINNED, mirroring
/// `HeartPathError`'s shipped pattern (#1524) and `OutputClassifierError`'s /
/// `LLMError`'s (PRs D/E). 5 cases exist today; only `.deleteFailed` is
/// proven to reach Sentry (legacy-key-cleanup path), but the conformance is
/// exhaustive across all 5 so a future capture site inherits a stable
/// identity instead of an ordinal that can silently shift.
///
/// The expected strings are not re-derived here: they were MEASURED against
/// shipping code and cross-checked against a fresh 90-day Sentry pull that
/// found no matching issue (`docs/audits/2026-07-14-1525-pr-f-preflight.md`).
/// This suite is the lock — any drift in the shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the
/// bundle identifier, and a test runner's bundle is not production.
@Suite("KeyStoreError Sentry stable identity (#1525 PR F)")
struct KeyStoreErrorSentryIdentityTests {

  private static let env = "production"
  private static let category = SentryBreadcrumb.ErrorCategory.legacyKeyCleanupFailed

  private static let pins: [(KeyStoreError, String, String)] = [
    (.storeFailed(-1), "EnviousWisprLLM.KeyStoreError#0", "keystore.store_failed"),
    (.retrieveFailed(-1), "EnviousWisprLLM.KeyStoreError#1", "keystore.retrieve_failed"),
    (.deleteFailed(-1), "EnviousWisprLLM.KeyStoreError#2", "keystore.delete_failed"),
    (.unsupportedKey("x"), "EnviousWisprLLM.KeyStoreError#3", "keystore.unsupported_key"),
    (
      .rollbackFailed(
        cleanup: NSError(domain: "fixture.cleanup", code: 1),
        rollback: NSError(domain: "fixture.rollback", code: 2)),
      "EnviousWisprLLM.KeyStoreError#4", "keystore.rollback_failed"
    ),
  ]

  // MARK: - A. Pin lock

  @Test("every case keeps its exact measured production fingerprint")
  func pinLock() {
    for (error, descriptor, semanticID) in Self.pins {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(error.sentrySemanticID == semanticID)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(
          for: Self.category, error: error, detail: "openai-api-key", environment: Self.env)
          == ["handled_error", Self.category.rawValue, descriptor, "openai-api-key", Self.env]
      )
    }
  }

  @Test("all 5 declared identities are unique within KeyStoreError")
  func identitiesAreUnique() {
    let errors = Self.pins.map(\.0)

    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 5)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 5)
  }

  // MARK: - B. The property that matters

  // MARK: - C. Dev/prod split survives the pin

  // MARK: - D. Event-construction contract

  @MainActor
  @Test(
    "the confirmed-live .deleteFailed case's event carries the production title, fingerprint and identity tag"
  )
  func deleteFailedEventShape() {
    let error = KeyStoreError.deleteFailed(-1)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "keychain", fingerprintDetail: "openai-api-key",
      environment: Self.env)

    #expect(
      event.message?.formatted == "legacy_key_cleanup_failed: EnviousWisprLLM.KeyStoreError#2")
    #expect(
      event.fingerprint
        == [
          "handled_error", "legacy_key_cleanup_failed", "EnviousWisprLLM.KeyStoreError#2",
          "openai-api-key", Self.env,
        ])
    #expect(event.tags?["pipeline.stage"] == "keychain")
    #expect(event.tags?["error.category"] == "legacy_key_cleanup_failed")
    #expect(event.tags?["error.identity"] == "keystore.delete_failed")
  }

}
