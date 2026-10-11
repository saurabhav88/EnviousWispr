import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3546 chunk 7a: the Parakeet selection-policy owner with no upgrade target.
/// If it breaks, dictation loads the wrong directory or mode, or a direct load
/// (crash recovery, file import) reads a request an earlier selection
/// published instead of the one the current selection chose.
@MainActor
@Suite("Parakeet upgrade coordinator", .tags(.productOutcome))
struct ParakeetUpgradeCoordinatorTests {

  @Test("with no handle, a preparation publishes the legacy v3 request")
  func noHandlePublishesLegacyRequest() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    let prepared = try await coordinator.prepareLoad()
    guard let expected = ParakeetInstallLocation.directoryFromSystemApplicationSupport() else {
      #expect(prepared.selection == nil)
      #expect(selection.current == nil)
      return
    }
    let request = try #require(selection.current)
    #expect(prepared.selection == request)
    #expect(request.model == .v3)
    #expect(request.directory == expected)
    #expect(request.cacheOnly == false)
    #expect(request.repairable == false)
    #expect(request.displayBytes == 483_256_769)
  }

  @Test("a direct load with no pending selection point prepares nothing")
  func settleWithoutSelectionPointIsANoOp() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    #expect(coordinator.hasPendingSelectionPoint == false)
    try await coordinator.settlePendingSelection()
    #expect(selection.current == nil)
  }

  @Test("a pending selection point is prepared before a direct load, and only once")
  func settlePreparesThePendingSelectionOnce() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    coordinator.markSelectionPoint()
    coordinator.markSelectionPoint()  // a second launch poke coalesces
    #expect(coordinator.hasPendingSelectionPoint)
    try await coordinator.settlePendingSelection()
    #expect(coordinator.hasPendingSelectionPoint == false)
    let afterSettle = selection.current
    try await coordinator.settlePendingSelection()
    #expect(selection.current == afterSettle, "a settled point is not prepared again")
    if ParakeetInstallLocation.directoryFromSystemApplicationSupport() != nil {
      #expect(afterSettle?.generation == 1)
    }
  }

  @Test("a selection point marked after a preparation returned stays pending")
  func laterSelectionPointIsNotConsumedEarly() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    coordinator.markSelectionPoint()
    _ = try await coordinator.prepareLoad()
    coordinator.markSelectionPoint()
    #expect(coordinator.hasPendingSelectionPoint)
  }

  @Test("a selection point marked DURING a preparation is settled before any caller returns")
  func markDuringPreparationIsSettledBeforeReturn() async throws {
    let gate = StageGate()
    let coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: ParakeetSelectionProvider(), delivery: nil)
    coordinator.deliveryStageGateForTesting = { await gate.pass() }
    coordinator.markSelectionPoint()
    let runner = Task { try await coordinator.prepareLoad() }
    await gate.waitForEntry(1)
    let joiner = Task { try await coordinator.prepareLoad() }
    await gate.waitForParked(coordinator, 1)
    coordinator.markSelectionPoint()  // arrives while the first stage runs
    gate.open()
    _ = try await runner.value
    _ = try await joiner.value
    #expect(gate.entries == 2, "the stage ran again for the point marked during it")
    #expect(coordinator.hasPendingSelectionPoint == false)
  }

  @Test("cancelling a waiting caller cancels only that caller")
  func cancellingAJoinerLeavesTheRunner() async throws {
    let gate = StageGate()
    let coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: ParakeetSelectionProvider(), delivery: nil)
    coordinator.deliveryStageGateForTesting = { await gate.pass() }
    let runner = Task { try await coordinator.prepareLoad() }
    await gate.waitForEntry(1)
    let joiner = Task { try await coordinator.prepareLoad() }
    await gate.waitForParked(coordinator, 1)
    joiner.cancel()
    await #expect(throws: CancellationError.self) { _ = try await joiner.value }
    gate.open()
    _ = try await runner.value
    #expect(gate.entries == 1)
  }

  @Test("a cancelled runner lets an uncancelled waiter run the stage itself")
  func cancelledRunnerHandsOverToAWaiter() async throws {
    let gate = StageGate()
    let coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: ParakeetSelectionProvider(), delivery: nil)
    coordinator.deliveryStageGateForTesting = { await gate.pass() }
    let runner = Task { try await coordinator.prepareLoad() }
    await gate.waitForEntry(1)
    let joiner = Task { try await coordinator.prepareLoad() }
    await gate.waitForParked(coordinator, 1)
    runner.cancel()
    gate.open()
    await #expect(throws: CancellationError.self) { _ = try await runner.value }
    _ = try await joiner.value
    #expect(gate.entries == 2, "the waiter ran the stage after the runner's cancel")
  }
}

/// Holds every delivery stage at its start until `open()`, counting entries, and
/// observes callers parking behind a running stage. Signals come from the
/// subject (`deliveryStageGateForTesting`, `onWaiterParkedForTesting`), never
/// from timing.
@MainActor
private final class StageGate {
  private(set) var entries = 0
  private var isOpen = false
  private var parked = 0
  private var held: [CheckedContinuation<Void, Never>] = []
  private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var parkWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func pass() async {
    entries += 1
    resumeReached(&entryWaiters, entries)
    if isOpen { return }
    await withCheckedContinuation { held.append($0) }
  }

  func open() {
    isOpen = true
    let released = held
    held = []
    for continuation in released { continuation.resume() }
  }

  func waitForEntry(_ count: Int) async {
    if entries >= count { return }
    await withCheckedContinuation { entryWaiters.append((count, $0)) }
  }

  func waitForParked(_ coordinator: ParakeetUpgradeCoordinator, _ count: Int) async {
    coordinator.onWaiterParkedForTesting = { [weak self] in
      guard let self else { return }
      self.parked += 1
      self.resumeReached(&self.parkWaiters, self.parked)
    }
    if parked >= count { return }
    await withCheckedContinuation { parkWaiters.append((count, $0)) }
  }

  private func resumeReached(
    _ waiters: inout [(Int, CheckedContinuation<Void, Never>)], _ value: Int
  ) {
    let ready = waiters.filter { $0.0 <= value }
    waiters.removeAll { $0.0 <= value }
    for (_, continuation) in ready { continuation.resume() }
  }
}
