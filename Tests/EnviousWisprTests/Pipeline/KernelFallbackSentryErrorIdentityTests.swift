import EnviousWisprCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #1525 PR I-A — `KernelFallbackSentryError` (replacing the 8 raw
/// `NSError(domain: "EnviousWispr", code: ...)` construction sites across
/// `KernelLifecycleTelemetrySink.swift` and `KernelDictationDriver.swift`) and
/// `AudioError` (`AudioBufferProcessor.swift`) have PINNED Sentry identities,
/// mirroring `HeartPathError`'s shipped pattern (#1524).
///
/// `KernelFallbackSentryError`'s 7 descriptors are not re-derived: they were
/// MEASURED against the shipping literals (`EnviousWispr#-3/-10/-11/-13/-14/-15/-16`)
/// and cross-checked against live Sentry — `-3` has TWO live issues (ENVIOUSWISPR-3G
/// development, ENVIOUSWISPR-29 production, split by the fingerprint's environment
/// component, not a duplicate). `AudioError`'s descriptors were already stable
/// through explicit `CustomNSError` codes 1/2/3. This conformance preserves its
/// NSError bridge, Sentry title, and fingerprint; it only adds the readable
/// `error.identity` metadata tag and satisfies PR J's future compile-time
/// requirement.
///
/// `environment` is passed explicitly throughout: the default reads the bundle
/// identifier, and a test runner's bundle is not production.
@Suite("Kernel fallback + AudioError Sentry stable identity (#1525 PR I-A)")
struct KernelFallbackSentryErrorIdentityTests {

  private static let env = "production"

  // MARK: - A. Pin lock — KernelFallbackSentryError

  @Test("every KernelFallbackSentryError case keeps the exact production fingerprint")
  func kernelFallbackPinLock() {
    let cases: [(KernelFallbackSentryError, String, SentryBreadcrumb.ErrorCategory)] = [
      (.xpcServiceError(backendLabel: "WhisperKit"), "EnviousWispr#-3", .xpcServiceError),
      (.modelLoadFailed, "EnviousWispr#-10", .modelLoadFailed),
      (.captureStartFailed, "EnviousWispr#-11", .audioCaptureFailed),
      (.noMicrophoneFound, "EnviousWispr#-16", .audioCaptureFailed),
      (.transcriptionFailed, "EnviousWispr#-13", .asrFailed),
      (.permissionDenied, "EnviousWispr#-14", .audioCaptureFailed),
      (.prepareFailed, "EnviousWispr#-15", .audioCaptureFailed),
    ]
    for (error, descriptor, category) in cases {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(for: category, error: error, environment: Self.env)
          == ["handled_error", category.rawValue, descriptor, Self.env])
    }
  }

  @Test("xpcServiceError's associated backendLabel never changes the pinned descriptor")
  func xpcServiceErrorIgnoresBackendLabel() {
    let whisperKit = KernelFallbackSentryError.xpcServiceError(backendLabel: "WhisperKit")
    let parakeet = KernelFallbackSentryError.xpcServiceError(backendLabel: "Parakeet")
    #expect(
      SentryBreadcrumb.structuredDescriptor(whisperKit)
        == SentryBreadcrumb.structuredDescriptor(parakeet))
    #expect(whisperKit.errorDescription == "ASR XPC service crashed (WhisperKit)")
    #expect(parakeet.errorDescription == "ASR XPC service crashed (Parakeet)")
  }

  @Test("all 7 declared KernelFallbackSentryError identities are unique")
  func kernelFallbackIdentitiesAreUnique() {
    let cases: [KernelFallbackSentryError] = [
      .xpcServiceError(backendLabel: "WhisperKit"), .modelLoadFailed, .captureStartFailed,
      .noMicrophoneFound, .transcriptionFailed, .permissionDenied, .prepareFailed,
    ]
    #expect(Set(cases.map(\.sentryFingerprintDescriptor)).count == cases.count)
    #expect(Set(cases.map(\.sentrySemanticID)).count == cases.count)
  }

  // MARK: - B. Pin lock — AudioError

  @Test("every AudioError case keeps the exact production fingerprint")
  func audioErrorPinLock() {
    let cases: [(AudioError, String)] = [
      (.formatCreationFailed(source: "test"), "EnviousWisprAudio.AudioError#1"),
      (.alreadyCapturing, "EnviousWisprAudio.AudioError#2"),
      (.noBuiltInMicrophoneFound, "EnviousWisprAudio.AudioError#3"),
    ]
    for (error, descriptor) in cases {
      #expect(SentryBreadcrumb.structuredDescriptor(error) == descriptor)
      #expect(
        SentryBreadcrumb.handledErrorFingerprint(
          for: .audioCaptureFailed, error: error, environment: Self.env)
          == ["handled_error", "audio_capture_failed", descriptor, Self.env])
    }
  }

  @Test("all 3 declared AudioError identities are unique")
  func audioErrorIdentitiesAreUnique() {
    let cases: [AudioError] = [
      .formatCreationFailed(), .alreadyCapturing, .noBuiltInMicrophoneFound,
    ]
    #expect(Set(cases.map(\.sentryFingerprintDescriptor)).count == cases.count)
    #expect(Set(cases.map(\.sentrySemanticID)).count == cases.count)
  }

  // MARK: - C. The property that matters

  /// A deterministic `CustomNSError` — its bridged domain/code are declared,
  /// not inferred from enum layout, so this test asserts the override itself
  /// and never depends on the compiler behaviour the design escapes.
  private struct StableFixtureError: Error, CustomNSError, StableSentryErrorIdentity {
    static let errorDomain = "fixture.raw"
    var errorCode: Int { 40 }
    let sentryFingerprintDescriptor = "fixture.pinned#kernelfallback"
    let sentrySemanticID = "fixture.semantic"
  }

  @Test("the explicit identity overrides the bridged NSError identity")
  func explicitIdentityOverridesBridge() {
    let error = StableFixtureError()
    let bridged = error as NSError

    #expect(bridged.domain == "fixture.raw")
    #expect(bridged.code == 40)
    #expect(SentryBreadcrumb.structuredDescriptor(error) == "fixture.pinned#kernelfallback")
  }

  // MARK: - D. Dev/prod split survives the pin

  @Test("environment keeps the same descriptor's dev and prod fingerprints separate")
  func devProdSplitSurvives() {
    let error = KernelFallbackSentryError.xpcServiceError(backendLabel: "Parakeet")
    let prod = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: error, environment: "production")
    let dev = SentryBreadcrumb.handledErrorFingerprint(
      for: .xpcServiceError, error: error, environment: "development")

    #expect(prod != dev)
    #expect(prod.last == "production")
    #expect(dev.last == "development")
  }

  // MARK: - E. Event-construction contract

  @MainActor
  @Test(
    "KernelFallbackSentryError's event carries the production title, fingerprint and identity tag")
  func kernelFallbackEventShape() {
    let error = KernelFallbackSentryError.xpcServiceError(backendLabel: "WhisperKit")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .xpcServiceError, stage: "asr", environment: Self.env)

    #expect(event.message?.formatted == "xpc_service_error: EnviousWispr#-3")
    #expect(
      event.fingerprint == ["handled_error", "xpc_service_error", "EnviousWispr#-3", Self.env])
    #expect(event.tags?["pipeline.stage"] == "asr")
    #expect(event.tags?["error.category"] == "xpc_service_error")
    #expect(event.tags?["error.identity"] == "kernel.xpc_service_error")
  }

  @MainActor
  @Test("AudioError's event carries the production title, fingerprint and identity tag")
  func audioErrorEventShape() {
    let error = AudioError.noBuiltInMicrophoneFound

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .audioCaptureFailed, stage: "recording", environment: Self.env)

    #expect(
      event.message?.formatted
        == "audio_capture_failed: EnviousWisprAudio.AudioError#3")
    #expect(
      event.fingerprint
        == [
          "handled_error", "audio_capture_failed", "EnviousWisprAudio.AudioError#3", Self.env,
        ])
    #expect(event.tags?["error.identity"] == "audio.no_built_in_microphone_found")
  }

  @Test(
    "a non-conforming error's descriptor and fingerprint are unchanged (#1525 PR J-1: makeHandledErrorEvent narrowed — structuredDescriptor/handledErrorFingerprint stay generic)"
  )
  func nonConformingErrorEventUnchanged() {
    let error = NSError(domain: "EnviousWispr", code: -99)

    #expect(SentryBreadcrumb.structuredDescriptor(error) == "EnviousWispr#-99")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .xpcServiceError, error: error, environment: Self.env)
        == ["handled_error", "xpc_service_error", "EnviousWispr#-99", Self.env])
  }
}
