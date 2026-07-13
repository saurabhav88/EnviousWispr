import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #1525 PR B — `ModelLoadWatchdog.WedgeError`'s Sentry identity is PINNED,
/// mirroring `HeartPathError`'s shipped pattern (#1524,
/// `StableSentryErrorIdentityTests.swift`). `WedgeError` has one shape today
/// (a struct, not an enum), so there is no ordinal-reorder risk yet — this
/// pin closes the latent risk before a second shape is ever added.
///
/// The expected string is not re-derived here: it was MEASURED against
/// shipping code and cross-checked against the live Sentry issue title
/// (ENVIOUSWISPR-30, `docs/sentry-identity-refactor/BIBLE.md` §2.5.5). This
/// suite is the lock — any drift in the shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the
/// bundle identifier, and a test runner's bundle is not production.
@Suite("ModelLoadWatchdog.WedgeError Sentry stable identity (#1525 PR B)")
struct ModelLoadWatchdogSentryIdentityTests {

  private static let env = "production"
  private static let descriptor = "EnviousWisprCore.ModelLoadWatchdog.WedgeError#1"
  private static let semanticID = "modelload.wedge"

  /// The two live production categories this type is captured under
  /// (`RecordingStarter.swift:356`, `KernelDictationDriver.swift:220`,
  /// `KernelLifecycleTelemetrySink.swift:564`) — different categories,
  /// same descriptor, kept separate by the category component of the
  /// fingerprint.
  private static let liveCategories: [SentryBreadcrumb.ErrorCategory] = [
    .pipelinePostConditionFailed,
    .modelLoadWedged,
  ]

  // MARK: - A. Pin lock

  @Test("both live capture-site shapes keep the exact production fingerprint")
  func pinLock() {
    for stage in ["post_condition", "model_load"] {
      let error = ModelLoadWatchdog.WedgeError(stage: stage)
      #expect(SentryBreadcrumb.structuredDescriptor(error) == Self.descriptor)
      for category in Self.liveCategories {
        #expect(
          SentryBreadcrumb.handledErrorFingerprint(
            for: category, error: error, environment: Self.env)
            == ["handled_error", category.rawValue, Self.descriptor, Self.env])
      }
    }
  }

  @Test("the single declared identity is unique within WedgeError")
  func identityIsUniqueWithinType() {
    let errors = [ModelLoadWatchdog.WedgeError()]

    #expect(
      Set(errors.map(\.sentryFingerprintDescriptor)).count == errors.count
    )
    #expect(
      Set(errors.map(\.sentrySemanticID)).count == errors.count
    )
  }

  // MARK: - B. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override
  /// itself and never depends on the compiler behaviour the design exists
  /// to escape.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 10 }
    let sentryFingerprintDescriptor = "fixture.pinned#modelload"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 10)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#modelload")
  }

  // MARK: - C. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = ModelLoadWatchdog.WedgeError()
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: .modelLoadWedged, error: error, environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: .modelLoadWedged, error: error, environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - D. Event-construction contract

  @MainActor
  @Test("a pinned error's event carries the production title, fingerprint and identity tag")
  func pinnedErrorEventShape() {
    let error = ModelLoadWatchdog.WedgeError()

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .modelLoadWedged, stage: "asr", environment: Self.env)

    #expect(event.message?.formatted == "model_load_wedged: \(Self.descriptor)")
    #expect(
      event.fingerprint == ["handled_error", "model_load_wedged", Self.descriptor, Self.env])
    #expect(event.tags?["pipeline.stage"] == "asr")
    #expect(event.tags?["error.category"] == "model_load_wedged")
    #expect(event.tags?["error.identity"] == Self.semanticID)
  }

  @MainActor
  @Test("a non-conforming error's event is unchanged and carries no identity tag")
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .modelLoadFailed, stage: "asr", environment: Self.env)

    #expect(event.message?.formatted == "model_load_failed: EnviousWispr#-3")
    #expect(
      event.fingerprint == ["handled_error", "model_load_failed", "EnviousWispr#-3", Self.env])
    #expect(event.tags?["error.identity"] == nil)
  }
}
