import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprModelDelivery
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

  @Test("a pending selection point is prepared once, and a later load reuses the frozen request")
  func pendingSelectionPreparedOnce() async throws {
    let rig = try await ParakeetUpgradePolicyTests.rig(v3: true, ultra: false)
    rig.coordinator.markSelectionPoint()
    rig.coordinator.markSelectionPoint()  // a second launch poke coalesces
    #expect(rig.coordinator.hasPendingSelectionPoint)
    let first = try await rig.coordinator.prepareLoad()
    #expect(first.isSelectionLoad)
    #expect(rig.coordinator.hasPendingSelectionPoint == false)
    let afterSettle = rig.selection.current
    let reload = try await rig.coordinator.prepareLoad()
    #expect(reload.isSelectionLoad == false, "no new selection: the frozen request")
    #expect(rig.selection.current == afterSettle, "a settled point is not prepared again")
  }

  @Test("a pending selection point is prepared once before a direct load")
  func prepareLoadConsumesOnePendingSelection() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    let gate = StageGate(maximumEntries: 1)
    gate.open()
    coordinator.deliveryStageGateForTesting = { await gate.pass() }
    coordinator.markSelectionPoint()
    coordinator.markSelectionPoint()  // a second launch poke coalesces
    #expect(coordinator.hasPendingSelectionPoint)
    let prepared = try await coordinator.prepareLoad()
    #expect(gate.entries == 1)
    #expect(coordinator.hasPendingSelectionPoint == false)
    #expect(prepared.isSelectionLoad)
    #expect(selection.current == prepared.selection)
    if ParakeetInstallLocation.directoryFromSystemApplicationSupport() != nil {
      #expect(prepared.selection?.generation == 1)
    }
  }

  @Test("a selection point marked after a preparation returned stays pending")
  func laterSelectionPointIsNotConsumedEarly() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    let gate = StageGate(maximumEntries: 1)
    gate.open()
    coordinator.deliveryStageGateForTesting = { await gate.pass() }
    coordinator.markSelectionPoint()
    _ = try await coordinator.prepareLoad()
    #expect(gate.entries == 1)
    coordinator.markSelectionPoint()
    #expect(coordinator.hasPendingSelectionPoint)
  }

  @Test("a selection point marked DURING a preparation is settled before any caller returns")
  func markDuringPreparationIsSettledBeforeReturn() async throws {
    for withJoiner in [false, true] {
      let gate = StageGate(maximumEntries: 2)
      let selection = ParakeetSelectionProvider()
      let coordinator = ParakeetUpgradeCoordinator(
        parakeetSelection: selection, delivery: nil)
      coordinator.deliveryStageGateForTesting = { await gate.pass() }
      coordinator.markSelectionPoint()
      let runner = Task { try await coordinator.prepareLoad() }
      await gate.waitForEntry(1)
      let joiner = withJoiner
        ? Task { try await coordinator.prepareLoad() } : nil
      if withJoiner {
        await gate.waitForParked(coordinator, 1)
      }
      coordinator.markSelectionPoint()
      gate.open()
      let runnerResult = await runner.result
      let joinerResult = await joiner?.result
      let prepared = try runnerResult.get()
      #expect(prepared.isSelectionLoad == true)
      #expect(prepared.selection == selection.current)
      if let joinerResult {
        let joined = try joinerResult.get()
        #expect(joined.isSelectionLoad == prepared.isSelectionLoad)
        #expect(joined.selection == selection.current)
      }
      #expect(
        gate.entries == 2,
        "the stage ran again for the point marked during it")
      #expect(coordinator.hasPendingSelectionPoint == false)
    }
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
    let gate = StageGate(maximumEntries: 2)
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: selection, delivery: nil)
    coordinator.deliveryStageGateForTesting = { await gate.pass() }
    let runner = Task { try await coordinator.prepareLoad() }
    await gate.waitForEntry(1)
    let joiner = Task { try await coordinator.prepareLoad() }
    await gate.waitForParked(coordinator, 1)
    runner.cancel()
    gate.open()
    let ownerResult = await runner.result
    let joinedResult = await joiner.result
    #expect(throws: CancellationError.self) { _ = try ownerResult.get() }
    let prepared = try joinedResult.get()
    #expect(prepared.selection == selection.current)
    #expect(prepared.isSelectionLoad == true)
    #expect(coordinator.hasPendingSelectionPoint == false)
    #expect(gate.entries == 2)
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
  private var expired = false
  private var parked = 0
  private var held: [CheckedContinuation<Void, Never>] = []
  private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var parkWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var deadlineTask: Task<Void, Never>?
  private let maximumEntries: Int?
  private let sourceLocation: SourceLocation

  init(
    deadline: Duration = .seconds(5),
    maximumEntries: Int? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    self.maximumEntries = maximumEntries
    self.sourceLocation = sourceLocation
    deadlineTask = Task { @MainActor [weak self] in
      do {
        // deadline-fallback: fail loudly and release a missing-signal wait.
        try await Task.sleep(for: deadline)
      } catch {
        return
      }
      self?.failAndRelease(sourceLocation: sourceLocation)
    }
  }

  var heldCountForTesting: Int { held.count }

  func waitForDeadlineForTesting() async {
    await deadlineTask?.value
  }

  private func rejectExpired(_ operation: String) -> Bool {
    guard expired else { return false }
    Issue.record(
      "StageGate \(operation) arrived after deadline",
      sourceLocation: sourceLocation)
    return true
  }

  private func failAndRelease(sourceLocation: SourceLocation) {
    // Retain terminal expiry even when no waiter existed when the deadline fired.
    guard expired == false else { return }
    expired = true
    guard !held.isEmpty || !entryWaiters.isEmpty || !parkWaiters.isEmpty else {
      return
    }
    Issue.record(
      "StageGate deadline expired while waiting for the subject",
      sourceLocation: sourceLocation)

    open()
    let entriesWaiting = entryWaiters
    let parksWaiting = parkWaiters
    entryWaiters = []
    parkWaiters = []
    for (_, continuation) in entriesWaiting {
      continuation.resume()
    }
    for (_, continuation) in parksWaiting {
      continuation.resume()
    }
  }

  func pass() async {
    entries += 1
    resumeReached(&entryWaiters, entries)
    if let maximumEntries, entries > maximumEntries {
      Issue.record(
        "Repeated preparation: StageGate entered \(entries) times; maximum is \(maximumEntries)",
        sourceLocation: sourceLocation)
      withUnsafeCurrentTask { $0?.cancel() }
      return
    }
    if rejectExpired("pass") {
      withUnsafeCurrentTask { $0?.cancel() }
      return
    }
    if isOpen { return }
    await withCheckedContinuation { held.append($0) }
    if expired {
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }

  func open() {
    if expired == false { isOpen = true }
    let released = held
    held = []
    for continuation in released { continuation.resume() }
  }

  func waitForEntry(_ count: Int) async {
    if entries >= count { return }
    if rejectExpired("waitForEntry") { return }
    await withCheckedContinuation { entryWaiters.append((count, $0)) }
  }

  func waitForParked(_ coordinator: ParakeetUpgradeCoordinator, _ count: Int) async {
    coordinator.onWaiterParkedForTesting = { [weak self] in
      guard let self else { return }
      self.parked += 1
      self.resumeReached(&self.parkWaiters, self.parked)
    }
    if parked >= count { return }
    if rejectExpired("waitForParked") { return }
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

@MainActor
@Suite(.tags(.harnessContract))
struct ParakeetUpgradeStageGateTests {
  @Test func pendingWaitExpiryCannotBeReopened() async {
    for park in [false, true] {
      var cancelled = false
      await withKnownIssue("Pending expiry rejects reopening and its late pass") {
        let gate = StageGate(deadline: .milliseconds(1))
        let c = ParakeetUpgradeCoordinator(
          parakeetSelection: ParakeetSelectionProvider(), delivery: nil)
        defer { c.onWaiterParkedForTesting = nil }
        if park { await gate.waitForParked(c, 1) }
        else { await gate.waitForEntry(1) }
        await gate.waitForDeadlineForTesting()
        gate.open()
        cancelled = await Task {
          await gate.pass()
          return Task.isCancelled
        }.value
      }
      #expect(cancelled == true)
      #expect(Task.isCancelled == false)
    }
  }

  @Test func heldExpiryPropagatesThroughCoordinator() async throws {
    var observedHeld = false
    var result: Result<ParakeetUpgradeCoordinator.PreparedLoad, any Error>?
    await withKnownIssue("Held subject expires") {
      let gate = StageGate(deadline: .milliseconds(1))
      let c = ParakeetUpgradeCoordinator(
        parakeetSelection: ParakeetSelectionProvider(), delivery: nil)
      c.deliveryStageGateForTesting = { await gate.pass() }
      defer {
        gate.open()
        c.deliveryStageGateForTesting = nil
      }
      let subject = Task { try await c.prepareLoad() }
      await gate.waitForEntry(1)
      observedHeld = gate.heldCountForTesting == 1
      await gate.waitForDeadlineForTesting()
      result = await subject.result
    }
    #expect(observedHeld == true)
    let completed = try #require(result)
    #expect(throws: CancellationError.self) { _ = try completed.get() }
    #expect(Task.isCancelled == false)
  }

  @Test func explicitOpenBeforeExpiryPermitsPass() async {
    let gate = StageGate()
    gate.open()
    await gate.pass()
    #expect(gate.entries == 1)
    #expect(Task.isCancelled == false)
  }

  @Test func idleExpiryRejectsLateEntryWait() async {
    let gate = StageGate(deadline: .milliseconds(1))
    await gate.waitForDeadlineForTesting()
    await withKnownIssue("Late entry wait must fail without hanging") {
      await gate.waitForEntry(1)
    }
  }

  @Test func idleExpiryRejectsLateParkWait() async {
    let gate = StageGate(deadline: .milliseconds(1))
    let coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: ParakeetSelectionProvider(), delivery: nil)
    defer { coordinator.onWaiterParkedForTesting = nil }
    await gate.waitForDeadlineForTesting()
    await withKnownIssue("Late park wait must fail without hanging") {
      await gate.waitForParked(coordinator, 1)
    }
  }

  @Test func idleExpiryCancelsLatePassSubject() async {
    let gate = StageGate(deadline: .milliseconds(1))
    await gate.waitForDeadlineForTesting()
    var cancelled = false
    await withKnownIssue("Late pass must fail and cancel its subject") {
      cancelled = await Task {
        await gate.pass()
        return Task.isCancelled
      }.value
    }
    #expect(cancelled == true)
    #expect(Task.isCancelled == false)
  }

  @Test func missingProgressRecordsAnIssueAndReleasesTheWaiter() async {
    await withKnownIssue("A missing progress signal must fail instead of hanging") {
      await ParakeetUpgradePolicyTests.ProgressRecorder().waitForAny(deadline: .milliseconds(1))
    }
  }

  @Test func missingSignalRecordsAnIssueAndReleasesTheWaiter() async {
    await withKnownIssue("The missing subject signal must fail instead of hanging") {
      let gate = StageGate(deadline: .milliseconds(1))
      await gate.waitForEntry(1)
    }
  }
}

// MARK: - Chunk 7b-1: the upgrade policy with a configured target

/// #3546 plan §3.4 rows and events, driven through the PRODUCTION coordinator,
/// state store, controller and admission on fixture registrations in temporary
/// owned directories. A physical load is simulated at the vendor boundary only:
/// the test calls the provider hooks the coordinator installed, exactly as
/// `ASRManager.performLoad` does (the real-model hook order is proven in
/// `ParakeetRealBoundaryTests`). If this breaks, a Mac can loop on a bad Ultra,
/// lose working v3 service, or delete a model it still needs.
@MainActor
@Suite("Parakeet upgrade policy", .serialized, .tags(.productOutcome))
struct ParakeetUpgradePolicyTests {

  @Test("initial eligibility survives cancelled frozen successor takeover")
  func initialEligibilitySurvivesOwnerTakeover() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let c = rig.coordinator
    let stages = StageGate(maximumEntries: 3)
    let wake1 = StageGate(maximumEntries: 1)
    let reloadGate = StageGate(maximumEntries: 1)
    var wakes = 0
    c.deliveryStageGateForTesting = {
      await stages.pass()
      if stages.entries == 2 { await reloadGate.pass() }
    }
    c.preparationWakeGateForTesting = {
      wakes += 1
      if wakes == 1 { await wake1.pass() }
    }
    defer {
      stages.open()
      wake1.open()
      reloadGate.open()
      c.deliveryStageGateForTesting = nil
      c.preparationWakeGateForTesting = nil
      c.onWaiterParkedForTesting = nil
      try? FileManager.default.removeItem(at: rig.root)
    }

    let owner = Task { try await c.prepareLoad() }
    await stages.waitForEntry(1)
    let waiter = Task { try await c.prepareLoad() }
    await stages.waitForParked(c, 1)
    stages.open()
    let ownerResult = await owner.result
    await wake1.waitForEntry(1)

    let successor = Task { try await c.prepareLoad() }
    await reloadGate.waitForEntry(1)
    wake1.open()
    await stages.waitForParked(c, 2)
    successor.cancel()
    reloadGate.open()
    let successorResult = await successor.result
    let waiterResult = await waiter.result

    let initial = try ownerResult.get()
    #expect(throws: CancellationError.self) {
      _ = try successorResult.get()
    }
    let prepared = try waiterResult.get()
    let request = try #require(initial.selection)
    #expect(initial.isSelectionLoad == true)
    #expect(prepared.selection == request)
    #expect(rig.selection.current == request)
    #expect(prepared.isSelectionLoad == true)
    #expect(c.hasPendingSelectionPoint == false)
    #expect(stages.entries == 3)
    #expect(reloadGate.entries == 1)
    #expect(wakes == 2)
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    let plan = await c.handleLoadFailure(
      prepared, error: VendorLoadFailed())
    #expect(plan == .reload)
    #expect(rig.selection.current?.model == .v3)
  }

  @Test("initial eligibility survives only identical-request frozen handoffs")
  func initialEligibilitySurvivesFrozenHandoff() async throws {
    for (newPoint, rejoin) in [(false, false), (true, false), (false, true)] {
      let rig = try await Self.rig(v3: true, ultra: true)
      let c = rig.coordinator
      let stages = StageGate(maximumEntries: 3)
      let wake1 = StageGate(maximumEntries: 1)
      let wake2 = StageGate(maximumEntries: 1)
      let reloadGate = StageGate(maximumEntries: 1)
      var wakes = 0
      c.deliveryStageGateForTesting = {
        await stages.pass()
        if rejoin, stages.entries == 2 { await reloadGate.pass() }
      }
      c.preparationWakeGateForTesting = {
        wakes += 1
        if wakes == 1 { await wake1.pass() }
        else { await wake2.pass() }
      }
      defer {
        stages.open()
        wake1.open()
        wake2.open()
        reloadGate.open()
        c.deliveryStageGateForTesting = nil
        c.preparationWakeGateForTesting = nil
        c.onWaiterParkedForTesting = nil
        try? FileManager.default.removeItem(at: rig.root)
      }
      let owner = Task { try await c.prepareLoad() }
      await stages.waitForEntry(1)
      let waiter = Task { try await c.prepareLoad() }
      await stages.waitForParked(c, 1)
      stages.open()
      let ownerResult = await owner.result
      await wake1.waitForEntry(1)

      var intermediate: [Result<ParakeetUpgradeCoordinator.PreparedLoad, any Error>] = []
      if newPoint {
        c.markSelectionPoint()
        intermediate.append(await Task { try await c.prepareLoad() }.result)
      }
      if rejoin {
        let reload = Task { try await c.prepareLoad() }
        await reloadGate.waitForEntry(1)
        wake1.open()
        await stages.waitForParked(c, 2)
        reloadGate.open()
        intermediate.append(await reload.result)
        await wake2.waitForEntry(1)
      }
      let freshResult = await Task { try await c.prepareLoad() }.result
      wake1.open()
      wake2.open()
      let joinedResult = await waiter.result

      let initial = try ownerResult.get()
      for result in intermediate { _ = try result.get() }
      let fresh = try freshResult.get()
      let joined = try joinedResult.get()
      #expect(initial.isSelectionLoad == true)
      #expect(fresh.isSelectionLoad == false)
      #expect(joined.selection == rig.selection.current)
      #expect(joined.selection == fresh.selection)
      #expect(joined.isSelectionLoad == (newPoint == false))
      if newPoint {
        #expect(joined.selection != initial.selection)
      } else {
        #expect(joined.selection == initial.selection)
      }
      #expect(stages.entries == (newPoint || rejoin ? 3 : 2))
      #expect(c.hasPendingSelectionPoint == false)
      #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
      let plan = await c.handleLoadFailure(joined, error: VendorLoadFailed())
      // A changed request is no longer this waiter's selection load: it may repair
      // and reload Ultra, but must not fall back to v3. The model assertion below
      // binds that distinction.
      #expect(plan == .reload)
      #expect(rig.selection.current?.model == (newPoint ? .ultra : .v3))
    }
  }

  @Test("cancelling a wake-held waiter preserves the owner request")
  func cancellationWhileWakeHeld() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let c = rig.coordinator
    let stage = StageGate(maximumEntries: 1)
    let wake = StageGate(maximumEntries: 1)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    c.onOutcome = { outcomes.append($0) }
    c.deliveryStageGateForTesting = { await stage.pass() }
    c.preparationWakeGateForTesting = { await wake.pass() }
    defer {
      stage.open()
      wake.open()
      c.deliveryStageGateForTesting = nil
      c.preparationWakeGateForTesting = nil
      c.onWaiterParkedForTesting = nil
      c.onOutcome = nil
      try? FileManager.default.removeItem(at: rig.root)
    }

    let owner = Task { try await c.prepareLoad() }
    await stage.waitForEntry(1)
    let joiner = Task { try await c.prepareLoad() }
    await stage.waitForParked(c, 1)
    stage.open()
    let ownerResult = await owner.result
    await wake.waitForEntry(1)
    let beforeCancel = rig.selection.current
    joiner.cancel()
    wake.open()
    let joinedResult = await joiner.result

    let prepared = try ownerResult.get()
    #expect(throws: CancellationError.self) {
      _ = try joinedResult.get()
    }
    #expect(prepared.selection == beforeCancel)
    #expect(prepared.isSelectionLoad == true)
    #expect(rig.selection.current == beforeCancel)
    #expect(rig.selection.current?.model == .ultra)
    #expect(c.hasPendingSelectionPoint == false)
    #expect(stage.entries == 1)
    #expect(wake.entries == 1)
    #expect(outcomes.contains(.fellBackToV3) == false)
  }

  @Test("a delayed joiner receives the newer failure without a third stage")
  func delayedJoinerReceivesNewerFailure() async throws {
    let rig = try await Self.rig(v3: false, ultra: true, enabled: false)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    // No v3 handle: these delivery-off decisions contain no transport await.
    let coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: rig.selection, delivery: nil,
      target: .init(
        delivery: rig.ultra, store: rig.store, ownedModelsRoot: rig.models))
    let gate = StageGate(maximumEntries: 2)
    coordinator.deliveryStageGateForTesting = {
      await gate.pass()
      if gate.entries == 2 {
        do {
          try rig.store.write(.init(
            attempts: 0, refetchSpent: false, exhausted: true, declined: false))
        } catch {
          Issue.record(error)
        }
      }
    }
    coordinator.markSelectionPoint()
    let runner = Task { try await coordinator.prepareLoad() }
    await gate.waitForEntry(1)
    let joiner = Task { try await coordinator.prepareLoad() }
    await gate.waitForParked(coordinator, 1)
    coordinator.markSelectionPoint()
    gate.open()
    let ownerResult = await runner.result
    let joinedResult = await joiner.result
    let expected = ParakeetUpgradeUnavailableError(reason: "exhausted")
    #expect(throws: expected) { _ = try ownerResult.get() }
    #expect(throws: expected) { _ = try joinedResult.get() }
    #expect(gate.entries == 2)
    #expect(coordinator.hasPendingSelectionPoint)
    #expect(rig.selection.current == nil)

    // A later fresh invocation must not reuse the retained failure.
    coordinator.deliveryStageGateForTesting = nil
    try coordinator.retry()
    let recovered = try await coordinator.prepareLoad()
    #expect(recovered.selection == rig.selection.current)
    #expect(recovered.selection?.model == .ultra)
    #expect(recovered.isSelectionLoad == true)
    #expect(coordinator.hasPendingSelectionPoint == false)
  }

  @Test("a fresh preparation retains frozen reload semantics")
  func completedPreparationPreservesFrozenReload() async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let initial = try await rig.coordinator.prepareLoad()
    #expect(initial.isSelectionLoad == true)
    let reload = try await rig.coordinator.prepareLoad()
    #expect(reload.selection == initial.selection)
    #expect(reload.selection == rig.selection.current)
    #expect(reload.isSelectionLoad == false)
  }
  final class WriteSwitch: @unchecked Sendable {
    var failing = false
    private var failCall: Int?
    private var calls = 0

    /// Fails only the `n`th store write or removal from now (1-based), so a
    /// test can fail a write between two fields.
    func failCall(_ n: Int) {
      calls = 0
      failCall = n
    }

    func check() throws {
      if failing { throw CocoaError(.fileWriteNoPermission) }
      guard let failCall else { return }
      calls += 1
      if calls == failCall { throw CocoaError(.fileWriteNoPermission) }
    }
  }

  /// Records what a handle writes to its progress channel, instead of the
  /// shared file the dev app and other suites use.
  final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var firstWrite: [CheckedContinuation<Void, Never>] = []

    var sink: ParakeetDeliveryHandle.ProgressSink {
      .init(
        write: { [self] _, phase, _ in record("write:\(phase)") },
        clear: { [self] in record("clear") })
    }

    var recorded: [String] { lock.withLock { events } }

    private func record(_ event: String) {
      let waiting = lock.withLock {
        events.append(event)
        let waiting = firstWrite
        firstWrite = []
        return waiting
      }
      for continuation in waiting { continuation.resume() }
    }

    /// Records a test marker (e.g. "LOAD") in the same sequence as the events.
    func mark(_ label: String) { record(label) }

    /// Returns once anything has been recorded (the foreground fetch is live).
    /// Deadline-bounded so a missing signal fails instead of hanging the lane.
    func waitForAny(
      deadline: Duration = .seconds(5),
      sourceLocation: SourceLocation = #_sourceLocation
    ) async {
      let deadlineTask = Task { [weak self] in
        do {
          // deadline-fallback: fail loudly and release a missing-signal wait.
          try await Task.sleep(for: deadline)
        } catch {
          return
        }
        guard let self else { return }
        let waiting = self.lock.withLock {
          let waiting = self.firstWrite
          self.firstWrite = []
          return waiting
        }
        guard !waiting.isEmpty else { return }
        Issue.record("foreground progress never arrived", sourceLocation: sourceLocation)
        for continuation in waiting { continuation.resume() }
      }
      await withCheckedContinuation { continuation in
        let ready = lock.withLock {
          if events.isEmpty {
            firstWrite.append(continuation)
            return false
          }
          return true
        }
        if ready { continuation.resume() }
      }
      deadlineTask.cancel()
    }
  }

  final class Flag: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
  }

  struct Rig {
    let root: URL
    let models: URL
    let metadata: URL
    let controller: ModelDeliveryController
    let v3Registration: DeliveryRegistration
    let ultraRegistration: DeliveryRegistration
    let v3: ParakeetDeliveryHandle
    let ultra: ParakeetDeliveryHandle
    let store: ParakeetUpgradeStateStore
    let selection: ParakeetSelectionProvider
    let defaults: UserDefaults
    let writes: WriteSwitch
    /// The Ultra fixture's download source; unique per rig, so a test counts
    /// only its own requests.
    let ultraBase: URL
    let ultraProgress: ProgressRecorder
    let onboarding: Flag
    var coordinator: ParakeetUpgradeCoordinator
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
  }

  static let v3Files: [(path: String, content: Data, component: String)] = [
    ("Encoder.mlmodelc/weights/weight.bin", Data("v3-weights".utf8), "Encoder.mlmodelc"),
    ("parakeet_vocab.json", Data("{\"v\":3}".utf8), "parakeet_vocab.json"),
  ]
  static let ultraFiles: [(path: String, content: Data, component: String)] = [
    ("Encoder.mlmodelc/weights/weight.bin", Data("ultra-weights".utf8), "Encoder.mlmodelc"),
    ("parakeet_vocab.json", Data("{\"u\":1}".utf8), "parakeet_vocab.json"),
  ]

  static func manifest(
    _ files: [(path: String, content: Data, component: String)], name: String, tag: String
  ) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: files,
        sources: [
          ["id": "our_copy", "baseURL": "https://upgrade.invalid.example/\(tag)/\(name)/"],
          ["id": "backup", "baseURL": "https://upgrade.invalid.example/\(tag)/\(name)-b/"],
        ]
      ) { object in
        var identity = object["identity"] as! [String: Any]
        identity["name"] = name
        object["identity"] = identity
      })
  }

  static func install(
    _ files: [(path: String, content: Data, component: String)], into directory: URL
  ) throws {
    for f in files {
      let url = directory.appendingPathComponent(f.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try f.content.write(to: url)
    }
  }

  /// A rig with the owned v3 and Ultra installs present (and admitted) or not.
  static func rig(
    v3: Bool, ultra: Bool, enabled: Bool = true, state: ParakeetUpgradeState? = nil,
    v3Donor: Bool = false, ultraLocationRefused: Bool = false, onboarding: Bool = false,
    diskBytes: Int64 = .max
  ) async throws -> Rig {
    let tag = UUID().uuidString
    DeliveryStubProtocol.beginScope(pathPrefix: "/\(tag)/")
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-upgrade-\(UUID().uuidString)", isDirectory: true)
    let data = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    let models = data.appendingPathComponent("Models", isDirectory: true)
    let metadata = data.appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let donor = root.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
    let v3Registration = DeliveryRegistration(
      manifest: try manifest(v3Files, name: "v3-fixture", tag: tag),
      installDirectory: ParakeetInstallLocation.directory(for: .v3, dataDirectory: data),
      metadataDirectory: metadata, legacyDonorDirectory: v3Donor ? donor : nil)
    let ultraRegistration = DeliveryRegistration(
      manifest: try manifest(ultraFiles, name: "ultra-fixture", tag: tag),
      installDirectory: ParakeetInstallLocation.directory(for: .ultra, dataDirectory: data),
      metadataDirectory: metadata,
      // A donor that contains the install is the location refusal (#2697).
      legacyDonorDirectory: ultraLocationRefused ? data : nil)
    let suite = "test.upgrade.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(suite)!
    defaults.set(enabled, forKey: DeliveryFlags.key("enabled", family: .parakeet))
    let controller = ModelDeliveryController(
      defaults: TestDefaults.suite(suite)!, availableDiskBytes: { _ in diskBytes })
    if v3 {
      try install(v3Files, into: v3Registration.installDirectory)
      #expect(await controller.admitIfComplete(v3Registration))
    }
    if ultra {
      try install(ultraFiles, into: ultraRegistration.installDirectory)
      #expect(await controller.admitIfComplete(ultraRegistration))
    }
    let writes = WriteSwitch()
    let store = ParakeetUpgradeStateStore(
      metadataDirectory: metadata,
      targetCacheKey: ultraRegistration.manifest.identity.cacheKey,
      writeData: { data, url in
        try writes.check()
        try data.write(to: url, options: .atomic)
      },
      removeItem: { url in
        try writes.check()
        try LegacyRetirement.clearMarker(url)
      })
    if let state { try store.write(state) }
    let v3Handle = ParakeetDeliveryHandle(
      controller: controller, registration: v3Registration, defaults: defaults,
      progressOwnership: .always, progress: ProgressRecorder().sink)
    let ultraProgress = ProgressRecorder()
    let ultraHandle = ParakeetDeliveryHandle(
      controller: controller, registration: ultraRegistration, defaults: defaults,
      progressOwnership: .scoped, progress: ultraProgress.sink)
    let onboardingFlag = Flag(onboarding)
    let selection = ParakeetSelectionProvider()
    var rig = Rig(
      root: root, models: models, metadata: metadata, controller: controller,
      v3Registration: v3Registration, ultraRegistration: ultraRegistration, v3: v3Handle,
      ultra: ultraHandle, store: store, selection: selection, defaults: defaults,
      writes: writes,
      ultraBase: URL(string: "https://upgrade.invalid.example/\(tag)/ultra-fixture/")!,
      ultraProgress: ultraProgress, onboarding: onboardingFlag,
      coordinator: ParakeetUpgradeCoordinator(
        parakeetSelection: selection, delivery: v3Handle,
        target: .init(delivery: ultraHandle, store: store, ownedModelsRoot: models),
        isOnboardingComplete: { onboardingFlag.value }))
    rig.coordinator.markSelectionPoint()
    return rig
  }

  /// A relaunch: a fresh coordinator over the SAME disk and store.
  static func relaunch(_ rig: Rig) -> Rig {
    var next = rig
    let selection = ParakeetSelectionProvider()
    next.coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: selection, delivery: rig.v3,
      target: .init(delivery: rig.ultra, store: rig.store, ownedModelsRoot: rig.models),
      isOnboardingComplete: { [onboarding = rig.onboarding] in onboarding.value })
    next.coordinator.markSelectionPoint()
    return Rig(
      root: next.root, models: next.models, metadata: next.metadata,
      controller: next.controller, v3Registration: next.v3Registration,
      ultraRegistration: next.ultraRegistration, v3: next.v3, ultra: next.ultra,
      store: next.store, selection: selection, defaults: next.defaults, writes: next.writes,
      ultraBase: next.ultraBase, ultraProgress: next.ultraProgress, onboarding: next.onboarding,
      coordinator: next.coordinator)
  }

  /// The vendor boundary, as `ASRManager.performLoad` reaches it: the count
  /// hook first (it may refuse), then success publishes through the publish hook.
  enum LoadResult: Equatable { case loaded, refused }
  static func physicalLoad(_ rig: Rig, succeeds: Bool = true) -> LoadResult {
    guard let request = rig.selection.current else { return .refused }
    do {
      try rig.selection.beforePhysicalLoad?(request)
    } catch {
      return .refused
    }
    if succeeds { rig.selection.didPublishLoad?(request) }
    return .loaded
  }

  static func state(_ rig: Rig) -> ParakeetUpgradeState? {
    if case .state(let s) = rig.store.read() { return s }
    return nil
  }

  struct VendorLoadFailed: Error {}

  // MARK: Rows

  @Test("A: an admitted Ultra within budget is chosen, counted, activated, and v3 retired")
  func rowAActivatesAndRetiresV3() async throws {
    var rig = try await Self.rig(v3: true, ultra: true)
    let retired = OutcomeSignal(.retiredV3)
    rig.coordinator.onOutcome = { retired.observe($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
    #expect(prepared.selection?.cacheOnly == true)
    #expect(prepared.selection?.repairable == false, "v3 serves on failure; no Ultra repair")
    #expect(prepared.selection?.directory.lastPathComponent == "parakeet-ultra")
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(Self.state(rig)?.attempts == 1, "the attempt is on disk before the loader")
    rig = Self.relaunch(rig)
    rig.coordinator.onOutcome = { retired.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded)
    await retired.wait()
    #expect(Self.state(rig) == .fresh, "a successful Ultra load resets the target")
    #expect(
      FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path) == false)
    #expect(await rig.controller.isAdmitted(rig.v3Registration) == false)
  }

  @Test("A-fail: a genuine Ultra failure at the initial load serves accepted v3 at once")
  func rowAFailFallsBackToV3() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    let plan = await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed())
    #expect(plan == .reload)
    #expect(rig.selection.current?.model == .v3)
    #expect(rig.selection.current?.repairable == false, "v3 is never repaired under a target")
    #expect(Self.physicalLoad(rig) == .loaded)
    #expect(Self.state(rig)?.attempts == 1, "the failed Ultra attempt stays spent")
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
  }

  /// Founder 2026-10-12: once Ultra has worked, v3 is gone and is never a fallback. The
  /// first migration leaves a completed record, and retiring the owned v3 keeps it. When this
  /// fails, every launch re-creates v3 from the donor only to retire it again.
  @Test("after activation retired v3, a launch does not copy v3 back from the donor")
  func retiredV3StaysRetired() async throws {
    let rig = try await Self.rig(v3: false, ultra: true, v3Donor: true)
    let donor = try #require(rig.v3Registration.legacyDonorDirectory)
    try Self.install(Self.v3Files, into: donor)
    #expect(
      LegacyDonorMigration.record(
        .completed, metadataDirectory: rig.metadata, manifest: rig.v3Registration.manifest))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
    #expect(prepared.selection?.repairable == true, "no v3: Ultra failures get the bounded repair")
    #expect(
      FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path) == false)
    #expect(await rig.controller.isAdmitted(rig.v3Registration) == false)
  }

  /// The launch migration may start after Ultra already activated. Acceptance joins it even
  /// for an accepted owned v3, so its completed record exists before retirement. When this
  /// fails, a late launch migration with no record copies the donor's v3 back.
  @Test("a launch migration that runs after activation does not copy v3 back")
  func lateLaunchMigrationAfterActivation() async throws {
    let rig = try await Self.rig(v3: true, ultra: true, v3Donor: true)
    let donor = try #require(rig.v3Registration.legacyDonorDirectory)
    try Self.install(Self.v3Files, into: donor)
    let retired = OutcomeSignal(.retiredV3)
    rig.coordinator.onOutcome = { retired.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded)
    await retired.wait()
    #expect(await rig.v3.ensureModelLocationReady() != nil)
    #expect(
      FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path) == false)
    for file in Self.v3Files {
      #expect(
        try Data(contentsOf: donor.appendingPathComponent(file.path)) == file.content,
        "the donor is never touched")
    }
  }

  /// Founder 2026-10-12: no v3 fallback after Ultra has worked. When this fails, a broken
  /// Ultra silently serves an old v3 from the shared donor.
  @Test("an Ultra failure after activation does not fall back to the donor's v3")
  func noDonorFallbackAfterActivation() async throws {
    let rig = try await Self.rig(v3: false, ultra: true, v3Donor: true)
    let donor = try #require(rig.v3Registration.legacyDonorDirectory)
    try Self.install(Self.v3Files, into: donor)
    #expect(
      LegacyDonorMigration.record(
        .completed, metadataDirectory: rig.metadata, manifest: rig.v3Registration.manifest))
    var fallbacks: [ParakeetUpgradeCoordinator.Fallback] = []
    rig.coordinator.onOutcome = {
      if case .loadFailed(_, _, _, let fallback) = $0 { fallbacks.append(fallback) }
    }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    _ = await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed())
    #expect(fallbacks == [ParakeetUpgradeCoordinator.Fallback.none])
    #expect(rig.selection.current?.model != .v3)
    #expect(
      FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path) == false)
  }

  /// #3546 §3.7 T2: an Ultra activation reports the attempt count read before the success
  /// reset zeroes it, its own load time, and that nothing served before. When this fails,
  /// the upgrade report says zero attempts or times another load.
  @Test("an Ultra activation carries its attempt count and load time from before the reset")
  func activationCarriesItsFacts() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    var activations: [ParakeetUpgradeCoordinator.LoadFacts] = []
    rig.coordinator.onOutcome = { if case .activated(let facts) = $0 { activations.append(facts) } }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded)
    let facts = try #require(activations.first)
    #expect(activations.count == 1)
    #expect(facts.selection.model == .ultra)
    #expect(facts.attempts == 1, "read before the reset below")
    #expect(facts.loadMilliseconds != nil, "this coordinator timed the load")
    #expect(facts.priorModel == nil, "nothing was serving")
    #expect(Self.state(rig) == .fresh)
  }

  /// #3546 §3.7 T2: an Ultra load failure reports the fallback the policy is about to take,
  /// decided before the report, with the loader's own error. When this fails, the report
  /// waits for or contradicts the fallback the app actually made.
  @Test("an Ultra load failure carries the fallback it is about to take and the loader error")
  func loadFailureCarriesItsFallback() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    var failures:
      [(
        ParakeetModel, ParakeetUpgradeCoordinator.LoadFacts, String,
        ParakeetUpgradeCoordinator.Fallback
      )] = []
    rig.coordinator.onOutcome = {
      if case .loadFailed(let model, let facts, let error, let fallback) = $0 {
        failures.append((model, facts, error, fallback))
      }
    }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    let plan = await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed())
    #expect(plan == .reload)
    #expect(rig.selection.current?.model == .v3, "the fallback the report named")
    let failure = try #require(failures.first)
    #expect(failures.count == 1)
    #expect(failure.0 == .ultra)
    #expect(failure.3 == .v3)
    #expect(failure.1.attempts == 1)
    #expect(failure.1.loadMilliseconds != nil)
    #expect(failure.2 == SentryBreadcrumb.structuredDescriptor(VendorLoadFailed()))
  }

  @Test("X: a spent budget on admitted bytes persists refetch intent, then removes them")
  func rowXRefetchesOnce() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3, "row B after the refetch decision")
    #expect(
      Self.state(rig) == .init(attempts: 0, refetchSpent: true, exhausted: false, declined: false))
    #expect(
      FileManager.default.fileExists(atPath: rig.ultraRegistration.installDirectory.path) == false)
  }

  @Test("X then exhaustion with v3: exhausted is persisted, v3 serves, Ultra bytes go")
  func rowXExhaustsWithV3() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 2, refetchSpent: true, exhausted: false, declined: false))
    let removed = OutcomeSignal(.removedTarget)
    rig.coordinator.onOutcome = { removed.observe($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(Self.state(rig)?.exhausted == true)
    await removed.wait()
    #expect(
      FileManager.default.fileExists(atPath: rig.ultraRegistration.installDirectory.path) == false)
  }

  @Test("X then exhaustion without v3: row T, and the Ultra bytes are retained")
  func rowXExhaustsWithoutV3() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: true, exhausted: false, declined: false))
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "exhausted")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(Self.state(rig)?.exhausted == true)
    #expect(rig.selection.current == nil)
    #expect(FileManager.default.fileExists(atPath: rig.ultraRegistration.installDirectory.path))
  }

  @Test("V: exhausted with accepted v3 serves v3 and removes the target's bytes")
  func rowVServesV3() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 0, refetchSpent: true, exhausted: true, declined: false))
    let removed = OutcomeSignal(.removedTarget)
    rig.coordinator.onOutcome = { removed.observe($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    await removed.wait()
    #expect(Self.state(rig)?.exhausted == true, "cleanup never clears exhaustion")
  }

  @Test("T and explicit Retry: no automatic work, then one new bounded cycle")
  func rowTThenRetry() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: true, exhausted: true, declined: true))
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "exhausted")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    try rig.coordinator.retry()
    #expect(
      Self.state(rig) == .init(attempts: 0, refetchSpent: false, exhausted: false, declined: true))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
  }

  @Test("Retry refuses when the store cannot be written, and grants nothing")
  func retryProvesTheStoreFirst() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: true, exhausted: true, declined: false))
    rig.writes.failing = true
    #expect(throws: ParakeetUpgradeStoreWriteError(field: "probe")) { try rig.coordinator.retry() }
    rig.writes.failing = false
    #expect(Self.state(rig)?.exhausted == true)
  }

  @Test("B: unadmitted Ultra with accepted v3 serves v3 immediately")
  func rowBServesV3() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(prepared.selection?.cacheOnly == true)
    #expect(Self.physicalLoad(rig) == .loaded)
    #expect(Self.state(rig) == .fresh, "a v3 load spends no Ultra attempt")
  }

  @Test("K: with delivery off, accepted v3 loads cache-only")
  func rowKServesV3() async throws {
    let rig = try await Self.rig(v3: true, ultra: true, enabled: false)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(prepared.selection?.cacheOnly == true)
  }

  @Test("K: with delivery off and no v3, the vendor Ultra branch is chosen and counted")
  func rowKVendorUltra() async throws {
    let rig = try await Self.rig(v3: false, ultra: false, enabled: false)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
    #expect(prepared.selection?.cacheOnly == false)
    #expect(prepared.selection?.repairable == false)
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(Self.state(rig)?.attempts == 1, "the vendor branch spends the same budget")
  }

  @Test("K: with delivery off, exhaustion and no v3 still mean T")
  func rowKExhaustedIsT() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: false, enabled: false,
      state: .init(attempts: 2, refetchSpent: true, exhausted: true, declined: false))
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "exhausted")) {
      _ = try await rig.coordinator.prepareLoad()
    }
  }

  // MARK: Budget, persistence and failure isolation

  @Test("frozen reloads cannot exceed the budget")
  func frozenReloadsAreBudgeted() async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    _ = try await rig.coordinator.prepareLoad()  // a cold press: frozen, not re-decided
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .refused)
    #expect(Self.state(rig)?.attempts == 2)
  }

  @Test("a crash after the attempt is persisted, before the loader, still spends it")
  func crashAfterCountKeepsTheAttempt() async throws {
    var rig = try await Self.rig(v3: true, ultra: true)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)  // count, then "crash"
    rig = Self.relaunch(rig)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    rig = Self.relaunch(rig)
    let third = try await rig.coordinator.prepareLoad()
    #expect(third.selection?.model == .v3, "two spent attempts lead to row X, not a third load")
    #expect(Self.state(rig)?.refetchSpent == true)
  }

  @Test("a store that cannot persist the attempt starts no Ultra load")
  func storeWriteFailureStartsNoLoad() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let prepared = try await rig.coordinator.prepareLoad()
    rig.writes.failing = true
    #expect(Self.physicalLoad(rig) == .refused)
    let plan = await rig.coordinator.handleLoadFailure(
      prepared, error: ParakeetUpgradeStoreWriteError(field: "attempts"))
    #expect(plan == .fail, "a store failure is not a loader failure: no fallback, no repair")
    rig.writes.failing = false
    #expect(Self.state(rig) == .fresh)
  }

  @Test("a reset that cannot be written keeps Ultra serving and keeps v3")
  func resetFailureKeepsV3() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = { outcomes.append($0) }
    _ = try await rig.coordinator.prepareLoad()
    guard let request = rig.selection.current else {
      Issue.record("no request")
      return
    }
    try rig.selection.beforePhysicalLoad?(request)
    rig.writes.failing = true
    rig.selection.didPublishLoad?(request)
    rig.writes.failing = false
    #expect(outcomes.contains(.storeUnavailable("reset")))
    #expect(outcomes.contains { if case .activated = $0 { true } else { false } } == false)
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
  }

  @Test("unreadable state blocks automatic Ultra work; accepted v3 serves")
  func unreadableStateIsExhausted() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    try Data("garbage".utf8).write(to: rig.store.url(for: .attempts))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
  }

  @Test(
    "cancellation and supersession are never loader failures",
    arguments: [
      "CancellationError", "ASRLoadCancelledError", "ASRLoadSupersededError",
    ])
  func cancellationIsNotAFailure(kind: String) async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    let error: any Error =
      switch kind {
      case "CancellationError": CancellationError()
      case "ASRLoadCancelledError": ASRLoadCancelledError()
      default: ASRLoadSupersededError()
      }
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: error) == .fail)
    #expect(rig.selection.current?.model == .ultra, "no fallback")
    #expect(Self.state(rig)?.attempts == 1, "the attempt stays spent")
  }

  @Test("E19: a genuine v3 failure at the initial load moves to Ultra, never repairing v3")
  func e19MovesToUltra() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, enabled: false)
    let v3Load = try await rig.coordinator.prepareLoad()
    #expect(v3Load.selection?.model == .v3)
    #expect(await rig.coordinator.handleLoadFailure(v3Load, error: VendorLoadFailed()) == .reload)
    #expect(rig.selection.current?.model == .ultra)
    #expect(rig.selection.current?.cacheOnly == false, "delivery off: the vendor branch")
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(Self.state(rig)?.attempts == 1, "E19 cannot bypass the budget")
    // v3 stays rejected for this launch: the next selection point does not pick it.
    rig.coordinator.markSelectionPoint()
    let next = try await rig.coordinator.prepareLoad()
    #expect(next.selection?.model == .ultra)
  }

  @Test("E19 on a frozen reload never changes the serving identity")
  func e19FrozenReloadFails() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    _ = try await rig.coordinator.prepareLoad()
    let frozenReload = try await rig.coordinator.prepareLoad()
    #expect(frozenReload.isSelectionLoad == false)
    let plan = await rig.coordinator.handleLoadFailure(frozenReload, error: VendorLoadFailed())
    #expect(plan == .fail)
    #expect(rig.selection.current?.model == .v3)
  }

  // MARK: v3 acceptance

  @Test("v3 is accepted after mtime drift through full validation and a marker refresh")
  func v3AcceptedAfterDrift() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    let file = rig.v3Registration.installDirectory.appendingPathComponent(Self.v3Files[0].path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
    #expect(await rig.controller.isAdmitted(rig.v3Registration) == false)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(await rig.controller.isAdmitted(rig.v3Registration))
  }

  @Test("complete markerless owned v3 bytes are accepted")
  func markerlessV3Accepted() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    try Self.install(Self.v3Files, into: rig.v3Registration.installDirectory)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
  }

  @Test("a first migration brings v3 from the donor; a completed or declined record does not")
  func donorMigrationOnlyWithoutRecord() async throws {
    let fresh = try await Self.rig(v3: false, ultra: false, enabled: false, v3Donor: true)
    try Self.install(Self.v3Files, into: try #require(fresh.v3Registration.legacyDonorDirectory))
    let migrated = try await fresh.coordinator.prepareLoad()
    #expect(migrated.selection?.model == .v3, "no record: the launch migration brings v3 over")
    for state in [LegacyDonorMigration.RecordedState.completed, .declined] {
      let rig = try await Self.rig(v3: false, ultra: false, enabled: false, v3Donor: true)
      try Self.install(Self.v3Files, into: try #require(rig.v3Registration.legacyDonorDirectory))
      #expect(
        LegacyDonorMigration.record(
          state, metadataDirectory: rig.metadata, manifest: rig.v3Registration.manifest))
      let prepared = try await rig.coordinator.prepareLoad()
      #expect(prepared.selection?.model == .ultra, "\(state): the donor is not read again")
    }
  }

  @Test("partial owned v3 bytes are not accepted")
  func partialV3NotAccepted() async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    try Self.install([Self.v3Files[0]], into: rig.v3Registration.installDirectory)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
    #expect(prepared.selection?.repairable == true, "no v3: Ultra failures get the bounded repair")
  }

  // MARK: Retirement containment

  @Test("retirement refuses an install outside the owned models root and deletes nothing")
  func retirementRefusesOutsideRoot() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    // A root that EXISTS, so only containment can refuse.
    let elsewhere = rig.root.appendingPathComponent("NotModels", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let ok = await rig.v3.retireOwnedInstall(ownedModelsRoot: elsewhere)
    #expect(ok == false)
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
    #expect(await rig.controller.isAdmitted(rig.v3Registration))
  }

  @Test("retirement removes unlisted remnants, the marker and staging, and records no decline")
  func retirementRemovesEverything() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, v3Donor: true)
    let donor = try #require(rig.v3Registration.legacyDonorDirectory)
    try Self.install(Self.v3Files, into: donor)
    let stray = rig.v3Registration.installDirectory.appendingPathComponent("stray.bin")
    try Data("x".utf8).write(to: stray)
    let staging = ModelDeliveryController.stagingDirectoryURL(for: rig.v3Registration)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    #expect(await rig.v3.retireOwnedInstall(ownedModelsRoot: rig.models))
    #expect(
      FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path) == false)
    #expect(FileManager.default.fileExists(atPath: staging.path) == false)
    #expect(await rig.controller.isAdmitted(rig.v3Registration) == false)
    #expect(
      LegacyDonorMigration.recordedState(
        metadataDirectory: rig.metadata, manifest: rig.v3Registration.manifest) != .declined)
    for file in Self.v3Files {
      #expect(
        try Data(contentsOf: donor.appendingPathComponent(file.path)) == file.content,
        "the donor is never touched")
    }
  }
  @Test("retirement refuses an install it cannot look up, and deletes nothing")
  func retirementRefusesUnreadablePath() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.models.path)
    let ok = await rig.v3.retireOwnedInstall(ownedModelsRoot: rig.models)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.models.path)
    #expect(ok == false, "a failed lookup is not absence")
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
    #expect(await rig.controller.isAdmitted(rig.v3Registration))
  }

  @Test("retirement removes a dangling link left where staging was")
  func retirementRemovesDanglingResidue() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    let staging = ModelDeliveryController.stagingDirectoryURL(for: rig.v3Registration)
    try FileManager.default.createDirectory(
      at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: staging, withDestinationURL: rig.root.appendingPathComponent("gone"))
    #expect(await rig.v3.retireOwnedInstall(ownedModelsRoot: rig.models))
    #expect(PathSafety.reachability(of: staging) == .absent, "the link itself is gone")
  }

  @Test("retirement that cannot delete reports failure and leaves the donor intact")
  func retirementFailureIsTruthful() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, v3Donor: true)
    let donor = try #require(rig.v3Registration.legacyDonorDirectory)
    try Self.install(Self.v3Files, into: donor)
    let locked = rig.v3Registration.installDirectory.appendingPathComponent(Self.v3Files[0].path)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    #expect(await rig.v3.retireOwnedInstall(ownedModelsRoot: rig.models) == false)
    for file in Self.v3Files {
      #expect(try Data(contentsOf: donor.appendingPathComponent(file.path)) == file.content)
    }
  }

  @Test("a cancelled retirement caller deletes nothing")
  func cancelledRetirementDeletesNothing() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    let task = Task { await rig.v3.retireOwnedInstall(ownedModelsRoot: rig.models) }
    task.cancel()
    #expect(await task.value == false)
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
    #expect(await rig.controller.isAdmitted(rig.v3Registration))
  }

  // MARK: Both load doors run the whole failure sequence

  /// What the scripted manager loaded, and whether each load succeeds.
  @MainActor final class LoadLog {
    var order: [ParakeetModel] = []
    var results: [Bool]
    init(_ results: [Bool]) { self.results = results }
  }

  /// A manager whose loads run the provider hooks as `ASRManager.performLoad`
  /// does, record the model, and fail while the log says so.
  static func scriptedManager(_ rig: Rig, _ log: LoadLog) -> StubParakeetASRManager {
    let manager = StubParakeetASRManager()
    let selection = rig.selection
    manager.loadModelScript = {
      guard let request = selection.current else { throw ParakeetModelDirectoryUnsetError() }
      try selection.beforePhysicalLoad?(request)
      log.order.append(request.model)
      let succeeds = log.results.isEmpty ? true : log.results.removeFirst()
      guard succeeds else { throw VendorLoadFailed() }
      selection.didPublishLoad?(request)
    }
    return manager
  }

  enum Door: String, CaseIterable, Sendable { case warmUp, directLoad }

  static func load(through door: Door, _ rig: Rig, _ manager: StubParakeetASRManager) async throws {
    switch door {
    case .warmUp:
      try await ParakeetEngineAdapter(asrManager: manager, parakeetUpgrade: rig.coordinator)
        .warmUp(modelReceipt: nil)
    case .directLoad:
      try await ActiveEngineOperation.live(
        asrManager: manager, parakeetUpgrade: rig.coordinator,
        whisperKitBackend: WhisperKitBackend(admittedModelFolder: { nil })
      ).load()
    }
  }

  static func ultraRequests(_ rig: Rig) -> Int {
    DeliveryStubProtocol.requests(in: rig.ultraBase.deletingLastPathComponent().path + "/").count
  }

  static func enqueueUltra(_ rig: Rig) {
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
    for f in ultraFiles {
      DeliveryStubProtocol.enqueue(
        url: rig.ultraBase.appendingPathComponent(f.path).absoluteString,
        .init(
          status: 200, headers: ["Content-Length": String(f.content.count), "ETag": "\"u\""],
          body: f.content))
    }
  }

  @Test(
    "v3 fails, then Ultra fails: the bounded Ultra repair still runs, through either door",
    arguments: Door.allCases)
  func v3ThenUltraFailureRepairs(door: Door) async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    // Complete Ultra bytes without admission: v3 serves first (B); E19 admits them.
    try Self.install(Self.ultraFiles, into: rig.ultraRegistration.installDirectory)
    Self.enqueueUltra(rig)
    let log = LoadLog([false, false, false])
    let manager = Self.scriptedManager(rig, log)
    var failed: [ParakeetModel] = []
    rig.coordinator.onOutcome = {
      if case .loadFailed(let model, _, _, _) = $0 { failed.append(model) }
    }
    await #expect(throws: VendorLoadFailed.self) {
      try await Self.load(through: door, rig, manager)
    }
    #expect(log.order == [.v3, .ultra, .ultra], "E19 to Ultra, then its one repair and reload")
    #expect(failed == log.order, "every failure, the last included, is reported")
    #expect(Self.state(rig)?.attempts == 2)
  }

  /// Chunk 12 second pass: a file import, recovery replay or Diagnostics load reaches the
  /// frozen Ultra through `ActiveEngineOperation`. When this fails, that door loads the manager
  /// directly, so a damaged Ultra after the activation is never repaired there and every retry
  /// of the import fails the same way.
  @Test(
    "after the activation, a failed frozen reload is repaired through either door",
    arguments: Door.allCases)
  func frozenReloadRepairsThroughEitherDoor(door: Door) async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    Self.enqueueUltra(rig)
    let log = LoadLog([true, false, true])
    let manager = Self.scriptedManager(rig, log)
    try await Self.load(through: .warmUp, rig, manager)
    #expect(log.order == [.ultra], "the activation's selection load chose Ultra")
    #expect(rig.selection.current?.repairable == false, "chosen while v3 could still serve")
    manager.isModelLoaded = false  // an idle unload; the next load reloads the frozen request
    try await Self.load(through: door, rig, manager)
    #expect(log.order == [.ultra, .ultra, .ultra], "frozen reload, its bounded repair, reload")
  }

  /// Chunk 12 second pass: v3 fails its launch load and E19's Ultra fetch then fails. When
  /// this fails, the caller is told v3 failed to load instead of the fetch's real cause (no
  /// network, no disk), and a cancelled fetch reads as a load failure.
  @Test(
    "v3 fails and E19's Ultra fetch fails: the fetch failure is what the caller sees",
    arguments: Door.allCases)
  func e19FetchFailureSurfaces(door: Door) async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    for f in Self.ultraFiles {
      DeliveryStubProtocol.enqueue(
        url: rig.ultraBase.appendingPathComponent(f.path).absoluteString,
        .init(status: 404, headers: [:], body: Data()))
    }
    let log = LoadLog([false])
    let manager = Self.scriptedManager(rig, log)
    await #expect(throws: ParakeetDeliveryError.self) {
      try await Self.load(through: door, rig, manager)
    }
    #expect(log.order == [.v3], "only v3 loaded; Ultra never arrived")
  }

  @Test(
    "Ultra fails, then accepted v3 fails: E19 still runs, through either door",
    arguments: Door.allCases)
  func ultraThenV3FailureRunsE19(door: Door) async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let log = LoadLog([false, false, false])
    let manager = Self.scriptedManager(rig, log)
    var failed: [ParakeetModel] = []
    rig.coordinator.onOutcome = {
      if case .loadFailed(let model, _, _, _) = $0 { failed.append(model) }
    }
    await #expect(throws: VendorLoadFailed.self) {
      try await Self.load(through: door, rig, manager)
    }
    #expect(log.order == [.ultra, .v3, .ultra], "A-fail to v3, then E19 back to Ultra")
    #expect(failed == log.order, "every failure, the last included, is reported")
    #expect(Self.state(rig)?.attempts == 2)
  }

  @Test(
    "Ultra fails, v3 fails, Ultra loads: Ultra activates through either door",
    arguments: Door.allCases)
  func thirdLoadActivates(door: Door) async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let log = LoadLog([false, false, true])
    let manager = Self.scriptedManager(rig, log)
    try await Self.load(through: door, rig, manager)
    #expect(log.order == [.ultra, .v3, .ultra])
    #expect(Self.state(rig) == .fresh, "the ready Ultra publish reset the target")
  }

  // MARK: Budget bounds repair and cleanup

  @Test("after the last permitted Ultra attempt fails, nothing is repaired or fetched")
  func noRepairAfterTheBudget() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 1, refetchSpent: false, exhausted: false, declined: false))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.repairable == true)
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    // Damage the bytes, and serve good ones: a forbidden repair would fetch and succeed.
    Self.enqueueUltra(rig)
    try Data("damaged".utf8).write(
      to: rig.ultraRegistration.installDirectory.appendingPathComponent(Self.ultraFiles[1].path))
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) == .fail)
    #expect(Self.ultraRequests(rig) == 0)
    #expect(Self.state(rig)?.attempts == 2)
  }

  /// Chunk 12 whole-PR review: Ultra chosen while v3 could still serve is non-repairable, and
  /// that request stays frozen after the activation retires v3. When this fails, damaged Ultra
  /// files on a later reload leave no engine at all instead of the bounded repair (A1).
  @Test("after an activation retired v3, a failed frozen Ultra reload gets the bounded repair")
  func frozenReloadAfterActivationRepairs() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    let retired = OutcomeSignal(.retiredV3)
    rig.coordinator.onOutcome = { retired.observe($0) }
    let first = try await rig.coordinator.prepareLoad()
    #expect(first.selection?.repairable == false, "v3 could serve when Ultra was chosen")
    #expect(Self.physicalLoad(rig) == .loaded)
    await retired.wait()
    let reload = try await rig.coordinator.prepareLoad()
    #expect(reload.isSelectionLoad == false)
    #expect(reload.selection?.model == .ultra)
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    Self.enqueueUltra(rig)
    try Data("damaged".utf8).write(
      to: rig.ultraRegistration.installDirectory.appendingPathComponent(Self.ultraFiles[1].path))
    #expect(await rig.coordinator.handleLoadFailure(reload, error: VendorLoadFailed()) == .reload)
    #expect(Self.ultraRequests(rig) > 0, "the repair fetched good bytes")
    #expect(rig.coordinator.needsExplicitRetry == false, "a load is still permitted")
  }

  /// Chunk 12 whole-PR review: when this fails, Settings shows no Try again after the last
  /// permitted Ultra load fails, until a later press is refused.
  @Test("the last permitted Ultra failure asks for the explicit Retry at once")
  func lastPermittedFailureAsksForRetry() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 1, refetchSpent: false, exhausted: false, declined: false))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(rig.coordinator.needsExplicitRetry == false)
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) == .fail)
    #expect(rig.coordinator.needsExplicitRetry)
  }

  enum Residue: String, CaseIterable, Sendable { case marker, install, staging }

  /// Makes one retirement step fail by locking a file it must delete.
  static func lock(_ residue: Residue, _ rig: Rig) throws -> URL {
    let fm = FileManager.default
    let url: URL
    switch residue {
    case .marker:
      url = rig.metadata.appendingPathComponent(
        "\(rig.ultraRegistration.manifest.identity.cacheKey).admission.json")
    case .install:
      url = rig.ultraRegistration.installDirectory.appendingPathComponent(
        Self.ultraFiles[0].path)
    case .staging:
      let staging = ModelDeliveryController.stagingDirectoryURL(for: rig.ultraRegistration)
      try fm.createDirectory(at: staging, withIntermediateDirectories: true)
      url = staging.appendingPathComponent("part")
      try Data("p".utf8).write(to: url)
    }
    #expect(fm.fileExists(atPath: url.path))
    try fm.setAttributes([.immutable: true], ofItemAtPath: url.path)
    return url
  }

  @Test(
    "X: bytes that cannot be removed exhaust the target; attempts never reset, no row C",
    arguments: Residue.allCases)
  func failedRefetchCleanupExhausts(residue: Residue) async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    let locked = try Self.lock(residue, rig)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "exhausted")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(
      Self.state(rig) == .init(attempts: 2, refetchSpent: true, exhausted: true, declined: false))
    #expect(Self.ultraRequests(rig) == 0, "no foreground fetch")
  }

  @Test("X: failed cleanup with accepted v3 serves v3")
  func failedRefetchCleanupServesV3() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    let locked = try Self.lock(.install, rig)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(Self.state(rig)?.exhausted == true)
    #expect(Self.state(rig)?.attempts == 2)
  }

  @Test("X: a refetch-intent write that fails between fields deletes nothing; v3 serves")
  func refetchIntentFailsBetweenFields() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    rig.writes.failCall(2)  // `attempts` is written, `refetchSpent` is not
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration), "the Ultra bytes stay")
  }

  @Test("X: a reset that fails between fields after deletion never starts a fetch")
  func refetchResetFailsBetweenFields() async throws {
    var rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    rig.writes.failCall(5)  // the refetch intent (4 fields) lands; the reset's first field fails
    await #expect(throws: ParakeetUpgradeStoreWriteError(field: "attempts")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(Self.state(rig)?.attempts == 2)
    #expect(Self.state(rig)?.refetchSpent == true)
    rig = Self.relaunch(rig)
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "budget_spent")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(Self.ultraRequests(rig) == 0)
  }

  // MARK: Stale loads and queued cleanup

  @Test("a failure reported after a newer selection point changes nothing")
  func staleFailureIsIgnored() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = { outcomes.append($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    rig.coordinator.markSelectionPoint()
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) == .fail)
    #expect(rig.selection.current?.model == .ultra, "no v3 fallback was published")
    #expect(outcomes.contains(.fellBackToV3) == false)
  }

  @Test("a stale v3 failure does not reject v3 for the launch")
  func staleV3FailureKeepsV3() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    let prepared = try await rig.coordinator.prepareLoad()
    rig.coordinator.markSelectionPoint()
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) == .fail)
    let next = try await rig.coordinator.prepareLoad()
    #expect(next.selection?.model == .v3)
  }

  @Test("a stale success neither resets the target nor retires v3")
  func staleSuccessIsIgnored() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = { outcomes.append($0) }
    _ = try await rig.coordinator.prepareLoad()
    let request = try #require(rig.selection.current)
    try rig.selection.beforePhysicalLoad?(request)
    rig.coordinator.markSelectionPoint()
    rig.selection.didPublishLoad?(request)
    #expect(Self.state(rig)?.attempts == 1)
    #expect(outcomes.contains { if case .activated = $0 { true } else { false } } == false)
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
  }

  @Test("a load of a stale request is refused before it spends anything")
  func staleLoadIsNotCounted() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    _ = try await rig.coordinator.prepareLoad()
    rig.coordinator.markSelectionPoint()
    #expect(Self.physicalLoad(rig) == .refused)
    #expect(Self.state(rig) == .fresh)
  }

  @Test("a cancelled failure handler repairs nothing")
  func cancelledFailureHandlerRepairsNothing() async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    try Data("damaged".utf8).write(
      to: rig.ultraRegistration.installDirectory.appendingPathComponent(Self.ultraFiles[1].path))
    let task = Task { await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) }
    task.cancel()
    #expect(await task.value == .fail)
    #expect(Self.ultraRequests(rig) == 0)
  }

  /// Chunk 12 Codex r2: a failure handler whose repair awaited while a newer selection took
  /// over must not set the newer selection's Try again. When this fails, Settings shows a
  /// Try again that the current load never asked for.
  @Test(
    "a repair that fails after a newer selection leaves its Retry presentation alone",
    arguments: [false, true])
  func supersededRepairLeavesRetryAlone(cancelled: Bool) async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(Self.state(rig)?.attempts == 1, "one load left: the repair runs")
    try Data("damaged".utf8).write(
      to: rig.ultraRegistration.installDirectory.appendingPathComponent(Self.ultraFiles[1].path))
    let gate = StageGate()
    await rig.controller.setBeforeExistingCacheValidationForTesting { await gate.pass() }
    let handler = Task {
      await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed())
    }
    await gate.waitForEntry(1)
    // While the repair waits: a newer selection, and the store reaches the budget.
    rig.coordinator.markSelectionPoint()
    try rig.store.write(.init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    if cancelled { handler.cancel() }
    // Every Ultra file answers 404, so the repair fails at once instead of admitting.
    for f in Self.ultraFiles {
      DeliveryStubProtocol.enqueue(
        url: rig.ultraBase.appendingPathComponent(f.path).absoluteString,
        .init(status: 404, headers: [:], body: Data()))
    }
    gate.open()
    #expect(await handler.value == .fail)
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
    #expect(
      rig.coordinator.needsExplicitRetry == false, "the newer selection owns the presentation")
  }

  @Test("Retry during the retirement drain prevents deletion")
  func retryDuringDrainDeletesNothing() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 0, refetchSpent: true, exhausted: true, declined: false))
    let gate = StageGate()
    await rig.controller.setRetirementDrainGateForTesting { await gate.pass() }
    let ended = CleanupEnded()
    rig.coordinator.onCleanupEndedForTesting = { _ in ended.fire() }
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = { outcomes.append($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    await gate.waitForEntry(1)
    // Chunk 12 r5: v3 ready when Retry is pressed takes Retry's background branch, which
    // marks no selection point; Retry itself must still cancel the queued removal.
    rig.coordinator.servingReadiness = { true }
    #expect(Self.physicalLoad(rig) == .loaded, "v3 is ready when Retry is pressed")
    try rig.coordinator.retry()
    gate.open()
    await ended.wait()
    await rig.controller.setRetirementDrainGateForTesting(nil)
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
    #expect(await rig.controller.isAdmitted(rig.v3Registration))
    #expect(outcomes.contains(.removedTarget) == false)
    #expect(outcomes.contains(.retirementFailed(.ultra)) == false)
  }

  @Test("Retry cancels a queued target removal: nothing is deleted or reported")
  func retryCancelsQueuedRemoval() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: true,
      state: .init(attempts: 0, refetchSpent: true, exhausted: true, declined: false))
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = { outcomes.append($0) }
    let ended = CleanupEnded()
    rig.coordinator.onCleanupEndedForTesting = { _ in ended.fire() }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3, "row V queued the removal")
    try rig.coordinator.retry()
    await ended.wait()
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
    #expect(outcomes.contains(.removedTarget) == false)
    #expect(outcomes.contains(.retirementFailed(.ultra)) == false)
  }

  // MARK: Row C: foreground fetch

  @Test("C: Ultra is admitted before it is published, and only then loads")
  func rowCAdmitsBeforePublishing() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    Self.enqueueUltra(rig)
    var filesPresentAtPublish: Bool?
    rig.coordinator.onOutcome = { outcome in
      guard outcome == .selected(.ultra, row: "C") else { return }
      filesPresentAtPublish = Self.ultraFiles.allSatisfy {
        FileManager.default.fileExists(
          atPath: rig.ultraRegistration.installDirectory.appendingPathComponent($0.path).path)
      }
    }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(filesPresentAtPublish == true)
    #expect(prepared.selection?.model == .ultra)
    #expect(prepared.selection?.cacheOnly == true)
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
    #expect(Self.physicalLoad(rig) == .loaded)
  }

  @Test("C: a failed fetch publishes nothing, and the next preparation fetches again")
  func rowCFailureLeavesNothingFrozen() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
    await #expect(throws: ParakeetDeliveryError.self) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(rig.selection.current == nil)
    let failedRequests = Self.ultraRequests(rig)
    #expect(failedRequests > 0)
    Self.enqueueUltra(rig)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
    #expect(Self.ultraRequests(rig) > failedRequests)
  }

  @Test("C: a cancelled preparation fetches and publishes nothing")
  func rowCCancelled() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    let gate = StageGate()
    rig.coordinator.deliveryStageGateForTesting = { await gate.pass() }
    let task = Task { try await rig.coordinator.prepareLoad() }
    await gate.waitForEntry(1)
    task.cancel()
    gate.open()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(rig.selection.current == nil)
    #expect(Self.ultraRequests(rig) == 0)
  }

  @Test("C: a spent budget fetches nothing")
  func rowCBudgetSpent() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: false,
      state: .init(attempts: 2, refetchSpent: true, exhausted: false, declined: false))
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "budget_spent")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(rig.selection.current == nil)
    #expect(Self.ultraRequests(rig) == 0)
  }

  @Test("a refused Ultra location fetches nothing; accepted v3 still serves")
  func refusedUltraLocation() async throws {
    let refused = try await Self.rig(v3: false, ultra: false, ultraLocationRefused: true)
    await #expect(throws: ParakeetDeliveryError.self) {
      _ = try await refused.coordinator.prepareLoad()
    }
    #expect(refused.selection.current == nil)
    #expect(Self.ultraRequests(refused) == 0)
    let withV3 = try await Self.rig(v3: true, ultra: false, ultraLocationRefused: true)
    let prepared = try await withV3.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
  }

  @Test("a refused Ultra location is never loaded, even through the vendor branch")
  func refusedUltraLocationWithDeliveryOff() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: false, enabled: false, ultraLocationRefused: true)
    await #expect(throws: ParakeetDeliveryError.self) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(rig.selection.current == nil)
  }
  // MARK: 7b-2: background fetch, Cancel/Resume, progress ownership, usability

  /// Serves the first Ultra file's headers and part of its body, then holds the
  /// request open until it is cancelled.
  static func enqueueHangingUltra(_ rig: Rig) {
    let f = ultraFiles[0]
    DeliveryStubProtocol.enqueue(
      url: rig.ultraBase.appendingPathComponent(f.path).absoluteString,
      .init(
        status: 200, headers: ["Content-Length": String(f.content.count), "ETag": "\"u\""],
        body: f.content.prefix(2), hangAfterBody: true))
  }

  @Test("B: the background fetch starts after v3 is published and never changes the choice")
  func rowBBackgroundAdmitsWithoutSwitching() async throws {
    var rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    rig.coordinator.onOutcome = { admitted.observe($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    let published = try #require(rig.selection.current)
    await admitted.wait()
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
    #expect(rig.selection.current == published, "admission mid-session is recorded only")
    let frozen = try await rig.coordinator.prepareLoad()
    #expect(frozen.selection?.model == .v3)
    #expect(rig.ultraProgress.recorded.isEmpty, "background work never touches progress")
    rig = Self.relaunch(rig)
    let next = try await rig.coordinator.prepareLoad()
    #expect(next.selection?.model == .ultra, "the next selection point activates it (row A)")
  }

  /// #3546 A3: when this fails, a v3 user keeps v3 until a relaunch, or the activation row
  /// cannot tell an in-session switch from a launch.
  @Test("A3: a background admission while v3 serves owes one in-session activation to Ultra")
  func backgroundAdmissionOwesActivation() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    var owed = 0
    var activations: [ParakeetUpgradeCoordinator.LoadFacts] = []
    rig.coordinator.onActivationOwed = { owed += 1 }
    rig.coordinator.onOutcome = {
      admitted.observe($0)
      if case .activated(let facts) = $0 { activations.append(facts) }
    }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded, "v3 serves this session")
    await admitted.wait()
    #expect(owed == 1)
    #expect(rig.coordinator.isActivationOwed)

    #expect(rig.coordinator.beginOwedActivation())
    #expect(rig.coordinator.isActivationOwed == false, "the selection point settles the debt")
    #expect(rig.coordinator.beginOwedActivation() == false, "only once")
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra, "row A for the admitted Ultra")
    #expect(Self.physicalLoad(rig) == .loaded)
    let facts = try #require(activations.first)
    #expect(facts.trigger == .backgroundAdmission)
    #expect(facts.priorModel == .v3)
  }

  /// #3546 A3, Chunk 12 live UAT: an 8 s Ultra download was admitted before v3's launch
  /// load published, so the offer found nothing serving and was dropped; v3 served until a
  /// relaunch. When this fails, that ordering again leaves the switch for the next launch.
  @Test("A3: an admission before v3's load publishes is owed once v3 serves")
  func admissionBeforeV3PublishesIsOwedAfterLoad() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    var owed = 0
    rig.coordinator.onActivationOwed = { owed += 1 }
    rig.coordinator.onOutcome = { admitted.observe($0) }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    await admitted.wait()
    #expect(owed == 0, "nothing serves yet, so nothing is owed")
    #expect(rig.coordinator.isActivationOwed == false)

    #expect(Self.physicalLoad(rig) == .loaded, "v3's launch load publishes after admission")
    #expect(owed == 1, "v3 now serves: the admitted Ultra is offered")
    #expect(rig.coordinator.isActivationOwed)
    #expect(rig.coordinator.beginOwedActivation())
    let next = try await rig.coordinator.prepareLoad()
    #expect(next.selection?.model == .ultra, "row A for the admitted Ultra")
  }

  /// Chunk 12 Codex ruling: the background fetch's admission can resume on the main actor after
  /// a newer selection point already re-decided the model. Here that selection takes the admitted
  /// Ultra, fails, and falls back to v3. When this fails, v3's publication re-opens the settled
  /// choice and the app tries Ultra again by itself.
  @Test("A3: an admission that lands after a newer selection point offers nothing")
  func admissionAfterNewerSelectionOffersNothing() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    var owed = 0
    rig.coordinator.onActivationOwed = { owed += 1 }
    rig.coordinator.onOutcome = { [coordinator = rig.coordinator] outcome in
      // The newer selection point lands in the hop between admission and the offer.
      if outcome == .backgroundAdmitted { coordinator.markSelectionPoint() }
      admitted.observe(outcome)
    }
    _ = try await rig.coordinator.prepareLoad()
    await admitted.wait()
    let ultra = try await rig.coordinator.prepareLoad()
    #expect(ultra.selection?.model == .ultra, "the newer selection takes the admitted Ultra")
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(await rig.coordinator.handleLoadFailure(ultra, error: VendorLoadFailed()) == .reload)
    #expect(rig.selection.current?.model == .v3, "A-fail")
    #expect(Self.physicalLoad(rig) == .loaded, "v3 publishes")
    #expect(owed == 0, "the settled choice is not re-opened")
    #expect(rig.coordinator.isActivationOwed == false)
  }

  @Test("A3: a decline after admission withdraws the owed activation")
  func declineWithdrawsOwedActivation() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    rig.coordinator.onOutcome = { admitted.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded)
    await admitted.wait()
    #expect(rig.coordinator.isActivationOwed)
    try rig.store.write(.init(attempts: 0, refetchSpent: false, exhausted: false, declined: true))
    #expect(rig.coordinator.isActivationOwed == false)
    #expect(rig.coordinator.beginOwedActivation() == false)
  }

  /// When this fails, a Cancel whose decline could not be saved still swaps the model, or a
  /// Resume after the download already finished leaves v3 serving until a relaunch.
  @Test("A3: a Cancel that cannot persist withdraws the activation; Resume offers it again")
  func cancelWithdrawsAndResumeReoffers() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    rig.coordinator.onOutcome = { admitted.observe($0) }
    // The offer is not an outcome; the bounded signal is released by hand on the second one.
    let reoffered = OutcomeSignal("a second activation offer", matching: { _ in true })
    var offerCount = 0
    rig.coordinator.onActivationOwed = {
      offerCount += 1
      if offerCount == 2 { reoffered.observe(.backgroundAdmitted) }
    }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded, "v3 serves this session")
    await admitted.wait()
    #expect(offerCount == 1)
    #expect(rig.coordinator.isActivationOwed)

    rig.writes.failing = true
    await #expect(throws: ParakeetUpgradeStoreWriteError(field: "declined")) {
      try await rig.coordinator.cancelBackgroundUpgrade()
    }
    rig.writes.failing = false
    #expect(Self.state(rig)?.declined == false, "the decline did not persist")
    #expect(rig.coordinator.isActivationOwed == false, "Cancel still withdraws it")
    #expect(rig.coordinator.beginOwedActivation() == false)

    try await rig.coordinator.resumeBackgroundUpgrade()
    await reoffered.wait()
    #expect(offerCount == 2, "Resume finds Ultra already admitted and offers it again")
    #expect(rig.coordinator.isActivationOwed)
  }

  @Test("E22: a row-B launch before onboarding holds the fetch until onboarding completes")
  func onboardingHoldsThenStarts() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: false)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    rig.coordinator.onOutcome = { admitted.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false, "held for onboarding")
    rig.onboarding.value = true
    rig.coordinator.onboardingDidComplete()
    await admitted.wait()
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
  }

  /// Chunk 12 whole-PR review r2: a refetch removed Ultra but its attempt reset never landed,
  /// so the budget is spent with no bytes. When this fails, the app downloads about 630 MB
  /// that the next selection exhausts and deletes, and Settings shows no Try again.
  @Test("a spent budget without bytes fetches nothing in the background and asks for Retry")
  func spentBudgetFetchesNothing() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 2, refetchSpent: true, exhausted: false, declined: false),
      onboarding: true)
    Self.enqueueUltra(rig)
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3)
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false, "no download nothing may load")
    #expect(rig.coordinator.needsExplicitRetry, "Settings offers Try again")
    #expect(Self.physicalLoad(rig) == .loaded)
    #expect(rig.coordinator.needsExplicitRetry, "v3 readiness must keep Ultra's Retry")
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
    try rig.coordinator.retry()
    let next = try await rig.coordinator.prepareLoad()
    #expect(next.selection?.model == .v3)
    #expect(rig.coordinator.hasBackgroundFetchForTesting, "Retry grants the download again")
  }

  /// Chunk 12 whole-PR review r3: Try again while v3 is loaded. Settings' warm-up returns at
  /// once for a ready engine, so a selection point would wait for a load that never comes.
  /// When this fails, the Try again row clears and the upgrade stalls until a relaunch.
  @Test("Try again while v3 serves restarts the background upgrade and owes the activation")
  func retryWhileV3ServesResumesTheUpgrade() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 2, refetchSpent: true, exhausted: false, declined: false),
      onboarding: true)
    rig.coordinator.servingReadiness = { true }
    let admitted = OutcomeSignal(.backgroundAdmitted)
    var owed = 0
    rig.coordinator.onActivationOwed = { owed += 1 }
    rig.coordinator.onOutcome = { admitted.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded, "v3 serves and stays loaded")
    #expect(rig.coordinator.needsExplicitRetry)
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
    Self.enqueueUltra(rig)
    try rig.coordinator.retry()
    #expect(rig.coordinator.needsExplicitRetry == false)
    #expect(rig.coordinator.hasBackgroundFetchForTesting, "no load needed to restart the download")
    await admitted.wait()
    #expect(
      owed == 1, "the admitted Ultra is owed to the engine owner, as any background admission")
    #expect(rig.coordinator.isActivationOwed)
  }

  enum Ineligible: String, CaseIterable, Sendable { case declined, deliveryOff, noSelection }

  @Test(
    "no background fetch when declined, delivery is off, or nothing chose row B",
    arguments: Ineligible.allCases)
  func backgroundIneligible(_ reason: Ineligible) async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false, enabled: reason != .deliveryOff,
      state: reason == .declined
        ? .init(attempts: 0, refetchSpent: false, exhausted: false, declined: true) : nil,
      onboarding: true)
    var started = false
    rig.coordinator.onOutcome = { if $0 == .backgroundStarted { started = true } }
    if reason == .noSelection {
      // A WhisperKit-only launch: no Parakeet selection was ever settled.
      rig.coordinator.onboardingDidComplete()
    } else {
      let prepared = try await rig.coordinator.prepareLoad()
      #expect(prepared.selection?.model == .v3)
      rig.coordinator.onboardingDidComplete()
    }
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
    #expect(rig.coordinator.backgroundUpgrade == (reason == .declined ? .declined : .idle))
    #expect(started == false)
    #expect(Self.ultraRequests(rig) == 0)
  }

  @Test("E3: insufficient disk defers silently; v3 keeps serving")
  func insufficientDiskDefers() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true, diskBytes: 1)
    let deferred = OutcomeSignal(.deferredDisk)
    rig.coordinator.onOutcome = { deferred.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    await deferred.wait()
    #expect(rig.coordinator.backgroundUpgrade == .deferredDisk)
    #expect(rig.selection.current?.model == .v3)
    #expect(Self.state(rig)?.declined == false)
  }

  @Test("E3: another fetch failure is recorded and v3 keeps serving")
  func backgroundFailureRecorded() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    let failed = OutcomeSignal("backgroundFetchFailed") {
      if case .backgroundFetchFailed = $0 { return true }
      return false
    }
    rig.coordinator.onOutcome = { failed.observe($0) }
    // Both sources answer 404 for the first file: the fetch fails at once.
    let first = Self.ultraFiles[0].path
    for base in [
      rig.ultraBase,
      rig.ultraBase.deletingLastPathComponent().appendingPathComponent("ultra-fixture-b/"),
    ] {
      DeliveryStubProtocol.enqueue(
        url: base.appendingPathComponent(first).absoluteString,
        .init(status: 404, headers: [:], body: Data()))
    }
    _ = try await rig.coordinator.prepareLoad()
    await failed.wait()
    #expect(rig.coordinator.backgroundUpgrade == .failed)
    #expect(rig.selection.current?.model == .v3)
  }

  @Test("E12: Cancel persists the decline, then stops the download")
  func cancelPersistsThenStops() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 1, refetchSpent: false, exhausted: false, declined: false),
      onboarding: true)
    Self.enqueueHangingUltra(rig)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    let started = OutcomeSignal(.backgroundStarted)
    rig.coordinator.onOutcome = {
      outcomes.append($0)
      started.observe($0)
    }
    _ = try await rig.coordinator.prepareLoad()
    await started.wait()
    try await rig.coordinator.cancelBackgroundUpgrade()
    #expect(
      Self.state(rig) == .init(attempts: 1, refetchSpent: false, exhausted: false, declined: true),
      "only the decline field changed")
    #expect(rig.coordinator.backgroundUpgrade == .declined)
    #expect(outcomes.contains(.declined))
    #expect(outcomes.contains(.backgroundAdmitted) == false)
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration) == false)
  }

  @Test("E12: a decline that cannot be persisted still stops this process's background work")
  func cancelWithoutPersistenceStillStops() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueHangingUltra(rig)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    let started = OutcomeSignal(.backgroundStarted)
    rig.coordinator.onOutcome = {
      outcomes.append($0)
      started.observe($0)
    }
    _ = try await rig.coordinator.prepareLoad()
    await started.wait()
    rig.writes.failing = true
    await #expect(throws: ParakeetUpgradeStoreWriteError(field: "declined")) {
      try await rig.coordinator.cancelBackgroundUpgrade()
    }
    rig.writes.failing = false
    #expect(outcomes.contains(.storeUnavailable("declined")))
    #expect(rig.coordinator.backgroundUpgrade == .declined)
    rig.coordinator.onboardingDidComplete()
    #expect(
      rig.coordinator.hasBackgroundFetchForTesting == false, "no automatic restart until Resume")
  }

  @Test("E13: Resume clears only the decline and starts the fetch again")
  func resumeClearsAndStarts() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 1, refetchSpent: true, exhausted: false, declined: true),
      onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = {
      outcomes.append($0)
      admitted.observe($0)
    }
    _ = try await rig.coordinator.prepareLoad()
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false, "declined")
    try await rig.coordinator.resumeBackgroundUpgrade()
    #expect(outcomes.contains(.resumed))
    #expect(
      Self.state(rig) == .init(attempts: 1, refetchSpent: true, exhausted: false, declined: false))
    await admitted.wait()
  }

  @Test("E13: Resume that cannot write starts nothing")
  func resumeWriteFailureStartsNothing() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 0, refetchSpent: false, exhausted: false, declined: true),
      onboarding: true)
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    rig.coordinator.onOutcome = { outcomes.append($0) }
    _ = try await rig.coordinator.prepareLoad()
    rig.writes.failing = true
    await #expect(throws: ParakeetUpgradeStoreWriteError(field: "declined")) {
      try await rig.coordinator.resumeBackgroundUpgrade()
    }
    rig.writes.failing = false
    #expect(outcomes.contains(.resumed) == false)
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
    #expect(Self.state(rig)?.declined == true)
  }

  @Test("E14: a later selection point does not stop a background fetch")
  func selectionPointKeepsBackgroundFetch() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueUltra(rig)
    let admitted = OutcomeSignal(.backgroundAdmitted)
    let started = OutcomeSignal(.backgroundStarted)
    rig.coordinator.onOutcome = {
      admitted.observe($0)
      started.observe($0)
    }
    _ = try await rig.coordinator.prepareLoad()
    await started.wait()
    rig.coordinator.markSelectionPoint()
    await admitted.wait()
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
    #expect(await rig.controller.isAdmitted(rig.v3Registration), "nothing is deleted")
  }

  @Test("progress: a foreground Ultra fetch owns the channel and clears it before loading")
  func foregroundFetchOwnsProgress() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    Self.enqueueUltra(rig)
    _ = try await rig.coordinator.prepareLoad()
    let events = rig.ultraProgress.recorded
    #expect(events.contains { $0.hasPrefix("write:") })
    #expect(events.last == "clear", "the download boundary is cleared before the load")
  }

  @Test("foreground Cancel stops row C's fetch without a decline")
  func foregroundCancelDuringRowC() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    Self.enqueueHangingUltra(rig)
    let task = Task { try await rig.coordinator.prepareLoad() }
    await rig.ultraProgress.waitForAny()
    await rig.coordinator.cancelActiveFetch()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(Self.state(rig)?.declined == false)
    #expect(rig.selection.current == nil)
  }

  @Test("foreground Cancel with only background work in flight does nothing")
  func foregroundCancelLeavesBackgroundAlone() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueHangingUltra(rig)
    let started = OutcomeSignal(.backgroundStarted)
    rig.coordinator.onOutcome = { started.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    await started.wait()
    await rig.coordinator.cancelActiveFetch()
    guard case .downloading = rig.coordinator.backgroundUpgrade else {
      Issue.record("the background download stopped")
      return
    }
    #expect(Self.state(rig)?.declined == false)
    try await rig.coordinator.cancelBackgroundUpgrade()  // release the held request
  }

  // MARK: Usability

  @Test("usable: accepted v3, or admitted Ultra whose state still permits a load")
  func usabilityTruthTable() async throws {
    let v3Only = try await Self.rig(v3: true, ultra: false)
    #expect(await v3Only.coordinator.isParakeetUsable())
    let ultraFresh = try await Self.rig(v3: false, ultra: true)
    #expect(await ultraFresh.coordinator.isParakeetUsable())
    let ultraExhausted = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 0, refetchSpent: true, exhausted: true, declined: false))
    #expect(await ultraExhausted.coordinator.isParakeetUsable() == false, "retained, not usable")
    let ultraSpent = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: false, exhausted: false, declined: false))
    #expect(await ultraSpent.coordinator.isParakeetUsable() == false)
    let nothing = try await Self.rig(v3: false, ultra: false)
    #expect(await nothing.coordinator.isParakeetUsable() == false)
  }

  @Test("usable: a ready serving model counts, including the K vendor branch")
  func usabilityCountsServing() async throws {
    let rig = try await Self.rig(v3: false, ultra: false, enabled: false)
    var ready = false
    rig.coordinator.servingReadiness = { ready }
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig) == .loaded)
    #expect(await rig.coordinator.isParakeetUsable() == false, "a request alone proves nothing")
    ready = true
    #expect(await rig.coordinator.isParakeetUsable())
  }

  @Test("usable: v3 rejected by E19 no longer counts")
  func usabilityAfterE19() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, enabled: false)
    let v3Load = try await rig.coordinator.prepareLoad()
    #expect(await rig.coordinator.isParakeetUsable())
    #expect(await rig.coordinator.handleLoadFailure(v3Load, error: VendorLoadFailed()) == .reload)
    #expect(await rig.coordinator.isParakeetUsable() == false)
  }

  @Test("companions are invited to re-read on fallback, rejection, exhaustion, Retry and Resume")
  func usabilityNotifications() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    var invitations = 0
    rig.coordinator.onUsabilityMayHaveChanged = { invitations += 1 }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    let before = invitations
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) == .reload)
    #expect(invitations > before, "A-fail fallback")
    let exhausted = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: true, exhausted: false, declined: false))
    var exhaustInvites = 0
    exhausted.coordinator.onUsabilityMayHaveChanged = { exhaustInvites += 1 }
    _ = try? await exhausted.coordinator.prepareLoad()
    #expect(exhaustInvites > 0, "exhaustion")
    let retried = exhaustInvites
    try exhausted.coordinator.retry()
    #expect(exhaustInvites > retried, "Retry")
    let declined = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 0, refetchSpent: false, exhausted: false, declined: true))
    var resumeInvites = 0
    declined.coordinator.onUsabilityMayHaveChanged = { resumeInvites += 1 }
    try await declined.coordinator.resumeBackgroundUpgrade()
    #expect(resumeInvites > 0, "Resume")
  }

  // MARK: 7b-2 round 2: command ordering, ordered progress, attribution, decline, fresh reads

  /// A background fetch held inside existing-cache validation (complete
  /// unmarked Ultra bytes), so a Cancel's transport drain stays held until
  /// the gate opens.
  fileprivate static func heldBackgroundFetch() async throws -> (Rig, StageGate) {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    try Self.install(Self.ultraFiles, into: rig.ultraRegistration.installDirectory)
    let gate = StageGate()
    await rig.controller.setBeforeExistingCacheValidationForTesting { await gate.pass() }
    _ = try await rig.coordinator.prepareLoad()
    await gate.waitForEntry(1)
    return (rig, gate)
  }

  @Test("E13: Resume waits for Cancel's drain before clearing the decline")
  func resumeWaitsForCancelDrain() async throws {
    let (rig, gate) = try await Self.heldBackgroundFetch()
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    let declined = OutcomeSignal(.declined)
    rig.coordinator.onOutcome = {
      outcomes.append($0)
      declined.observe($0)
    }
    let cancel = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    await declined.wait()
    let waiting = CleanupEnded()
    rig.coordinator.onResumeWaitingForTesting = { waiting.fire() }
    let resume = Task { try await rig.coordinator.resumeBackgroundUpgrade() }
    await waiting.wait()
    #expect(outcomes.contains(.resumed) == false, "Resume is held behind the drain")
    #expect(Self.state(rig)?.declined == true)
    gate.open()
    try await cancel.value
    try await resume.value
    #expect(outcomes.contains(.resumed))
    #expect(Self.state(rig)?.declined == false)
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
  }

  @Test("Cancel, Resume, Cancel while the drain is held: the last Cancel wins")
  func newerCancelBeatsWaitingResume() async throws {
    let (rig, gate) = try await Self.heldBackgroundFetch()
    var outcomes: [ParakeetUpgradeCoordinator.Outcome] = []
    let declined = OutcomeSignal(.declined)
    let secondDeclined = CleanupEnded()
    var declineCount = 0
    rig.coordinator.onOutcome = {
      outcomes.append($0)
      declined.observe($0)
      if $0 == .declined {
        declineCount += 1
        if declineCount == 2 { secondDeclined.fire() }
      }
    }
    let first = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    await declined.wait()
    let waiting = CleanupEnded()
    rig.coordinator.onResumeWaitingForTesting = { waiting.fire() }
    let resume = Task { try await rig.coordinator.resumeBackgroundUpgrade() }
    await waiting.wait()
    let second = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    await secondDeclined.wait()
    gate.open()
    try await first.value
    await #expect(throws: CancellationError.self) { try await resume.value }
    try await second.value
    #expect(outcomes.contains(.resumed) == false)
    #expect(Self.state(rig)?.declined == true)
    #expect(rig.coordinator.backgroundUpgrade == .declined)
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
  }

  @Test("a cancelled waiting Resume clears nothing")
  func cancelledResumeClearsNothing() async throws {
    let (rig, gate) = try await Self.heldBackgroundFetch()
    let declined = OutcomeSignal(.declined)
    rig.coordinator.onOutcome = { declined.observe($0) }
    let cancel = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    await declined.wait()
    let waiting = CleanupEnded()
    rig.coordinator.onResumeWaitingForTesting = { waiting.fire() }
    let resume = Task { try await rig.coordinator.resumeBackgroundUpgrade() }
    await waiting.wait()
    resume.cancel()
    gate.open()
    try await cancel.value
    await #expect(throws: CancellationError.self) { try await resume.value }
    #expect(Self.state(rig)?.declined == true)
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
  }

  @Test("E12 cancels a foreground continuation sharing the background attempt")
  func cancelReachesForegroundJoiner() async throws {
    let (rig, gate) = try await Self.heldBackgroundFetch()
    let prepared = ParakeetUpgradeCoordinator.PreparedLoad(
      selection: rig.selection.current, isSelectionLoad: true)
    let joined = CleanupEnded()
    rig.ultra.onFetchDecisionForTesting = { decision in
      guard decision == .joined else { return }
      Task { @MainActor in joined.fire() }
    }
    let moved = CleanupEnded()
    await rig.controller.setAfterMovedToDrainingForTesting {
      Task { @MainActor in moved.fire() }
    }
    // E19 on the v3 load: the coordinator's own foreground Ultra fetch (row C)
    // joins the held background attempt.
    let foreground = Task {
      await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed())
    }
    await joined.wait()
    let cancel = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    await moved.wait()
    gate.open()
    try await cancel.value
    #expect(await foreground.value == .fail)
    #expect(Self.state(rig)?.declined == true)
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration) == false)
    rig.ultra.onFetchDecisionForTesting = nil
    await rig.controller.setAfterMovedToDrainingForTesting(nil)
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
  }

  @Test("a foreground operation cancelled before it starts reports staged bytes truthfully")
  func cancelledBeforeAcquiringReportsStaging() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    let fresh = Task { await rig.ultra.ensureAvailableInForeground() }
    fresh.cancel()
    #expect(await fresh.value == .cancelled(resumable: false), "nothing staged")
    let staging = ModelDeliveryController.stagingDirectoryURL(for: rig.ultraRegistration)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("part".utf8).write(to: staging.appendingPathComponent("part"))
    let staged = Task { await rig.ultra.ensureAvailableInForeground() }
    staged.cancel()
    #expect(await staged.value == .cancelled(resumable: true), "a non-empty staged file")
  }

  @Test("progress: two foreground joiners see nothing after the first load starts")
  func orderedForegroundProgress() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    Self.enqueueUltra(rig)
    let recorder = rig.ultraProgress
    let handle = rig.ultra
    // Deliver every progress event late: callers must still wait for them.
    handle.setProgressDelayForTesting {
      for _ in 0..<50 { await Task.yield() }
    }
    let a = Task {
      _ = await handle.ensureAvailableInForeground()
      recorder.mark("LOAD")
    }
    let b = Task {
      _ = await handle.ensureAvailableInForeground()
      recorder.mark("LOAD")
    }
    await a.value
    await b.value
    await rig.ultra.drainProgressForTesting()
    let events = recorder.recorded
    let firstLoad = try #require(events.firstIndex(of: "LOAD"))
    #expect(
      events[firstLoad...].allSatisfy { $0 == "LOAD" },
      "a progress event landed after a caller started loading: \(events)")
    #expect(events[..<firstLoad].last == "clear", "the boundary is cleared before loading")
  }

  @Test("an old attempt's progress never updates a newer background download")
  func oldProgressIsNotAttributed() async throws {
    let (rig, gate) = try await Self.heldBackgroundFetch()
    let old = try #require(rig.coordinator.backgroundGenerationForTesting)
    let cancel = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    gate.open()
    try await cancel.value
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
    let newGate = StageGate()
    await rig.controller.setBeforeExistingCacheValidationForTesting { await newGate.pass() }
    try await rig.coordinator.resumeBackgroundUpgrade()
    await newGate.waitForEntry(1)
    let before = rig.coordinator.backgroundUpgrade
    rig.coordinator.targetStateChanged(
      .downloading(fractionCompleted: 0.5, bytesWritten: 1, totalBytes: 2), generation: old)
    #expect(rig.coordinator.backgroundUpgrade == before)
    newGate.open()
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
  }

  @Test("a persisted decline is shown after relaunch without starting or rewriting anything")
  func declineSurvivesRelaunch() async throws {
    let rig = try await Self.rig(
      v3: true, ultra: false,
      state: .init(attempts: 1, refetchSpent: true, exhausted: false, declined: true),
      onboarding: true)
    #expect(rig.coordinator.backgroundUpgrade == .declined)
    _ = try await rig.coordinator.prepareLoad()
    #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
    #expect(
      Self.state(rig) == .init(attempts: 1, refetchSpent: true, exhausted: false, declined: true))
  }

  @Test("usable: a v3 rejection that lands during the admission read is honoured")
  func usabilityRereadsRejection() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, enabled: false)
    let v3Load = try await rig.coordinator.prepareLoad()
    let gate = StageGate()
    rig.coordinator.usabilityReadGateForTesting = { await gate.pass() }
    let read = Task { await rig.coordinator.isParakeetUsable() }
    await gate.waitForEntry(1)
    rig.coordinator.usabilityReadGateForTesting = nil
    #expect(await rig.coordinator.handleLoadFailure(v3Load, error: VendorLoadFailed()) == .reload)
    gate.open()
    #expect(await read.value == false)
  }

  @Test("usable: exhaustion that lands during the Ultra admission read is honoured")
  func usabilityRereadsExhaustion() async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    let gate = StageGate()
    var reads = 0
    // Hold only the second read (the Ultra admission); the v3 read passes.
    rig.coordinator.usabilityReadGateForTesting = {
      reads += 1
      if reads == 2 { await gate.pass() }
    }
    let read = Task { await rig.coordinator.isParakeetUsable() }
    await gate.waitForEntry(1)
    try rig.store.write(.init(attempts: 0, refetchSpent: true, exhausted: true, declined: false))
    gate.open()
    #expect(await read.value == false)
  }

  // MARK: 8b: what Settings presents

  @Test("Settings names the serving model, else the pending one; fallback names v3")
  func presentedModelFollowsServing() async throws {
    let rig = try await Self.rig(v3: true, ultra: true)
    #expect(rig.coordinator.presentedModel == nil, "nothing selected yet")
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(rig.coordinator.presentedModel == .ultra, "row A: Ultra is pending")
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    #expect(await rig.coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) == .reload)
    #expect(rig.coordinator.presentedModel == .v3, "A-fail serves v3")
    #expect(Self.physicalLoad(rig) == .loaded)
    #expect(rig.coordinator.presentedModel == .v3)
  }

  @Test("v3 is named while Ultra is missing, before and after v3 loads")
  func presentedModelWhileUltraIsMissing() async throws {
    let rig = try await Self.rig(v3: true, ultra: false)
    _ = try await rig.coordinator.prepareLoad()
    #expect(rig.coordinator.presentedModel == .v3, "row B: v3 while Ultra is missing")
    #expect(Self.physicalLoad(rig) == .loaded)
    #expect(rig.coordinator.presentedModel == .v3)
  }

  @Test("Settings asks for an explicit Retry only after the policy stops loading")
  func explicitRetryPresentation() async throws {
    let rig = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 2, refetchSpent: true, exhausted: true, declined: false))
    var changes = 0
    rig.coordinator.onPresentationChanged = { changes += 1 }
    #expect(rig.coordinator.needsExplicitRetry == false)
    await #expect(throws: ParakeetUpgradeUnavailableError(reason: "exhausted")) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(rig.coordinator.needsExplicitRetry)
    #expect(changes > 0, "Settings is told to re-read")
    try rig.coordinator.retry()
    #expect(rig.coordinator.needsExplicitRetry == false)
  }

  @Test("a refused frozen Ultra reload also asks for the explicit Retry")
  func budgetRefusalAsksForRetry() async throws {
    let rig = try await Self.rig(v3: false, ultra: true)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .loaded)
    _ = try await rig.coordinator.prepareLoad()
    #expect(Self.physicalLoad(rig, succeeds: false) == .refused)
    #expect(rig.coordinator.needsExplicitRetry)
  }

  @Test("the Model ready read follows the presented identity and its permission")
  func currentAdmissionFollowsPresented() async throws {
    let v3Serving = try await Self.rig(v3: true, ultra: false)
    _ = try await v3Serving.coordinator.prepareLoad()
    #expect(await v3Serving.coordinator.currentAdmission(), "v3 is admitted and accepted")

    let rejected = try await Self.rig(v3: true, ultra: false, enabled: false)
    let v3Load = try await rejected.coordinator.prepareLoad()
    #expect(
      await rejected.coordinator.handleLoadFailure(v3Load, error: VendorLoadFailed()) == .reload)
    #expect(await rejected.coordinator.currentAdmission() == false, "rejected v3 is not ready")

    let exhausted = try await Self.rig(
      v3: false, ultra: true,
      state: .init(attempts: 0, refetchSpent: true, exhausted: true, declined: false))
    #expect(await exhausted.coordinator.currentAdmission() == false, "retained, not permitted")

    let fresh = try await Self.rig(v3: false, ultra: true)
    #expect(await fresh.coordinator.currentAdmission())
  }

  @Test("Settings' foreground fetch is counted, so its Cancel reaches it")
  func settingsForegroundFetchCancels() async throws {
    let rig = try await Self.rig(v3: false, ultra: false)
    Self.enqueueHangingUltra(rig)
    let task = Task { await rig.coordinator.fetchInForeground() }
    await rig.ultraProgress.waitForAny()
    await rig.coordinator.cancelActiveFetch()
    let outcome = await task.value
    guard case .cancelled? = outcome else {
      Issue.record("the Settings fetch was not cancelled: \(String(describing: outcome))")
      return
    }
    #expect(Self.state(rig)?.declined == false, "a foreground Cancel is not a decline")
  }

  @Test("the background download state carries its own byte counts")
  func backgroundStateCarriesCounts() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, onboarding: true)
    Self.enqueueHangingUltra(rig)
    let started = OutcomeSignal(.backgroundStarted)
    rig.coordinator.onOutcome = { started.observe($0) }
    _ = try await rig.coordinator.prepareLoad()
    await started.wait()
    guard case .downloading(_, _, let total) = rig.coordinator.backgroundUpgrade else {
      Issue.record("not downloading: \(rig.coordinator.backgroundUpgrade)")
      return
    }
    #expect(total == rig.ultra.modelTotalBytes)
    try await rig.coordinator.cancelBackgroundUpgrade()
  }

  // MARK: 8b round 2: stale reads and a Resume parked behind a Cancel's drain

  @Test("a Model ready read whose request changed answers false, not the old answer")
  func currentAdmissionDropsAStaleIdentity() async throws {
    for changeRequest in [false, true] {
      let rig = try await Self.rig(v3: true, ultra: false)
      _ = try await rig.coordinator.prepareLoad()
      #expect(Self.physicalLoad(rig) == .loaded)
      #expect(rig.coordinator.presentedModel == .v3)
      let gate = StageGate()
      rig.coordinator.usabilityReadGateForTesting = { await gate.pass() }
      let read = Task { await rig.coordinator.currentAdmission() }
      await gate.waitForEntry(1)
      rig.coordinator.usabilityReadGateForTesting = nil
      if changeRequest { rig.selection.clear() }
      gate.open()
      #expect(
        await read.value == !changeRequest,
        changeRequest ? "v3's answer must not reach the new request" : "control: v3 is ready")
    }
  }

  /// Which newer fact lands while a foreground Resume waits for a held Cancel
  /// drain.
  enum ParkedResumeChange: CaseIterable {
    case none, foregroundCancel, backgroundCancel, exhaustion
  }

  @Test(
    "a foreground Resume parked behind a drain re-checks before it fetches",
    arguments: ParkedResumeChange.allCases)
  func parkedForegroundResume(_ change: ParkedResumeChange) async throws {
    let (rig, gate) = try await Self.heldBackgroundFetch()
    let declined = OutcomeSignal(.declined)
    rig.coordinator.onOutcome = { declined.observe($0) }
    let cancel = Task { try await rig.coordinator.cancelBackgroundUpgrade() }
    await declined.wait()
    let waiting = CleanupEnded()
    rig.coordinator.onResumeWaitingForTesting = { waiting.fire() }
    let resume = Task { await rig.coordinator.fetchInForeground() }
    await waiting.wait()
    rig.coordinator.onResumeWaitingForTesting = nil
    // Each newer command bumps its generation before its first suspension,
    // and `started` fires on the same actor just before the call, so the
    // change has landed when the wait returns.
    var newer: Task<Void, any Error>?
    switch change {
    case .none: break
    case .foregroundCancel:
      let started = CleanupEnded()
      newer = Task {
        started.fire()
        await rig.coordinator.cancelActiveFetch()
      }
      await started.wait()
    case .backgroundCancel:
      let started = CleanupEnded()
      newer = Task {
        started.fire()
        try await rig.coordinator.cancelBackgroundUpgrade()
      }
      await started.wait()
    case .exhaustion:
      try rig.store.write(.init(attempts: 0, refetchSpent: true, exhausted: true, declined: true))
    }
    gate.open()
    try await cancel.value
    try await newer?.value
    let outcome = await resume.value
    await rig.controller.setBeforeExistingCacheValidationForTesting(nil)
    if change == .none {
      #expect(outcome != nil, "control: an unchanged Resume fetches")
    } else {
      #expect(outcome == nil, "the newer \(change) wins over the waiting Resume")
    }
    #expect(rig.coordinator.needsExplicitRetry == (change == .exhaustion))
  }
}

/// Waits for one coordinator outcome, fired by the subject. Deadline-bounded so
/// a missing outcome fails loudly instead of hanging.
@MainActor
private final class OutcomeSignal {
  private let matches: (ParakeetUpgradeCoordinator.Outcome) -> Bool
  private let want: String
  private var seen = false
  private var waiting: CheckedContinuation<Void, Never>?

  init(_ want: ParakeetUpgradeCoordinator.Outcome) {
    self.matches = { $0 == want }
    self.want = "\(want)"
  }

  init(_ label: String, matching: @escaping (ParakeetUpgradeCoordinator.Outcome) -> Bool) {
    self.matches = matching
    self.want = label
  }

  func observe(_ outcome: ParakeetUpgradeCoordinator.Outcome) {
    guard matches(outcome) else { return }
    seen = true
    waiting?.resume()
    waiting = nil
  }

  func wait(sourceLocation: SourceLocation = #_sourceLocation) async {
    if seen { return }
    let deadline = Task { @MainActor [weak self] in
      // deadline-fallback: fail loudly and release a missing-outcome wait.
      try? await Task.sleep(for: .seconds(5))
      guard let self, !self.seen, let waiting = self.waiting else { return }
      Issue.record("outcome \(self.want) never arrived", sourceLocation: sourceLocation)
      self.waiting = nil
      waiting.resume()
    }
    await withCheckedContinuation { waiting = $0 }
    deadline.cancel()
  }
}

/// Fired by the coordinator's cleanup-ended seam. Deadline-bounded so a
/// missing signal fails loudly instead of hanging.
@MainActor
private final class CleanupEnded {
  private var fired = false
  private var waiting: CheckedContinuation<Void, Never>?

  func fire() {
    fired = true
    waiting?.resume()
    waiting = nil
  }

  func wait(sourceLocation: SourceLocation = #_sourceLocation) async {
    if fired { return }
    let deadline = Task { @MainActor [weak self] in
      // deadline-fallback: fail loudly and release a missing-signal wait.
      try? await Task.sleep(for: .seconds(5))
      guard let self, !self.fired, let waiting = self.waiting else { return }
      Issue.record("cleanup never ended", sourceLocation: sourceLocation)
      self.waiting = nil
      waiting.resume()
    }
    await withCheckedContinuation { waiting = $0 }
    deadline.cancel()
  }
}
