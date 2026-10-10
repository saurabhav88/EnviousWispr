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

  // MARK: - D. Dev/prod split survives the pin

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

  @MainActor
  @Test("#3069: file import's ASR failures share dictation's fingerprint, tag alone differs")
  func fileImportStageDoesNotFragmentASRGrouping() {
    let error = ASRError.transcriptionFailed("x")
    let dictation = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .asrFailed, stage: "transcription", environment: Self.env)
    let fileImport = SentryBreadcrumb.makeHandledErrorEvent(
      error, category: .asrFailed, stage: "file_import", environment: Self.env)

    #expect(dictation.fingerprint == fileImport.fingerprint)
    #expect(dictation.tags?["pipeline.stage"] == "transcription")
    #expect(fileImport.tags?["pipeline.stage"] == "file_import")
  }

}
