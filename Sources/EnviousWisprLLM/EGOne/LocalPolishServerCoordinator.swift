import EnviousWisprCore
import Foundation
import os

/// The only code permitted to start, stop or swap the bundled polish server
/// (#2649, contract delta C6).
///
/// **The defect this closes is quiet and would not have shown up in any
/// single-model test.** `EGOneServerManager.start(configuration:)` returns
/// early when the server is already `.ready` — deliberately, because
/// activation is called from launch, provider switch and settings-open and must
/// be idempotent. It compares STATE, not which model's configuration produced
/// that state. So with EG-1 resident, S1-mini's activation would no-op and
/// every S1-mini polish would be answered by EG-1's weights, at the right
/// endpoint, with a 200 and plausible text. Nothing would look broken.
///
/// **And two runtimes could not have enforced this between them.** Each
/// constructed its own `EGOneServerManager`, so two managers meant two
/// processes and 3.4 GB resident. One-at-a-time is a property of the SET, and a
/// property of a set needs an owner that can see the whole set.
///
/// So residency is enforced two ways at once, and both are load-bearing:
/// containment, because this holds the single manager and hands it to nobody;
/// and identity, because it records WHICH model that manager is running and
/// stops the old one before starting a different one.
/// What the app wants running: a model and the configuration to run it with.
///
/// Nil-as-absence is the whole point — "stop" and "start" become one value, so
/// a caller states an intent rather than issuing two commands that can cross.
public struct LocalPolishTarget: Sendable {
  public let provider: LLMProvider
  public let configuration: EGOneServerManager.Configuration
  /// Set only by delivery's adapter-availability signal. A resident server that
  /// fell back to the bare base keeps the requested adapter URL, so an ordinary
  /// restatement (launch, provider switch, settings open) must not reboot it on
  /// every call; this request may, once, to load an adapter delivery replaced.
  public let retriesAdapterFallback: Bool

  public init(
    provider: LLMProvider, configuration: EGOneServerManager.Configuration,
    retriesAdapterFallback: Bool = false
  ) {
    self.provider = provider
    self.configuration = configuration
    self.retriesAdapterFallback = retriesAdapterFallback
  }
}

/// A physical hold on the resident bundled server. The coordinator alone
/// admits and releases these tokens; callers cannot infer safety from a frozen
/// configuration read on another actor.
public struct LocalPolishServerLease: Sendable {
  fileprivate let id: UUID
  fileprivate let provider: LLMProvider
  fileprivate let purpose: LocalPolishLeasePurpose

  fileprivate init(provider: LLMProvider, purpose: LocalPolishLeasePurpose) {
    id = UUID()
    self.provider = provider
    self.purpose = purpose
  }
}

/// What a lease holds the server for (#4319). Both kinds defer a process change; only inference
/// sends requests, so only inference is drained before an EnviousMeet summary takes the server.
public enum LocalPolishLeasePurpose: Sendable, Equatable {
  /// Requests in flight: a polish attempt (live, recovery or import part) or a learned-word
  /// check.
  case inference
  /// A whole file import's hold across its parts. It sends nothing itself, and its owner may
  /// be waiting on part inference a summary would refuse, so a summary never drains it: it
  /// waits for the import instead.
  case residency
}

/// An EnviousMeet summary's exclusive hold on the bundled server (#4319): taken once every
/// admitted request has finished, released by the token alone. While it exists no new
/// inference, probe, import hold or process change from anyone else is admitted.
public struct LocalPolishSummaryReservation: Sendable, Equatable {
  fileprivate let id: UUID
  public let provider: LLMProvider
}

/// The answer to a summary's reservation request (#4319).
public enum LocalPolishReservationOutcome: Sendable, Equatable {
  case granted(LocalPolishSummaryReservation)
  /// A file import holds the server, or another summary does: nothing was reserved; wait for
  /// a local turn and ask again.
  case retryLater
  /// The asking task was cancelled while earlier requests drained; nothing is reserved.
  case cancelled
}

public enum LocalPolishLeaseAdmission: Sendable {
  case granted(LocalPolishServerLease)
  /// The server is stopping, starting, or does not yet hold this provider.
  /// The optional polish limb uses its existing unchanged-text fallback.
  case changing
}

/// What a caller is asking the coordinator for.
///
/// **The two cases have different SCOPE, and collapsing them cost EG-1.** A
/// `run` speaks for the whole resource: it evicts whatever else holds the
/// process, because only one model may. A stop does NOT: an engine can say only
/// that IT should not be running, never that nothing should.
///
/// Modelling the stop as a bare `nil` target lost that distinction, and the
/// reconciler makes the difference matter on an ordinary switch. Selecting EG-1
/// deactivates every unselected engine TWICE — once in the stop-outgoing pass
/// and again in the main pass, which runs AFTER EG-1 has started. That second
/// deactivate carries the newest stamp, so a whole-resource stop obeyed it and
/// shut down the engine the user had just selected. Founder found it in UAT on
/// 2026-09-04: EG-1 sat on "Attention" after switching back, and only the
/// refresh button brought it up.
///
/// Both guards are load-bearing and neither is sufficient alone. Scope stops an
/// engine speaking for another; the stamp still orders two requests that BOTH
/// legitimately speak for the resource.
public enum LocalPolishIntent: Sendable {
  /// Run this model, evicting any other. Speaks for the whole resource.
  case run(LocalPolishTarget)
  /// This model should not be running. A no-op unless it is the resident.
  case idle(LLMProvider)
}

/// A lifecycle as delivered to one engine (#3988), stamped by the manager with
/// the revision that produced it, in the same actor turn, so a receiver can
/// refuse a stale one that lands late after the unstructured hops.
public struct LocalPolishLifecycleEvent: Sendable, Equatable {
  public let lifecycle: EGOneServerManager.Lifecycle
  public let order: Int
}

public actor LocalPolishServerCoordinator {
  /// The one manager. Deliberately not exposed: handing it out would restore
  /// exactly the two-owners situation this type exists to remove.
  private let manager = EGOneServerManager()

  /// Which model the manager is currently running, or nil when nothing is.
  /// This is the identity half of the rule; the manager's own state is the
  /// process half, and neither alone is sufficient.
  private var resident: LLMProvider?
  private var residentTarget: LocalPolishTarget?
  private var deferredRequest: (request: LocalPolishIntent, intent: Int)?
  private var leases: [UUID: (provider: LLMProvider, purpose: LocalPolishLeasePurpose)] = [:]
  /// #4319: the summary holding the server, if any, and the waits for its drain.
  private var summaryReservation: LocalPolishSummaryReservation?
  private var probesInFlight = 0
  private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var drainWaitWatchersForTesting: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
  private var changing = false
  private var removalWaiters: [CheckedContinuation<Void, Never>] = []
  /// #3105: per engine, because each local engine boots its own checker adapter
  /// and one engine's fallback must not describe the other's.
  private var recordedCheckerFailures: [LLMProvider: EGOneServerManager.CheckerFailureReason] = [:]
  /// The resident process was asked for an adapter and runs the bare base.
  private var residentAdapterFellBack = false

  /// One observer per model. See `setStateObserver(for:_:)` for why a single
  /// slot was a regression rather than merely a limitation.
  private var observers: [LLMProvider: @Sendable (LocalPolishLifecycleEvent) -> Void] = [:]
  private var failureObservers: [LLMProvider: @Sendable (ChildProcessFailure) -> Void] = [:]
  private var managerObserverInstalled = false

  /// A non-isolated mirror of `resident`, read from inside the manager's own
  /// callback so an event carries the identity it was emitted UNDER. The
  /// actor-isolated field cannot be read there without a hop, and the hop is
  /// exactly the window this closes.
  private let observedResident = OSAllocatedUnfairLock<LLMProvider?>(initialState: nil)

  /// Monotonic intent stamp, CLAIMED BY THE CALLER before it spawns its task.
  ///
  /// **The earlier design derived order from execution and that is the wrong
  /// clock.** A counter bumped inside the transition records which task got
  /// here first, not which switch the user asked for last — and activate and
  /// deactivate reach this actor as separate unstructured tasks, which Swift
  /// does not order. So an ordinary EG-1 to S1-mini switch could run the stop
  /// after the start: the stop superseded the newer start, the start bailed at
  /// its own guard, and the user's selected engine never came up with nothing
  /// reporting it.
  ///
  /// The order that matters is the order the user's actions were OBSERVED, and
  /// that is known synchronously on the main actor. `claimIntent()` is taken
  /// there, before any task exists, and `transition` obeys only the newest
  /// stamp it has seen. Two methods guarded separately cannot express "latest
  /// intent wins" at all, which is why they are gone rather than tightened.
  private let intentCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
  private var honouredIntent = 0

  /// Claim the next intent stamp. Synchronous and callable from any isolation,
  /// so a main-actor caller can stamp its request in the order the user made
  /// it and hand that stamp to whatever task carries it out.
  public nonisolated func claimIntent() -> Int {
    intentCounter.withLock { value in
      value += 1
      return value
    }
  }

  /// One writer for both, so the mirror cannot drift from the field it mirrors.
  private func setResident(_ provider: LLMProvider?) {
    resident = provider
    observedResident.withLock { $0 = provider }
  }

  public init() {}

  #if DEBUG
    public func qualificationTrapOwnedReadyChild() async
      -> EGOneServerManager.QualificationChildSignal?
    {
      await manager.qualificationTrapOwnedReadyChild()
    }
  #endif

  /// Admission and the eviction decision share this actor's non-suspending
  /// turn. A take either gets a hold before a transition decides to stop, or
  /// sees changing before it freezes its local-polish choice.
  /// #4319: no default purpose, so an import's whole-run hold can never be counted as
  /// inference by omission. While a summary holds the server every admission is refused, and
  /// each caller takes its existing changing fallback (polish unchanged, word check skipped,
  /// import cleanup refused).
  public func acquireLease(
    for provider: LLMProvider, purpose: LocalPolishLeasePurpose
  ) -> LocalPolishLeaseAdmission {
    guard !changing, resident == provider, summaryReservation == nil else { return .changing }
    let lease = LocalPolishServerLease(provider: provider, purpose: purpose)
    leases[lease.id] = (provider, purpose)
    return .granted(lease)
  }

  public func releaseLease(_ lease: LocalPolishServerLease) async {
    guard leases.removeValue(forKey: lease.id)?.provider == lease.provider else { return }
    wakeRemovalWaiters()
    if leases.isEmpty { await retryDeferredReconfiguration() }
  }

  public func hasLease(for provider: LLMProvider) -> Bool {
    leases.values.contains { $0.provider == provider }
  }

  // MARK: - #4319: an EnviousMeet summary's exclusive hold

  /// Requests that must finish before a summary may use the server.
  private var inferenceInFlight: Int {
    leases.values.filter { $0.purpose == .inference }.count + probesInFlight
  }

  /// Closes admission at once, in this actor turn, then waits for admitted requests and any
  /// process change to finish. An import holding the server wins: nothing is reserved and the
  /// caller waits for a local turn (the import's own pin, read by the caller, covers its
  /// preparation before this hold exists). Cancelled while waiting: the reservation is
  /// removed and admission reopens.
  public func reserveForSummary(_ provider: LLMProvider) async -> LocalPolishReservationOutcome {
    guard Task.isCancelled == false else { return .cancelled }
    guard summaryReservation == nil,
      !leases.values.contains(where: { $0.purpose == .residency })
    else { return .retryLater }
    let reservation = LocalPolishSummaryReservation(id: UUID(), provider: provider)
    summaryReservation = reservation
    while changing || inferenceInFlight > 0 {
      let wait = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled {
            continuation.resume()
          } else {
            drainWaiters[wait] = continuation
            let watchers = drainWaitWatchersForTesting
            drainWaitWatchersForTesting = []
            watchers.forEach { $0.continuation.resume() }
          }
        }
      } onCancel: {
        Task { await self.cancelDrainWait(wait) }
      }
      if Task.isCancelled {
        await releaseSummaryReservation(reservation)
        return .cancelled
      }
    }
    if Task.isCancelled {
      await releaseSummaryReservation(reservation)
      return .cancelled
    }
    return .granted(reservation)
  }

  /// A cancelled drain wait ends now. A wait not yet stored needs nothing: storing checks the
  /// task's cancellation in the same actor turn.
  private func cancelDrainWait(_ wait: UUID) {
    drainWaiters.removeValue(forKey: wait)?.resume()
  }

  private func wakeDrainWaitersIfIdle() {
    guard !changing, inferenceInFlight == 0 else { return }
    let waiters = drainWaiters
    drainWaiters = [:]
    waiters.values.forEach { $0.resume() }
  }

  /// Releases only the reservation it names; a stale or repeated release changes nothing.
  /// Then admission reopens and a process change deferred behind it runs.
  public func releaseSummaryReservation(_ reservation: LocalPolishSummaryReservation) async {
    guard summaryReservation == reservation else { return }
    summaryReservation = nil
    wakeRemovalWaiters()
    if leases.isEmpty { await retryDeferredReconfiguration() }
  }

  /// Whether a summary holds the server now.
  public func isReservedForSummary() -> Bool { summaryReservation != nil }

  /// Reserve the server for Remove Model, including the artifact deletion that
  /// follows the stop. New takes see changing before they freeze. A live hold
  /// waits on its release signal instead of racing a separate MainActor read.
  ///
  /// `stillWanted` is asked after the wait, in the same turn that claims the
  /// server: a user who re-selected this model while the removal waited
  /// (Codex branch review r2) keeps the running server. False means nothing
  /// was claimed and `endRemoval` must not be called.
  public func beginRemoval(
    for provider: LLMProvider, intent: Int,
    stillWanted: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    honouredIntent = max(honouredIntent, intent)
    while true {
      while changing || leases.values.contains(where: { $0.provider == provider })
        || summaryReservation != nil
      {
        await withCheckedContinuation { removalWaiters.append($0) }
      }
      guard await stillWanted() else { return false }
      // Asking suspended this actor; claim only if nothing moved meanwhile.
      if !changing && !leases.values.contains(where: { $0.provider == provider })
        && summaryReservation == nil
      {
        break
      }
    }
    changing = true
    if resident == provider {
      // The manager's own stop event, revision included (#3988). `changing`
      // is held, so no other transition can run while this awaits.
      let stopped = await manager.stop()
      observers[provider]?(stopped)
      setResident(nil)
      residentTarget = nil
      residentAdapterFellBack = false
    }
    return true
  }

  public func endRemoval() async {
    changing = false
    wakeRemovalWaiters()
    await retryDeferredReconfiguration()
  }

  private func wakeRemovalWaiters() {
    let waiters = removalWaiters
    removalWaiters = []
    waiters.forEach { $0.resume() }
    // #4319: every place a transition or a hold ends is also where a summary's drain may end.
    wakeDrainWaitersIfIdle()
  }

  /// Drive the server to `target`, or to nothing when `target` is nil.
  ///
  /// One entry point, because starting and stopping are not independent
  /// operations on a single-process resource — they are two values of one
  /// question, "what should be running now". Expressed as two methods, the
  /// answer depends on which task the runtime happens to schedule first.
  ///
  /// Re-stating the resident model stays idempotent, which is required:
  /// launch, provider switch and settings-open all arrive here and must not
  /// restart a working server.
  /// #4319: `reservation` is passed only by the summary that holds the server, to load its
  /// model after the drain. Anyone else's request that would change the process, or start a
  /// different model, while a summary holds the server is deferred like one behind a lease,
  /// and runs when the summary releases it.
  public func transition(
    to request: LocalPolishIntent, intent: Int,
    reservation: LocalPolishSummaryReservation? = nil
  ) async {
    // #4319: a token that no longer holds the server (released, or never granted) changes
    // nothing. The holder's own load is not a selection: it is not refused for being older
    // than a newer settings request, never moves the selection's stamp, and never replaces
    // or clears the selection deferred behind it, which must run at release.
    if let reservation {
      guard summaryReservation == reservation else { return }
    }
    let ownsReservation = reservation != nil
    // A stamp older than one already honoured describes a world the user has
    // moved on from. Obeying it is exactly the defect this replaced.
    guard ownsReservation || intent >= honouredIntent else { return }
    if changing {
      // The holder only loads after its drain saw no change in progress; a change starting
      // since then is refused here rather than overwriting the deferred selection.
      guard !ownsReservation else { return }
      honouredIntent = intent
      deferredRequest = (request, intent)
      return
    }

    let target: LocalPolishTarget?
    switch request {
    case .run(let wanted):
      target = wanted
    case .idle(let provider):
      // The caller speaks for itself only. A deactivate from a model that does
      // not hold the process is not news about the process, and obeying it
      // stops a server somebody else is waiting on.
      guard resident == provider else { return }
      target = nil
    }
    // A ready start cannot change argv. Adapter arrival/removal is an explicit
    // stop and boot, and neither that nor a model switch may evict a pinned
    // take or import. The release callback retries the latest deferred intent.
    let changesProcess =
      resident != nil
      && (resident != target?.provider
        || residentTarget?.configuration.learnedWordAdapterURL
          != target?.configuration.learnedWordAdapterURL
        || (residentAdapterFellBack && target?.retriesAdapterFallback == true
          && target?.configuration.learnedWordAdapterURL != nil))
    let heldByAnotherSummary = summaryReservation != nil && !ownsReservation
    // Anyone but the holder starting any process during the summary, even the same model
    // from nothing, would race the holder's load.
    let startsUnownedProcess =
      heldByAnotherSummary && target != nil
      && (resident == nil || target?.provider != summaryReservation?.provider)
    if (changesProcess && (!leases.isEmpty || heldByAnotherSummary)) || startsUnownedProcess {
      honouredIntent = intent
      deferredRequest = (request, intent)
      return
    }
    if !ownsReservation {
      guard intent >= honouredIntent else { return }
      honouredIntent = intent
      deferredRequest = nil
    }
    // A same-model restatement needs no process change; marking it
    // changing would skip the polish of a take that lands during the
    // idempotent start.
    changing = changesProcess || (resident == nil && target != nil)

    if let resident, changesProcess {
      // Stop the outgoing model BEFORE recording the new resident, so a start
      // that fails leaves the field honestly empty rather than naming a model
      // that is not running.
      let stopped = await manager.stop()
      // Whoever actually lost the process is told so, rather than whichever
      // provider the caller named: its row must not keep showing a live server
      // it no longer owns. The manager's own stop event, revision included
      // (#3988); `changing` is held, so no other transition ran meanwhile.
      observers[resident]?(stopped)
      setResident(nil)
      residentTarget = nil
      residentAdapterFellBack = false
    }

    if !ownsReservation, intent < honouredIntent {
      changing = false
      wakeRemovalWaiters()
      await retryDeferredReconfiguration()
      return
    }
    guard let target else {
      changing = false
      wakeRemovalWaiters()
      await retryDeferredReconfiguration()
      return
    }
    setResident(target.provider)
    residentTarget = target
    var configuration = target.configuration
    configuration.owningProvider = target.provider
    await manager.start(configuration: configuration)
    changing = false
    wakeRemovalWaiters()
    await retryDeferredReconfiguration()
    let provider = target.provider
    if resident == provider {
      let reason = await manager.checkerFailureReason
      guard resident == provider,
        residentTarget?.configuration.learnedWordAdapterURL
          == target.configuration.learnedWordAdapterURL
      else { return }
      if let reason {
        recordedCheckerFailures[provider] = reason
      } else if target.configuration.learnedWordAdapterURL != nil {
        recordedCheckerFailures[provider] = nil
      }
      // Every manager failure reason is a bare-base fallback of an adapter boot.
      residentAdapterFellBack = reason != nil && target.configuration.learnedWordAdapterURL != nil
    }
  }

  /// Called when the last server lease is released. Rechecks actor-owned
  /// leases; a newer provider intent supersedes an older deferred adapter change.
  public func retryDeferredReconfiguration() async {
    guard let deferredRequest else { return }
    await transition(to: deferredRequest.request, intent: deferredRequest.intent)
  }

  public func checkerFailureReason(for provider: LLMProvider) -> EGOneServerManager
    .CheckerFailureReason?
  {
    recordedCheckerFailures[provider]
  }

  public func currentBootCheckerFailureReason() async -> EGOneServerManager.CheckerFailureReason? {
    await manager.checkerFailureReason
  }

  /// Health for `provider`. Returns red when a DIFFERENT model is resident,
  /// rather than the manager's state — which would describe the other model's
  /// process and read green about the wrong thing.
  /// #4319: nil when an EnviousMeet summary holds the server: the probe is an inference
  /// request and does not run, and there is no verdict to publish. An admitted probe counts as
  /// inference, so a summary's drain waits for it. The startup readiness check (`GET /health`
  /// inside the manager's start) is not a probe and is never held back.
  public func probeHealth(
    _ provider: LLMProvider, promptFamily: PromptFamily,
    spec: EGOneServerManager.ProbeSpec
  ) async -> EGOneHealth? {
    guard summaryReservation == nil else { return nil }
    guard resident == provider else { return .red(reason: "not_running") }
    probesInFlight += 1
    let result = await manager.probeHealth(promptFamily: promptFamily, spec: spec)
    probesInFlight -= 1
    wakeDrainWaitersIfIdle()
    // A probe takes real time. If the user switched during it, this verdict
    // describes a process the asking model no longer owns, and reporting it
    // would put another model's health on this model's row.
    guard resident == provider else { return .red(reason: "not_running") }
    return result
  }

  /// The live endpoint for `provider`, or nil when another model holds the
  /// process. A polish request must never be answered by different weights.
  /// #3988: `provider`'s lifecycle, including an outstanding outside stop, read
  /// in one manager turn. Another model's stop is never this model's news.
  public func lifecycle(for provider: LLMProvider) async -> EGOneServerManager.Lifecycle {
    guard resident == provider else { return .stopped }
    let lifecycle = await manager.currentLifecycle()
    guard resident == provider else { return .stopped }
    return lifecycle
  }

  /// #3988: a polish attempt's admission and what it meets, as ONE decision.
  /// The manager's snapshot is read first; admission is then decided in this
  /// actor's turn with no suspension in between, so a refusal can never be
  /// paired with evidence from a later moment. The manager checks the
  /// provider itself, so another engine's request cannot use up attribution.
  ///
  /// The snapshot can go stale while it is awaited: a process change, an
  /// outside stop or a recovery to ready. Once granted, the lease defers every
  /// further process change, so a granted take always reads the snapshot again
  /// under it and talks to the server it holds. A refusal keeps the first
  /// snapshot. A stop after that second read fails the request like any other.
  public func admitPolish(
    for provider: LLMProvider, takeID: String?
  ) async -> (admission: LocalPolishLeaseAdmission, availability: EGOneServerManager.Availability) {
    let availability = await manager.observeAvailability(for: provider, claimingFor: takeID)
    let admission = acquireLease(for: provider, purpose: .inference)
    guard case .granted = admission else { return (admission, availability) }
    // Endpoint and stop evidence are read again together: an outside stop can
    // still end the held server, and its skip must carry that stop. The same
    // take asking twice keeps its recovery claim.
    return (admission, await manager.observeAvailability(for: provider, claimingFor: takeID))
  }

  public func endpoint(for provider: LLMProvider) async -> EGOneEndpoint? {
    guard resident == provider else { return nil }
    let endpoint = await manager.activeEndpoint()
    // The most consequential of the five: handing back an endpoint the asking
    // model no longer owns is the wrong-model polish this whole type exists to
    // prevent, arriving through the door that was supposed to stop it.
    guard resident == provider else { return nil }
    return endpoint
  }

  public func reapOrphansIfIdle(binaryPath: String, initiator: LLMProvider? = nil) async {
    await installManagerObserverIfNeeded()
    await manager.reapOrphansIfIdle(binaryPath: binaryPath, initiator: initiator)
  }

  public func setProcessFailureObserver(
    for provider: LLMProvider, _ observer: @escaping @Sendable (ChildProcessFailure) -> Void
  ) async {
    failureObservers[provider] = observer
    await installManagerObserverIfNeeded()
  }

  func publishFailure(_ failure: ChildProcessFailure) {
    if let provider = failure.provider {
      failureObservers[provider]?(failure)
    } else {
      // One observer forwards unknown attribution without inventing an owning provider.
      failureObservers.values.first?(failure)
    }
  }

  /// Server-state observation, KEYED BY MODEL.
  ///
  /// `EGOneServerManager.setStateObserver` holds ONE closure, so two runtimes
  /// registering against it meant the second silently replaced the first. That
  /// is an EG-1 REGRESSION, not just a gap in the new model: depending on which
  /// unstructured registration task won, EG-1 could stop receiving state
  /// entirely and sit on "Starting", or receive S1-mini's state and report
  /// health about the wrong process.
  ///
  /// Keying by provider fixes the replacement. Gating delivery on residency
  /// fixes the other half: a model that does not hold the process must not be
  /// told the process changed, because the change is not about it.
  public func setStateObserver(
    for provider: LLMProvider,
    _ observer: @escaping @Sendable (LocalPolishLifecycleEvent) -> Void
  ) async {
    observers[provider] = observer
    // Seed with the caller's OWN truth rather than the manager's state: a model
    // that is not resident is stopped as far as it is concerned, whatever the
    // other one is doing.
    // State and revision come from ONE manager turn, so the seed sorts
    // correctly against any event emitted while this registration awaited.
    let current = await manager.currentEvent()
    // Re-checked after the await for the same reason as the readers above: a
    // switch during registration would seed this model with the other's state.
    observer(
      resident == provider
        ? current : LocalPolishLifecycleEvent(lifecycle: .stopped, order: current.order))
    await installManagerObserverIfNeeded()
  }

  /// One closure on the manager, forever, fanning out to whoever is resident.
  /// Re-registering per model is what created the replacement in the first
  /// place, so this installs exactly once.
  private func installManagerObserverIfNeeded() async {
    guard !managerObserverInstalled else { return }
    managerObserverInstalled = true
    await manager.setProcessFailureObserver { [weak self] failure in
      // A fact belongs to the completed lifetime even after a provider switch.
      Task { await self?.publishFailure(failure) }
    }
    await manager.setStateObserver { [weak self, observedResident] state in
      // Identity is captured AT EMISSION, not read when the task runs. Reading
      // it later is a real race and it delivers to the wrong model: during an
      // eviction the manager emits `.stopped` for the OUTGOING model, and
      // residency can flip to the incoming one before the queued task executes.
      // The outgoing model's stop would then arrive at the model that just
      // started, telling a live server it is stopped.
      let provider = observedResident.withLock { $0 }
      Task { await self?.publish(state, for: provider) }
    }
  }

  private func publish(_ state: LocalPolishLifecycleEvent, for provider: LLMProvider?) {
    // Both halves matter: the event must belong to a model, and that model must
    // STILL be resident when it lands. A stale event for a model that has since
    // been evicted is not news it can act on.
    guard let provider, resident == provider, let observer = observers[provider] else { return }
    observer(state)
  }

  /// App quit. Synchronous by necessity: `applicationWillTerminate` cannot await
  /// into an actor, and a `Process` child is NOT killed when its parent exits.
  public nonisolated func terminateForAppQuit() {
    manager.terminateImmediately()
  }

  #if DEBUG
    /// #4319 DEBUG: `provider`'s server slots, through the manager's own endpoint. A control
    /// request: no lease, no reservation check, available while a summary holds the server.
    public func observeSlotsForDebug(for provider: LLMProvider) async -> EGOneSlotObservation {
      guard resident == provider else { return .unavailable }
      let observation = await manager.observeSlotsForDebug()
      guard resident == provider else { return .replaced }
      return observation
    }
  #endif

  /// Test seam (#4319): true once a summary's reservation is waiting for earlier requests to
  /// drain, so a test can act inside that window; false at the deadline, so a broken setup
  /// fails by name instead of hanging.
  func awaitDrainWaitForTesting() async -> Bool {
    guard drainWaiters.isEmpty else { return true }
    let watch = UUID()
    await withCheckedContinuation { continuation in
      drainWaitWatchersForTesting.append((watch, continuation))
      Task {
        // deadline-fallback: give up so the test fails by name instead of hanging
        try? await Task.sleep(for: .seconds(20))
        await self.expireDrainWatchForTesting(watch)
      }
    }
    return !drainWaiters.isEmpty
  }

  private func expireDrainWatchForTesting(_ watch: UUID) {
    guard let index = drainWaitWatchersForTesting.firstIndex(where: { $0.id == watch }) else {
      return
    }
    drainWaitWatchersForTesting.remove(at: index).continuation.resume()
  }

  /// Test seam. Reading the resident identity is how a test proves the SWAP
  /// happened rather than proving the coordinator merely returned.
  var residentModelForTesting: LLMProvider? { resident }
}

/// The set of local polish engines the app constructed, so a view can reach the
/// SECOND one (#2649).
///
/// SwiftUI keys `@Environment` by TYPE, and both engines are `EGOneRuntime`, so
/// injecting two of them would have the second silently replace the first. This
/// holder gives the settings screen an unambiguous way to ask for a specific
/// engine rather than "the" engine — which is the same mistake the server
/// coordinator exists to prevent, one layer up.
@MainActor
@Observable
public final class LocalPolishRuntimeSet {
  public let egOne: EGOneRuntime
  public let s1Mini: EGOneRuntime

  public init(egOne: EGOneRuntime, s1Mini: EGOneRuntime) {
    self.egOne = egOne
    self.s1Mini = s1Mini
  }

  /// The runtime a BUNDLED local provider owns, or `nil` for every provider that has no
  /// server on this Mac.
  ///
  /// #2772: added so a caller that already holds a provider — the file import's frozen run
  /// configuration — can reach its runtime without restating which providers are bundled.
  /// Exhaustive on purpose: a third bundled engine must fail to compile here rather than
  /// fall into a `default:` and silently never start, which is the shape #2649 fixed twice.
  @MainActor
  public func runtime(for provider: LLMProvider) -> EGOneRuntime? {
    switch provider {
    case .egOne: return egOne
    case .s1Mini: return s1Mini
    case .appleIntelligence, .ollama, .openAI, .gemini, .claude, .none: return nil
    }
  }

  // MARK: - #4319: one EnviousMeet summary attempt's hold on the bundled server

  /// The attempt's own token. Only the hold it names can be ended with it, so a stale,
  /// repeated or late release never touches a later attempt.
  public struct SummaryHold: Sendable, Equatable {
    fileprivate let id: UUID
    public let provider: LLMProvider
  }

  public enum SummaryHoldOutcome: Sendable, Equatable {
    case held(SummaryHold)
    /// A file import holds the server (or another summary does); nothing is held. Wait for a
    /// local turn and ask again.
    case retryLater
    /// The asking task was cancelled while earlier requests drained; nothing is held.
    case cancelled
  }

  private var summaryHold:
    (id: UUID, runtime: EGOneRuntime, reservation: LocalPolishSummaryReservation?)?

  /// The bundled model a summary attempt holds (or is draining the server for), or nil. The
  /// settings pin, the dictation clash and the health-probe busy check read this; the
  /// coordinator's reservation is what actually excludes other requests.
  public private(set) var summaryHeldProvider: LLMProvider?
  /// Moves when an attempt starts holding the server, so a health probe measured across that
  /// moment is discarded (`EGOneRuntime.activateAndProbe` compares it before and after).
  public private(set) var summaryAdmissionEpoch = 0

  /// Starts this attempt's hold: the projection is published at once, so dictation sees the
  /// engine busy while earlier requests drain; it is withdrawn if nothing is held.
  public func beginSummaryHold(_ provider: LLMProvider) async -> SummaryHoldOutcome {
    guard summaryHold == nil, let runtime = runtime(for: provider) else { return .retryLater }
    let id = UUID()
    summaryHold = (id, runtime, nil)
    summaryHeldProvider = provider
    summaryAdmissionEpoch &+= 1
    let outcome = await runtime.reserveServerForSummary()
    guard summaryHold?.id == id else {
      // Ended while waiting (cannot happen through this API, but never strand a reservation).
      if case .granted(let reservation) = outcome {
        await runtime.releaseServerReservation(reservation)
      }
      return .cancelled
    }
    switch outcome {
    case .granted(let reservation):
      summaryHold = (id, runtime, reservation)
      return .held(SummaryHold(id: id, provider: provider))
    case .retryLater:
      summaryHold = nil
      summaryHeldProvider = nil
      return .retryLater
    case .cancelled:
      summaryHold = nil
      summaryHeldProvider = nil
      return .cancelled
    }
  }

  /// The coordinator reservation behind `hold`, for loading its model; nil for a stale token.
  public func reservation(for hold: SummaryHold) -> LocalPolishSummaryReservation? {
    guard summaryHold?.id == hold.id else { return nil }
    return summaryHold?.reservation
  }

  /// Ends `hold`: the projection goes first (in this main-actor turn), then the server is
  /// released. Never waits for the summary chain or for dictation's engine; restoring the
  /// selected engine is the caller's next step. A stale or repeated call does nothing.
  public func endSummaryHold(_ hold: SummaryHold) async {
    guard let current = summaryHold, current.id == hold.id else { return }
    summaryHold = nil
    summaryHeldProvider = nil
    if let reservation = current.reservation {
      await current.runtime.releaseServerReservation(reservation)
    }
  }

  /// #3105: the file import's whole-run hold on its bundled server. Each part
  /// also holds one through its own inference; this one covers the gaps
  /// between parts, so a provider switch or adapter change made mid-import
  /// waits for the run's end instead of landing between two parts.
  private var importHold: (runtime: EGOneRuntime, lease: LocalPolishServerLease)?

  /// Takes the import's hold once its server is ready. False when the server
  /// is changing; the caller refuses the local cleanup as for a missing
  /// endpoint.
  public func holdForImport(_ provider: LLMProvider) async -> Bool {
    await releaseImportHold()?.value
    guard let runtime = runtime(for: provider) else { return false }
    switch await runtime.acquireLocalServerResidency() {
    case .granted(let lease):
      importHold = (runtime, lease)
      return true
    case .changing:
      return false
    }
  }

  /// Takes the current hold synchronously, so a later import's hold can never
  /// be the one this call releases, and returns the release for the caller
  /// to await before reconciling.
  @discardableResult
  public func releaseImportHold() -> Task<Void, Never>? {
    guard let hold = importHold else { return nil }
    importHold = nil
    return Task { await hold.runtime.releaseLocalServerLease(hold.lease) }
  }
}
