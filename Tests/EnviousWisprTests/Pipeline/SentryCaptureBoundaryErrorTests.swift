import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1525 PR J-1 — `SentryCaptureBoundaryError` is the closed-world boundary-violation
/// identity that lets `SentryBreadcrumb.captureError`/`makeHandledErrorEvent` narrow from
/// `any Error` to `any Error & StableSentryErrorIdentity` without silently dropping the
/// small number of genuinely-external, genuinely-reachable non-conforming producers.
///
/// `.urlTransport`/`.coreML` MUST preserve the exact historical fallback descriptor for
/// their one proven external family — this suite locks that parity against
/// `SentryBreadcrumb.handledErrorFingerprint`'s pre-existing NSError-bridge fallback,
/// which stays generic (`any Error`) and is not touched by this PR.
@Suite("SentryCaptureBoundaryError (#1525 PR J-1)")
struct SentryCaptureBoundaryErrorTests {

  private static let env = "production"

  // MARK: - A. .urlTransport parity against the pre-normalization raw URLError

  @Test("normalizingGenerationFailure(.badURL) matches the raw URLError's own fingerprint")
  func urlTransportMatchesRawURLErrorBadURL() {
    let raw = URLError(.badURL)
    let normalized = SentryCaptureBoundaryError.normalizingGenerationFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "NSURLErrorDomain#-1000")
    #expect(normalized.sentrySemanticID == "polish.external_url_transport")
  }

  @Test(
    "normalizingGenerationFailure(.notConnectedToInternet) matches the raw URLError's own fingerprint"
  )
  func urlTransportMatchesRawURLErrorNotConnected() {
    let raw = URLError(.notConnectedToInternet)
    let normalized = SentryCaptureBoundaryError.normalizingGenerationFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "NSURLErrorDomain#-1009")
    #expect(normalized.sentrySemanticID == "polish.external_url_transport")
  }

  // MARK: - B. .coreML parity against the pre-normalization raw CoreML NSError

  @Test("normalizingTranscriptionFailure(CoreML#0) matches the raw NSError's own fingerprint")
  func coreMLMatchesRawNSErrorCodeZero() {
    let raw = NSError(domain: "com.apple.CoreML", code: 0)
    let normalized = SentryCaptureBoundaryError.normalizingTranscriptionFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "com.apple.CoreML#0")
    #expect(normalized.sentrySemanticID == "asr.external_coreml")
  }

  @Test("normalizingTranscriptionFailure(CoreML#9) matches the raw NSError's own fingerprint")
  func coreMLMatchesRawNSErrorCodeNine() {
    let raw = NSError(domain: "com.apple.CoreML", code: 9)
    let normalized = SentryCaptureBoundaryError.normalizingTranscriptionFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "com.apple.CoreML#9")
    #expect(normalized.sentrySemanticID == "asr.external_coreml")
  }

  // MARK: - C. Already-conforming values pass through unchanged

  private struct AlreadyConforming: Error, StableSentryErrorIdentity {
    let sentryFingerprintDescriptor = "Already#1"
    let sentrySemanticID = "already.conforming"
  }

  @Test("every normalizer passes an already-conforming value through unchanged")
  func alreadyConformingPassesThroughUnchanged() {
    let error = AlreadyConforming()
    #expect(
      SentryCaptureBoundaryError.normalizingGenerationFailure(error).sentrySemanticID
        == "already.conforming")
    #expect(
      SentryCaptureBoundaryError.normalizingTranscriptionFailure(error).sentrySemanticID
        == "already.conforming")
    #expect(
      SentryCaptureBoundaryError.normalizingLegacyKeyCleanupFailure(error).sentrySemanticID
        == "already.conforming")
    #expect(
      SentryCaptureBoundaryError.normalizingHeartControlFailure(error).sentrySemanticID
        == "already.conforming")
    #expect(
      SentryCaptureBoundaryError.normalizingModelLoadFailure(error).sentrySemanticID
        == "already.conforming")
  }

  // MARK: - D. Non-conforming, unrecognized misses fall to the fixed `.unexpected*` identity

  private struct Opaque: Error {}

  @Test("normalizingGenerationFailure on a non-URLError miss falls to .unexpectedGenerationFailure")
  func generationFailureMissFallsToUnexpected() {
    let normalized = SentryCaptureBoundaryError.normalizingGenerationFailure(Opaque())
    #expect(normalized.sentrySemanticID == "boundary.unexpected_generation_failure")
  }

  @Test(
    "normalizingTranscriptionFailure on a non-CoreML miss falls to .unexpectedTranscriptionFailure"
  )
  func transcriptionFailureMissFallsToUnexpected() {
    let normalized = SentryCaptureBoundaryError.normalizingTranscriptionFailure(Opaque())
    #expect(normalized.sentrySemanticID == "boundary.unexpected_transcription_failure")
  }

  @Test(
    "normalizingLegacyKeyCleanupFailure on a miss falls to .unexpectedLegacyKeyCleanupFailure"
  )
  func legacyKeyCleanupFailureMissFallsToUnexpected() {
    let normalized = SentryCaptureBoundaryError.normalizingLegacyKeyCleanupFailure(Opaque())
    #expect(normalized.sentrySemanticID == "boundary.unexpected_legacy_key_cleanup_failure")
  }

  @Test("normalizingHeartControlFailure on a miss falls to .unexpectedHeartControlFailure")
  func heartControlFailureMissFallsToUnexpected() {
    let normalized = SentryCaptureBoundaryError.normalizingHeartControlFailure(Opaque())
    #expect(normalized.sentrySemanticID == "boundary.unexpected_heart_control_failure")
  }

  // MARK: - E. Full event-construction shape through the narrowed captureError entry point

  @MainActor
  @Test(
    "a normalized .urlTransport event carries the production title, fingerprint, and identity tag")
  func urlTransportEventShape() {
    let normalized = SentryCaptureBoundaryError.normalizingGenerationFailure(URLError(.badURL))
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      normalized, category: .polishProviderFailed, stage: "polish", environment: Self.env)
    #expect(event.message?.formatted == "polish_provider_failed: NSURLErrorDomain#-1000")
    #expect(
      event.fingerprint
        == ["handled_error", "polish_provider_failed", "NSURLErrorDomain#-1000", Self.env])
    #expect(event.tags?["error.identity"] == "polish.external_url_transport")
  }

  @MainActor
  @Test("a normalized .coreML event carries the production title, fingerprint, and identity tag")
  func coreMLEventShape() {
    let normalized = SentryCaptureBoundaryError.normalizingTranscriptionFailure(
      NSError(domain: "com.apple.CoreML", code: 0))
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      normalized, category: .asrFailed, stage: "transcription", environment: Self.env)
    #expect(event.message?.formatted == "asr_failed: com.apple.CoreML#0")
    #expect(
      event.fingerprint == ["handled_error", "asr_failed", "com.apple.CoreML#0", Self.env])
    #expect(event.tags?["error.identity"] == "asr.external_coreml")
  }

  // MARK: - F. #1658 PR J-2 — .normalizingModelLoadFailure preserves the raw bridged identity

  @Test("normalizingModelLoadFailure(raw NSError) matches the raw error's own fingerprint")
  func modelLoadRawNSErrorMatchesBridgedFingerprint() {
    let raw = NSError(domain: "com.acme.vendor", code: 42)
    let normalized = SentryCaptureBoundaryError.normalizingModelLoadFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "com.acme.vendor#42")
    #expect(normalized.sentrySemanticID == "asr.unrecognized_model_load_failure")
  }

  @Test("normalizingModelLoadFailure(second domain/code pair) matches the raw fingerprint")
  func modelLoadRawNSErrorSecondPairMatchesBridgedFingerprint() {
    let raw = NSError(domain: "NSCocoaErrorDomain", code: 260)
    let normalized = SentryCaptureBoundaryError.normalizingModelLoadFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "NSCocoaErrorDomain#260")
    #expect(normalized.sentrySemanticID == "asr.unrecognized_model_load_failure")
  }

  @Test(
    "normalizingModelLoadFailure on a mangled-domain Swift error keeps structuredDescriptor parity")
  func modelLoadMangledDomainSwiftErrorKeepsParity() {
    let raw = Opaque()
    let normalized = SentryCaptureBoundaryError.normalizingModelLoadFailure(raw)
    #expect(normalized.sentryFingerprintDescriptor == SentryBreadcrumb.structuredDescriptor(raw))
    #expect(normalized.sentryFingerprintDescriptor == "Opaque#1")
    #expect(normalized.sentrySemanticID == "asr.unrecognized_model_load_failure")
  }

  @Test("UnrecognizedModelLoadSentryError equality follows the stored descriptor")
  func unrecognizedModelLoadEquality() {
    let a = UnrecognizedModelLoadSentryError(NSError(domain: "com.acme.vendor", code: 42))
    let b = UnrecognizedModelLoadSentryError(NSError(domain: "com.acme.vendor", code: 42))
    let c = UnrecognizedModelLoadSentryError(NSError(domain: "com.acme.vendor", code: 43))
    #expect(a == b)
    #expect(a != c)
  }

  @MainActor
  @Test(
    "a normalized model-load event carries the production title, fingerprint, and identity tag")
  func unrecognizedModelLoadEventShape() {
    let normalized = SentryCaptureBoundaryError.normalizingModelLoadFailure(
      NSError(domain: "com.acme.vendor", code: 42))
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      normalized, category: .modelLoadFailed, stage: "model_load", environment: Self.env)
    #expect(event.message?.formatted == "model_load_failed: com.acme.vendor#42")
    #expect(
      event.fingerprint
        == ["handled_error", "model_load_failed", "com.acme.vendor#42", Self.env])
    #expect(event.tags?["error.identity"] == "asr.unrecognized_model_load_failure")
  }
}
