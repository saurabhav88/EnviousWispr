import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #1524 — `HeartPathError`'s Sentry identity is PINNED, not derived from its
/// enum layout. Before this, the bridged `NSError.code` was the case's declaration
/// ordinal, so deleting a case renumbered every later one and silently re-pointed
/// their shipped Sentry issues onto each other's defects.
///
/// The expected strings below are not re-derived here: they were MEASURED against
/// shipping code and cross-checked against the live Sentry issue titles
/// (`docs/audits/2026-07-12-sentry-identity-preflight.md`). This suite is the lock —
/// any drift in a shipped identity reddens.
///
/// `environment` is passed explicitly throughout: the default reads the bundle
/// identifier, and a test runner's bundle is not production.
@Suite("Sentry stable error identity (#1524)")
struct StableSentryErrorIdentityTests {

  private static let env = "production"
  private static let domain = "EnviousWisprServices.HeartPathError"

  /// Every case, with the category its production call site actually passes.
  /// `pasteAppleScriptFailed` and `xpcServerClientProxyNil` have no producer today;
  /// they carry their declared paste/XPC category.
  private static let allCases: [(HeartPathError, SentryBreadcrumb.ErrorCategory, String, String)] =
    {
      let stallCtx = CaptureStallContext(
        sessionID: 1, armedAtUptimeNs: 0, firedAtUptimeNs: 1, route: "builtin",
        sourceType: "audioEngine", engineStartedSuccessfully: true, tapInstalled: true,
        formatMismatchObserved: false, inputDeviceUIDPreferred: nil,
        inputDeviceUIDSystemDefault: nil, failureMode: .noBuffers)

      return [
        (
          .audioCaptureStalled(sessionID: 1, ctx: stallCtx), .audioCaptureStalled,
          "\(domain)#0", "heartpath.audio_capture_stalled"
        ),
        (
          .noAudioCaptured(sessionID: 1, durationMs: 0, wasStreaming: false, route: "builtin"),
          .audioCaptureFailed, "\(domain)#1", "heartpath.no_audio_captured"
        ),
        (
          .pasteCascadeClipboardFallback(
            tiersAttempted: ["a"], focusClassification: "f", targetBundleID: nil),
          .pasteFailed, "\(domain)#3", "heartpath.paste_cascade_clipboard_fallback"
        ),
        (
          .pasteCGEventCreationFailed(accessibilityTrusted: true), .pasteFailed,
          "\(domain)#4", "heartpath.paste_cgevent_creation_failed"
        ),
        (
          .pasteAppleScriptFailed(errorCode: nil, errorMessage: nil, targetBundleID: nil),
          .pasteFailed, "\(domain)#5", "heartpath.paste_applescript_failed"
        ),
        (
          .emptyAfterProcessing(route: "builtin", wasPolishEnabled: true),
          .heartPathFinalization, "\(domain)#9", "heartpath.empty_after_processing"
        ),
        (
          .zombieEngineZeroPeak(sessionID: 1, durationMs: 0, route: "builtin", sampleCount: 1),
          .audioCaptureFailed, "\(domain)#10", "heartpath.zombie_engine_zero_peak"
        ),
        (
          .audioEngineInterrupted(route: "builtin", durationMs: 0), .audioCaptureFailed,
          "\(domain)#11", "heartpath.audio_engine_interrupted"
        ),
      ]
    }()

  // MARK: - A. Pin lock

  @Test("every shipped case keeps its exact production fingerprint")
  func pinLock() {
    for (error, category, descriptor, _) in Self.allCases {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(
          for: category, error: error, environment: Self.env)
          == ["handled_error", category.rawValue, descriptor, Self.env])
    }
  }

  // MARK: - B. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared, not
  /// inferred from enum layout, so this test asserts the override itself and never
  /// depends on the compiler behaviour the design exists to escape.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 10 }
    let sentryFingerprintDescriptor = "fixture.pinned#11"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 10)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#11")
  }

  // MARK: - C. Uniqueness

  @Test("descriptors and semantic IDs are unique across cases")
  func identitiesAreUnique() {
    let descriptors = Self.allCases.map(\.2)
    let semanticIDs = Self.allCases.map(\.3)

    #expect(Set(descriptors).count == descriptors.count)
    #expect(Set(semanticIDs).count == semanticIDs.count)
  }

  // MARK: - F. Collision freeze

  /// The three same-category pairs that a renumber would have merged: each pair's
  /// second member would have inherited the first's shipped fingerprint.
  @Test("cases a renumber would have merged still group separately")
  func collisionPairsStaySeparate() {
    let pairs: [(HeartPathError, HeartPathError, SentryBreadcrumb.ErrorCategory)] = [
      (
        .pasteCascadeClipboardFallback(
          tiersAttempted: ["a"], focusClassification: "f", targetBundleID: nil),
        .pasteCGEventCreationFailed(accessibilityTrusted: true), .pasteFailed
      ),
      (
        .zombieEngineZeroPeak(sessionID: 1, durationMs: 0, route: "builtin", sampleCount: 1),
        .audioEngineInterrupted(route: "builtin", durationMs: 0), .audioCaptureFailed
      ),
    ]

    for (lhs, rhs, category) in pairs {
      let lhsFingerprint = SentryBreadcrumb.handledErrorFingerprint(
        for: category, error: lhs, environment: Self.env)
      let rhsFingerprint = SentryBreadcrumb.handledErrorFingerprint(
        for: category, error: rhs, environment: Self.env)
      #expect(lhsFingerprint != rhsFingerprint)
    }
  }

  // MARK: - G. Event-construction contract

  @MainActor
  @Test("a pinned error's event carries the production title, fingerprint and identity tag")
  func pinnedErrorEventShape() {
    let error = HeartPathError.pasteCascadeClipboardFallback(
      tiersAttempted: ["accessibility"], focusClassification: "text_field",
      targetBundleID: nil)

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .pasteFailed, stage: "paste", environment: Self.env)

    #expect(
      event.message?.formatted == "paste_failed: \(Self.domain)#3")
    #expect(
      event.fingerprint == ["handled_error", "paste_failed", "\(Self.domain)#3", Self.env])
    #expect(event.tags?["pipeline.stage"] == "paste")
    #expect(event.tags?["error.category"] == "paste_failed")
    #expect(event.tags?["error.identity"] == "heartpath.paste_cascade_clipboard_fallback")
  }

  @Test(
    "a non-conforming error's descriptor and fingerprint are unchanged (#1525 PR J-1: makeHandledErrorEvent narrowed — structuredDescriptor/handledErrorFingerprint stay generic)"
  )
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -3)

    #expect(SentryBreadcrumb.structuredDescriptor(error) == "EnviousWispr#-3")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .xpcServiceError, error: error, environment: Self.env)
        == ["handled_error", "xpc_service_error", "EnviousWispr#-3", Self.env])
  }
}
