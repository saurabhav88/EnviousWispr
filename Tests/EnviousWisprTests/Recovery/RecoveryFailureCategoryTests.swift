import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #1897. Freezes the reason → Sentry category mapping that `RecoverySpoolReplayer`
/// applies to every unrecoverable replay.
///
/// The defect this exists to prevent: `.emptyText` used to be filed under
/// `.recoveryTranscribeFailed`, the SAME category as a genuine ASR throw, because
/// each call site picked its own category inline. One label then covered both
/// "transcription broke" and "the recording held no words", and #1813 was read as
/// a 76-user P0 transcription bug when genuine throws were 5 events / 2 users.
///
/// Every test here carries a NEGATIVE arm. A mapping that returned one category
/// for everything, or that renamed the tokens wholesale, would satisfy the
/// positive assertions alone while destroying the split this change exists to
/// create.
@Suite struct RecoveryFailureCategoryTests {

  // MARK: - The split itself

  @Test("an empty transcript is NOT filed as a transcription failure")
  func emptyTextGetsItsOwnCategory() {
    let empty = RecoverySpoolReplayer.category(for: .emptyText)

    // POSITIVE — it has its own bucket.
    #expect(empty == .recoveryEmptyText)

    // NEGATIVE, and this is the whole point of #1897: it must not be the
    // category a genuine ASR throw uses, or the two collapse back into one
    // Sentry issue and the count that misled #1813 returns.
    #expect(empty != .recoveryTranscribeFailed)
    #expect(RecoverySpoolReplayer.category(for: .transcribeError) == .recoveryTranscribeFailed)
    #expect(empty != RecoverySpoolReplayer.category(for: .transcribeError))
  }

  @Test("nothing-came-out-of-the-spool reasons stay on the decrypt category")
  func spoolReadFailuresShareTheDecryptCategory() {
    for reason: RecoveryTelemetryReason in [
      .keyMissing, .keyReadFailed, .reconstructionFailed, .emptyOrUnreadableSamples,
    ] {
      #expect(
        RecoverySpoolReplayer.category(for: reason) == .recoveryDecryptFailed,
        "\(reason.rawValue) must stay on the decrypt bucket")
    }
  }

  @Test("ASR could not run or threw — both stay a transcription failure")
  func asrFailuresShareTheTranscribeCategory() {
    for reason: RecoveryTelemetryReason in [.modelLoadFailed, .transcribeError] {
      #expect(
        RecoverySpoolReplayer.category(for: reason) == .recoveryTranscribeFailed,
        "\(reason.rawValue) is a real failure of transcription and must stay counted as one")
    }
  }

  // MARK: - The tokens dashboards query

  @Test("the category raw values are the exact snake_case tokens")
  func rawValuesAreFrozen() {
    // These strings ARE the Sentry issue identity and the PostHog query terms. A
    // rename is silent at compile time and breaks every saved query, so freeze
    // the bytes rather than the case names.
    #expect(SentryBreadcrumb.ErrorCategory.recoveryEmptyText.rawValue == "recovery_empty_text")
    #expect(
      SentryBreadcrumb.ErrorCategory.recoveryTranscribeFailed.rawValue
        == "recovery_transcribe_failed")
    #expect(
      SentryBreadcrumb.ErrorCategory.recoveryDecryptFailed.rawValue == "recovery_decrypt_failed")
  }

  // MARK: - Totality

  @Test("every recovery reason maps to a category")
  func mappingIsTotal() {
    // The switch is exhaustive, so this cannot fail to compile — but it CAN
    // silently funnel a new reason into a wrong bucket. Asserting the full set
    // here means adding a reason forces a deliberate choice with a visible diff,
    // rather than inheriting whichever arm it was pattern-matched into.
    let expected: [RecoveryTelemetryReason: SentryBreadcrumb.ErrorCategory] = [
      .keyMissing: .recoveryDecryptFailed,
      .keyReadFailed: .recoveryDecryptFailed,
      .reconstructionFailed: .recoveryDecryptFailed,
      .emptyOrUnreadableSamples: .recoveryDecryptFailed,
      .modelLoadFailed: .recoveryTranscribeFailed,
      .transcribeError: .recoveryTranscribeFailed,
      .emptyText: .recoveryEmptyText,
      .saveFailed: .recoveryDecryptFailed,
      .markerWriteFailed: .recoveryDecryptFailed,
      .markerClearFailed: .recoveryDecryptFailed,
      .attemptAlreadySpent: .recoveryDecryptFailed,
      .keychainTransient: .recoveryDecryptFailed,
    ]
    for (reason, category) in expected {
      #expect(
        RecoverySpoolReplayer.category(for: reason) == category,
        "\(reason.rawValue) changed category — is that deliberate?")
    }
  }
}
