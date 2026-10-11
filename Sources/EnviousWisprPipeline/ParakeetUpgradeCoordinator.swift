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
    /// The Ultra registration's handle: admission, foreground fetch, repair,
    /// and the background fetch. Built with `.scoped` progress ownership, so
    /// background work never writes the foreground warm-up's progress.
    package let delivery: ParakeetDeliveryHandle
    /// The target's persisted budget.
    package let store: ParakeetUpgradeStateStore
    /// The app-owned `Models` directory every retired install must sit inside.
    package let ownedModelsRoot: URL

    package init(
      delivery: ParakeetDeliveryHandle, store: ParakeetUpgradeStateStore, ownedModelsRoot: URL
    ) {
      precondition(
        delivery.progressOwnership == .scoped,
        "the upgrade target's handle must not own the foreground progress channel")
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
    case backgroundStarted
    case backgroundAdmitted
    case deferredDisk
    case backgroundFetchFailed(String)
    case declined
    case resumed
  }

  /// The background Ultra download, for Settings (chunk 8). Serving-model
  /// readiness keeps its own channel; this never describes the model in use.
  package enum BackgroundUpgradeState: Equatable, Sendable {
    case idle
    /// Carried together from one generation-qualified delivery state, so the
    /// counts shown always belong to the same attempt.
    case downloading(fraction: Double, bytesWritten: Int64, totalBytes: Int64)
    case declined
    case deferredDisk
    case failed
  }

  /// Ultra loads per bounded cycle before the refetch / exhaustion rows (X).
  package static let attemptBudget = 2

  private let parakeetSelection: ParakeetSelectionProvider
  /// #1348 Phase 2: the delivery stage that runs before any Parakeet load —
  /// nil means the legacy in-service download path (tests, or the flag off).
  private let delivery: ParakeetDeliveryHandle?
  private let target: UpgradeTarget?
  /// The request the last selection point chose, kept until the next one.
  private var frozen: ParakeetModelSelection? {
    didSet { onPresentationChanged?() }
  }
  /// Set at a selection point: whether the owned v3 install is accepted, and
  /// whether v3 genuinely failed to load in this launch (E19).
  private var v3Accepted = false
  private var v3RejectedThisLaunch = false
  /// The selection-point token `frozen` was chosen under; queued cleanup is
  /// valid only while it still matches.
  private var frozenSelectionPoint: UInt64 = 0
  /// Queued deletions (v3 retirement, target removal), one per model. A new
  /// selection point or a changed identity cancels them, so bytes are never
  /// deleted on behalf of a decision that no longer holds.
  private var cleanupTasks: [ParakeetModel: (id: UUID, task: Task<Void, Never>)] = [:]
  /// Observed transitions.
  package var onOutcome: (@MainActor (Outcome) -> Void)?
  /// Invites companion policies to re-read `isParakeetUsable()`; it never
  /// grants usability itself.
  package var onUsabilityMayHaveChanged: (@MainActor () -> Void)?
  /// Whether the manager has a Parakeet model loaded right now. Set by the
  /// bootstrapper; nil reads as not ready.
  package var servingReadiness: (@MainActor () -> Bool)?
  /// The last request a READY load published for the current selection.
  private var servingRequest: ParakeetModelSelection? {
    didSet { onPresentationChanged?() }
  }
  /// Told whenever something Settings presents may have changed: the serving
  /// or frozen model, the background download, or whether an explicit Retry is
  /// needed. Observers re-read; it carries no state.
  package var onPresentationChanged: (@MainActor () -> Void)?
  /// True after the policy refused Ultra for its budget, exhaustion or an
  /// unreadable store (row T and the load-time refusals), until a ready
  /// publish, a new selection or a successful Retry. Settings shows the
  /// explicit Retry only from this, never from the persisted flags alone.
  package private(set) var needsExplicitRetry = false {
    didSet { if needsExplicitRetry != oldValue { onPresentationChanged?() } }
  }

  package private(set) var backgroundUpgrade: BackgroundUpgradeState = .idle
  package var onBackgroundUpgradeChanged: (@MainActor (BackgroundUpgradeState) -> Void)?
  private let isOnboardingComplete: @MainActor () -> Bool
  /// One background fetch at a time. The slot is reserved before any await;
  /// only its own generation may clear it, report state or emit an outcome.
  private var backgroundFetch: (generation: UInt64, task: Task<Void, Never>)?
  private var backgroundGeneration: UInt64 = 0
  /// A Cancel in this process stops automatic background work until Resume
  /// succeeds, even when the decline could not be persisted.
  private var backgroundSuppressed = false
  /// Cancel's transport drain; Resume waits for it.
  private var cancelDrain: Task<Void, Never>?
  /// Bumped by every Cancel and Resume, so a Resume that waited on a drain
  /// does nothing if a newer command arrived meanwhile.
  private var backgroundCommandGeneration: UInt64 = 0
  /// The background generation that owns the target's delivery events, read
  /// at publication so an old attempt's progress is never attributed to a
  /// newer one.
  private let backgroundPublication = BackgroundPublicationToken()
  /// Foreground Ultra operations (row C fetch, repair) in flight.
  private var foregroundFetches = 0

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
  /// Told when a queued cleanup task ends, whether it deleted, refused or was
  /// cancelled, so tests can wait for it without timing guesses.
  var onCleanupEndedForTesting: (@MainActor (ParakeetModel) -> Void)?
  /// Awaited after each admission read in `isParakeetUsable()`, so a test can
  /// change the facts inside that await.
  var usabilityReadGateForTesting: (@MainActor () async -> Void)?
  /// Told when Resume starts waiting for a Cancel's drain.
  var onResumeWaitingForTesting: (@MainActor () -> Void)?

  /// `isOnboardingComplete` gates background work only (E22 starts it later);
  /// it defaults closed.
  package init(
    parakeetSelection: ParakeetSelectionProvider, delivery: ParakeetDeliveryHandle?,
    target: UpgradeTarget? = nil,
    isOnboardingComplete: @escaping @MainActor () -> Bool = { false }
  ) {
    self.parakeetSelection = parakeetSelection
    self.delivery = delivery
    self.target = target
    self.isOnboardingComplete = isOnboardingComplete
    if let target {
      // A persisted decline is shown after relaunch (Settings' Resume row).
      if case .state(let state) = target.store.read(), state.declined {
        backgroundUpgrade = .declined
      }
      let publication = backgroundPublication
      target.delivery.observeState(capture: { publication.read() }) {
        [weak self] state, generation in
        self?.targetStateChanged(state, generation: generation)
      }
      parakeetSelection.beforePhysicalLoad = { [weak self] request in
        // No owner means no accounting: refuse rather than load uncounted.
        guard let self else { throw ParakeetLoadAccountingUnavailableError() }
        try self.countPhysicalLoad(request)
      }
      parakeetSelection.didPublishLoad = { [weak self] request in
        self?.loadPublished(request)
      }
    }
  }

  /// Records a selection point (launch, or an actual switch into Parakeet).
  package func markSelectionPoint() {
    cancelCleanupTasks()
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

  /// The one load-and-recover sequence both load doors run (the engine
  /// adapter's warm-up and `ActiveEngineOperation`), so neither door can skip
  /// a step of the failure plan on its second load.
  ///
  /// No target, or a frozen reload: one load and at most one reload (the
  /// one-shot repair, unchanged). An initial load under a target may also take
  /// A-fail or E19, which allows at most two Ultra loads and one v3 load; the
  /// persisted Ultra budget stays the authoritative limit.
  ///
  /// `checkCaller` throws when the calling warm-up or operation is stale. With
  /// a target it runs before the failure plan too, because that plan can
  /// publish a new identity; without one the plan only repairs, as before.
  package func loadPrepared(
    _ prepared: PreparedLoad,
    checkCaller: @MainActor () throws -> Void,
    load: @MainActor () async throws -> Void
  ) async throws {
    let maxLoads = target != nil && prepared.isSelectionLoad ? 3 : 2
    var current = prepared
    var loads = 0
    while true {
      do {
        loads += 1
        try await load()
        return
      } catch {
        if target != nil { try checkCaller() }
        // Without a target the second failure is terminal before any plan, as
        // before. With one, every failure, the last included, reaches the plan
        // so its outcome is reported; the persisted budget keeps a terminal
        // plan from repairing.
        if target == nil, loads >= maxLoads { throw error }
        let plan = await handleLoadFailure(current, error: error)
        guard loads < maxLoads, plan == .reload else { throw error }
        try checkCaller()
        if target != nil {
          current = PreparedLoad(selection: frozen, isSelectionLoad: current.isSelectionLoad)
        }
      }
    }
  }

  /// #1388 step 3: the onboarding install Cancel's download half.
  ///
  /// With a target, only a FOREGROUND Ultra fetch (row C, a repair) is
  /// cancelled, and never as a decline; nothing foreground in flight makes
  /// this a no-op. A foreground caller that joined background work shares its
  /// one controller attempt, so that attempt is cancelled too, and the
  /// background observation is invalidated so no stale completion reports.
  package func cancelActiveFetch() async {
    guard let target else {
      await delivery?.cancelActiveFetch()
      return
    }
    guard foregroundFetches > 0 else { return }
    if backgroundFetch != nil {
      invalidateBackgroundFetch()
      setBackgroundUpgrade(.idle)
    }
    await enqueueCancelDrain(target.delivery).value
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
  /// Whether `request` is still the load this coordinator wants: no newer
  /// selection point is pending, and it is both the frozen choice and the
  /// published request. A stale load may not spend, publish, fall back, reset
  /// or delete anything.
  func isCurrentLoad(_ request: ParakeetModelSelection) -> Bool {
    !hasPendingSelectionPoint && frozen == request && parakeetSelection.current == request
  }

  /// The load accounting hook (`ParakeetSelectionProvider.beforePhysicalLoad`):
  /// once per PHYSICAL load, after offline-mode admission and before the
  /// vendor. A stale load is refused as superseded. For Ultra it checks the
  /// budget BEFORE spending it, so a frozen reload cannot exceed it either, and
  /// persists the attempt before returning.
  func countPhysicalLoad(_ request: ParakeetModelSelection) throws {
    guard isCurrentLoad(request), !Task.isCancelled else { throw ASRLoadSupersededError() }
    guard request.model == .ultra, let target else { return }
    switch target.store.read() {
    case .unreadable(let reason):
      needsExplicitRetry = true
      emit(.storeUnavailable(reason))
      throw ParakeetUpgradeUnavailableError(reason: "state_unreadable")
    case .state(var state):
      guard !state.exhausted, state.attempts < Self.attemptBudget else {
        needsExplicitRetry = true
        throw ParakeetUpgradeUnavailableError(reason: "budget_spent")
      }
      state.attempts += 1
      try target.store.write(state)
      onPresentationChanged?()
    }
  }

  /// The success hook (`didPublishLoad`): a READY Ultra publish for the current
  /// load activates Ultra. The state reset is checked: if it cannot be
  /// written, Ultra keeps serving, the failure is reported as a store failure,
  /// and v3 is kept until a later activation resets cleanly. Only then is v3
  /// retirement queued, off the main actor, after readiness was published.
  func loadPublished(_ request: ParakeetModelSelection) {
    guard isCurrentLoad(request) else { return }
    servingRequest = request
    needsExplicitRetry = false
    guard request.model == .ultra, let target else {
      onUsabilityMayHaveChanged?()
      return
    }
    do {
      try target.store.write(.fresh)
    } catch {
      emit(.storeUnavailable("reset"))
      return
    }
    emit(.activated)
    guard let delivery, isCurrentLoad(request) else { return }
    scheduleCleanup(delivery, model: .v3, selection: request, root: target.ownedModelsRoot)
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
    // An offline-mode refusal happens before the vendor, so under a target it
    // is no loader failure either. (Without a target it keeps the one-shot
    // repair it always had.)
    if error is ParakeetOfflineModeConflictError { return .fail }
    // A stale load (a newer selection point, or a request no longer frozen)
    // may not reject v3 or publish a fallback over the newer choice.
    guard let request = prepared.selection, isCurrentLoad(request), !Task.isCancelled else {
      return .fail
    }
    emit(.loadFailed(request.model))
    switch request.model {
    case .ultra:
      // A-fail: accepted v3 serves now, in the same selection attempt.
      if prepared.isSelectionLoad, v3Accepted, let v3 = v3Request() {
        freeze(v3)
        emit(.fellBackToV3)
        return .reload
      }
      // No v3: the existing bounded repair of Ultra, only while the budget
      // allows another load; a repair after the last permitted attempt would
      // fetch bytes nothing may load.
      if request.repairable,
        case .state(let state) = target.store.read(),
        !state.exhausted, state.attempts < Self.attemptBudget,
        case .admitted = await foreground({ await target.delivery.repairInForeground() })
      {
        guard isCurrentLoad(request), !Task.isCancelled else { return .fail }
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
        guard try await chooseUltraWithoutV3(target, replacing: request) != nil else {
          return .fail
        }
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
    needsExplicitRetry = false
    emit(.retryGranted)
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
      emit(.storeUnavailable(reason))
      exhausted = true
    }
    v3Accepted = v3RejectedThisLaunch ? false : await acceptV3()

    // The legacy route's location refusal (#2697) holds for the target too:
    // nothing reads, fetches into or deletes from a refused Ultra location.
    guard target.delivery.locationIsUsable else {
      if v3Accepted, let v3 = v3Request() { return selected(v3, row: "location_refused") }
      throw ParakeetDeliveryError(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "location_refused"))
    }

    // K: delivery off. No owned Ultra fetch, repair or admission.
    if !enabled {
      if v3Accepted, let v3 = v3Request() { return selected(v3, row: "K") }
      if exhausted { throw rowT() }
      return selected(ultraRequest(target, cacheOnly: false, repairable: false), row: "K")
    }
    // V / T: exhausted.
    if exhausted {
      if v3Accepted, let v3 = v3Request() {
        let prepared = selected(v3, row: "V")
        removeTargetBytes(target, selection: v3)
        return prepared
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
          emit(.refetchStarted)
          guard
            await target.delivery.retireOwnedInstall(ownedModelsRoot: target.ownedModelsRoot)
          else {
            // A cancelled preparation decides nothing; the next selection
            // point continues from the persisted state.
            try Task.checkCancellation()
            // Bytes that cannot be removed cannot be refetched: the spent
            // count and the refetch intent stay, and the target is exhausted.
            emit(.retirementFailed(.ultra))
            state.exhausted = true
            try target.store.write(state)
            if v3Accepted, let v3 = v3Request() { return selected(v3, row: "V") }
            throw rowT()
          }
          try Task.checkCancellation()
          emit(.removedTarget)
          state.attempts = 0
          try target.store.write(state)
        } else {
          state.exhausted = true
          try target.store.write(state)
          emit(.exhausted)
          if v3Accepted, let v3 = v3Request() {
            let prepared = selected(v3, row: "X")
            removeTargetBytes(target, selection: v3)
            return prepared
          }
          throw rowT()  // no v3: Ultra bytes are retained
        }
      } catch let failure as ParakeetUpgradeStoreWriteError {
        // Store failure: no Ultra work and no row C. Accepted v3 still serves.
        emit(.storeUnavailable(failure.field))
        if v3Accepted, let v3 = v3Request() { return selected(v3, row: "store") }
        throw failure
      }
    }
    // B: Ultra not admitted, v3 accepted. v3 is published first; the
    // background fetch starts after, so v3's load never waits on it.
    if v3Accepted, let v3 = v3Request() {
      let prepared = selected(v3, row: "B")
      scheduleBackgroundFetch()
      return prepared
    }
    // C: neither available: foreground Ultra fetch and load within budget.
    return try await foregroundUltra(target)
  }

  /// E19's continuation when v3 failed at its initial load: Ultra within the
  /// budget (A or C), never by repairing v3. Nil when nothing is allowed.
  private func chooseUltraWithoutV3(
    _ target: UpgradeTarget,
    replacing request: ParakeetModelSelection
  ) async throws -> ParakeetModelSelection? {
    guard isCurrentLoad(request), !Task.isCancelled,
      case .state(let state) = target.store.read(),
      !state.exhausted, state.attempts < Self.attemptBudget
    else { return nil }
    guard target.delivery.locationIsUsable else {
      throw ParakeetDeliveryError(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "location_refused"))
    }
    if !(delivery ?? target.delivery).isEnabled() {
      return freeze(ultraRequest(target, cacheOnly: false, repairable: false))
    }
    let admitted = await target.delivery.isAdmitted()
    guard isCurrentLoad(request), !Task.isCancelled else { return nil }
    if admitted {
      return freeze(ultraRequest(target, cacheOnly: true, repairable: true))
    }
    return try await foregroundUltra(target, replacing: request).selection
  }

  /// Row C: fetch and admit Ultra in the foreground, and only then publish it,
  /// so a failed or cancelled fetch leaves nothing frozen. Within the budget and
  /// the location refusal, like every other Ultra route.
  private func foregroundUltra(
    _ target: UpgradeTarget,
    replacing request: ParakeetModelSelection? = nil
  ) async throws -> PreparedLoad {
    try Task.checkCancellation()
    guard target.delivery.locationIsUsable else {
      throw ParakeetDeliveryError(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "location_refused"))
    }
    guard case .state(let state) = target.store.read(),
      !state.exhausted, state.attempts < Self.attemptBudget
    else {
      needsExplicitRetry = true
      throw ParakeetUpgradeUnavailableError(reason: "budget_spent")
    }
    switch await foreground({ await target.delivery.ensureAvailableInForeground() }) {
    case .admitted:
      try Task.checkCancellation()
      if let request, !isCurrentLoad(request) { throw ASRLoadSupersededError() }
      return selected(ultraRequest(target, cacheOnly: true, repairable: true), row: "C")
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
    if frozen != published { cancelCleanupTasks() }
    frozenSelectionPoint = selectionPointsMarked
    frozen = published
    return published
  }

  private func selected(_ request: ParakeetModelSelection, row: String) -> PreparedLoad {
    needsExplicitRetry = false
    if frozen != request { cancelCleanupTasks() }
    frozenSelectionPoint = selectionPointsMarked
    frozen = request
    emit(.selected(request.model, row: row))
    return PreparedLoad(selection: request, isSelectionLoad: true)
  }

  private func rowT() -> ParakeetUpgradeUnavailableError {
    needsExplicitRetry = true
    emit(.exhausted)
    parakeetSelection.clear()
    frozen = nil
    return ParakeetUpgradeUnavailableError(reason: "exhausted")
  }

  /// Rows V and X with v3: the exhausted target's bytes go, off the main actor,
  /// without making v3 service wait on the deletion or depend on it.
  private func removeTargetBytes(_ target: UpgradeTarget, selection: ParakeetModelSelection) {
    scheduleCleanup(
      target.delivery, model: .ultra, selection: selection, root: target.ownedModelsRoot)
  }

  /// Queues one deletion that runs only while the decision that queued it
  /// still holds: the same selection point and the same frozen request, before
  /// and after the delivery drain. A new selection point (including Retry) or
  /// a changed identity cancels it; the controller checks cancellation around
  /// its drain, so a cancelled cleanup deletes nothing and reports nothing.
  private func scheduleCleanup(
    _ handle: ParakeetDeliveryHandle, model: ParakeetModel,
    selection: ParakeetModelSelection, root: URL
  ) {
    let point = frozenSelectionPoint
    let id = UUID()
    cleanupTasks[model]?.task.cancel()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.onCleanupEndedForTesting?(model) }
      guard !Task.isCancelled, self.selectionPointsMarked == point, self.frozen == selection
      else { return }
      let removed = await handle.retireOwnedInstall(ownedModelsRoot: root)
      guard !Task.isCancelled, self.selectionPointsMarked == point, self.frozen == selection
      else { return }
      self.emit(
        model == .v3
          ? (removed ? .retiredV3 : .retirementFailed(.v3))
          : (removed ? .removedTarget : .retirementFailed(.ultra)))
      if self.cleanupTasks[model]?.id == id { self.cleanupTasks[model] = nil }
    }
    cleanupTasks[model] = (id, task)
  }

  private func cancelCleanupTasks() {
    for cleanup in cleanupTasks.values { cleanup.task.cancel() }
    cleanupTasks.removeAll()
  }

  /// Every outcome is reported here, and each may change what
  /// `isParakeetUsable()` answers, so companions are invited to re-read.
  func emit(_ outcome: Outcome) {
    onOutcome?(outcome)
    onPresentationChanged?()
    if case .selected = outcome { return }
    if case .backgroundStarted = outcome { return }
    onUsabilityMayHaveChanged?()
  }

  /// A foreground Ultra operation: counted, so a foreground Cancel knows it
  /// has something to cancel.
  private func foreground(
    _ operation: () async -> ModelDeliveryController.DeliveryOutcome
  ) async -> ModelDeliveryController.DeliveryOutcome {
    foregroundFetches += 1
    defer { foregroundFetches -= 1 }
    return await operation()
  }
}

// MARK: - Background upgrade, Cancel/Resume and usability (plan §3.4 B, E3, E12-E14, E22)

extension ParakeetUpgradeCoordinator {
  /// E22: first-run setup finished; a row-B launch that held its background
  /// fetch for onboarding starts it now.
  package func onboardingDidComplete() {
    scheduleBackgroundFetch()
  }

  /// E12: the user cancelled the background download. The decline is written
  /// FIRST (that field only); whether or not it persisted, the download is
  /// cancelled (plan §3.4 E12, including an attempt a foreground caller joined)
  /// and automatic background work stays off in this process until Resume.
  package func cancelBackgroundUpgrade() async throws {
    guard let target else { return }
    backgroundCommandGeneration &+= 1
    var storeError: (any Error)?
    do {
      try target.store.writeDeclined(true)
    } catch {
      storeError = error
    }
    backgroundSuppressed = true
    backgroundFetch?.task.cancel()
    invalidateBackgroundFetch()
    setBackgroundUpgrade(.declined)
    if storeError != nil { emit(.storeUnavailable("declined")) } else { emit(.declined) }
    await enqueueCancelDrain(target.delivery).value
    if let storeError { throw storeError }
  }

  /// E13: the user resumed. Waits for a Cancel's transport drain, clears the
  /// decline field only (attempts, refetch and exhaustion are untouched), and
  /// starts the background fetch if the current choice still allows it. A
  /// write failure starts nothing.
  package func resumeBackgroundUpgrade() async throws {
    guard let target else { return }
    backgroundCommandGeneration &+= 1
    let command = backgroundCommandGeneration
    if let cancelDrain {
      onResumeWaitingForTesting?()
      await cancelDrain.value
    }
    try Task.checkCancellation()
    guard command == backgroundCommandGeneration else { throw CancellationError() }
    try target.store.writeDeclined(false)
    backgroundSuppressed = false
    setBackgroundUpgrade(.idle)
    emit(.resumed)
    scheduleBackgroundFetch()
  }

  /// Whether Parakeet can serve with a target configured: a confirmed ready
  /// serving request (Ultra whose reset failed and the K vendor branch
  /// included), else accepted, unrejected v3, else admitted Ultra whose
  /// readable state still permits a load. Retained exhausted Ultra that is not
  /// serving is not usable. Without a target the caller answers (the v3 mirror
  /// and marker, unchanged).
  package var hasUpgradeTarget: Bool { target != nil }

  ///
  /// Every fact is re-read AFTER the admission awaits, so a rejection,
  /// exhaustion or spent budget that lands during them is honoured.
  package func isParakeetUsable() async -> Bool {
    guard let target else { return false }
    if hasReadyServingRequest() { return true }
    if let delivery, delivery.locationIsUsable, !v3RejectedThisLaunch {
      let admitted = await delivery.isAdmitted()
      if let usabilityReadGateForTesting { await usabilityReadGateForTesting() }
      if hasReadyServingRequest() { return true }
      if admitted, !v3RejectedThisLaunch, delivery.locationIsUsable { return true }
    }
    guard target.delivery.locationIsUsable else { return false }
    let admitted = await target.delivery.isAdmitted()
    if let usabilityReadGateForTesting { await usabilityReadGateForTesting() }
    if hasReadyServingRequest() { return true }
    guard admitted, target.delivery.locationIsUsable,
      case .state(let state) = target.store.read(),
      !state.exhausted, state.attempts < Self.attemptBudget
    else { return false }
    return true
  }

  /// The model Settings names: the confirmed serving model while it is still
  /// the published request, otherwise the frozen model of the pending load or
  /// reload. Nil before any selection; the caller then falls back. A name
  /// never implies the model is loaded.
  package var presentedModel: ParakeetModel? {
    if let servingRequest, servingRequest == parakeetSelection.current {
      return servingRequest.model
    }
    return frozen?.model
  }

  /// Settings' "Model ready" read (#3385) with a target: whether the identity
  /// that serves, or will serve, is admitted and still permitted, from fresh
  /// marker and file-stamp reads. Never fetches. Rejection and load permission
  /// are applied after the awaited reads, so retained exhausted Ultra or a
  /// rejected v3 is not "ready" merely because its marker exists.
  package func currentAdmission() async -> Bool {
    guard let target else { return false }
    func v3Ready() async -> Bool {
      guard let delivery, delivery.locationIsUsable, !v3RejectedThisLaunch else { return false }
      let admitted = await delivery.isAdmitted()
      return admitted && !v3RejectedThisLaunch && delivery.locationIsUsable
    }
    func ultraReady() async -> Bool {
      guard target.delivery.locationIsUsable else { return false }
      let admitted = await target.delivery.isAdmitted()
      guard admitted, target.delivery.locationIsUsable,
        case .state(let state) = target.store.read(),
        !state.exhausted, state.attempts < Self.attemptBudget
      else { return false }
      return true
    }
    switch presentedModel {
    case .v3?: return await v3Ready()
    case .ultra?: return await ultraReady()
    case nil:
      if await v3Ready() { return true }
      return await ultraReady()
    }
  }

  /// Settings' Resume / Try again for the shipped download while nothing else
  /// serves (fresh install, no v3): a FOREGROUND fetch of the target, counted
  /// so the foreground Cancel reaches it, and only where the location, the
  /// store and the budget allow a later load. Waits for a Cancel's drain.
  /// Nil when refused before any work.
  package func fetchInForeground() async -> ModelDeliveryController.DeliveryOutcome? {
    guard let target, target.delivery.locationIsUsable,
      case .state(let state) = target.store.read(),
      !state.exhausted, state.attempts < Self.attemptBudget
    else { return nil }
    if let cancelDrain { await cancelDrain.value }
    guard !Task.isCancelled else { return nil }
    return await foreground({ await target.delivery.ensureAvailableInForeground() })
  }

  private func hasReadyServingRequest() -> Bool {
    guard let servingRequest else { return false }
    return servingRequest == parakeetSelection.current && servingReadiness?() == true
  }

  /// One serial transport drain: each Cancel's drain waits for the one before.
  private func enqueueCancelDrain(_ handle: ParakeetDeliveryHandle) -> Task<Void, Never> {
    let previous = cancelDrain
    let drain = Task { @MainActor in
      if let previous { await previous.value }
      await handle.cancelActiveFetch()
    }
    cancelDrain = drain
    return drain
  }

  /// Ends the current background fetch's ownership: its slot, its generation
  /// and its claim on the target's delivery events.
  private func invalidateBackgroundFetch() {
    backgroundGeneration &+= 1
    backgroundPublication.set(nil)
    backgroundFetch = nil
  }

  /// Row B's background fetch, when the CURRENT choice is row B: accepted,
  /// unrejected v3 frozen; the owned transport on; onboarding complete; the
  /// target's state readable, not declined, not exhausted; its location
  /// usable; no Cancel this process. A WhisperKit-only launch has no frozen
  /// choice, so it starts nothing; work already running survives E14.
  private func backgroundEligible(_ target: UpgradeTarget) -> Bool {
    guard !backgroundSuppressed, isOnboardingComplete(),
      (delivery ?? target.delivery).isEnabled(), target.delivery.locationIsUsable,
      v3Accepted, !v3RejectedThisLaunch, frozen?.model == .v3,
      case .state(let state) = target.store.read(), !state.declined, !state.exhausted
    else { return false }
    return true
  }

  private func scheduleBackgroundFetch() {
    guard let target, backgroundFetch == nil, backgroundEligible(target) else { return }
    backgroundGeneration &+= 1
    let generation = backgroundGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runBackgroundFetch(generation: generation)
    }
    backgroundFetch = (generation: generation, task: task)
    backgroundPublication.set(generation)
  }

  /// Test seam (internal): whether the background slot is taken. It is
  /// reserved synchronously, so a test can tell "not scheduled" without
  /// waiting.
  var hasBackgroundFetchForTesting: Bool { backgroundFetch != nil }
  var backgroundGenerationForTesting: UInt64? { backgroundFetch?.generation }

  private func isCurrentBackground(_ generation: UInt64) -> Bool {
    backgroundGeneration == generation && !Task.isCancelled
  }

  private func runBackgroundFetch(generation: UInt64) async {
    defer {
      if backgroundFetch?.generation == generation {
        backgroundPublication.set(nil)
        backgroundFetch = nil
      }
    }
    guard let target, isCurrentBackground(generation), backgroundEligible(target) else { return }
    let admitted = await target.delivery.isAdmitted()
    guard isCurrentBackground(generation), !admitted, backgroundEligible(target) else { return }
    emit(.backgroundStarted)
    setBackgroundUpgrade(
      .downloading(fraction: 0, bytesWritten: 0, totalBytes: target.delivery.modelTotalBytes))
    // E3/E14: the outcome is recorded only; activation waits for the next
    // selection point, and failure leaves v3 serving until then.
    let outcome = await target.delivery.ensureAvailable()
    guard isCurrentBackground(generation) else { return }
    switch outcome {
    case .admitted:
      setBackgroundUpgrade(.idle)
      emit(.backgroundAdmitted)
    case .failed(let failure) where failure.reason == .insufficientDisk:
      setBackgroundUpgrade(.deferredDisk)
      emit(.deferredDisk)
    case .failed(let failure):
      setBackgroundUpgrade(.failed)
      emit(.backgroundFetchFailed(failure.reason.rawValue))
    case .cancelled:
      setBackgroundUpgrade(.idle)
    }
  }

  /// The target identity's delivery states (publication order): download
  /// progress is the background's only while background work owns it and no
  /// foreground operation does.
  func targetStateChanged(_ state: DeliveryState, generation: UInt64?) {
    guard let generation, backgroundFetch?.generation == generation,
      backgroundGeneration == generation, foregroundFetches == 0,
      case .downloading(let fraction, let bytesWritten, let totalBytes) = state
    else { return }
    setBackgroundUpgrade(
      .downloading(fraction: fraction, bytesWritten: bytesWritten, totalBytes: totalBytes))
  }

  private func setBackgroundUpgrade(_ state: BackgroundUpgradeState) {
    guard backgroundUpgrade != state else { return }
    backgroundUpgrade = state
    onBackgroundUpgradeChanged?(state)
    onPresentationChanged?()
  }
}

/// #3546: the background generation that owns the target's delivery events,
/// readable on the controller actor at publication.
final class BackgroundPublicationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64?

  func read() -> UInt64? { lock.withLock { generation } }
  func set(_ value: UInt64?) { lock.withLock { generation = value } }
}
