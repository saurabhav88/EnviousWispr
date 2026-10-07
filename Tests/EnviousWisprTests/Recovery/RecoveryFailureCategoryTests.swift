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
/// "ASR threw" and "ASR returned an empty result", and #1813 was read as
/// a 76-user P0 transcription bug when genuine throws were 5 events / 2 users.
///
/// Every test here carries a NEGATIVE arm. A mapping that returned one category
/// for everything, or that renamed the tokens wholesale, would satisfy the
/// positive assertions alone while destroying the split this change exists to
/// create.
@Suite struct RecoveryFailureCategoryTests {

  // MARK: - The split itself

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
      // #2087: its OWN category, not the decrypt catch-all. Nothing is decrypted
      // on this path — the spool is refused at the entry guard — and folding it
      // into the decrypt bucket would inflate a count meaning "the audio would
      // not come back", the conflation that made #1813 read as a 76-user P0.
      .malformedEscapeMarker: .recoveryMalformedEscapeMarker,
      .escapeRecoveryExpired: .recoveryEscapeRecoveryExpired,
    ]
    #expect(
      expected.count == RecoveryTelemetryReason.allCases.count,
      "every reason must appear above — a missing one inherits its bucket unseen")
    for (reason, category) in expected {
      #expect(
        RecoverySpoolReplayer.category(for: reason) == category,
        "\(reason.rawValue) changed category — is that deliberate?")
    }
  }

  @Test("only the empty-result outcome is counted without alerting (#1942)")
  func onlyEmptyTextIsCountedNotAlerted() {
    // `empty_text` means ASR ran cleanly and returned nothing — almost always a
    // recording with no speech in it, and re-triaged to the same P3 verdict on
    // four consecutive days. It is counted by `recovery.completed` (measured
    // 13 events / 5 people on 2.4.3, matching the Sentry fingerprint exactly),
    // so removing its alert loses no visibility.
    #expect(RecoverySpoolReplayer.isCountedNotAlerted(.emptyText))
    // #2087: a Mac left off past the 24-hour window is the world being ordinary.
    #expect(RecoverySpoolReplayer.isCountedNotAlerted(.escapeRecoveryExpired))

    // THE TWO-WAY CONTROL, and the whole safety of this change: every reason
    // that IS ours must still alert. A blanket downgrade would pass the
    // assertion above while silencing a real ASR throw or a decrypt failure.
    let mustAlert: [RecoveryTelemetryReason] = [
      .keyMissing, .keyReadFailed, .reconstructionFailed, .emptyOrUnreadableSamples,
      .modelLoadFailed, .transcribeError, .saveFailed, .markerWriteFailed,
      .markerClearFailed, .attemptAlreadySpent, .keychainTransient,
      // #2087: a marker WE wrote durably that will not read back is our defect,
      // never a user's environment.
      .malformedEscapeMarker,
    ]
    for reason in mustAlert {
      #expect(
        !RecoverySpoolReplayer.isCountedNotAlerted(reason),
        "\(reason.rawValue) must keep alerting — it is a failure we own")
    }

    // Completeness: the two lists together must cover the enum, so a NEW reason
    // cannot be silently added to neither and inherit a channel by accident.
    // `isCountedNotAlerted` switches exhaustively with no `default`, so a new
    // case is already a compile error there; this asserts the TEST stays
    // exhaustive too, which the compiler cannot do for an array literal.
    // #2087 fixed this guard, which had gone stale WITHOUT failing. It read
    // `mustAlert.count + 1 == 12` — a literal compared against the list it was
    // meant to police. Adding a 13th reason and forgetting to list it left the
    // list at 11, so `11 + 1 == 12` still passed and the new reason inherited a
    // channel silently. The guard's one job was to catch exactly that.
    //
    // Now compared against the ENUM, so the number cannot drift from reality: a
    // new case changes `allCases.count` and this fails until someone assigns it
    // a channel on purpose. Ask of any count guard which direction it does NOT
    // check; this one checked none.
    // `+ 2` = the two counted-not-alerted reasons asserted above.
    #expect(
      mustAlert.count + 2 == RecoveryTelemetryReason.allCases.count,
      "a reason was added — give it a channel here")
  }
}
