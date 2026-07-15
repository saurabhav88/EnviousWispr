import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #1525 PR G — `ASREngineError`, `XPCOperationSignalWedgeError`, and
/// `ParakeetDeliveryError`'s Sentry identities are PINNED, mirroring
/// `ModelLoadWatchdog.WedgeError`'s shipped pattern (PR B) for the two structs.
///
/// `ASREngineError` measures to plain declaration order (`#0`-`#3`) — but none of
/// its 4 cases is currently reachable against a real production adapter today
/// (preflight §3: `.decodeFailed` is superseded before capture, `.wedged` cannot
/// arm against either real adapter, `.loadFailed`/`.engineCrashed` have no
/// producer). `XPCOperationSignalWedgeError` measures as `#1` and carries 2 real
/// production issues (ENVIOUSWISPR-22, ENVIOUSWISPR-1B) from a producer deleted
/// this morning — this suite's pin lock asserts the EXACT string that matches
/// those issues verbatim. `ParakeetDeliveryError` measures as `#1`, confirmed
/// constant across all 10 `DeliveryFailureClass` reasons, and is a confirmed
/// current capture route.
///
/// The expected strings are not re-derived here: they were MEASURED against
/// shipping code (`docs/audits/2026-07-14-1525-pr-g-preflight.md`). This suite is
/// the lock — any drift in the shipped identity reddens.
@Suite(
  "ASREngineError / XPCOperationSignalWedgeError / ParakeetDeliveryError Sentry stable identity (#1525 PR G)"
)
struct ASREngineClusterSentryIdentityTests {

  private static let env = "production"
  private static let asrCategory = SentryBreadcrumb.ErrorCategory.asrFailed
  private static let audioCategory = SentryBreadcrumb.ErrorCategory.audioCaptureFailed
  private static let modelLoadCategory = SentryBreadcrumb.ErrorCategory.modelLoadFailed

  private static let asrEnginePins: [(ASREngineError, String, String)] = [
    (.loadFailed, "EnviousWisprPipeline.ASREngineError#0", "asrengine.load_failed"),
    (.decodeFailed, "EnviousWisprPipeline.ASREngineError#1", "asrengine.decode_failed"),
    (.engineCrashed, "EnviousWisprPipeline.ASREngineError#2", "asrengine.engine_crashed"),
    (.wedged, "EnviousWisprPipeline.ASREngineError#3", "asrengine.wedged"),
  ]

  // MARK: - A. Pin lock — ASREngineError

  @Test("every ASREngineError case keeps its exact measured production fingerprint")
  func asrEnginePinLock() {
    for (error, descriptor, semanticID) in Self.asrEnginePins {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(error.sentrySemanticID == semanticID)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(
          for: Self.asrCategory, error: error, environment: Self.env)
          == ["handled_error", Self.asrCategory.rawValue, descriptor, Self.env]
      )
    }
  }

  @Test("all 4 declared ASREngineError identities are unique")
  func asrEngineIdentitiesAreUnique() {
    let errors = Self.asrEnginePins.map(\.0)

    #expect(Set(errors.map(\.sentryFingerprintDescriptor)).count == 4)
    #expect(Set(errors.map(\.sentrySemanticID)).count == 4)
  }

  // MARK: - B. Pin lock — XPCOperationSignalWedgeError, ParakeetDeliveryError

  @Test("XPCOperationSignalWedgeError keeps the exact string matching its 2 live production issues")
  func xpcOperationSignalWedgeErrorPinLock() {
    let error = XPCOperationSignalWedgeError(
      service: "ASR", stage: "start_streaming", observedPhase: "loading")

    #expect(
      SentryBreadcrumb.structuredDescriptor(error)
        == "EnviousWisprCore.XPCOperationSignalWedgeError#1")
    #expect(error.sentrySemanticID == "xpc.operation_signal_wedge")
  }

  @Test("ParakeetDeliveryError keeps the same descriptor across every DeliveryFailureClass reason")
  func parakeetDeliveryErrorPinLock() {
    let reasons: [DeliveryFailureClass] = [
      .sourceUnreachable, .sourceTimeout, .source5xx, .source4xx, .integrityMismatch,
      .insufficientDisk, .permissionDenied, .cacheRepairFailed, .cancelled, .unknown,
    ]

    for reason in reasons {
      let error = ParakeetDeliveryError(DeliveryFailure(reason: reason))
      #expect(
        SentryBreadcrumb.structuredDescriptor(error)
          == "EnviousWisprPipeline.ParakeetDeliveryError#1")
      #expect(error.sentrySemanticID == "parakeet.delivery_failed")
    }
  }

  // MARK: - C. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 40 }
    let sentryFingerprintDescriptor = "fixture.pinned#asrengine"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 40)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#asrengine")
  }

  // MARK: - D. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = ParakeetDeliveryError(DeliveryFailure(reason: .sourceUnreachable))
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: Self.modelLoadCategory, error: error, environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: Self.modelLoadCategory, error: error, environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - E. Event-construction contract

  @MainActor
  @Test(
    "the confirmed-reachable ParakeetDeliveryError event carries the production title, fingerprint and identity tag"
  )
  func parakeetDeliveryErrorEventShape() {
    let error = ParakeetDeliveryError(DeliveryFailure(reason: .sourceUnreachable))

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.modelLoadCategory, stage: "asr", environment: Self.env)

    #expect(
      event.message?.formatted == "model_load_failed: EnviousWisprPipeline.ParakeetDeliveryError#1"
    )
    #expect(
      event.fingerprint
        == [
          "handled_error", "model_load_failed", "EnviousWisprPipeline.ParakeetDeliveryError#1",
          Self.env,
        ])
    #expect(event.tags?["pipeline.stage"] == "asr")
    #expect(event.tags?["error.category"] == "model_load_failed")
    #expect(event.tags?["error.identity"] == "parakeet.delivery_failed")
  }

  @MainActor
  @Test(
    "the historical-live XPCOperationSignalWedgeError event carries the exact string matching ENVIOUSWISPR-22/-1B"
  )
  func xpcOperationSignalWedgeErrorEventShape() {
    let error = XPCOperationSignalWedgeError(
      service: "Audio", stage: "stop_capture", observedPhase: "draining")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.audioCategory, stage: "audio", environment: "development")

    #expect(
      event.message?.formatted
        == "audio_capture_failed: EnviousWisprCore.XPCOperationSignalWedgeError#1")
    #expect(
      event.fingerprint
        == [
          "handled_error", "audio_capture_failed",
          "EnviousWisprCore.XPCOperationSignalWedgeError#1", "development",
        ])
    #expect(event.tags?["error.identity"] == "xpc.operation_signal_wedge")
  }

  @MainActor
  @Test("a non-conforming error's event is unchanged and carries no identity tag")
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: Self.modelLoadCategory, stage: "asr", environment: Self.env)

    #expect(
      event.fingerprint == ["handled_error", "model_load_failed", "EnviousWispr#-3", Self.env])
    #expect(event.tags?["error.identity"] == nil)
  }
}
