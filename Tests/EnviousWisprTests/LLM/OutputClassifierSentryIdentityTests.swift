import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #1525 PR D — `OutputClassifierError`'s Sentry identity is PINNED, mirroring
/// `HeartPathError`'s shipped pattern (#1524) and `ModelLoadWatchdog.WedgeError`'s
/// (PR B). One case exists today (`.disabled(reason)`), so there is no
/// ordinal-reorder risk yet — this pin closes the latent risk before a second
/// case is ever added.
///
/// The expected string is not re-derived here: it was MEASURED against
/// shipping code and cross-checked against the 3 live Sentry issue titles
/// (`docs/audits/2026-07-14-1525-pr-d-preflight.md`). This suite is the lock —
/// any drift in the shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the
/// bundle identifier, and a test runner's bundle is not production.
@Suite("OutputClassifierError Sentry stable identity (#1525 PR D)")
struct OutputClassifierSentryIdentityTests {

  private static let env = "production"
  private static let descriptor = "EnviousWisprLLM.OutputClassifierError#0"
  private static let semanticID = "outputclassifier.disabled"
  private static let category = SentryBreadcrumb.ErrorCategory.outputClassifierLoadFailed

  /// The 8 disablement reasons the type's associated value can carry. All
  /// must measure to the SAME descriptor (§2.5 premise 1) — only
  /// `fingerprintDetail` (the reason's raw value) differentiates them.
  private static let allReasons: [OutputClassifierDisabledReason] = [
    .contractHashMismatch, .missingFile, .unsupportedFamily, .fixtureSelfTestFailed,
    .shapeMismatch, .inferenceError, .tokenizerLoadFailed, .modelLoadFailed,
  ]

  // MARK: - A. Pin lock

  @Test("every disablement reason keeps the exact production fingerprint")
  func pinLock() {
    for reason in Self.allReasons {
      let error = OutputClassifierError.disabled(reason)
      #expect(SentryBreadcrumb.structuredDescriptor(error) == Self.descriptor)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(
          for: Self.category, error: error, detail: reason.rawValue, environment: Self.env)
          == ["handled_error", Self.category.rawValue, Self.descriptor, reason.rawValue, Self.env]
      )
    }
  }

  @Test("the single declared identity is unique within OutputClassifierError")
  func identityIsUniqueWithinType() {
    let errors = Self.allReasons.map(OutputClassifierError.disabled)

    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 1)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 1)
  }

  // MARK: - B. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 20 }
    let sentryFingerprintDescriptor = "fixture.pinned#outputclassifier"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 20)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#outputclassifier")
  }

  // MARK: - C. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = OutputClassifierError.disabled(.missingFile)
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: Self.category, error: error, detail: "missing_file", environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: Self.category, error: error, detail: "missing_file", environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - D. Event-construction contract

  @MainActor
  @Test("a pinned error's event carries the production title, fingerprint and identity tag")
  func pinnedErrorEventShape() {
    let error = OutputClassifierError.disabled(.tokenizerLoadFailed)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "llm", fingerprintDetail: "tokenizer_load_failed",
      environment: Self.env)

    #expect(event.message?.formatted == "output_classifier_load_failed: \(Self.descriptor)")
    #expect(
      event.fingerprint
        == [
          "handled_error", "output_classifier_load_failed", Self.descriptor,
          "tokenizer_load_failed", Self.env,
        ])
    #expect(event.tags?["pipeline.stage"] == "llm")
    #expect(event.tags?["error.category"] == "output_classifier_load_failed")
    #expect(event.tags?["error.identity"] == Self.semanticID)
  }

  @MainActor
  @Test("a non-conforming error's event is unchanged and carries no identity tag")
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "llm", environment: Self.env)

    #expect(
      event.fingerprint
        == ["handled_error", "output_classifier_load_failed", "EnviousWispr#-3", Self.env])
    #expect(event.tags?["error.identity"] == nil)
  }
}
