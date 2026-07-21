import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Observation

/// Telemetry Bible Phase 2 (#1171) — the single App-owned owner of ASR-engine
/// selection, status, and switching.
///
/// Before this, "which engine is selected / active / ready / busy" and the
/// switch operation itself were scattered across 8+ sites with no owner; the
/// first #1171 fix piled three stored "want" copies onto `PipelineSettingsSync`
/// and drove them from five racing async triggers, which lost six review rounds
/// to timing bugs. The root causes (Codex architecture review + council): (a)
/// duplicate want-state that drifts, (b) too many racing triggers, (c) no owner
/// of engine status. `@MainActor` does NOT serialize across the `await` inside
/// `switchBackend` (it suspends to unload the old engine), so "one serial
/// worker" was never actually serial.
///
/// This coordinator fixes all three:
/// - It is the SOLE production caller of `asrManager.switchBackend(to:)`.
/// - The user's choice is read LIVE from `settings.selectedBackend`; there is
///   no stored duplicate of the target (pending-switch is DERIVED as
///   `selected != active`).
/// - Switches are strictly single-in-flight via ONE consumer over an
///   `AsyncStream<PokeReason>` (`.bufferingNewest(1)`), so a flurry of pokes
///   coalesces into one re-evaluation and rapid toggles collapse to latest-wins.
/// - It holds `isSwitching` across the whole `await`, which recovery-start and
///   record-start both respect (heart-path safety).
///
/// Limb-adjacent control plane, not heart: if it fails, the active engine keeps
/// transcribing. Carries minimal state (the published `EngineStatus` snapshot +
/// a telemetry deferred-epoch marker); it orchestrates injected services and
/// builds nothing. Ownership rationale: `docs/feature-requests/issue-1171-…`.
@MainActor
@Observable
final class EngineCoordinator {

  /// Why the worker was poked. The reason is informational (every poke runs the
  /// same reconcile); it documents the trigger and keeps the poke-source set
  /// (status-invalidation contract, §5) auditable.
  enum PokeReason: Sendable {
    case settingsChanged
    case driverStateChanged
    case recoveryComplete
    case warmCompleted
    case setupStateChanged
    case launch
  }

  /// Injected reads + operations. Bundling them keeps the coordinator a thin
  /// policy object (it owns no drivers) and makes every race deterministically
  /// unit-testable with fakes (fake want / active / busy / recovering /
  /// installed / readiness, a recording-free switch fn, a programmable warm fn).
  struct Dependencies {
    /// The user's live selection (`settings.selectedBackend`).
    let selectedBackend: @MainActor () -> ASRBackendType
    /// The actually-active engine (`asrManager.activeBackendType`).
    let activeBackend: @MainActor () -> ASRBackendType
    /// A given engine's normalized readiness (the matching driver's).
    let readiness: @MainActor (ASRBackendType) -> ASREngineReadiness
    /// Whether a given engine's pipeline is recording/transcribing/polishing.
    let isEngineActive: @MainActor (ASRBackendType) -> Bool
    /// Whether crash recovery is replaying on the shared engine.
    let isRecovering: @MainActor () -> Bool
    /// Whether the given engine's model is on disk (gates a load attempt).
    let isInstalled: @MainActor (ASRBackendType) -> Bool
    /// A telemetry label for the given engine's pipeline state.
    let stateLabel: @MainActor (ASRBackendType) -> String
    /// The mechanical, nonthrowing backend switch (`asrManager.switchBackend`).
    let performSwitch: @MainActor (ASRBackendType) async -> Void
    /// Background warm of the given engine (the matching driver's
    /// `ensureEngineWarm`). The ONLY place a load failure surfaces.
    let warm: @MainActor (ASRBackendType) async -> EngineWarmupOutcome
    /// #1707 Phase 3 (§3.2, row 4) — `EngineRecoveryGate.tryBeginMutation()`,
    /// injected exactly like `isRecovering` above (this type never references
    /// `EngineRecoveryGate` by concrete type). Bound by the composition root;
    /// default keeps every existing test that doesn't wire a gate behaving as
    /// before (always able to proceed).
    var tryBeginEngineMutation: @MainActor () -> Bool = { true }
    /// `EngineRecoveryGate.endMutation()` — returns whether recovery was
    /// denied while this mutation was in flight and is now owed a wake-up.
    var endEngineMutation: @MainActor () -> Bool = { false }
    /// Called when `endEngineMutation()` returns true — wakes a stranded
    /// recovery attempt. Bound to `RecoveryCoordinator.requestRecoveryRecheck`.
    var wakeRecoveryIfOwed: @MainActor () -> Void = {}
  }

  // MARK: - Published snapshot + gate

  /// The single read-source for every consumer. Recomputed + republished on
  /// every poke (status-invalidation contract, §5).
  private(set) var status: EngineStatus

  /// True for the whole duration of an in-flight switch (set synchronously
  /// before the `await`, cleared synchronously after). Recovery-start and
  /// record-start read it to mutually exclude with a switch (§3.4).
  private(set) var isSwitching = false

  /// #1707 Phase 3 (§3.4 wake-up table) — fired when a warm completes, a
  /// setup/migration state change lands, or an engine switch completes: any
  /// of these may unblock a recovery pass that previously yielded. The
  /// composition root binds this to
  /// `RecoveryCoordinator.requestRecoveryRecheck`.
  var onEngineStateChangedForRecovery: (() -> Void)?

  // MARK: - Wiring

  private let deps: Dependencies
  @ObservationIgnored private let pokeContinuation: AsyncStream<PokeReason>.Continuation
  @ObservationIgnored private let pokeStream: AsyncStream<PokeReason>
  @ObservationIgnored private var worker: Task<Void, Never>?

  /// The current background warm Task + the engine it is warming, so a new
  /// switch cancels a stale warm and a repeated convergence poke does not churn
  /// the Task.
  @ObservationIgnored private var warmTask: Task<Void, Never>?
  @ObservationIgnored private var warmingBackend: ASRBackendType?
  /// The engine whose in-flight load gate 4b is currently joining (so repeated
  /// gate-4b pokes don't spawn duplicate join tasks).
  @ObservationIgnored private var joiningBackend: ASRBackendType?

  /// True while a record-start is minting a session (from the moment the start
  /// path commits — selected == active confirmed — through the kernel going
  /// active). The reconcile worker treats this exactly like a live recording and
  /// REFUSES to switch (gate 5), so the active engine cannot change out from under
  /// the start path. This is the SuperWhisper "Cannot switch in <starting> state"
  /// state-gate — the sibling of "don't switch while recording" — and it replaces
  /// the previous (fundamentally leaky) re-check-after-await guards.
  @ObservationIgnored private var isMinting = false

  // Coordinator-owned status fields (not derivable from live sources).
  @ObservationIgnored private var currentSwitchPhase: EngineStatus.SwitchPhase = .idle
  @ObservationIgnored private var currentBlockedReason: EngineStatus.BlockedReason?

  // Deferred-epoch bookkeeping for once-per-divergence telemetry + defer timing.
  @ObservationIgnored private var emittedBlocked: Set<EngineStatus.BlockedReason> = []
  @ObservationIgnored private var deferStart: ContinuousClock.Instant?

  // Record-start waiters (awaitable convergence; see `ensureSelectedReadyForPress`).
  @ObservationIgnored private var pressWaiters: [CheckedContinuation<Void, Never>] = []

  init(dependencies: Dependencies) {
    self.deps = dependencies
    self.status = EngineCoordinator.snapshot(
      deps: dependencies, switchPhase: .idle, blockedReason: nil)
    let (stream, continuation) = AsyncStream<PokeReason>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    self.pokeStream = stream
    self.pokeContinuation = continuation
  }

  /// Launch the single reconcile worker, begin observing the WhisperKit
  /// setup-state directly, and fire the initial reconcile. Called once by the
  /// composition root after construction (and by unit tests).
  func start() {
    guard worker == nil else { return }
    // Capture the stream strongly but `self` weakly: a strong `self` held across
    // the infinite `for await` would be a retain cycle (self → worker → self) that
    // never deallocates. When `self` is released, its `pokeContinuation` finishes
    // the stream, the loop ends, and the worker completes.
    let stream = pokeStream
    worker = Task { [weak self] in
      for await reason in stream {
        guard let self else { break }
        await self.reconcile(reason)
      }
    }
    observeInstalledState()
    poke(.launch)
  }

  // MARK: - Public API

  /// Fire-and-forget reconcile trigger. Coalesced by the mailbox's
  /// `bufferingNewest(1)`, so a burst collapses to one re-evaluation.
  func poke(_ reason: PokeReason) {
    pokeContinuation.yield(reason)
  }

  /// Called by the record-start path the instant it commits to minting a session
  /// (after it has confirmed selected == active and no switch is in flight). While
  /// held, the worker refuses to switch engines (gate 5), so the active engine the
  /// start path captured cannot change under it. Synchronous and re-entrancy-free
  /// (record-start is single-flight on the MainActor). Pairs with `endMinting()`.
  func beginMinting() { isMinting = true }

  /// #1386 PR-2c: the Remove refusal's second read. `currentSessionConfig`
  /// materializes only at kernel-active, so a start that has committed but not
  /// yet frozen its config reads as "no session" — this gate covers exactly
  /// that window (the same gate 5 uses to refuse engine switches mid-start).
  /// Scoped to WhisperKit: a Parakeet start does not block removing the
  /// multilingual model.
  var isMintingWhisperKitSession: Bool { isMinting && status.active == .whisperKit }

  /// Called when the record-start path finishes (via `defer`, so it runs on every
  /// exit). Re-pokes so an engine switch deferred during the start window applies
  /// now (or stays deferred behind the live recording, which gate 5 still covers).
  func endMinting() {
    isMinting = false
    poke(.driverStateChanged)
  }

  /// The outcome of a record-start readiness drive, so the caller shows the
  /// correct pill for EVERY cell of (press × selected-engine state) rather than
  /// only the ready cell.
  enum PressReadiness: Sendable, Equatable {
    /// Selected engine is active + warmed → record-ready (the user re-presses).
    case ready
    /// Selected model is not on disk → direct the user to download it.
    case notInstalled
    /// Switched but not ready (a failed warm, or an unexpected block) → the next
    /// press retries via the cold-press path.
    case notReady
  }

  /// Awaitable record-start path: ensure the SELECTED engine is switched-to and
  /// warm before a recording is minted, returning the outcome so the caller
  /// surfaces an honest pill and mints no session. Drives the work THROUGH the
  /// single switcher (it pokes and awaits convergence), so it can never race the
  /// worker into a double switch.
  @discardableResult
  func ensureSelectedReadyForPress() async -> PressReadiness {
    // Refresh from live deps FIRST: an immediate press right after a picker change
    // can arrive before the worker drains the `.settingsChanged` poke, leaving
    // `status` a stale converged snapshot. Recomputing here makes the ready/terminal
    // short-circuit see the real (diverged) state, so it registers a waiter instead
    // of returning early and stranding the caching pill without a Ready announcement.
    publishStatus()
    if !isSelectedReadyOrTerminal() {
      poke(.settingsChanged)
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        pressWaiters.append(cont)
      }
    }
    // Recompute from the now-settled status + LIVE install state (consistent with
    // `isSelectedReadyOrTerminal`, which reads live deps rather than the cached block).
    let s = status
    if s.selected == s.active && s.selectedReadiness == .ready { return .ready }
    if !deps.isInstalled(s.selected) { return .notInstalled }
    return .notReady
  }

  // MARK: - The reconcile worker (single mailbox consumer)

  private func reconcile(_ reason: PokeReason) async {
    // Every exit resumes any record-start waiter whose condition is now met.
    defer { resumePressWaitersIfReady() }

    // #1707 Phase 3 (§3.4 wake-up table): either of these may unblock a
    // recovery pass that previously yielded because the engine wasn't ready
    // or a migration was in flight.
    if reason == .warmCompleted || reason == .setupStateChanged {
      onEngineStateChangedForRecovery?()
    }

    let want = deps.selectedBackend()
    let actual = deps.activeBackend()

    // 3. Converged — nothing owed.
    if want == actual {
      currentBlockedReason = nil
      var justLeftSwitchingPhase = false
      if deps.readiness(actual) == .ready, case .switching = currentSwitchPhase {
        currentSwitchPhase = .idle
        justLeftSwitchingPhase = true
      }
      clearEpoch()
      publishStatus()
      // GitHub cloud review, PR #1732 (round 2 — the round-1 fix here was
      // itself a real self-inflicted regression, caught by a later review
      // round rather than shipped): a recovery pass that deferred because
      // `isEngineSwitching()` was true can reach a genuinely converged engine
      // through a `reason` this function doesn't otherwise wake recovery for
      // (e.g. `.settingsChanged` looping back here after a superseded switch
      // re-settled to the id it started from) — without a wake here, such a
      // pass stays stranded until an unrelated wake-up or the next launch.
      // MUST be gated on `justLeftSwitchingPhase`, not unconditional: this
      // fast path is ALSO reached via `.recoveryComplete` itself (fired after
      // EVERY replayed item, retained or not) — an unconditional wake here
      // creates a closed loop for any RETAINED outcome (e.g. persistent
      // marker-write or History-save failure): replay → onRecoveryComplete →
      // poke(.recoveryComplete) → this fast path → wake → requestRecheck →
      // re-discover the SAME still-retained spool → replay again, forever.
      // Gating on the phase transition breaks the cycle: `currentSwitchPhase`
      // is already `.idle` by the second iteration, so the condition is false.
      if justLeftSwitchingPhase {
        onEngineStateChangedForRecovery?()
      }
      return
    }

    // 4. Selected model not on disk — never attempt to load a missing model.
    if !deps.isInstalled(want) {
      markBlocked(.notInstalled)
      return
    }

    // 4b. Active engine's load is in flight — defer so `switchBackend` only ever
    // runs against a SETTLED active engine. This closes the XPC stale
    // in-flight-load race: a switch mid-load could leave the OLD backend
    // resident service-side (the service routes by backend ref, not
    // activeBackendType). The in-flight load may be a COORDINATOR-owned warm OR
    // an external one (launch preload, cold-press warm) that does NOT poke us —
    // so we join it (`ensureEngineWarm` is single-flight: this coalesces with the
    // in-flight load and returns when it settles, no second load, no timer) and
    // re-poke, re-arming the deferred switch regardless of who started the load.
    if deps.readiness(actual) == .warming {
      markBlocked(.loading)
      joinInFlightWarm(actual)
      return
    }

    // 5. A pipeline is recording/transcribing/polishing — OR a record-start is
    // minting a session on the active engine — defer to its terminal. The
    // `isMinting` gate closes the start-window race race-free (the active engine
    // can't be switched out mid-startup), replacing the leaky re-check-after-await guards.
    if deps.isEngineActive(.parakeet) || deps.isEngineActive(.whisperKit) || isMinting {
      markBlocked(.pipelineActive)
      return
    }

    // 6. Crash recovery is replaying on the shared engine — defer to completion.
    if deps.isRecovering() {
      markBlocked(.recovery)
      return
    }

    // 7. Perform the (mechanical, nonthrowing) switch under the held gate.
    let deferred = deferStart != nil
    let deferMs = deferStart.map { Self.elapsedMs(since: $0) } ?? 0
    isSwitching = true
    currentBlockedReason = nil
    currentSwitchPhase = .switching
    publishStatus()
    let switchStart = ContinuousClock.now
    await deps.performSwitch(want)
    let switchMs = Self.elapsedMs(since: switchStart)
    isSwitching = false

    // Re-read the live selection: a flip during the `await` supersedes this.
    let wantNow = deps.selectedBackend()
    if wantNow != want {
      TelemetryService.shared.engineSwitchSuperseded(from: want.rawValue, to: wantNow.rawValue)
      currentSwitchPhase = .idle
      publishStatus()
      // GitHub cloud review, PR #1732: `isSwitching` just cleared (line 325)
      // — a recovery pass that deferred behind THIS switch may now be able to
      // proceed even though this particular switch was superseded rather than
      // cleanly completed. The queued `.settingsChanged` poke below re-drives
      // the engine toward the new target but is not itself a recovery-wake
      // reason (line ~254), so without this call a pass deferred here has no
      // guaranteed wake-up.
      onEngineStateChangedForRecovery?()
      poke(.settingsChanged)  // loop to the latest target
      return
    }

    TelemetryService.shared.settingsChangeApplied(
      setting: "selected_backend", from: actual.rawValue, to: want.rawValue,
      deferred: deferred, deferMs: deferMs, switchMs: switchMs)
    currentSwitchPhase = .idle
    clearEpoch()
    publishStatus()
    // #1707 Phase 3 (§3.4 wake-up table): a completed switch may unblock a
    // recovery pass that previously yielded because a switch was in flight.
    onEngineStateChangedForRecovery?()

    // 8. Warm the now-active engine in the background (never awaited here).
    startWarm(for: want)
  }

  // MARK: - Background warm (the only place a load FAILURE surfaces)

  private func startWarm(for backend: ASRBackendType) {
    // Never load a model that isn't on disk; never warm one already ready;
    // never warm during an active recording (the record path warms its own).
    guard deps.isInstalled(backend) else { return }
    guard deps.readiness(backend) != .ready else { return }
    guard !deps.isEngineActive(.parakeet), !deps.isEngineActive(.whisperKit) else { return }
    if warmingBackend == backend, warmTask != nil { return }

    warmTask?.cancel()
    warmingBackend = backend
    warmTask = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      // #1707 Phase 3 (§3.2, row 4): hold a mutation claim for the FULL
      // awaited warm — recovery must never race a background warm. A denied
      // claim (recovery holds the engine) skips this attempt; the next
      // natural trigger (a future switch landing here, or a press's own
      // cold-press warm) re-attempts — no bespoke retry machinery for a
      // background convenience warm.
      guard self.deps.tryBeginEngineMutation() else {
        TelemetryService.shared.recoveryEngineActionDeferred(site: "startWarm")
        self.warmingBackend = nil
        return
      }
      defer {
        if self.deps.endEngineMutation() { self.deps.wakeRecoveryIfOwed() }
      }
      let start = ContinuousClock.now
      let outcome = await self.deps.warm(backend)
      self.warmingBackend = nil
      if Task.isCancelled { return }
      let ms = Self.elapsedMs(since: start)
      switch outcome {
      case .ready:
        TelemetryService.shared.engineWarm(
          engine: backend.rawValue, durationMs: ms, outcome: "ready")
        if case .failed = self.currentSwitchPhase { self.currentSwitchPhase = .idle }
      case .failed:
        // switchBackend itself cannot fail; a load failure is a WARM outcome.
        // Honor the user's choice (active stays the newly-selected engine) and
        // surface honestly — the next press takes the cold-press path. No tight
        // retry; the next genuine poke/press re-attempts.
        self.currentSwitchPhase = .failed(reason: "warm_failed")
        TelemetryService.shared.engineWarm(
          engine: backend.rawValue, durationMs: ms, outcome: "failed")
        TelemetryService.shared.engineSwitchFailed(engine: backend.rawValue, reason: "warm_failed")
      case .cancelled:
        // #1388: a deliberate cancel (user Cancel during the onboarding
        // install, which shares the single-flighted load this warm joined) is
        // a choice, not a failure — no failed switch phase, no
        // engine_switch_failed. The next genuine poke/press re-attempts.
        TelemetryService.shared.engineWarm(
          engine: backend.rawValue, durationMs: ms, outcome: "cancelled")
      }
      // Readiness changed with NO kernel state transition, so `onStateChange`
      // would miss it — self-poke so the published status reflects it AND any
      // gate-4b-deferred switch re-arms (REV-4).
      self.poke(.warmCompleted)
    }
  }

  /// Gate 4b helper: join the active engine's in-flight load and re-poke when it
  /// settles, so a switch deferred because the active engine is mid-load is
  /// re-armed even when the load was started OUTSIDE the coordinator (launch
  /// preload, cold-press warm) and therefore never self-pokes. `ensureEngineWarm`
  /// is single-flight, so this coalesces with the in-flight load (no second load)
  /// and resolves on settle — a signal, not a timer. Guarded so repeated gate-4b
  /// pokes don't spawn duplicate joiners.
  private func joinInFlightWarm(_ backend: ASRBackendType) {
    guard joiningBackend != backend else { return }
    joiningBackend = backend
    Task(priority: .utility) { [weak self] in
      guard let self else { return }
      _ = await self.deps.warm(backend)
      self.joiningBackend = nil
      self.poke(.warmCompleted)
    }
  }

  // MARK: - Status publication + epoch bookkeeping

  private func publishStatus() {
    status = Self.snapshot(
      deps: deps, switchPhase: currentSwitchPhase, blockedReason: currentBlockedReason)
  }

  private static func snapshot(
    deps: Dependencies,
    switchPhase: EngineStatus.SwitchPhase,
    blockedReason: EngineStatus.BlockedReason?
  ) -> EngineStatus {
    let sel = deps.selectedBackend()
    let act = deps.activeBackend()
    return EngineStatus(
      selected: sel,
      active: act,
      selectedReadiness: deps.readiness(sel),
      activeReadiness: deps.readiness(act),
      parakeetActive: deps.isEngineActive(.parakeet),
      whisperKitActive: deps.isEngineActive(.whisperKit),
      switchPhase: switchPhase,
      selectedInstalled: deps.isInstalled(sel),
      blockedReason: blockedReason)
  }

  /// Record a deferral, emit `change_blocked` once per reason per epoch, publish.
  private func markBlocked(_ reason: EngineStatus.BlockedReason) {
    if deferStart == nil { deferStart = ContinuousClock.now }
    currentBlockedReason = reason
    if !emittedBlocked.contains(reason) {
      emittedBlocked.insert(reason)
      let want = deps.selectedBackend()
      let active = deps.activeBackend()
      TelemetryService.shared.settingsChangeBlocked(
        setting: "selected_backend", requested: want.rawValue, activeBackend: active.rawValue,
        reason: reason.rawValue,
        parakeetState: deps.stateLabel(.parakeet), whisperKitState: deps.stateLabel(.whisperKit))
    }
    publishStatus()
  }

  /// Reset the divergence epoch (telemetry dedup + defer timer) on convergence.
  private func clearEpoch() {
    emittedBlocked.removeAll()
    deferStart = nil
  }

  // MARK: - WhisperKit setup-state observation (direct, not via SetupCoordinator)

  /// Observe the WhisperKit setup-state DIRECTLY: `SetupCoordinator`'s observer
  /// bails unless WhisperKit is the active backend, so a Settings-initiated
  /// download completing while Fast is active would otherwise never flip
  /// `selectedInstalled`. Reading `isInstalled(.whisperKit)` inside the tracking
  /// block registers the dependency on `whisperKitSetup.setupState` (REV-4). In
  /// unit tests the fake reader touches no `@Observable` source, so this is inert.
  private func observeInstalledState() {
    withObservationTracking {
      _ = deps.isInstalled(.whisperKit)
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.poke(.setupStateChanged)
        self.observeInstalledState()  // re-arm (one-shot per fire)
      }
    }
  }

  // MARK: - Record-start convergence waiters

  /// Whether a record-start wait should STOP (the selected engine is ready, or it
  /// has reached a state where waiting longer is pointless). Derived from first
  /// principles over the full coordinator state so a press never reports Ready
  /// early or hangs:
  ///
  /// 1. ANY work in flight — a switch (`isSwitching`), a gate-4b load-join
  ///    (`joiningBackend`), or a post-switch warm (`warmingBackend`) — means
  ///    "keep waiting": each re-pokes on completion, and reporting Ready now could
  ///    race a superseded switch that has not settled (Codex r5).
  /// 2. Settled + the selected engine is active and ready → READY.
  /// 3. Settled terminal-for-press: not installed (→ download), a failed warm, or
  ///    a standing block (pipeline/recovery — the press cannot proceed now).
  ///    `.loading` is NOT terminal here: while it holds, the gate-4b join is in
  ///    flight, so case 1 already returned false.
  /// 4. Settled + converged but not ready → let the cold-press path take over
  ///    (the coordinator only warms after a switch; defensive no-hang).
  /// 5. Settled + still diverged with no terminal block → the switch is pending
  ///    (we always poked before waiting); keep waiting.
  ///
  /// Terminal blocks are read from LIVE deps, not the cached `blockedReason` (which
  /// lags a reconcile and can be stale right after a recording/recovery clears),
  /// so a press never gives up early on a block that has already lifted.
  private func isSelectedReadyOrTerminal() -> Bool {
    if isSwitching || joiningBackend != nil || warmingBackend != nil { return false }
    let s = status
    if s.selected == s.active && s.selectedReadiness == .ready { return true }
    if !deps.isInstalled(s.selected) { return true }  // model absent (on-disk fact)
    if case .failed = s.switchPhase { return true }  // warm genuinely failed
    // Genuinely busy/recovering RIGHT NOW (live, not a stale cached reason): the
    // press cannot proceed, so give up rather than hang.
    if deps.isEngineActive(.parakeet) || deps.isEngineActive(.whisperKit) { return true }
    if deps.isRecovering() { return true }
    if s.selected == s.active { return true }  // converged steady not-ready → cold-press
    return false  // diverged + free → the switch is pending; keep waiting
  }

  private func resumePressWaitersIfReady() {
    guard !pressWaiters.isEmpty, isSelectedReadyOrTerminal() else { return }
    let waiters = pressWaiters
    pressWaiters.removeAll()
    for w in waiters { w.resume() }
  }

  private static func elapsedMs(since instant: ContinuousClock.Instant) -> Int {
    let (s, a) = (ContinuousClock.now - instant).components
    return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
  }
}
