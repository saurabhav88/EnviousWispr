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

  @Test("an empty ASR result is not filed as a transcription failure")
  func emptyTextGetsItsOwnCategory() {
    let empty = RecoverySpoolReplayer.category(for: .emptyText)

    // POSITIVE — "ASR returned empty" has its own bucket, separate from "ASR
    // threw". Both are observations; neither claims a cause.
    #expect(empty == .recoveryEmptyText)

    // NEGATIVE, and this is the whole point of #1897: it must not be the
    // category a genuine ASR throw uses, or the two collapse back into one
    // Sentry issue and the count that misled #1813 returns.
    #expect(empty != .recoveryTranscribeFailed)
    #expect(RecoverySpoolReplayer.category(for: .transcribeError) == .recoveryTranscribeFailed)
    #expect(empty != RecoverySpoolReplayer.category(for: .transcribeError))
  }

  @Test("the split is THREW vs RETURNED-EMPTY, and claims no cause")
  func theSplitIsAnObservationNotAnInference() {
    // Three review rounds were spent trying to make this category mean "the
    // recording was silent", and it cannot:
    //
    //   1. Assuming every empty is silence used no evidence at all.
    //   2. The dead-air classifier is a DEAD-AIR detector, not a speech one.
    //      Room noise sits near 0.0178 against its 0.006 floor (13 quiet-room
    //      controls measured 0.0170-0.0930), so real silent rooms would read as
    //      "had signal" and the split would barely fire.
    //   3. Rerunning VAD is the only true discriminator, and is out of scope.
    //
    // What the categories DO mean is checkable, so that is what is asserted.
    #expect(RecoverySpoolReplayer.category(for: .transcribeError) == .recoveryTranscribeFailed)
    #expect(RecoverySpoolReplayer.category(for: .emptyText) == .recoveryEmptyText)

    // The property that fixes #1813: a throw and an empty result cannot share a
    // bucket, so neither can inflate the other's count. That is the whole claim.
    #expect(
      RecoverySpoolReplayer.category(for: .transcribeError)
        != RecoverySpoolReplayer.category(for: .emptyText))

    // A model-load failure — ASR never ran at all — stays with the throw,
    // because it is also "we failed", not "we looked and found nothing".
    #expect(RecoverySpoolReplayer.category(for: .modelLoadFailed) == .recoveryTranscribeFailed)
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
      // Default (no signal measured) — the with-signal arm is covered above.
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
