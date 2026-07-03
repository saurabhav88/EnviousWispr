import Testing

@testable import EnviousWisprASR

// Pure-function tests for the #1276 Step 1 load-state machine. No WhisperKit
// instance is ever constructed — the state carries an `any LoadedASRModel`, and
// these tests supply a trivial `FakeModel`, exactly the property that made the
// functional-core split worth its cost. Covers the exhaustive (state × event)
// matrix (plan test 8) plus the targeted invariant scenarios (tests 1-4, 6, 7 at
// the decision-logic level; the actor-orchestration parts — #1282 capture timing,
// two-consumer — live in the actor test file).

private final class FakeModel: LoadedASRModel {}

private typealias Machine = WhisperKitLoadStateMachine

// Dummy task handles for building states/events. Their bodies never run in these
// pure tests — only the handle identity matters to the state machine.
private func dummyLoadTask() -> Task<Void, Error> { Task {} }
private func dummyWarmupTask() -> Task<WarmupOutcome, Never> { Task { .completed(ms: 0) } }

private func tags(_ effects: [Effect]) -> [EffectTag] { effects.map(\.tag) }

@Suite("WhisperKitLoadState — pure transition matrix (#1276 Step 1)")
struct WhisperKitLoadStateTests {

  // MARK: prepareRequested — single-flight 3-way decision (invariant #1)

  @Test("prepareRequested from idle → beginLoad")
  func prepareFromIdle() {
    let (next, effects) = Machine.transition(.idle, on: .prepareRequested, generation: 0)
    #expect(next.phase == .idle)
    #expect(tags(effects) == [.beginLoad])
  }

  @Test("prepareRequested while loading → joinLoad, no second load")
  func prepareWhileLoading() {
    let id = LoadIdentity(generation: 0, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(state, on: .prepareRequested, generation: 0)
    #expect(next.phase == .loading(id))
    #expect(tags(effects) == [.joinLoad])
  }

  @Test("prepareRequested while warming → joinLoad (returns warm)")
  func prepareWhileWarming() {
    let info = WarmupInfo(generation: 0, budgetSpent: false)
    let state = LoadState.warming(
      kit: FakeModel(), info, loadTask: dummyLoadTask(), warmupTask: dummyWarmupTask())
    let (next, effects) = Machine.transition(state, on: .prepareRequested, generation: 0)
    #expect(next.phase == .warming(info))
    #expect(tags(effects) == [.joinLoad])
  }

  @Test("prepareRequested while ready → idempotent no-op")
  func prepareWhileReady() {
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: nil)
    let (next, effects) = Machine.transition(state, on: .prepareRequested, generation: 0)
    #expect(next.isReady)
    #expect(effects.isEmpty)
  }

  // MARK: loadStarted — record the created load task

  @Test("loadStarted from idle → loading with that identity")
  func loadStartedRecords() {
    let id = LoadIdentity(generation: 3, id: 7)
    let (next, effects) = Machine.transition(
      .idle, on: .loadStarted(id, task: dummyLoadTask()), generation: 3)
    #expect(next.phase == .loading(id))
    #expect(effects.isEmpty)
  }

  // MARK: loadSucceeded — proceed to warm-up, or discard when stale (inv #3)

  @Test("loadSucceeded for the current load → beginWarmup")
  func loadSucceededCurrent() {
    let id = LoadIdentity(generation: 2, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(
      state, on: .loadSucceeded(kit: FakeModel(), id), generation: 2)
    #expect(next.phase == .loading(id))  // stays loading until warmupStarted records the task
    #expect(tags(effects) == [.beginWarmup(generation: 2)])
  }

  @Test("loadSucceeded after unload bumped generation → throwSuperseded (invariant #3)")
  func loadSucceededStaleGeneration() {
    // Load captured gen 2; unload() bumped live generation to 3 mid-load.
    let id = LoadIdentity(generation: 2, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(
      state, on: .loadSucceeded(kit: FakeModel(), id), generation: 3)
    #expect(next.phase == .loading(id))
    #expect(tags(effects) == [.throwSuperseded])
  }

  @Test("loadSucceeded when state already moved on → throwSuperseded")
  func loadSucceededWrongState() {
    let (next, effects) = Machine.transition(
      .idle, on: .loadSucceeded(kit: FakeModel(), LoadIdentity(generation: 1, id: 1)),
      generation: 1)
    #expect(next.phase == .idle)
    #expect(tags(effects) == [.throwSuperseded])
  }

  // MARK: loadFailed — retryable idle, only for the current load

  @Test("loadFailed for the current load → idle (retryable)")
  func loadFailedCurrent() {
    let id = LoadIdentity(generation: 0, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(state, on: .loadFailed(id), generation: 0)
    #expect(next.phase == .idle)
    #expect(effects.isEmpty)
  }

  @Test("loadFailed for a superseded load → ignored")
  func loadFailedStale() {
    let current = LoadIdentity(generation: 1, id: 2)
    let state = LoadState.loading(current, task: dummyLoadTask())
    let stale = LoadIdentity(generation: 0, id: 1)
    let (next, effects) = Machine.transition(state, on: .loadFailed(stale), generation: 1)
    #expect(next.phase == .loading(current))
    #expect(effects.isEmpty)
  }

  // MARK: warmupStarted — record warm-up task (loading → warming)

  @Test("warmupStarted for current load → warming")
  func warmupStartedCurrent() {
    let id = LoadIdentity(generation: 4, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(
      state, on: .warmupStarted(kit: FakeModel(), generation: 4, warmupTask: dummyWarmupTask()),
      generation: 4)
    #expect(next.phase == .warming(WarmupInfo(generation: 4, budgetSpent: false)))
    #expect(effects.isEmpty)
  }

  @Test("warmupStarted after generation bumped → cancel the orphan warm-up task")
  func warmupStartedStale() {
    let id = LoadIdentity(generation: 4, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(
      state, on: .warmupStarted(kit: FakeModel(), generation: 4, warmupTask: dummyWarmupTask()),
      generation: 5)
    #expect(next.phase == .loading(id))
    #expect(tags(effects) == [.cancelWarmupTask])
  }

  // MARK: warmupResolved — clean finish → ready(nil) + telemetry (inv #7)

  @Test("warmupResolved(completed) → ready(nil) + recordWarmupMs")
  func warmupCompleted() {
    let state = warmingState(generation: 1)
    let (next, effects) = Machine.transition(
      state, on: .warmupResolved(.completed(ms: 42), generation: 1), generation: 1)
    #expect(next.phase == .ready(staleWarmup: nil))
    #expect(next.isReady)
    #expect(tags(effects) == [.recordWarmupMs(42)])
  }

  @Test("warmupResolved(threw) → ready(nil) + logWarmupThrew, no ms recorded (inv #7)")
  func warmupThrew() {
    let state = warmingState(generation: 1)
    let (next, effects) = Machine.transition(
      state, on: .warmupResolved(.threw(desc: "boom"), generation: 1), generation: 1)
    #expect(next.phase == .ready(staleWarmup: nil))
    #expect(tags(effects) == [.logWarmupThrew("boom")])
  }

  @Test("warmupResolved for a superseded generation → ignored (no stale telemetry, inv #7)")
  func warmupResolvedStale() {
    let state = warmingState(generation: 1)
    let (next, effects) = Machine.transition(
      state, on: .warmupResolved(.completed(ms: 99), generation: 1), generation: 2)
    #expect(next.phase == .warming(WarmupInfo(generation: 1, budgetSpent: false)))
    #expect(effects.isEmpty)
  }

  // MARK: warmupTimedOut — fail-open ready carrying the orphan (invariant #6)

  @Test("warmupTimedOut → ready(orphan, budgetSpent) + logWarmupTimedOut, still vendable")
  func warmupTimedOut() {
    let state = warmingState(generation: 1)
    let (next, effects) = Machine.transition(
      state, on: .warmupTimedOut(generation: 1), generation: 1)
    #expect(next.phase == .ready(staleWarmup: WarmupInfo(generation: 1, budgetSpent: true)))
    #expect(next.isReady)  // fail-open-ready (invariant #6)
    #expect(tags(effects) == [.logWarmupTimedOut])
  }

  @Test("warmupTimedOut for a superseded generation → ignored")
  func warmupTimedOutStale() {
    let state = warmingState(generation: 1)
    let (next, effects) = Machine.transition(
      state, on: .warmupTimedOut(generation: 1), generation: 9)
    #expect(next.phase == .warming(WarmupInfo(generation: 1, budgetSpent: false)))
    #expect(effects.isEmpty)
  }

  // MARK: vendRequested — vend gate (invariants #4, #5, #6)

  @Test("vendRequested on clean ready → no drain (actor vends directly)")
  func vendCleanReady() {
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: nil)
    let (next, effects) = Machine.transition(state, on: .vendRequested, generation: 0)
    #expect(next.isReady)
    #expect(effects.isEmpty)
  }

  @Test("vendRequested on orphan whose budget is already spent → vend without re-draining (inv #4)")
  func vendOrphanBudgetSpent() {
    let orphan = OrphanWarmup(
      info: WarmupInfo(generation: 1, budgetSpent: true), task: dummyWarmupTask())
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: orphan)
    let (next, effects) = Machine.transition(state, on: .vendRequested, generation: 1)
    #expect(tags(effects) == [.logBudgetExhaustedVend])
    #expect(next.phase == .ready(staleWarmup: nil))  // orphan handle dropped
    #expect(next.isReady)
  }

  @Test("vendRequested on orphan with budget left → beginDrain")
  func vendOrphanDrain() {
    let orphan = OrphanWarmup(
      info: WarmupInfo(generation: 1, budgetSpent: false), task: dummyWarmupTask())
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: orphan)
    let (next, effects) = Machine.transition(state, on: .vendRequested, generation: 1)
    #expect(tags(effects) == [.beginDrain(generation: 1)])
    #expect(next.isReady)
  }

  @Test("vendRequested mid-warming with budget left → beginDrain the live warm-up")
  func vendWhileWarming() {
    let state = warmingState(generation: 2)
    let (next, effects) = Machine.transition(state, on: .vendRequested, generation: 2)
    #expect(tags(effects) == [.beginDrain(generation: 2)])
    #expect(next.phase == .warming(WarmupInfo(generation: 2, budgetSpent: false)))
  }

  @Test("vendRequested while idle or loading → no-op (actor returns nil)")
  func vendNotReady() {
    let (n1, e1) = Machine.transition(.idle, on: .vendRequested, generation: 0)
    #expect(n1.phase == .idle)
    #expect(e1.isEmpty)
    let id = LoadIdentity(generation: 0, id: 1)
    let (n2, e2) = Machine.transition(
      .loading(id, task: dummyLoadTask()), on: .vendRequested, generation: 0)
    #expect(n2.phase == .loading(id))
    #expect(e2.isEmpty)
  }

  // MARK: drainResolved — clear orphan, let actor re-vend

  @Test("drainResolved(success) on orphan → ready(nil), no log")
  func drainResolvedSuccess() {
    let orphan = OrphanWarmup(
      info: WarmupInfo(generation: 1, budgetSpent: false), task: dummyWarmupTask())
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: orphan)
    let (next, effects) = Machine.transition(
      state, on: .drainResolved(didTimeOut: false, generation: 1), generation: 1)
    #expect(next.phase == .ready(staleWarmup: nil))
    #expect(effects.isEmpty)
  }

  @Test("drainResolved(timeout) on orphan → ready(nil) + logDrainTimedOutVend")
  func drainResolvedTimeout() {
    let orphan = OrphanWarmup(
      info: WarmupInfo(generation: 1, budgetSpent: false), task: dummyWarmupTask())
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: orphan)
    let (next, effects) = Machine.transition(
      state, on: .drainResolved(didTimeOut: true, generation: 1), generation: 1)
    #expect(next.phase == .ready(staleWarmup: nil))
    #expect(tags(effects) == [.logDrainTimedOutVend])
  }

  @Test("drainResolved for a superseded generation → ignored")
  func drainResolvedStale() {
    let orphan = OrphanWarmup(
      info: WarmupInfo(generation: 1, budgetSpent: false), task: dummyWarmupTask())
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: orphan)
    let (next, effects) = Machine.transition(
      state, on: .drainResolved(didTimeOut: false, generation: 1), generation: 2)
    #expect(next.phase == .ready(staleWarmup: WarmupInfo(generation: 1, budgetSpent: false)))
    #expect(effects.isEmpty)
  }

  // MARK: unloadRequested — teardown, cancel held tasks

  @Test("unloadRequested from idle → idle")
  func unloadIdle() {
    let (next, effects) = Machine.transition(.idle, on: .unloadRequested, generation: 1)
    #expect(next.phase == .idle)
    #expect(effects.isEmpty)
  }

  @Test("unloadRequested while loading → idle + cancelLoadTask")
  func unloadLoading() {
    let id = LoadIdentity(generation: 0, id: 1)
    let state = LoadState.loading(id, task: dummyLoadTask())
    let (next, effects) = Machine.transition(state, on: .unloadRequested, generation: 1)
    #expect(next.phase == .idle)
    #expect(tags(effects) == [.cancelLoadTask])
  }

  @Test("unloadRequested while warming → idle + cancel both tasks")
  func unloadWarming() {
    let state = warmingState(generation: 0)
    let (next, effects) = Machine.transition(state, on: .unloadRequested, generation: 1)
    #expect(next.phase == .idle)
    #expect(tags(effects) == [.cancelLoadTask, .cancelWarmupTask])
  }

  @Test("unloadRequested with a ready orphan → idle + cancel orphan warm-up")
  func unloadReadyOrphan() {
    let orphan = OrphanWarmup(
      info: WarmupInfo(generation: 0, budgetSpent: true), task: dummyWarmupTask())
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: orphan)
    let (next, effects) = Machine.transition(state, on: .unloadRequested, generation: 1)
    #expect(next.phase == .idle)
    #expect(tags(effects) == [.cancelOrphanWarmupOnUnload])
  }

  @Test("unloadRequested from clean ready → idle, nothing to cancel")
  func unloadReadyClean() {
    let state = LoadState.ready(kit: FakeModel(), staleWarmup: nil)
    let (next, effects) = Machine.transition(state, on: .unloadRequested, generation: 1)
    #expect(next.phase == .idle)
    #expect(effects.isEmpty)
  }

  // Helper: a `.warming` state at a given generation.
  private func warmingState(generation: UInt64) -> LoadState {
    .warming(
      kit: FakeModel(), WarmupInfo(generation: generation, budgetSpent: false),
      loadTask: dummyLoadTask(), warmupTask: dummyWarmupTask())
  }
}
