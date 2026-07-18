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
}
