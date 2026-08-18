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

  /// Every state, both capability values. The pairs are written out rather than
  /// generated so the expected answer is visible next to its input — a table
  /// that computes its own expectations agrees with itself by construction.
  private static let cases: [(state: PipelineState, recovery: Bool, armed: Bool)] = [
    (.recording, false, true),
    (.recording, true, true),
    (.transcribing, false, false),
    (.transcribing, true, true),
    (.loadingModel, false, false),
    (.loadingModel, true, false),
    (.polishing, false, false),
    (.polishing, true, false),
    (.idle, false, false),
    (.idle, true, false),
    (.complete, false, false),
    (.complete, true, false),
    (.error(.asrFailed), false, false),
    (.error(.asrFailed), true, false),
    (.advisory(.zeroSignal), false, false),
    (.advisory(.zeroSignal), true, false),
  ]

  @Test("the affordance table holds for every state and both capability values")
  func truthTable() {
    for c in Self.cases {
      #expect(
        CancelAffordancePolicy.isShortcutEnabled(
          state: c.state, isEscapeRecoveryTranscribing: c.recovery) == c.armed,
        "state \(c.state) with recovery=\(c.recovery) must be armed=\(c.armed)")
    }
  }

  /// `.transcribing` is the ONLY state whose answer depends on the capability,
  /// and that is the entire behavioural change this policy introduces. Asserted
  /// directly so a future edit that made some other state capability-dependent
  /// has to come here and say so.
  @Test("transcribing is the only state the capability can change")
  func onlyTranscribingIsCapabilityDependent() {
    let states: [PipelineState] = [
      .recording, .transcribing, .loadingModel, .polishing, .idle, .complete,
      .error(.asrFailed), .advisory(.zeroSignal),
    ]
    let dependent = states.filter { state in
      CancelAffordancePolicy.isShortcutEnabled(state: state, isEscapeRecoveryTranscribing: true)
        != CancelAffordancePolicy.isShortcutEnabled(
          state: state, isEscapeRecoveryTranscribing: false)
    }
    #expect(dependent == [.transcribing])
  }

  /// The other half of the policy, and the reason both halves live together:
  /// `RecordingFinalizer` admits only `.recording` and `.loadingModel`, so if
  /// this ever answered false where `isShortcutEnabled(.transcribing, true)`
  /// answers true, the key would be armed and inert — a user pressing Escape
  /// and nothing happening at all.
  @Test("the two halves agree: a shortcut cancel during a live recovery is an abandonment")
  func halvesAgree() {
    #expect(
      CancelAffordancePolicy.isAbandonment(
        trigger: .shortcut, isEscapeRecoveryTranscribing: true))
    #expect(
      CancelAffordancePolicy.isShortcutEnabled(
        state: .transcribing, isEscapeRecoveryTranscribing: true),
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

  /// The inert claim, checked rather than asserted in prose: with the capability
  /// false — which is every take until chunk 12 ships the setting — the policy
  /// returns exactly what the six register/unregister calls it replaced did.
  /// Armed in `.recording`, down everywhere else.
  @Test("with the capability off the policy reproduces today's behaviour exactly")
  func inertWithoutTheCapability() {
    for c in Self.cases where !c.recovery {
      let expected = (c.state == .recording)
      #expect(
        CancelAffordancePolicy.isShortcutEnabled(
          state: c.state, isEscapeRecoveryTranscribing: false) == expected)
    }
  }
}
