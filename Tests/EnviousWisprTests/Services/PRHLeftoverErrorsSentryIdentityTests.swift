import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #1525 PR H — the four remaining single-shape app-owned leftovers
/// (`TimeoutError`, `HotkeyRegistrationError`, `NilCollaboratorError`,
/// `EmojiRestoreAnomaly`) have PINNED Sentry identities, mirroring
/// `HeartPathError`'s shipped pattern (#1524) and closing out §3a of
/// `docs/sentry-identity-refactor/BIBLE.md`.
///
/// The four expected descriptor strings are not re-derived here. All were
/// MEASURED against pre-change shipping code — `NilCollaboratorError` and
/// `EmojiRestoreAnomaly` while both stayed genuinely `private`; widening
/// happened only after the throwaway probe ran (same order as PR C's
/// `RecoveryReplayError`/`RecoveryArmError`). `TimeoutError`'s descriptor was
/// cross-checked against its live production issue title (ENVIOUSWISPR-32,
/// `polish_provider_failed: EnviousWisprCore.TimeoutError#1`). Fresh 90-day
/// Sentry searches found no matching issue for the other three. This suite is
/// the lock — any drift in the shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the
/// bundle identifier, and a test runner's bundle is not production.
@Suite("PR H leftover errors Sentry stable identity (#1525 PR H)")
struct PRHLeftoverErrorsSentryIdentityTests {

  private static let env = "production"

  // MARK: - A. Pin lock

  @Test("TimeoutError keeps the exact production fingerprint at both live capture sites")
  func timeoutErrorPinLock() {
    let error = TimeoutError(seconds: 5)
    let descriptor = "EnviousWisprCore.TimeoutError#1"
    #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)

    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .inverseNormalizationTimeout, error: error, environment: Self.env)
        == ["handled_error", "inverse_normalization_timeout", descriptor, Self.env])

    // The polish path routes through `PolishFailureReason.from(error)` (a
    // `TimeoutError` classifies to `.timedOut`), and `TextProcessingRunner`
    // passes its `telemetryTag` ("timed_out") as `fingerprintDetail` — Codex
    // grounded review r1 caught the first draft omitting this real detail
    // component (`TextProcessingRunner.swift:354`, `PolishFailureReason.swift:344,128`).
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .polishProviderFailed, error: error, detail: "timed_out", environment: Self.env)
        == ["handled_error", "polish_provider_failed", descriptor, "timed_out", Self.env])
  }

  @Test("HotkeyRegistrationError keeps the exact production fingerprint")
  func hotkeyRegistrationErrorPinLock() {
    let error = HotkeyRegistrationError(mechanism: "carbon", hotkeyKind: "toggle", osStatus: -50)
    #expect(
      SentryBreadcrumb.structuredDescriptor(error)
        == "EnviousWisprServices.HotkeyRegistrationError#1"
    )
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .hotkeyRegistrationFailed, error: error, detail: "carbon/toggle", environment: Self.env
      )
        == [
          "handled_error", "hotkey_registration_failed",
          "EnviousWisprServices.HotkeyRegistrationError#1", "carbon/toggle", Self.env,
        ])
  }

  @Test("NilCollaboratorError keeps the exact measured fingerprint")
  func nilCollaboratorErrorPinLock() {
    let error = HotkeyController.NilCollaboratorError(callback: "onToggleRecording")
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "NilCollaboratorError#1")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .pipelineDispatchFailed, error: error, environment: Self.env)
        == ["handled_error", "pipeline_dispatch_failed", "NilCollaboratorError#1", Self.env])
  }

  @Test("EmojiRestoreAnomaly keeps the exact measured fingerprint")
  func emojiRestoreAnomalyPinLock() {
    let error = EmojiRestoreAnomaly.underRestore
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "EmojiRestoreAnomaly#0")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .emojiRestoreIncomplete, error: error, environment: Self.env)
        == ["handled_error", "emoji_restore_incomplete", "EmojiRestoreAnomaly#0", Self.env])
  }

  @Test("all four declared identities are unique across the batch")
  func identitiesAreUniqueAcrossBatch() {
    let descriptors = [
      TimeoutError(seconds: 1).sentryFingerprintDescriptor,
      HotkeyRegistrationError(mechanism: "carbon", hotkeyKind: "toggle", osStatus: nil)
        .sentryFingerprintDescriptor,
      HotkeyController.NilCollaboratorError(callback: "x").sentryFingerprintDescriptor,
      EmojiRestoreAnomaly.underRestore.sentryFingerprintDescriptor,
    ]
    let semanticIDs = [
      TimeoutError(seconds: 1).sentrySemanticID,
      HotkeyRegistrationError(mechanism: "carbon", hotkeyKind: "toggle", osStatus: nil)
        .sentrySemanticID,
      HotkeyController.NilCollaboratorError(callback: "x").sentrySemanticID,
      EmojiRestoreAnomaly.underRestore.sentrySemanticID,
    ]
    #expect(Set(descriptors).count == descriptors.count)
    #expect(Set(semanticIDs).count == semanticIDs.count)
  }

  // MARK: - B. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 30 }
    let sentryFingerprintDescriptor = "fixture.pinned#prh"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 30)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#prh")
  }

  // MARK: - C. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = TimeoutError(seconds: 5)
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: error, environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: .polishProviderFailed, error: error, environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - D. Event-construction contract

  @MainActor
  @Test("TimeoutError's event carries the production title, fingerprint and identity tag")
  func timeoutErrorEventShape() {
    let error = TimeoutError(seconds: 5)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .polishProviderFailed, stage: "polish", fingerprintDetail: "timed_out",
      environment: Self.env)

    #expect(
      event.message?.formatted == "polish_provider_failed: EnviousWisprCore.TimeoutError#1")
    #expect(
      event.fingerprint
        == [
          "handled_error", "polish_provider_failed", "EnviousWisprCore.TimeoutError#1",
          "timed_out", Self.env,
        ])
    #expect(event.tags?["pipeline.stage"] == "polish")
    #expect(event.tags?["error.category"] == "polish_provider_failed")
    #expect(event.tags?["error.identity"] == "core.timeout")
  }

  @MainActor
  @Test(
    "HotkeyRegistrationError's event carries the production title, fingerprint and identity tag")
  func hotkeyRegistrationErrorEventShape() {
    let error = HotkeyRegistrationError(mechanism: "carbon", hotkeyKind: "toggle", osStatus: -50)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .hotkeyRegistrationFailed, stage: "input",
      fingerprintDetail: "carbon/toggle",
      environment: Self.env)

    #expect(
      event.message?.formatted
        == "hotkey_registration_failed: EnviousWisprServices.HotkeyRegistrationError#1")
    #expect(
      event.fingerprint
        == [
          "handled_error", "hotkey_registration_failed",
          "EnviousWisprServices.HotkeyRegistrationError#1", "carbon/toggle", Self.env,
        ])
    #expect(event.tags?["pipeline.stage"] == "input")
    #expect(event.tags?["error.category"] == "hotkey_registration_failed")
    #expect(event.tags?["error.identity"] == "hotkey.registration_failed")
  }

  @MainActor
  @Test("NilCollaboratorError's event carries the production title, fingerprint and identity tag")
  func nilCollaboratorErrorEventShape() {
    let error = HotkeyController.NilCollaboratorError(callback: "onToggleRecording")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .pipelineDispatchFailed, stage: "recording", environment: Self.env)

    #expect(event.message?.formatted == "pipeline_dispatch_failed: NilCollaboratorError#1")
    #expect(
      event.fingerprint
        == ["handled_error", "pipeline_dispatch_failed", "NilCollaboratorError#1", Self.env])
    #expect(event.tags?["pipeline.stage"] == "recording")
    #expect(event.tags?["error.category"] == "pipeline_dispatch_failed")
    #expect(event.tags?["error.identity"] == "hotkey.nil_collaborator")
  }

  @MainActor
  @Test("EmojiRestoreAnomaly's event carries the production title, fingerprint and identity tag")
  func emojiRestoreAnomalyEventShape() {
    let error = EmojiRestoreAnomaly.underRestore

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .emojiRestoreIncomplete, stage: "emoji_restore", environment: Self.env)

    #expect(event.message?.formatted == "emoji_restore_incomplete: EmojiRestoreAnomaly#0")
    #expect(
      event.fingerprint
        == ["handled_error", "emoji_restore_incomplete", "EmojiRestoreAnomaly#0", Self.env])
    #expect(event.tags?["pipeline.stage"] == "emoji_restore")
    #expect(event.tags?["error.category"] == "emoji_restore_incomplete")
    #expect(event.tags?["error.identity"] == "emoji.restore_under_restore")
  }

  @MainActor
  @Test("a non-conforming error's event is unchanged and carries no identity tag")
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .pipelineDispatchFailed, stage: "recording", environment: Self.env)

    #expect(event.message?.formatted == "pipeline_dispatch_failed: EnviousWispr#-3")
    #expect(
      event.fingerprint == [
        "handled_error", "pipeline_dispatch_failed", "EnviousWispr#-3", Self.env,
      ]
    )
    #expect(event.tags?["error.identity"] == nil)
  }
}
