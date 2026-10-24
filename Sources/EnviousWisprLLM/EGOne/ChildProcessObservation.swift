import EnviousWisprCore
import Foundation
import os

/// One transient record per owned Process. The callback snapshots before its actor hop.
/// Acceptance and intentional-stop suppression share one lock; reporting runs outside it.
/// #3988: the accepted record is kept, so the lifecycle path and the diagnostic
/// path read the SAME frozen facts; neither re-derives them from the Process.
final class ChildProcessObservation: Sendable {
  private struct State {
    var phase: ChildProcessFailure.Phase
    var suppressed = false
    var accepted: ChildProcessFailure?
  }
  private let state: OSAllocatedUnfairLock<State>
  private let provider: LLMProvider?
  private let generation: Int
  private let report: (@Sendable (ChildProcessFailure) -> Void)?

  init(provider: LLMProvider?, generation: Int, report: (@Sendable (ChildProcessFailure) -> Void)?)
  {
    self.provider = provider
    self.generation = generation
    self.report = report
    state = OSAllocatedUnfairLock(initialState: State(phase: .starting))
  }

  func publish(_ phase: ChildProcessFailure.Phase) { state.withLock { $0.phase = phase } }
  func suppressIntentionalStop() { state.withLock { $0.suppressed = true } }

  /// The accepted record, accepting it now if this is the first observation.
  /// Nil only when an intentional stop was suppressed before any acceptance.
  @discardableResult
  func recordTermination(_ process: Process) -> ChildProcessFailure? {
    recordTermination(
      reason: process.terminationReason == .uncaughtSignal ? .signal : .exit,
      status: process.terminationStatus, pid: process.processIdentifier)
  }

  @discardableResult
  func recordTermination(
    reason: ChildProcessFailure.Termination, status: Int32, pid: Int32
  ) -> ChildProcessFailure? {
    let (record, isNew) = state.withLock { state -> (ChildProcessFailure?, Bool) in
      if let accepted = state.accepted { return (accepted, false) }
      guard !state.suppressed else { return (nil, false) }
      let record = ChildProcessFailure(
        role: .server, provider: provider, generation: generation, phase: state.phase,
        termination: reason, status: status, pid: pid)
      state.accepted = record
      return (record, true)
    }
    if isNew, let record { report?(record) }
    return record
  }
}
