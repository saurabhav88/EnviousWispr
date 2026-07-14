import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #1525 PR C — `RecoverySpoolReplayer.RecoveryReplayError` and
/// `RecoveryCoordinator.RecoveryArmError`'s Sentry identities are PINNED,
/// mirroring `HeartPathError`'s shipped pattern (#1524) and
/// `ModelLoadWatchdog.WedgeError`'s (#1525 PR B,
/// `ModelLoadWatchdogSentryIdentityTests.swift`).
///
/// The three expected descriptor strings are not re-derived here. All were
/// MEASURED against pre-change shipping code while both types stayed genuinely
/// `private`; widening happened only after the throwaway probe ran. The two
/// `RecoveryReplayError` descriptors were also cross-checked against live
/// Sentry issue titles and per-issue environments (ENVIOUSWISPR-2R/2N
/// production; ENVIOUSWISPR-1Z/2M/20 development). No `RecoveryArmError`
/// issue existed, so its measured descriptor had no live-title cross-check.
/// This suite is the lock — any drift in the shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the
/// bundle identifier, and a test runner's bundle is not production.
@Suite("Recovery errors Sentry stable identity (#1525 PR C)")
struct RecoverySentryIdentityTests {

  private static let env = "production"

  // MARK: - A. Pin lock — RecoveryReplayError

  @Test("RecoveryReplayError keeps the exact production fingerprint per case")
  func replayPinLock() {
    let abandoned: RecoverySpoolReplayer.RecoveryReplayError = .abandonedAfterAttempt
    #expect(SentryBreadcrumb.structuredDescriptor(abandoned) == "RecoveryReplayError#1")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .recoveryAbandonedAfterAttempt, error: abandoned, environment: Self.env)
        == ["handled_error", "recovery_abandoned_after_attempt", "RecoveryReplayError#1", Self.env]
    )

    // `.failed` carries an associated reason string ("decrypt" / "transcribe" /
    // "empty" at the real call sites) that never enters the fingerprint — the
    // category param alone splits these into separate live issues (confirmed:
    // ENVIOUSWISPR-2N/2M on recovery_decrypt_failed, ENVIOUSWISPR-2R/1Z on
    // recovery_transcribe_failed, both sharing descriptor #0).
    for reason in ["decrypt", "transcribe", "empty"] {
      let failed: RecoverySpoolReplayer.RecoveryReplayError = .failed(reason)
      #expect(SentryBreadcrumb.structuredDescriptor(failed) == "RecoveryReplayError#0")
      for category: SentryBreadcrumb.ErrorCategory in [
        .recoveryDecryptFailed, .recoveryTranscribeFailed,
      ] {
        #expect(
          SentryBreadcrumb.handledErrorFingerprint(
            for: category, error: failed, environment: Self.env)
            == ["handled_error", category.rawValue, "RecoveryReplayError#0", Self.env])
      }
    }
  }

  @Test("RecoveryReplayError's two declared identities are unique within the type")
  func replayIdentityIsUniqueWithinType() {
    let errors: [RecoverySpoolReplayer.RecoveryReplayError] = [
      .abandonedAfterAttempt, .failed("decrypt"),
    ]

    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == errors.count)
    #expect(Set(errors.map(\.sentrySemanticID)).count == errors.count)
  }

  // MARK: - B. Pin lock — RecoveryArmError

  @Test("RecoveryArmError keeps the exact measured fingerprint")
  func armPinLock() {
    let error: RecoveryCoordinator.RecoveryArmError = .keyStoreFailed
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "RecoveryArmError#0")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .recoveryKeyStoreFailed, error: error, environment: Self.env)
        == ["handled_error", "recovery_key_store_failed", "RecoveryArmError#0", Self.env])
  }

  @Test("RecoveryArmError's single declared identity is unique within the type")
  func armIdentityIsUniqueWithinType() {
    let errors: [RecoveryCoordinator.RecoveryArmError] = [.keyStoreFailed]

    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == errors.count)
    #expect(Set(errors.map(\.sentrySemanticID)).count == errors.count)
  }

  // MARK: - C. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 10 }
    let sentryFingerprintDescriptor = "fixture.pinned#recovery"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 10)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#recovery")
  }

  // MARK: - D. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error: RecoverySpoolReplayer.RecoveryReplayError = .abandonedAfterAttempt
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: .recoveryAbandonedAfterAttempt, error: error, environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: .recoveryAbandonedAfterAttempt, error: error, environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - E. Event-construction contract

  @MainActor
  @Test("a pinned replay error's event carries the production title, fingerprint and identity tag")
  func pinnedReplayErrorEventShape() {
    let error: RecoverySpoolReplayer.RecoveryReplayError = .abandonedAfterAttempt

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .recoveryAbandonedAfterAttempt, stage: "recovery", environment: Self.env)

    #expect(event.message?.formatted == "recovery_abandoned_after_attempt: RecoveryReplayError#1")
    #expect(
      event.fingerprint
        == ["handled_error", "recovery_abandoned_after_attempt", "RecoveryReplayError#1", Self.env]
    )
    #expect(event.tags?["pipeline.stage"] == "recovery")
    #expect(event.tags?["error.category"] == "recovery_abandoned_after_attempt")
    #expect(event.tags?["error.identity"] == "recovery.replay_abandoned_after_attempt")
  }

  @MainActor
  @Test("a pinned arm error's event carries the production title, fingerprint and identity tag")
  func pinnedArmErrorEventShape() {
    let error: RecoveryCoordinator.RecoveryArmError = .keyStoreFailed

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .recoveryKeyStoreFailed, stage: "recording", environment: Self.env)

    #expect(event.message?.formatted == "recovery_key_store_failed: RecoveryArmError#0")
    #expect(
      event.fingerprint
        == ["handled_error", "recovery_key_store_failed", "RecoveryArmError#0", Self.env])
    #expect(event.tags?["pipeline.stage"] == "recording")
    #expect(event.tags?["error.category"] == "recovery_key_store_failed")
    #expect(event.tags?["error.identity"] == "recovery.arm_key_store_failed")
  }

  @MainActor
  @Test("a non-conforming error's event is unchanged and carries no identity tag")
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .recoveryDecryptFailed, stage: "recovery", environment: Self.env)

    #expect(event.message?.formatted == "recovery_decrypt_failed: EnviousWispr#-3")
    #expect(
      event.fingerprint == [
        "handled_error", "recovery_decrypt_failed", "EnviousWispr#-3", Self.env,
      ]
    )
    #expect(event.tags?["error.identity"] == nil)
  }
}
