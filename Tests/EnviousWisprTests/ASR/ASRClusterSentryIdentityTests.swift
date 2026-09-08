import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #1525 PR G — `ASRError` and `ASRLoadSupersededError`'s Sentry identities are
/// PINNED, mirroring `KeyStoreError`'s shipped pattern (PR F).
///
/// `ASRError.transcriptionFailed` measured as `#0` despite being declared fourth —
/// an observed anomaly, not a rule to re-derive. `ASRLoadSupersededError` is
/// pinned defensively (preflight §3: no currently reachable capture path).
///
/// The expected strings are not re-derived here: they were MEASURED against
/// shipping code (`docs/audits/2026-07-14-1525-pr-g-preflight.md`). This suite is
/// the lock — any drift in the shipped identity reddens.
///
/// #1908: `XPCASRTransportError`'s own pin-lock section (originally PR G's
/// section B) was deleted along with the type — the last XPC helper collapsed
/// in-process, so `XPCASRTransportError` has no producer and no declaration.
///
/// `environment` is passed explicitly throughout: the default reads the bundle
/// identifier, and a test runner's bundle is not production.
@Suite("ASRError / ASRLoadSupersededError Sentry stable identity (#1525 PR G)")
struct ASRClusterSentryIdentityTests {

  private static let env = "production"
  private static let category = SentryBreadcrumb.ErrorCategory.asrFailed

  private static let asrErrorPins: [(ASRError, String, String)] = [
    (.notReady, "EnviousWisprASR.ASRError#1", "asr.not_ready"),
    (.streamingNotSupported, "EnviousWisprASR.ASRError#2", "asr.streaming_not_supported"),
    (.streamingTimeout, "EnviousWisprASR.ASRError#3", "asr.streaming_timeout"),
    (.transcriptionFailed("x"), "EnviousWisprASR.ASRError#0", "asr.transcription_failed"),
  ]

  // MARK: - A. Pin lock — ASRError

  @Test("every ASRError case keeps its exact measured production fingerprint")
  func asrErrorPinLock() {
    for (error, descriptor, semanticID) in Self.asrErrorPins {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(error.sentrySemanticID == semanticID)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(
          for: Self.category, error: error, environment: Self.env)
          == ["handled_error", Self.category.rawValue, descriptor, Self.env]
      )
    }
  }

  @Test("all 4 declared ASRError identities are unique")
  func asrErrorIdentitiesAreUnique() {
    let errors = Self.asrErrorPins.map(\.0)

    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 4)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 4)
  }

  // MARK: - B. Pin lock — ASRLoadSupersededError

  @Test("ASRLoadSupersededError keeps its exact measured fingerprint")
  func asrLoadSupersededErrorPinLock() {
    let error = ASRLoadSupersededError()

    #expect(
      SentryBreadcrumb.structuredDescriptor(error) == "EnviousWisprASR.ASRLoadSupersededError#1")
    #expect(error.sentrySemanticID == "asr.load_superseded")
  }

  // MARK: - C. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 30 }
    let sentryFingerprintDescriptor = "fixture.pinned#asr"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 30)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#asr")
  }

  // MARK: - D. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = ASRError.transcriptionFailed("x")
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: Self.category, error: error, environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: Self.category, error: error, environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - E. Event-construction contract

  @MainActor
  @Test(
    "the confirmed-reachable .transcriptionFailed case's event carries the production title, fingerprint and identity tag"
  )
  func transcriptionFailedEventShape() {
    let error = ASRError.transcriptionFailed("x")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.category, stage: "transcription", environment: Self.env)

    #expect(event.message?.formatted == "asr_failed: EnviousWisprASR.ASRError#0")
    #expect(
      event.fingerprint
        == ["handled_error", "asr_failed", "EnviousWisprASR.ASRError#0", Self.env])
    #expect(event.tags?["pipeline.stage"] == "transcription")
    #expect(event.tags?["error.category"] == "asr_failed")
    #expect(event.tags?["error.identity"] == "asr.transcription_failed")
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
        == ["handled_error", "asr_failed", "EnviousWispr#-3", Self.env])
  }

}
