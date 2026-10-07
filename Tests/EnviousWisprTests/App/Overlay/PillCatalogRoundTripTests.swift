import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// The bijection between `OverlayIntent` and `PillCatalogRequest`, checked
/// rather than intended (#2375 Phase 3, chunk C2).
///
/// **Two mappings exist and they must agree.** `PillCatalogRequest(nonRecording:)`
/// converts an intent into a request; `matchingIntent` converts it back so the
/// catalog can ask `DictationNarrator` — still the sole author of announcement
/// TEXT — for the sentence. Written twice, they are a duplicate-authority risk of
/// exactly the kind this phase exists to remove, so the agreement is a test
/// rather than a comment.
///
/// **Drift Guard, not Product Outcome.** A failure here means our own two
/// mappings disagree, which is a fact about the code and not about what a user
/// sees. The user-facing consequence — the wrong pill, or the wrong sentence — is
/// `PillCatalogParityTests`.
@Suite(.tags(.driftGuard))
struct PillCatalogRoundTripTests {

  /// Every `OverlayIntent` arm, with a payload where it takes one.
  ///
  /// **Hand-written.** `OverlayIntent` is not `CaseIterable` (several arms carry
  /// payloads with no canonical value), so this list cannot be derived; a new arm
  /// must be added here by hand. Its completeness check was retired in #3505.
  private static let intents: [OverlayIntent] = [
    .hidden,
    .recording(audioLevel: 0),
    .processing(phase: .transcribing),
    .clipboardFallback,
    .accessibilityToast,
    .warning(reason: .polishFailed),
    .error(reason: .asrFailed),
    .advisory(reason: .zeroSignal),
    .interruption(reason: .deviceRemoved),
    .passiveChip(
      payload: LanguageChipPayload(
        lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)),
    .cachingModel(engineLabel: "Parakeet"),
    .engineReady,
    .recoveringLastRecording,
    .recoverySucceeded,
    .bluetoothAwareness,
    .escapeRecovery(transcriptID: UUID()),
  ]

  @Test("every intent except recording round-trips through a catalog request")
  func intentRoundTrip() {
    for intent in Self.intents {
      guard let request = PillCatalogRequest(nonRecording: intent) else {
        // The ONE legal refusal: recording is permanently outside this
        // initialiser's domain, because a recording request needs a resolved
        // design and an intent alone has not resolved one.
        #expect(
          Self.isRecording(intent),
          "PillCatalogRequest(nonRecording:) refused a non-recording intent")
        continue
      }
      #expect(
        request.matchingIntent == intent,
        "the two mappings disagree about this intent")
    }
  }

  @Test("the three feature-only requests have no matching intent; every pipeline-derived one keeps its intent")
  func featureOnlyRequestsHaveNoMatchingIntent() {
    let featureOnly: [PillCatalogRequest] = [
      .importStatus(message: "x"),
      // #996 auto-learn: the Undo pill and its save error are feature routes
      // with no pipeline intent.
      .correctionLearned(LearnedPillFixture.model()),
      .correctionLearnedSaveError(
        LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed)),
    ]
    #expect(featureOnly.allSatisfy { $0.matchingIntent == nil })
    for intent in Self.intents where !Self.isRecording(intent) {
      let request = PillCatalogRequest(nonRecording: intent)
      #expect(request?.matchingIntent != nil, "a pipeline-derived request lost its intent")
    }
  }


  private static func isRecording(_ intent: OverlayIntent) -> Bool {
    if case .recording = intent { return true }
    return false
  }
}
