import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// When the cancel shortcut is armed (#2087, chunk 7b).
///
/// A truth table over state × capability, which is the whole reason the rule was
/// extracted: before this it lived inside two per-backend `switch newState`
/// blocks and could only be reached by driving an entire dictation lifecycle.
/// Enumerated rather than spot-checked, so a future `PipelineState` case cannot
/// be added without deciding what the affordance does in it.
@MainActor
/// Class: `.productOutcome` — the user presses their cancel key and nothing happens, or it fires twice.
@Suite("Cancel affordance policy (#2087)", .tags(.productOutcome))
struct CancelAffordancePolicyTests {

  /// Every state. The pairs are written out rather than generated so the
  /// expected answer is visible next to its input — a table that computes its
  /// own expectations agrees with itself by construction.
  ///
  /// #2787 made `.transcribing` armed for every take, so the capability that
  /// used to split it (`isEscapeRecoveryTranscribing`) no longer reaches this
  /// half of the policy; it still decides `isAbandonment` below.
  private static let cases: [(state: PipelineState, armed: Bool)] = [
    (.recording, true),
    (.transcribing, true),
    (.loadingModel, false),
    (.polishing, false),
    (.idle, false),
    (.complete, false),
    (.error(.asrFailed), false),
    (.advisory(.zeroSignal), false),
  ]

  @Test("the affordance table holds for every state")
  func truthTable() {
    for c in Self.cases {
      #expect(
        CancelAffordancePolicy.isShortcutEnabled(state: c.state) == c.armed,
        "state \(c.state) must be armed=\(c.armed)")
    }
  }

  /// #2787: the key is live through an ORDINARY transcription. Before this,
  /// Escape during a stuck decode did nothing at all, and the customer's only
  /// exit was to quit the app four times.
  @Test("an ordinary transcription keeps the cancel shortcut live")
  func ordinaryTranscribingIsArmed() {
    #expect(CancelAffordancePolicy.isShortcutEnabled(state: .transcribing))
  }

  /// The other half of the policy, and the reason both halves live together:
  /// the state the finalizer must admit is exactly the state the key stays live
  /// for. If this ever answered false where `isShortcutEnabled(.transcribing)`
  /// answers true, the key would be armed and inert.
  @Test("the two halves agree: a shortcut cancel during a live recovery is an abandonment")
  func halvesAgree() {
    #expect(
      CancelAffordancePolicy.isAbandonment(
        trigger: .shortcut, isEscapeRecoveryTranscribing: true))
    #expect(
      CancelAffordancePolicy.isShortcutEnabled(state: .transcribing),
      "the state the finalizer must admit is exactly the state the key stays live for")
  }

  /// The Cancel BUTTON stays destructive — a founder-settled boundary, and the
  /// one place trigger identity changes the answer.
  @Test("the cancel button never abandons, whatever the recovery is doing")
  func buttonNeverAbandons() {
    #expect(
      CancelAffordancePolicy.isAbandonment(
        trigger: .cancelButton, isEscapeRecoveryTranscribing: true) == false)
    #expect(
      CancelAffordancePolicy.isAbandonment(
        trigger: .shortcut, isEscapeRecoveryTranscribing: false) == false,
      "and a shortcut outside a recovery is an ordinary cancel")
  }
}
