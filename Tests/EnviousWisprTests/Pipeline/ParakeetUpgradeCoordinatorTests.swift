import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

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
  private var deadlineTask: Task<Void, Never>?

  init(
    deadline: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
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

  private func failAndRelease(sourceLocation: SourceLocation) {
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

@MainActor
@Suite(.tags(.harnessContract))
struct ParakeetUpgradeStageGateTests {
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
  final class WriteSwitch: @unchecked Sendable {
    var failing = false
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
    _ files: [(path: String, content: Data, component: String)], name: String
  ) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: files,
        sources: [
          ["id": "our_copy", "baseURL": "https://upgrade.invalid.example/\(name)/"],
          ["id": "backup", "baseURL": "https://upgrade.invalid.example/\(name)-b/"],
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
    v3Donor: Bool = false
  ) async throws -> Rig {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-upgrade-\(UUID().uuidString)", isDirectory: true)
    let data = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    let models = data.appendingPathComponent("Models", isDirectory: true)
    let metadata = data.appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let donor = root.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
    let v3Registration = DeliveryRegistration(
      manifest: try manifest(v3Files, name: "v3-fixture"),
      installDirectory: ParakeetInstallLocation.directory(for: .v3, dataDirectory: data),
      metadataDirectory: metadata, legacyDonorDirectory: v3Donor ? donor : nil)
    let ultraRegistration = DeliveryRegistration(
      manifest: try manifest(ultraFiles, name: "ultra-fixture"),
      installDirectory: ParakeetInstallLocation.directory(for: .ultra, dataDirectory: data),
      metadataDirectory: metadata)
    let suite = "test.upgrade.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(suite)!
    defaults.set(enabled, forKey: DeliveryFlags.key("enabled", family: .parakeet))
    let controller = ModelDeliveryController(
      defaults: TestDefaults.suite(suite)!, availableDiskBytes: { _ in .max })
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
        if writes.failing { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
      },
      removeItem: { url in
        if writes.failing { throw CocoaError(.fileWriteNoPermission) }
        try LegacyRetirement.clearMarker(url)
      })
    if let state { try store.write(state) }
    let v3Handle = ParakeetDeliveryHandle(
      controller: controller, registration: v3Registration, defaults: defaults)
    let ultraHandle = ParakeetDeliveryHandle(
      controller: controller, registration: ultraRegistration, defaults: defaults)
    let selection = ParakeetSelectionProvider()
    var rig = Rig(
      root: root, models: models, metadata: metadata, controller: controller,
      v3Registration: v3Registration, ultraRegistration: ultraRegistration, v3: v3Handle,
      ultra: ultraHandle, store: store, selection: selection, defaults: defaults,
      writes: writes,
      coordinator: ParakeetUpgradeCoordinator(
        parakeetSelection: selection, delivery: v3Handle,
        target: .init(delivery: ultraHandle, store: store, ownedModelsRoot: models)))
    rig.coordinator.markSelectionPoint()
    return rig
  }

  /// A relaunch: a fresh coordinator over the SAME disk and store.
  static func relaunch(_ rig: Rig) -> Rig {
    var next = rig
    let selection = ParakeetSelectionProvider()
    next.coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: selection, delivery: rig.v3,
      target: .init(delivery: rig.ultra, store: rig.store, ownedModelsRoot: rig.models))
    next.coordinator.markSelectionPoint()
    return Rig(
      root: next.root, models: next.models, metadata: next.metadata,
      controller: next.controller, v3Registration: next.v3Registration,
      ultraRegistration: next.ultraRegistration, v3: next.v3, ultra: next.ultra,
      store: next.store, selection: selection, defaults: next.defaults, writes: next.writes,
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
    guard let request = rig.selection.current else { Issue.record("no request"); return }
    try rig.selection.beforePhysicalLoad?(request)
    rig.writes.failing = true
    rig.selection.didPublishLoad?(request)
    rig.writes.failing = false
    #expect(outcomes.contains(.storeUnavailable("reset")))
    #expect(outcomes.contains(.activated) == false)
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

  @Test("donor recovery is not stopped by a completed record, and is stopped by a decline")
  func donorRecoveryHonoursOnlyDecline() async throws {
    let rig = try await Self.rig(v3: false, ultra: false, enabled: false, v3Donor: true)
    let donor = try #require(rig.v3Registration.legacyDonorDirectory)
    try Self.install(Self.v3Files, into: donor)
    #expect(LegacyDonorMigration.record(
      .completed, metadataDirectory: rig.metadata, manifest: rig.v3Registration.manifest))
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3, "recovered from the donor despite the record")
    let declined = try await Self.rig(v3: false, ultra: false, enabled: false, v3Donor: true)
    try Self.install(Self.v3Files, into: try #require(declined.v3Registration.legacyDonorDirectory))
    #expect(LegacyDonorMigration.record(
      .declined, metadataDirectory: declined.metadata, manifest: declined.v3Registration.manifest))
    let vendor = try await declined.coordinator.prepareLoad()
    #expect(vendor.selection?.model == .ultra, "a deliberate decline is honoured")
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
    let elsewhere = rig.root.appendingPathComponent("NotModels", isDirectory: true)
    let ok = await rig.v3.retireOwnedInstall(ownedModelsRoot: elsewhere)
    #expect(ok == false)
    #expect(FileManager.default.fileExists(atPath: rig.v3Registration.installDirectory.path))
    #expect(await rig.controller.isAdmitted(rig.v3Registration))
  }

  @Test("retirement removes unlisted remnants, the marker and staging, and records no decline")
  func retirementRemovesEverything() async throws {
    let rig = try await Self.rig(v3: true, ultra: false, v3Donor: true)
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
  }
}

/// Waits for one coordinator outcome, fired by the subject. Deadline-bounded so
/// a missing outcome fails loudly instead of hanging.
@MainActor
private final class OutcomeSignal {
  private let want: ParakeetUpgradeCoordinator.Outcome
  private var seen = false
  private var waiting: CheckedContinuation<Void, Never>?

  init(_ want: ParakeetUpgradeCoordinator.Outcome) { self.want = want }

  func observe(_ outcome: ParakeetUpgradeCoordinator.Outcome) {
    guard outcome == want else { return }
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
