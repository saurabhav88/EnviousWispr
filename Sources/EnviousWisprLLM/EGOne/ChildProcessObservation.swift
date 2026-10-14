import EnviousWisprCore
import Foundation
import os

/// One transient record per owned Process. The callback snapshots before its actor hop.
/// Acceptance and intentional-stop suppression share one lock; reporting runs outside it.
final class ChildProcessObservation: Sendable {
  private struct State { var phase: ChildProcessFailure.Phase; var suppressed = false; var accepted = false }
  private let state: OSAllocatedUnfairLock<State>
  private let provider: LLMProvider?
  private let generation: Int
  private let report: (@Sendable (ChildProcessFailure) -> Void)?

  init(provider: LLMProvider?, generation: Int, report: (@Sendable (ChildProcessFailure) -> Void)?) {
    self.provider = provider
    self.generation = generation
    self.report = report
    state = OSAllocatedUnfairLock(initialState: State(phase: .starting))
  }

  func publish(_ phase: ChildProcessFailure.Phase) { state.withLock { $0.phase = phase } }
  func suppressIntentionalStop() { state.withLock { $0.suppressed = true } }

  func recordTermination(_ process: Process) {
    recordTermination(
      reason: process.terminationReason == .uncaughtSignal ? .signal : .exit,
      status: process.terminationStatus, pid: process.processIdentifier)
  }

  func recordTermination(reason: ChildProcessFailure.Termination, status: Int32, pid: Int32) {
    let phase = state.withLock { state -> ChildProcessFailure.Phase? in
      guard !state.suppressed, !state.accepted else { return nil }
      state.accepted = true
      return state.phase
    }
    guard let phase else { return }
    report?(ChildProcessFailure(
      role: .server, provider: provider, generation: generation, phase: phase,
      termination: reason, status: status, pid: pid))
  }
}
