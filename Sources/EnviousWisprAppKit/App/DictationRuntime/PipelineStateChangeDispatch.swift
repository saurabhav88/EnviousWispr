import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// Assembles the arguments for one `PipelineStateChangeHandler.handle(...)` call
/// from the driver that produced the transition.
///
/// Extracted from `DictationLifecycleCoordinator` (#2087). The Parakeet and
/// WhisperKit paths built this identical argument list twice, differing only in
/// which driver they read, so every field added to the contract had to be added
/// in two places and could be added correctly in one. That is a defect waiting
/// on the next contributor, not a style preference — `salvagedLead` and
/// `interruptionDisclosure` were each written twice before this one.
///
/// It also answers the coordinator's line ceiling by removing code rather than
/// raising the cap — `DictationLifecycleCoordinatorCeilingsTests` allows a raise
/// only via Bible §30, and nothing here warrants one. It adds no collaborator (a
/// namespace with one static method holds no state) and no import the
/// coordinator did not already have.
@MainActor
enum PipelineStateChangeDispatch {

  /// Run one state-change handler against its driver's current readings.
  ///
  /// **The Escape Recovery completion is TAKEN here, and taking is destructive**
  /// (#2087). Today the take always answers nil — nothing produces a completion
  /// yet. This is the window such a producer has to aim at: the
  /// terminal cleanup nils the paste target before `onStateChange` fires, so a
  /// completion frozen after it would carry nothing, and one read later than
  /// here would find nothing. A second notification for the same session takes
  /// nil, which is what stops one cancelled dictation being offered back twice.
  static func run(
    _ handler: PipelineStateChangeHandler,
    driver: KernelDictationDriver,
    to newState: PipelineState
  ) {
    handler.handle(
      to: newState,
      pipelineOverlayIntent: driver.overlayIntent,
      lastPolishError: driver.lastPolishError,
      currentTranscript: driver.currentTranscript,
      historySaved: driver.lastHistorySaved,
      historySaveReason: driver.lastHistorySaveReason,
      salvagedLead: driver.lastSalvagedLeadTrimMs != nil,
      // #1408 (A1): the full typed disclosure, not a Bool. nil = normal
      // completion; `.deviceRemoved` = verified removal (may say "Microphone
      // disconnected"); `.otherInterruption` = salvaged with the mic, as far as
      // we know, still attached (neutral copy). The factory owns the sentences.
      // #1317: a `becameZeroMidCapture` completion never stamps an
      // `EngineInterruptionCause` (§3.4 — no synthesized cause), so it is read
      // directly off the zero-signal side-channel instead of going through
      // `CompletionInterruptionDisclosure.init(cause:)` (§3.5).
      interruptionDisclosure: driver.lastZeroSignalFailureMode == .becameZeroMidCapture
        ? .otherInterruption
        : CompletionInterruptionDisclosure(cause: driver.lastAudioInterruptionCause),
      escapeRecoveryCompletion: driver.takeEscapeRecoveryCompletion())
  }
}
