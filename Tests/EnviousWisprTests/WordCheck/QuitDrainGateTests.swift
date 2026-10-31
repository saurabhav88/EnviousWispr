import Foundation
import Testing

@testable import EnviousWisprWordCheck

/// Quit waits for word check work still running, and refuses work that starts after it (#3939).
/// When these fail, `exit()` can finalize MLX's scheduler while a take is still encoding into it
/// and the app crashes at quit. Each test uses its own gate, never the process-wide one, which
/// would refuse every later test's evaluation.
@Suite(
  "Quit drain gate: quit waits for MLX work and refuses new work (#3939)", .tags(.productOutcome))
struct QuitDrainGateTests {
  /// Returns once the gate refuses new work: the drain set its flag, and waits right after.
  private func waitUntilRefusing(_ gate: QuitDrainGate) {
    while gate.enter() { gate.leave() }
  }

  @Test("a quit with nothing running returns at once")
  func idleDrainReturnsAtOnce() {
    let gate = QuitDrainGate()
    #expect(gate.drain(timeout: 5))
  }

  @Test("work that starts after quit began is refused")
  func newWorkRefusedAfterDrain() {
    let gate = QuitDrainGate()
    _ = gate.drain(timeout: 1)
    #expect(gate.enter() == false)
  }

  @Test("quit cleanup is still admitted after quit began, and the drain waits for it")
  func cleanupAdmittedAndAwaited() async {
    let gate = QuitDrainGate()
    let drain = Task.detached { gate.drain(timeout: 5) }
    waitUntilRefusing(gate)
    #expect(gate.enter(duringQuit: true))
    gate.leave()
    #expect(await drain.value)
  }

  @Test("a quit waits for the evaluation running, then returns true")
  func drainWaitsForRunningWork() async {
    let gate = QuitDrainGate()
    #expect(gate.enter())
    let finished = Task.detached { gate.drain(timeout: 5) }
    waitUntilRefusing(gate)
    gate.leave()
    #expect(await finished.value)
  }

  @Test("a quit gives up after the timeout when work never ends, and says so")
  func drainTimesOut() {
    let gate = QuitDrainGate()
    #expect(gate.enter())
    #expect(gate.drain(timeout: 0.1) == false)
    gate.leave()
  }
}
