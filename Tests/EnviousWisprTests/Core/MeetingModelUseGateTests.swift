import Foundation
import Testing

@testable import EnviousWisprCore

/// #3972 R26: when these fail, a model file is deleted or replaced while a meeting is reading
/// it, a meeting starts loading a model that is about to change, or a user's Cancel hangs for a
/// whole meeting.
@Suite("MeetingModelUseGate", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingModelUseGateTests {

  /// Runs `body` in a task and reports whether it finished before the gate's state settled;
  /// `settle` is a signal from the gate, never a timer.
  private actor Flag {
    var value = false
    func set() { value = true }
  }

  @Test("a meeting's use delays a change to its model; the change runs once the use ends")
  func useDelaysMutation() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginUse("v3")
    let done = Flag()
    let mutation = Task {
      try await gate.beginMutation("v3")
      await done.set()
      await gate.endMutation("v3")
    }
    await gate.waitForMutationRequest()
    #expect(await done.value == false)
    await gate.endUse("v3")
    try await mutation.value
    #expect(await done.value)
  }

  @Test("a change that has asked closes the model to new meeting loads until it ends")
  func pendingMutationBlocksNewUse() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginUse("v3")
    let mutation = Task {
      try await gate.beginMutation("v3")
      return true
    }
    await gate.waitForMutationRequest()
    let admitted = Flag()
    let newUse = Task {
      try await gate.beginUse("v3")
      await admitted.set()
    }
    await gate.endUse("v3")
    _ = try await mutation.value
    #expect(await admitted.value == false, "a new meeting load must wait for the change")
    await gate.endMutation("v3")
    try await newUse.value
    #expect(await admitted.value)
    await gate.endUse("v3")
  }

  @Test("a meeting reading one model never delays a change to another")
  func keysAreIndependent() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginUse("v3")
    try await gate.beginMutation("ultra")
    await gate.endMutation("ultra")
    await gate.endUse("v3")
  }

  @Test("changes never wait for each other at the gate")
  func mutationsDoNotExcludeEachOther() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginMutation("v3")
    try await gate.beginMutation("v3")
    await gate.endMutation("v3")
    await gate.endMutation("v3")
    try await gate.beginUse("v3")
    await gate.endUse("v3")
  }

  @Test("a cancelled waiting change withdraws: it changes nothing and meeting loads reopen")
  func cancelledMutationWithdraws() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginUse("v3")
    let mutation = Task { try await gate.beginMutation("v3") }
    await gate.waitForMutationRequest()
    mutation.cancel()
    await #expect(throws: CancellationError.self) { try await mutation.value }
    // A new use is admitted at once: the withdrawn claim no longer closes the model.
    try await gate.beginUse("v3")
    #expect(await gate.isInUse("v3"))
    await gate.endUse("v3")
    await gate.endUse("v3")
    #expect(await gate.isInUse("v3") == false)
  }

  @Test("a meeting load cancelled while a change runs withdraws: no use is counted or leaked")
  func cancelledUseWithdraws() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginMutation("v3")
    let use = Task { try await gate.beginUse("v3") }
    use.cancel()
    await #expect(throws: CancellationError.self) { try await use.value }
    #expect(await gate.isInUse("v3") == false)
    await gate.endMutation("v3")
    // The change ended and nothing holds the model: another change is granted at once.
    try await gate.beginMutation("v3")
    await gate.endMutation("v3")
  }

  @Test("a change cancelled before the last use ends is never granted")
  func cancelRacingLastReleaseIsNotGranted() async throws {
    let gate = MeetingModelUseGate()
    try await gate.beginUse("v3")
    let mutation = Task { try await gate.beginMutation("v3") }
    await gate.waitForMutationRequest()
    mutation.cancel()
    await gate.endUse("v3")
    await #expect(throws: CancellationError.self) { try await mutation.value }
    try await gate.beginUse("v3")
    await gate.endUse("v3")
  }
}
