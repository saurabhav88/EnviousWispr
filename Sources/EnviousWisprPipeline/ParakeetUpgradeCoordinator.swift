import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// Decides, at each model-selection point, which Parakeet model this Mac loads,
/// and prepares that load (#3546, plan §3.4 and §3b).
///
/// It is the ONE owner of Parakeet selection policy: the engine adapter asks it
/// for a prepared load instead of choosing a directory and mode itself, and
/// direct manager loads (`ActiveEngineOperation`) settle a pending selection
/// through it first. Fetching stays in ModelDelivery and loading stays in
/// `ASRManager`; this type writes the shared `ParakeetSelectionProvider` that
/// `ASRManager` reads.
///
/// Selection points are the app launch and an actual transition into Parakeet
/// (E21). `markSelectionPoint()` records one; the next preparation consumes it.
/// Cold presses, recovery, idle reloads and in-session warm-ups never create
/// one.
///
/// With no upgrade target (production until the Ultra manifest ships), every
/// preparation is exactly the v3 delivery route the adapter ran before this
/// type existed. With a target, a selection point runs the plan §3.4 table
/// (rows K V A A-fail X T B C) and freezes its choice until the next one.
@MainActor
package final class ParakeetUpgradeCoordinator {
  /// One prepared load: the request it published (nil when the request was
  /// cleared and the load will refuse), and whether a failed load of it may
  /// get the delivery repair pass.
  package struct PreparedLoad: Sendable {
    package let selection: ParakeetModelSelection?
    /// True when this load is the one a selection point chose (the initial
    /// load). Only an initial load may fall back to another identity; frozen
    /// reloads (recovery, idle reload, file import) never change it.
    package var isSelectionLoad: Bool = false
  }

  /// The upgrade a configured target enables (plan §3.4). Nil in production
  /// until the Ultra manifest ships; tests inject fixture registrations.
  package struct UpgradeTarget {
    /// The Ultra registration's handle: admission, foreground fetch, repair.
    package let delivery: ParakeetDeliveryHandle
    /// The target's persisted budget.
    package let store: ParakeetUpgradeStateStore
    /// The app-owned `Models` directory every retired install must sit inside.
    package let ownedModelsRoot: URL

    package init(
      delivery: ParakeetDeliveryHandle, store: ParakeetUpgradeStateStore, ownedModelsRoot: URL
    ) {
      self.delivery = delivery
      self.store = store
      self.ownedModelsRoot = ownedModelsRoot
    }
  }

  /// What a failed load should do next.
  package enum FailurePlan: Equatable, Sendable {
    /// A new request was published (repaired cache or fallback identity); load
    /// once more.
    case reload
    /// Surface the original error.
    case fail
  }

  /// Observable transitions (tests now, §3.7 telemetry later). No telemetry.
  package enum Outcome: Equatable, Sendable {
    case selected(ParakeetModel, row: String)
    case activated
    case loadFailed(ParakeetModel)
    case fellBackToV3
    case exhausted
    case refetchStarted
    case retiredV3
    case retirementFailed(ParakeetModel)
    case removedTarget
    case storeUnavailable(String)
    case retryGranted
  }

  /// Ultra loads per bounded cycle before the refetch / exhaustion rows (X).
  package static let attemptBudget = 2

  private let parakeetSelection: ParakeetSelectionProvider
  /// #1348 Phase 2: the delivery stage that runs before any Parakeet load —
  /// nil means the legacy in-service download path (tests, or the flag off).
  private let delivery: ParakeetDeliveryHandle?
  private let target: UpgradeTarget?
  /// The request the last selection point chose, kept until the next one.
  private var frozen: ParakeetModelSelection?
  /// Set at a selection point: whether the owned v3 install is accepted, and
  /// whether v3 genuinely failed to load in this launch (E19).
  private var v3Accepted = false
  private var v3RejectedThisLaunch = false
  /// Observed transitions.
  package var onOutcome: (@MainActor (Outcome) -> Void)?

  /// Selection points recorded and consumed (#3546). A token, not a flag, so a
  /// second launch poke while the first preparation is still running is
  /// coalesced into that preparation rather than lost or doubled.
  private var selectionPointsMarked: UInt64 = 0
  private var selectionPointsConsumed: UInt64 = 0
  /// Single flight: concurrent preparations (a launch warm-up and a direct load
  /// arriving together) share one run of the delivery stage. The first caller
  /// runs it in its OWN task, so cancelling that caller still reaches the
  /// delivery awaits exactly as it did when the adapter ran them inline; later
  /// callers wait for its result.
  private var preparing = false
  private var waiters: [UUID: CheckedContinuation<PreparedLoad, any Error>] = [:]

  /// Test seams (internal): awaited at the start of every delivery stage, and
  /// told when a caller parks behind a running one, so tests can hold a
  /// preparation open and act inside that window without timing guesses.
  var deliveryStageGateForTesting: (@MainActor () async -> Void)?
  var onWaiterParkedForTesting: (@MainActor () -> Void)?

  package init(
    parakeetSelection: ParakeetSelectionProvider, delivery: ParakeetDeliveryHandle?,
    target: UpgradeTarget? = nil
  ) {
    self.parakeetSelection = parakeetSelection
    self.delivery = delivery
    self.target = target
    if target != nil {
      parakeetSelection.beforePhysicalLoad = { [weak self] request in
        try self?.countPhysicalLoad(request)
      }
      parakeetSelection.didPublishLoad = { [weak self] request in
        self?.loadPublished(request)
      }
    }
  }

  /// Records a selection point (launch, or an actual switch into Parakeet).
  package func markSelectionPoint() {
    selectionPointsMarked &+= 1
  }

  package var hasPendingSelectionPoint: Bool {
    selectionPointsConsumed != selectionPointsMarked
  }

  /// Barrier for loads that do not go through the adapter
  /// (`ActiveEngineOperation`): when a selection point is pending, its request
  /// is prepared and published before the load reads one, so a direct load
  /// never consumes the request an earlier selection published.
  @discardableResult
  package func settlePendingSelection() async throws -> PreparedLoad? {
    guard hasPendingSelectionPoint else { return nil }
    return try await prepareLoad()
  }

  /// Runs the delivery stage and publishes the request the next physical load
  /// reads. Joins an in-flight preparation instead of starting a second.
  package func prepareLoad() async throws -> PreparedLoad {
    while true {
      try Task.checkCancellation()

      if preparing {
        do {
          let prepared = try await waitForPreparation()
          // A selection point marked while that preparation ran is not
          // settled by it: prepare again before returning.
          if hasPendingSelectionPoint { continue }
          return prepared
        } catch is CancellationError where !Task.isCancelled {
          // The caller that ran the stage was cancelled; this caller was not,
          // so it runs the stage itself rather than inherit someone else's
          // cancel.
          continue
        }
      }

      preparing = true
      let marked = selectionPointsMarked
      let result: Result<PreparedLoad, any Error>
      do {
        let prepared = try await runDeliveryStage(
          selectionPoint: hasPendingSelectionPoint || frozen == nil)
        try Task.checkCancellation()
        selectionPointsConsumed = marked
        result = .success(prepared)
      } catch {
        result = .failure(error)
      }

      preparing = false
      let joined = waiters
      waiters = [:]
      for waiter in joined.values {
        waiter.resume(with: result)
      }

      let prepared = try result.get()
      if hasPendingSelectionPoint { continue }
      return prepared
    }
  }

  /// Parks behind the running preparation. Cancelling THIS caller removes
  /// only its own wait and never cancels the runner.
  private func waitForPreparation() async throws -> PreparedLoad {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let prepared: PreparedLoad = try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[id] = continuation
          onWaiterParkedForTesting?()
        }
      }
      try Task.checkCancellation()
      return prepared
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
      }
    }
  }

  /// The one-shot load-miss repair for a prepared load (#1348 grounded r1
  /// revision 7). Returns true when the repair admitted the cache again and the
  /// caller may retry the load once.
  package func repairAfterLoadFailure(_ prepared: PreparedLoad) async -> Bool {
    // deliveryActive guarantees the handle exists; a nil here
    // would be a logic error, so fail the warm-up rather than crash.
    guard prepared.selection?.repairable == true, let delivery,
      case .admitted = await delivery.repair()
    else { return false }
    return true
  }

  /// #1388 step 3: the onboarding install Cancel's download half.
  package func cancelActiveFetch() async {
    await delivery?.cancelActiveFetch()
  }

  private func runDeliveryStage(selectionPoint: Bool) async throws -> PreparedLoad {
    if let deliveryStageGateForTesting { await deliveryStageGateForTesting() }
    if let target {
      return try await runTargetStage(target, selectionPoint: selectionPoint)
    }
    // #1348 Phase 2: delivery stage BEFORE any load. The host admits a
    // verified cache (fetch/validate/repair as needed); the service then
    // loads cache-only and can never download. Flag off (or no handle) =
    // legacy path, bit-for-bit.
    // #2697: ONE awaited door, taken before the branch rather than inside it.
    // Migration used to live inside `ensureAvailable()`, so the kill-switch
    // branch below never got it. Whatever the flag says, the location is made
    // ready first, and a REFUSAL arrives as `nil` rather than as a path that
    // looks fine.
    // Review B4: a missing HANDLE is not a refusal and must not be treated as
    // one. It means the bundled manifest failed to load, so there is no
    // registration and nothing has judged anything — while the user may still
    // have a perfectly good model in our own directory. Assigning `nil` there
    // made an existing installation unloadable to fix a problem it does not
    // have. A handle that EXISTS and returns `nil` has genuinely refused, and
    // that still travels to `loadModel()` as a refusal.
    //
    // #3546: the directory and the cache-only mode are written TOGETHER, as one
    // `ParakeetModelSelection`, once both are known. A refusal (or a no-handle
    // branch with no resolvable directory) CLEARS the request, which is what
    // assigning `nil` to the directory used to do, so no later direct load can
    // reuse a refused location.
    var locationRefused = false
    let directory: URL?
    if let delivery {
      let ready = await delivery.ensureModelLocationReady()
      locationRefused = ready == nil
      directory = ready
    } else {
      directory = ParakeetInstallLocation.directoryFromSystemApplicationSupport()
    }
    if directory == nil { parakeetSelection.clear() }
    // Cloud review P1: A REFUSAL STOPS THE ATTEMPT, not just the load.
    //
    // `nil` from the seam means the location was judged unusable — it resolves
    // into the donor, or storage is unavailable. Letting `ensureAvailable()` run
    // anyway sends an attempt at that location, and an attempt DELETES failed
    // components and promotes into it. Refusing at `loadModel()` alone is a
    // refusal that arrives after the writes it was supposed to prevent.
    //
    // This is the same defect the reviewer found at Settings Resume one round
    // earlier. I fixed that door and left this one, which is the MAIN path —
    // so the fix is stated here as a rule rather than a patch: every caller that
    // acts on the location must check the refusal, and there are now three.
    if locationRefused {
      throw ParakeetDeliveryError(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "location_refused"))
    }
    let selection: ParakeetModelSelection?
    if let delivery, delivery.isEnabled() {
      // `directory` is non-nil here: a handle that returned nil refused above.
      selection = directory.map {
        parakeetSelection.select(
          model: .v3, revision: delivery.modelRevision, directory: $0, cacheOnly: true,
          displayBytes: delivery.modelTotalBytes, repairable: true)
      }
      switch await delivery.ensureAvailable() {
      case .admitted:
        break
      case .failed(let failure):
        throw ParakeetDeliveryError(failure)
      case .cancelled:
        throw CancellationError()
      }
    } else {
      // No handle and no resolvable directory leaves the request cleared, and
      // the load below throws `ParakeetModelDirectoryUnsetError`, as before.
      selection = directory.map {
        parakeetSelection.select(
          model: .v3, revision: delivery?.modelRevision, directory: $0, cacheOnly: false,
          displayBytes: delivery?.modelTotalBytes ?? ParakeetModel.v3ShippedBytes,
          repairable: false)
      }
      // #2483: the legacy branch uses our directory TOO, and this is the half
      // that closes the vendor's own deletion. With `cacheOnly` false,
      // FluidAudio's offline switch is off, so `ModelHub.loadModels` may purge
      // the whole repo directory after a failed load and may write a vocabulary
      // file into it. Both are acceptable inside a directory we own and were
      // never acceptable inside FluidAudio's shared one.
      //
      // #2697: the directory is assigned above, before this branch, and it has
      // already been migrated. This branch used to resolve its own fallback,
      // which is why a user on the kill switch re-downloaded a model they
      // already had — and, offline, could not warm up at all.
      delivery?.noteLegacyPathActive()
    }
    return PreparedLoad(selection: selection, isSelectionLoad: selectionPoint)
  }
}

/// Thrown when the upgrade policy will not start an Ultra load: the target's
/// budget is spent (row T), or its persisted state cannot be read. Never a
/// loader failure, so it never triggers repair or fallback.
package struct ParakeetUpgradeUnavailableError: Error, Equatable {
  package let reason: String
  package init(reason: String) { self.reason = reason }
}

// MARK: - Upgrade policy with a configured target (plan §3.4)

extension ParakeetUpgradeCoordinator {
  /// The load accounting hook (`ParakeetSelectionProvider.beforePhysicalLoad`):
  /// once per PHYSICAL Ultra load, after offline-mode admission and before the
  /// vendor. Checks the budget BEFORE spending it, so a frozen reload cannot
  /// exceed it either, and persists the attempt before returning.
  func countPhysicalLoad(_ request: ParakeetModelSelection) throws {
    guard request.model == .ultra, let target else { return }
    switch target.store.read() {
    case .unreadable(let reason):
      onOutcome?(.storeUnavailable(reason))
      throw ParakeetUpgradeUnavailableError(reason: "state_unreadable")
    case .state(var state):
      guard !state.exhausted, state.attempts < Self.attemptBudget else {
        throw ParakeetUpgradeUnavailableError(reason: "budget_spent")
      }
      state.attempts += 1
      try target.store.write(state)
    }
  }

  /// The success hook (`didPublishLoad`): a READY Ultra publish for the frozen
  /// generation activates Ultra. The state reset is checked: if it cannot be
  /// written, Ultra keeps serving, the failure is reported as a store failure,
  /// and v3 is kept until a later activation resets cleanly. Only then is v3
  /// retired, off the main actor, after readiness was published.
  func loadPublished(_ request: ParakeetModelSelection) {
    guard request.model == .ultra, let target, request.generation == frozen?.generation else {
      return
    }
    do {
      try target.store.write(.fresh)
    } catch {
      onOutcome?(.storeUnavailable("reset"))
      return
    }
    onOutcome?(.activated)
    guard let delivery else { return }
    let root = target.ownedModelsRoot
    Task { @MainActor [weak self] in
      let retired = await delivery.retireOwnedInstall(ownedModelsRoot: root)
      self?.onOutcome?(retired ? .retiredV3 : .retirementFailed(.v3))
    }
  }

  /// What a failed load should do next. Cancellation, supersession, store and
  /// budget refusals are never loader failures: no repair, fallback, refetch or
  /// deletion follows them (E23), and an attempt already counted stays spent.
  package func handleLoadFailure(_ prepared: PreparedLoad, error: any Error) async -> FailurePlan {
    if error is CancellationError || error is ASRLoadCancelledError
      || error is ASRLoadSupersededError || error is ParakeetUpgradeStoreWriteError
      || error is ParakeetUpgradeUnavailableError || error is ParakeetLoadAccountingUnavailableError
    {
      return .fail
    }
    guard let target else {
      // No target: the one-shot load-miss repair, unchanged.
      return await repairAfterLoadFailure(prepared) ? .reload : .fail
    }
    guard let request = prepared.selection else { return .fail }
    onOutcome?(.loadFailed(request.model))
    switch request.model {
    case .ultra:
      // A-fail: accepted v3 serves now, in the same selection attempt.
      if prepared.isSelectionLoad, v3Accepted, let v3 = v3Request() {
        freeze(v3)
        onOutcome?(.fellBackToV3)
        return .reload
      }
      // No v3: the existing bounded repair of Ultra; the budget hook bounds it.
      if request.repairable, case .admitted = await target.delivery.repair() {
        return .reload
      }
      return .fail
    case .v3:
      // E19: v3 is rejected for this launch and is never repaired through the
      // Ultra handle. Only the initial load may move on, within the budget.
      v3RejectedThisLaunch = true
      v3Accepted = false
      guard prepared.isSelectionLoad else { return .fail }
      do {
        guard try await chooseUltraWithoutV3(target) != nil else { return .fail }
        return .reload
      } catch {
        return .fail
      }
    }
  }

  /// Explicit Retry: proves the store can be written, then grants one new
  /// bounded recovery cycle (attempts, refetch and exhaustion reset; a decline
  /// stays) and marks a selection point. Never automatic.
  package func retry() throws {
    guard let target else { return }
    try target.store.probeWritable()
    var state = ParakeetUpgradeState.fresh
    if case .state(let current) = target.store.read() { state.declined = current.declined }
    try target.store.write(state)
    onOutcome?(.retryGranted)
    markSelectionPoint()
  }

  // MARK: Selection

  func runTargetStage(_ target: UpgradeTarget, selectionPoint: Bool) async throws -> PreparedLoad {
    guard selectionPoint || frozen == nil else {
      // Frozen: cold presses, recovery, idle reloads and file import reload the
      // identity the last selection point chose, without re-deciding.
      if let frozen, parakeetSelection.current != frozen { freeze(frozen) }
      return PreparedLoad(selection: frozen, isSelectionLoad: false)
    }
    let enabled = (delivery ?? target.delivery).isEnabled()
    var state = ParakeetUpgradeState.fresh
    var exhausted = false
    switch target.store.read() {
    case .state(let current):
      state = current
      exhausted = current.exhausted
    case .unreadable(let reason):
      onOutcome?(.storeUnavailable(reason))
      exhausted = true
    }
    v3Accepted = v3RejectedThisLaunch ? false : await acceptV3()

    // K: delivery off. No owned Ultra fetch, repair or admission.
    if !enabled {
      if v3Accepted, let v3 = v3Request() { return selected(v3, row: "K") }
      if exhausted { throw rowT() }
      return selected(ultraRequest(target, cacheOnly: false, repairable: false), row: "K")
    }
    // V / T: exhausted.
    if exhausted {
      if v3Accepted, let v3 = v3Request() {
        removeTargetBytes(target)
        return selected(v3, row: "V")
      }
      throw rowT()
    }
    if await target.delivery.isAdmitted() {
      // A: admitted, within budget.
      if state.attempts < Self.attemptBudget {
        return selected(
          ultraRequest(target, cacheOnly: true, repairable: !v3Accepted), row: "A")
      }
      // X: the budget is spent on these bytes.
      do {
        if !state.refetchSpent {
          state.refetchSpent = true
          try target.store.write(state)  // refetch intent BEFORE deleting
          onOutcome?(.refetchStarted)
          if await target.delivery.retireOwnedInstall(ownedModelsRoot: target.ownedModelsRoot) {
            onOutcome?(.removedTarget)
          } else {
            onOutcome?(.retirementFailed(.ultra))
          }
          state.attempts = 0
          try target.store.write(state)
        } else {
          state.exhausted = true
          try target.store.write(state)
          onOutcome?(.exhausted)
          if v3Accepted, let v3 = v3Request() {
            removeTargetBytes(target)
            return selected(v3, row: "X")
          }
          throw rowT()  // no v3: Ultra bytes are retained
        }
      } catch let failure as ParakeetUpgradeStoreWriteError {
        // Store failure: no Ultra work and no row C. Accepted v3 still serves.
        onOutcome?(.storeUnavailable(failure.field))
        if v3Accepted, let v3 = v3Request() { return selected(v3, row: "store") }
        throw failure
      }
    }
    // B: Ultra not admitted, v3 accepted (background fetch arrives with 7b-2).
    if v3Accepted, let v3 = v3Request() { return selected(v3, row: "B") }
    // C: neither available: foreground Ultra fetch and load within budget.
    return try await foregroundUltra(target)
  }

  /// E19's continuation when v3 failed at its initial load: Ultra within the
  /// budget (A or C), never by repairing v3. Nil when nothing is allowed.
  private func chooseUltraWithoutV3(
    _ target: UpgradeTarget
  ) async throws -> ParakeetModelSelection? {
    guard case .state(let state) = target.store.read(), !state.exhausted,
      state.attempts < Self.attemptBudget
    else { return nil }
    let enabled = (delivery ?? target.delivery).isEnabled()
    if !enabled {
      return freeze(ultraRequest(target, cacheOnly: false, repairable: false))
    }
    if await target.delivery.isAdmitted() {
      return freeze(ultraRequest(target, cacheOnly: true, repairable: true))
    }
    return try await foregroundUltra(target).selection
  }

  private func foregroundUltra(_ target: UpgradeTarget) async throws -> PreparedLoad {
    let request = selected(ultraRequest(target, cacheOnly: true, repairable: true), row: "C")
    switch await target.delivery.ensureAvailable() {
    case .admitted:
      return request
    case .failed(let failure):
      throw ParakeetDeliveryError(failure)
    case .cancelled:
      throw CancellationError()
    }
  }

  /// v3 accepted (plan §3.4): the admission fast path, then a full validation
  /// of the owned install with a marker refresh, then read-only donor recovery
  /// (a completed migration record does not stop it; a deliberate decline
  /// does) followed by validation again. Never fetches.
  private func acceptV3() async -> Bool {
    guard let delivery, delivery.locationIsUsable else { return false }
    if await delivery.isAdmitted() { return true }
    if await delivery.admitIfComplete() { return true }
    await delivery.recoverFromDonor()
    return await delivery.admitIfComplete()
  }

  private func v3Request() -> ParakeetModelSelection? {
    guard let delivery else { return nil }
    return parakeetSelection.select(
      model: .v3, revision: delivery.modelRevision, directory: delivery.installDirectory,
      cacheOnly: true, displayBytes: delivery.modelTotalBytes, repairable: false)
  }

  private func ultraRequest(
    _ target: UpgradeTarget, cacheOnly: Bool, repairable: Bool
  ) -> ParakeetModelSelection {
    parakeetSelection.select(
      model: .ultra, revision: target.delivery.modelRevision,
      directory: target.delivery.installDirectory, cacheOnly: cacheOnly,
      displayBytes: target.delivery.modelTotalBytes, repairable: repairable)
  }

  @discardableResult
  private func freeze(_ request: ParakeetModelSelection) -> ParakeetModelSelection {
    let published =
      parakeetSelection.current == request
      ? request
      : parakeetSelection.select(
        model: request.model, revision: request.revision, directory: request.directory,
        cacheOnly: request.cacheOnly, displayBytes: request.displayBytes,
        repairable: request.repairable)
    frozen = published
    return published
  }

  private func selected(_ request: ParakeetModelSelection, row: String) -> PreparedLoad {
    frozen = request
    onOutcome?(.selected(request.model, row: row))
    return PreparedLoad(selection: request, isSelectionLoad: true)
  }

  private func rowT() -> ParakeetUpgradeUnavailableError {
    onOutcome?(.exhausted)
    parakeetSelection.clear()
    frozen = nil
    return ParakeetUpgradeUnavailableError(reason: "exhausted")
  }

  /// Rows V and X with v3: the exhausted target's bytes go, off the main actor,
  /// without making v3 service wait on the deletion or depend on it.
  private func removeTargetBytes(_ target: UpgradeTarget) {
    let handle = target.delivery
    let root = target.ownedModelsRoot
    Task { @MainActor [weak self] in
      let removed = await handle.retireOwnedInstall(ownedModelsRoot: root)
      self?.onOutcome?(removed ? .removedTarget : .retirementFailed(.ultra))
    }
  }
}
