import Foundation

// MARK: - WhisperKit model-load state machine (functional core, #1276 Step 1)
//
// Consolidates the nine hand-rolled load-state members that used to live on
// `WhisperKitBackend` (`loadTask`, `loadTaskSeq`, `activeLoadTaskID`,
// `loadGeneration`, `warmupTask`, `warmupTaskGeneration`, `warmupBudgetExhausted`,
// `whisperKit`, `isReady`) into ONE `LoadState` value plus one monotonic
// `generation` counter the actor owns. The scattered fields could disagree with
// each other (kit non-nil while `isReady` false, a budget-spent flag forgotten,
// a warm-up task orphaned with no matching generation); folding them into a
// single enum makes those disagreements unrepresentable.
//
// `transition(_:on:generation:)` is a PURE function: given the current state, an
// event, and the live generation, it returns the next state plus a list of
// side-effects for the actor to execute (create a task, throw, log). The actor
// (`WhisperKitBackend`) owns the `WhisperKit` instance and performs every effect;
// this file makes zero calls into WhisperKit and holds zero live state. That
// split lets the exhaustive (state × event) matrix be tested without ever
// constructing a `WhisperKit` (see `WhisperKitLoadStateTests`).
//
// Buy-vs-build note (#1276, Codex-validated 2026-07-03): the toolkit ships its
// own `ModelState`/`ModelManager`, but `ModelManager` needs a `ModelLoader` shim
// (WhisperKit isn't one) and its `unloadModels()` no-ops mid-load, so it does not
// solve the unload-during-load race this machine's `generation` guard covers.
// We therefore keep our own (now consolidated) machine. `isReady` is a strict
// superset of the toolkit's `.loaded` (loaded AND warm-up resolved), so
// `modelState` cannot be the readiness authority either. Detail:
// `docs/feature-requests/issue-1276-step1-buy-vs-build-inventory.md`.

/// Terminal status of the silent warm-up inference run once at load time.
/// Moved here (was a `private enum` on the actor) so tests can assert on it.
enum WarmupOutcome: Sendable, Equatable {
  case completed(ms: Int)
  case threw(desc: String)
}

/// Identity of a single load attempt. `generation` is the monotonic stamp
/// `unload()` bumps (staleness); `id` distinguishes concurrent load-task handles
/// so a superseded load's late cleanup can't clobber a newer load's handle
/// (the former `loadTaskSeq`/`activeLoadTaskID` pair).
struct LoadIdentity: Sendable, Equatable {
  let generation: UInt64
  let id: UInt64
}

/// Warm-up sub-state carried by `.warming` (live) and `.ready(staleWarmup:)`
/// (orphaned after a fail-open timeout). `budgetSpent` rides WITH the warm-up so
/// the "pay the 20s fail-open budget at most once per generation" guarantee
/// survives from the live phase into the ready phase (former
/// `warmupBudgetExhausted`).
struct WarmupInfo: Sendable, Equatable {
  let generation: UInt64
  var budgetSpent: Bool
}

/// A warm-up task left running after its 20s fail-open budget expired, carried by
/// `.ready(staleWarmup:)` so the vend gate can drain-or-skip it exactly once.
struct OrphanWarmup {
  var info: WarmupInfo
  let task: Task<WarmupOutcome, Never>
}

/// Marker for the loaded model instance the state carries. Real path: `WhisperKit`
/// (conformance below). Tests: a trivial fake. Deliberately NOT `Sendable` and
/// requirement-free — the instance is only ever touched inside the owning actor's
/// isolation, and existentiality is purely to let the state machine be tested
/// without constructing a real `WhisperKit`.
protocol LoadedASRModel: AnyObject {}

/// The single load-state authority. Each non-idle case carries exactly the
/// sub-state that phase needs; nothing outside these cases can represent load
/// state. Not `Equatable` (it carries `Task` handles and an existential kit);
/// assert on `phase` / `isReady` in tests.
enum LoadState {
  /// No kit, no load in flight.
  case idle
  /// A CoreML load is in flight. Carries the load `Task` so a concurrent caller
  /// joins it (single-flight) instead of starting a second load.
  case loading(LoadIdentity, task: Task<Void, Error>)
  /// Model loaded; the silent warm-up inference is running. NOT yet vendable
  /// (`isReady == false`) — matches the old design where `isReady` flips only
  /// after warm-up resolves. Carries the load task (still awaited by joiners
  /// until warm-up resolves, preserving "prepare() returns warm") and the
  /// warm-up task.
  case warming(
    kit: any LoadedASRModel,
    WarmupInfo,
    loadTask: Task<Void, Error>,
    warmupTask: Task<WarmupOutcome, Never>)
  /// Vendable. `staleWarmup == nil` after a clean warm-up; non-nil means
  /// fail-open-ready — warm-up timed out, its budget is spent, and its task is
  /// still orphaned for the vend gate to drain-or-skip exactly once.
  case ready(kit: any LoadedASRModel, staleWarmup: OrphanWarmup?)
}

/// Equatable projection of `LoadState` for test assertions (drops the live
/// `Task`/kit references, keeps identity + warm-up info).
enum LoadPhase: Sendable, Equatable {
  case idle
  case loading(LoadIdentity)
  case warming(WarmupInfo)
  case ready(staleWarmup: WarmupInfo?)
}

extension LoadState {
  var phase: LoadPhase {
    switch self {
    case .idle: return .idle
    case .loading(let id, _): return .loading(id)
    case .warming(_, let info, _, _): return .warming(info)
    case .ready(_, let stale): return .ready(staleWarmup: stale?.info)
    }
  }

  /// Protocol-required readiness: true iff the model is loaded AND warm-up has
  /// resolved. Single source of truth — replaces the stored `isReady` bool the
  /// old code had to hand-sync at six sites.
  var isReady: Bool {
    if case .ready = self { return true }
    return false
  }
}

/// Events fed into `transition`. Payload-carrying cases bring the freshly-created
/// resource (kit, task) so `transition` can slot it into the next state; identity
/// / generation on the event is compared against the live generation inside
/// `transition`, so the actor never re-checks staleness after an await
/// ([[state-gate-over-recheck]]).
enum LoadEvent {
  /// A caller wants the model loaded (`prepare()` / `prepareIfCached()`).
  case prepareRequested
  /// The actor created the load task for a `.beginLoad` effect; record it.
  case loadStarted(LoadIdentity, task: Task<Void, Error>)
  /// The load task finished building the kit.
  case loadSucceeded(kit: any LoadedASRModel, LoadIdentity)
  /// The load task threw.
  case loadFailed(LoadIdentity)
  /// The actor created the warm-up task for a `.beginWarmup` effect; record it.
  case warmupStarted(
    kit: any LoadedASRModel, generation: UInt64, warmupTask: Task<WarmupOutcome, Never>)
  /// The warm-up inference resolved (completed or threw) within budget.
  case warmupResolved(WarmupOutcome, generation: UInt64)
  /// The warm-up inference blew its 20s fail-open budget in `runWarmup`.
  case warmupTimedOut(generation: UInt64)
  /// A shared-instance caller wants the kit (`transcribe`/`observeLID`/
  /// `makeIncrementalSession`).
  case vendRequested
  /// The vend gate finished draining an orphan warm-up.
  case drainResolved(didTimeOut: Bool, generation: UInt64)
  /// `unload()` — generation already bumped by the actor before this event.
  case unloadRequested
}

/// Side-effects `transition` asks the actor to perform. Not `Equatable` (carries
/// tasks/kit); assert on `EffectTag` in tests.
enum Effect {
  /// Create the load task, then feed `.loadStarted`.
  case beginLoad
  /// Await this in-flight load task (single-flight join).
  case joinLoad(Task<Void, Error>)
  /// Create the warm-up task for this kit+generation, then feed `.warmupStarted`.
  case beginWarmup(kit: any LoadedASRModel, generation: UInt64)
  /// This completion lost its race with an `unload()`/newer load — throw
  /// `ASRLoadSupersededError` from the load task.
  case throwSuperseded
  /// Cancel a warm-up task created for a since-superseded load.
  case cancelWarmupTask(Task<WarmupOutcome, Never>)
  /// Record the warm-up duration on telemetry + log completion.
  case recordWarmupMs(Int)
  /// Log that the warm-up threw (no ms recorded).
  case logWarmupThrew(String)
  /// Log that the warm-up timed out (fail-open).
  case logWarmupTimedOut
  /// Drain this orphan warm-up task under the shared fail-open budget, then feed
  /// `.drainResolved`.
  case beginDrain(Task<WarmupOutcome, Never>, generation: UInt64)
  /// The orphan's budget was already spent — log and vend without re-draining.
  case logBudgetExhaustedVend
  /// The drain also timed out — log and vend anyway (accept documented risk).
  case logDrainTimedOutVend
  /// Cancel these tasks on unload (best-effort; CoreML load/decode is
  /// uncancellable — clearing the handle is what matters).
  case cancelLoadTask(Task<Void, Error>)
  case cancelOrphanWarmupOnUnload(Task<WarmupOutcome, Never>)
}

/// Equatable tag of an `Effect` for test assertions (drops task/kit payloads).
enum EffectTag: Sendable, Equatable {
  case beginLoad
  case joinLoad
  case beginWarmup(generation: UInt64)
  case throwSuperseded
  case cancelWarmupTask
  case recordWarmupMs(Int)
  case logWarmupThrew(String)
  case logWarmupTimedOut
  case beginDrain(generation: UInt64)
  case logBudgetExhaustedVend
  case logDrainTimedOutVend
  case cancelLoadTask
  case cancelOrphanWarmupOnUnload
}

extension Effect {
  var tag: EffectTag {
    switch self {
    case .beginLoad: return .beginLoad
    case .joinLoad: return .joinLoad
    case .beginWarmup(_, let g): return .beginWarmup(generation: g)
    case .throwSuperseded: return .throwSuperseded
    case .cancelWarmupTask: return .cancelWarmupTask
    case .recordWarmupMs(let ms): return .recordWarmupMs(ms)
    case .logWarmupThrew(let d): return .logWarmupThrew(d)
    case .logWarmupTimedOut: return .logWarmupTimedOut
    case .beginDrain(_, let g): return .beginDrain(generation: g)
    case .logBudgetExhaustedVend: return .logBudgetExhaustedVend
    case .logDrainTimedOutVend: return .logDrainTimedOutVend
    case .cancelLoadTask: return .cancelLoadTask
    case .cancelOrphanWarmupOnUnload: return .cancelOrphanWarmupOnUnload
    }
  }
}

/// The pure decision core. Every legal transition + every staleness/budget/
/// identity guard lives here; illegal (state, event) pairings are explicit
/// no-ops (state unchanged, no effects). The actor executes the returned effects
/// and feeds follow-up events; it never re-decides staleness itself.
///
/// `generation` is the LIVE generation at call time — the actor bumps it (in
/// `unload()`) BEFORE feeding `.unloadRequested`, so a completion event carrying
/// an older generation is recognizably stale here.
enum WhisperKitLoadStateMachine {
  static func transition(
    _ state: LoadState, on event: LoadEvent, generation: UInt64
  ) -> (LoadState, [Effect]) {
    switch (state, event) {

    // MARK: prepareRequested — the 3-way single-flight decision (invariant #1)
    case (.idle, .prepareRequested):
      return (state, [.beginLoad])
    case (.loading(_, let task), .prepareRequested):
      return (state, [.joinLoad(task)])
    case (.warming(_, _, let loadTask, _), .prepareRequested):
      // Still loading (warm-up phase) — join the load task, which resolves only
      // after warm-up, so a joiner's prepare() returns warm (isReady true).
      return (state, [.joinLoad(loadTask)])
    case (.ready, .prepareRequested):
      return (state, [])  // already loaded — idempotent no-op

    // MARK: loadStarted — record the created load task (idle → loading)
    case (.idle, .loadStarted(let id, let task)):
      return (.loading(id, task: task), [])
    case (_, .loadStarted(_, let task)):
      // A load task was created but the state already moved on (unload/newer
      // load between the .beginLoad decision and here — only possible if the
      // actor suspended, which it does not; defensive). Cancel the orphan.
      return (state, [.cancelLoadTask(task)])

    // MARK: loadSucceeded — kit built; proceed to warm-up or discard if stale
    case (.loading(let id, _), .loadSucceeded(let kit, let evId)):
      guard evId == id, id.generation == generation else {
        return (state, [.throwSuperseded])
      }
      return (state, [.beginWarmup(kit: kit, generation: id.generation)])
    case (_, .loadSucceeded):
      // Superseded before the kit finished building.
      return (state, [.throwSuperseded])

    // MARK: loadFailed — back to idle (retryable), only for the current load
    case (.loading(let id, _), .loadFailed(let evId)):
      guard evId == id else { return (state, []) }
      return (.idle, [])
    case (_, .loadFailed):
      return (state, [])  // stale failure — ignore

    // MARK: warmupStarted — record warm-up task (loading → warming)
    case (.loading(let id, let loadTask), .warmupStarted(let kit, let g, let warmupTask)):
      guard id.generation == g, g == generation else {
        return (state, [.cancelWarmupTask(warmupTask)])
      }
      return (
        .warming(
          kit: kit, WarmupInfo(generation: g, budgetSpent: false),
          loadTask: loadTask, warmupTask: warmupTask), []
      )
    case (_, .warmupStarted(_, _, let warmupTask)):
      return (state, [.cancelWarmupTask(warmupTask)])

    // MARK: warmupResolved — clean finish → ready(nil) (+ telemetry)
    case (.warming(let kit, let info, _, _), .warmupResolved(let outcome, let g)):
      guard info.generation == g, g == generation else { return (state, []) }
      let effect: Effect =
        switch outcome {
        case .completed(let ms): .recordWarmupMs(ms)
        case .threw(let desc): .logWarmupThrew(desc)
        }
      return (.ready(kit: kit, staleWarmup: nil), [effect])
    case (_, .warmupResolved):
      return (state, [])  // stale — ignore

    // MARK: warmupTimedOut — fail-open ready, carry the orphan (invariant #6)
    case (.warming(let kit, let info, _, let warmupTask), .warmupTimedOut(let g)):
      guard info.generation == g, g == generation else { return (state, []) }
      let orphan = OrphanWarmup(
        info: WarmupInfo(generation: g, budgetSpent: true), task: warmupTask)
      return (.ready(kit: kit, staleWarmup: orphan), [.logWarmupTimedOut])
    case (_, .warmupTimedOut):
      return (state, [])

    // MARK: vendRequested — the vend gate (invariants #4, #5, #6)
    case (.ready(_, nil), .vendRequested):
      return (state, [])  // clean-ready: actor vends the kit directly, no drain
    case (.ready(let kit, .some(let orphan)), .vendRequested):
      if orphan.info.budgetSpent {
        // Budget already spent for this generation — drop the orphan handle
        // (mirrors the old code nil-ing `warmupTask`) and vend without re-draining.
        return (.ready(kit: kit, staleWarmup: nil), [.logBudgetExhaustedVend])
      }
      return (state, [.beginDrain(orphan.task, generation: orphan.info.generation)])
    case (.warming(_, let info, _, let warmupTask), .vendRequested):
      // Concurrent caller arrived mid-warm-up. Drain the live warm-up (bounded);
      // the READY transition is owned by the load task, so after draining the
      // actor re-reads readiness.
      if info.budgetSpent {
        return (state, [])
      }
      return (state, [.beginDrain(warmupTask, generation: info.generation)])
    case (.idle, .vendRequested), (.loading, .vendRequested):
      return (state, [])  // not ready — actor returns nil

    // MARK: drainResolved — clear the orphan, mark budget, let actor re-vend
    case (.ready(let kit, .some(let orphan)), .drainResolved(let didTimeOut, let g)):
      guard orphan.info.generation == g, g == generation else { return (state, []) }
      let effects: [Effect] = didTimeOut ? [.logDrainTimedOutVend] : []
      return (.ready(kit: kit, staleWarmup: nil), effects)
    case (_, .drainResolved):
      // Warm-up resolved to ready(nil)/idle via another path during the drain,
      // or an unload intervened — nothing to clear.
      return (state, [])

    // MARK: unloadRequested — teardown to idle, cancel whatever tasks we hold
    case (.idle, .unloadRequested):
      return (.idle, [])
    case (.loading(_, let task), .unloadRequested):
      return (.idle, [.cancelLoadTask(task)])
    case (.warming(_, _, let loadTask, let warmupTask), .unloadRequested):
      return (.idle, [.cancelLoadTask(loadTask), .cancelWarmupTask(warmupTask)])
    case (.ready(_, .some(let orphan)), .unloadRequested):
      return (.idle, [.cancelOrphanWarmupOnUnload(orphan.task)])
    case (.ready(_, nil), .unloadRequested):
      return (.idle, [])
    }
  }
}
