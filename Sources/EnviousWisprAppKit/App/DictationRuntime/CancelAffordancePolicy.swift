import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// When the cancel shortcut is armed (#2087).
///
/// Extracted from the two `switch newState` blocks in
/// `DictationLifecycleCoordinator` that decided it inline, once per backend.
/// The rule Escape Recovery needs — **the cancel affordance stays live while a
/// recovery is transcribing** — could not be added to either without adding it
/// to both, in a file that had one line of headroom.
///
/// Giving the decision a name buys more than the lines back. It becomes a truth
/// table over state × capability that a test can enumerate directly, instead of
/// a rule reachable only by driving a whole dictation lifecycle; and the next
/// feature that needs a phase-dependent affordance extends a policy rather than
/// growing a switch for a third time.
///
/// **Consumes the PUBLIC `PipelineState` and one narrow driver capability, never
/// the kernel's internal disposition.** `EscapeRecoveryBoundaryFreezeTests`
/// enforces that boundary: AppKit asks "may the affordance stay live", not
/// "which disposition is this". Branching on the disposition here would put an
/// engine-lifetime decision outside the engine.
///
/// Caseless and pure, so it adds no collaborator to the coordinator's cap of 11
/// and nothing to its stored state.
enum CancelAffordancePolicy {

  /// Whether the cancel shortcut should be armed for this state.
  ///
  /// `.transcribing` is the only state whose answer depends on anything beyond
  /// the state itself. During an ordinary transcription there is nothing a
  /// cancel could do — the audio is already captured and the decode is not
  /// interruptible — so the shortcut stays down, exactly as today. During an
  /// Escape Recovery the same keypress means something new: discard the text
  /// this recovery is producing.
  ///
  /// `isEscapeRecoveryTranscribing` is false for every take the setting is off
  /// for, which is the default, so those takes get today's answers unchanged.
  static func isShortcutEnabled(
    state: PipelineState,
    isEscapeRecoveryTranscribing: Bool
  ) -> Bool {
    switch state {
    case .recording:
      return true
    case .transcribing:
      return isEscapeRecoveryTranscribing
    case .loadingModel, .polishing, .error, .idle, .complete, .advisory:
      // Every other state disarms, including all four terminals. Enumerated
      // rather than defaulted so a future `PipelineState` case is a compile
      // error here and has to be decided, instead of silently inheriting
      // "disarmed" — which is the safe answer only until it is not.
      return false
    }
  }

  /// Whether this cancel is an ABANDONMENT rather than an ordinary one.
  ///
  /// Lives here because it is the other half of `isShortcutEnabled`, and the
  /// two must agree or the shortcut is armed against a finalizer that refuses
  /// it: `RecordingFinalizer.cancel` admits only `.recording` and
  /// `.loadingModel`, so a key left live through `.transcribing` would be armed
  /// and inert — a user pressing Escape and nothing happening at all.
  ///
  /// An abandonment must ALSO skip that method's teardown. The session is still
  /// running until its decode returns, so hiding its overlay and clearing its
  /// chip would strip a live dictation of the affordances telling the user it
  /// is still working.
  ///
  /// Shortcut only, matching the affordance. The Cancel BUTTON stays
  /// destructive: a click on a control labelled Cancel says exactly one thing,
  /// while Escape is also how people dismiss popovers and back out of fields,
  /// which is the whole reason recovery is offered for it.
  ///
  /// **The answer has to travel back out to `HotkeyController`, and this is why.**
  /// An abandonment publishes NO state change — the session stays
  /// `.transcribing` until its decode returns, which is the entire point — so
  /// `fireStateChangeIfNeeded()` dedupes the unchanged state, the affordance
  /// policy never re-runs, and nothing would take the key down. The controller
  /// therefore disarms on the result rather than waiting for a transition that
  /// is never coming. Without that, a third press lands on a session that
  /// already granted the request.
  static func isAbandonment(
    trigger: UserCancelTrigger,
    isEscapeRecoveryTranscribing: Bool
  ) -> Bool {
    trigger == .shortcut && isEscapeRecoveryTranscribing
  }
}
