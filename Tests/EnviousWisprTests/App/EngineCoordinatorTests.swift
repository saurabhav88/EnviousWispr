import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1171 — deterministic coverage for every race the duct-tape design lost six
/// review rounds to, expressed against the injectable `EngineCoordinator` (fake
/// want / active / busy / recovering / installed / readiness). The coordinator is
/// the single switcher, so each race is a tight unit test with no drivers booting.
///
/// `.serialized` — the telemetry tests install the process-wide
/// `TelemetryService.shared.testEventHook`; serial execution prevents one test
/// clearing the hook while another awaits (mirrors the prior #1171 suite).
@MainActor
@Suite("EngineCoordinator (#1171)", .serialized)
struct EngineCoordinatorTests {

  // MARK: - Latest-wins / single-flight

  @Test("idle switch applies and warms the now-active engine")
  func idleSwitchAppliesAndWarms() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let converged = await enginePoll { fake.active == .whisperKit }
    #expect(converged, "idle switch must apply")
    #expect(fake.switchCount == 1)
    let warmed = await enginePoll { fake.whisperKitReadiness == .ready }
    #expect(warmed, "the now-active engine must be warmed")
    #expect(c.status.active == .whisperKit)
    #expect(c.status.selectedReadiness == .ready)
  }

  @Test("rapid toggles converge to the latest selection, never the intermediate")
  func latestWins() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    // P -> W -> P -> W back-to-back (synchronous): the mailbox coalesces to the
    // latest (whisperKit), so the coordinator switches straight to it and never
    // to the intermediate parakeet.
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    fake.selected = .parakeet
    c.poke(.settingsChanged)
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let settled = await enginePoll { fake.active == .whisperKit && !c.isSwitching }
    #expect(settled, "the latest selection (whisperKit) must win")
    #expect(
      fake.switchHistory.allSatisfy { $0 == .whisperKit },
      "must only ever switch toward the latest, never the coalesced intermediate: \(fake.switchHistory)"
    )
  }

  @Test("a rapid A->B->A flurry that nets to the active engine is a no-op (no switch)")
  func coalescedNoOpFlurry() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    fake.selected = .parakeet
    c.poke(.settingsChanged)
    let settled = await enginePoll { fake.active == .parakeet && !c.isSwitching }
    #expect(settled, "stays converged on the active engine")
    #expect(fake.switchCount == 0, "a net no-op flurry must not switch the engine at all")
  }

  @Test("a switch superseded mid-flight converges to the latest and reports churn")
  func supersededMidSwitch() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let latch = AsyncLatch()
    // While switching to WhisperKit, the user flips back to Parakeet.
    fake.onSwitchAwait = { [weak fake] in
      fake?.selected = .parakeet
      await latch.wait()
    }
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let switching = await enginePoll { c.isSwitching }
    #expect(switching)
    latch.release()
    // The first switch lands on WhisperKit but is detected superseded; the loop
    // then switches back to the latest (Parakeet).
    let settled = await enginePoll { fake.active == .parakeet && !c.isSwitching }
    #expect(settled, "must converge to the latest selection after supersession")
  }

  // MARK: - Deferral gates

  @Test("switch deferred while a pipeline is active, applies on the terminal poke")
  func deferredWhileRecording() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.parakeetActive = true  // recording in flight
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    // No swap while recording.
    let stayed = await enginePoll(.milliseconds(150)) { fake.active == .whisperKit }
    #expect(stayed == false, "must not swap mid-recording")
    #expect(c.status.blockedReason == .pipelineActive)
    // Recording ends → driver-state poke applies the deferred switch.
    fake.parakeetActive = false
    c.poke(.driverStateChanged)
    let applied = await enginePoll { fake.active == .whisperKit }
    #expect(applied, "the deferred switch must apply once recording ends")
  }

  @Test("switch deferred while recovering, applies on recovery-complete poke")
  func deferredWhileRecovering() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.recovering = true
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let stayed = await enginePoll(.milliseconds(150)) { fake.active == .whisperKit }
    #expect(stayed == false, "must not swap during recovery")
    #expect(c.status.blockedReason == .recovery)
    fake.recovering = false
    c.poke(.recoveryComplete)
    let applied = await enginePoll { fake.active == .whisperKit }
    #expect(applied, "the deferred switch must apply once recovery completes")
  }

  @Test(
    "a deferred switch applying on recovery-complete still wakes recovery (round-2 fix, PR #1732)"
  )
  func deferredSwitchAppliedOnRecoveryCompleteWakesRecovery() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.recovering = true
    let c = fake.makeStartedCoordinator()
    var wakeCount = 0
    c.onEngineStateChangedForRecovery = { wakeCount += 1 }
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    _ = await enginePoll(.milliseconds(150)) { fake.active == .whisperKit }
    fake.recovering = false
    c.poke(.recoveryComplete)
    let applied = await enginePoll { fake.active == .whisperKit }
    #expect(applied, "the deferred switch must still apply once recovery completes")
    // >=1, not an exact count: the switch-completion path (pre-existing,
    // unconditional) AND the subsequent warm-completion path (pre-existing,
    // `.warmCompleted`-gated) both legitimately fire here — this test's point
    // is that the ROUND-2 gating change (only wake on a genuine
    // switching->idle transition) does not accidentally suppress the real
    // wake this scenario depends on, not to pin an incidental trigger count.
    #expect(wakeCount >= 1, "a genuine switching->idle transition must wake recovery")
  }

  @Test(
    "an already-converged recovery-complete poke never wakes recovery — GitHub cloud review round 1's fix, self-caught before shipping, was a closed loop for any RETAINED recovery outcome (PR #1732)"
  )
  func alreadyConvergedRecoveryCompletePokeNeverWakesRecovery() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    var wakeCount = 0
    c.onEngineStateChangedForRecovery = { wakeCount += 1 }
    // Mirrors `RecoveryCoordinator.onRecoveryComplete` firing after EVERY
    // replayed item, retained or not — repeated to prove this never becomes
    // a self-perpetuating loop when nothing was ever switching.
    for _ in 0..<5 {
      c.poke(.recoveryComplete)
      _ = await enginePoll(.milliseconds(50)) { false }  // let the mailbox drain
    }
    #expect(
      wakeCount == 0,
      "an ordinary already-converged poke must never wake recovery — no switch ever deferred")
  }

  @Test("not-installed selection never loads, applies once the model downloads")
  func notInstalledDefersUntilDownloaded() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.whisperKitInstalled = false
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let stayed = await enginePoll(.milliseconds(150)) { fake.switchCount > 0 }
    #expect(stayed == false, "must never attempt a switch to a missing model")
    #expect(c.status.blockedReason == .notInstalled)
    // Download completes (fires even though Fast is active — direct observation).
    fake.whisperKitInstalled = true
    c.poke(.setupStateChanged)
    let applied = await enginePoll { fake.active == .whisperKit }
    #expect(applied, "the switch must apply once the model is installed")
  }

  @Test("switch deferred while the active engine is mid-load (gate 4b), re-armed when it settles")
  func deferredWhileActiveEngineWarming() async {
    let fake = FakeEngineDeps(
      selected: .parakeet, active: .parakeet,
      parakeetReadiness: .warming, whisperKitReadiness: .ready)
    // Hold the active engine's in-flight load open so the gate-4b defer is
    // observable; the coordinator joins this same (single-flight) warm.
    let latch = AsyncLatch()
    fake.onWarmAwait = { await latch.wait() }
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let blocked = await enginePoll { c.status.blockedReason == .loading }
    #expect(blocked, "must defer with .loading while the active engine is mid-load")
    #expect(fake.switchCount == 0, "must not switch while the active engine is mid-load")
    // The in-flight load settles → the coordinator's join re-pokes → switch applies,
    // even though nothing external poked it (the gate-4b stranding Codex r1 flagged).
    latch.release()
    let applied = await enginePoll { fake.active == .whisperKit }
    #expect(applied, "the switch must apply once the active engine's load settles")
  }

  @Test("a switch is deferred while a record-start is minting, applies when minting ends")
  func switchDeferredWhileMinting() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    _ = await enginePoll { c.status.active == .parakeet && !c.isSwitching }
    // A record-start commits (state-gate held). The coordinator must NOT switch the
    // active engine out from under the starting recording — the SuperWhisper
    // "Cannot switch in <starting> state" gate.
    c.beginMinting()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let stayed = await enginePoll(.milliseconds(150)) { fake.switchCount > 0 }
    #expect(stayed == false, "must not switch the engine while a record-start is minting")
    #expect(c.status.blockedReason == .pipelineActive)
    // Minting ends → the deferred switch applies (endMinting re-pokes).
    c.endMinting()
    let applied = await enginePoll { fake.active == .whisperKit }
    #expect(applied, "the deferred switch applies once minting ends")
  }

  @Test(
    "isMintingAnySession tracks beginMinting/endMinting for BOTH backends (GitHub cloud review, PR #1732)"
  )
  func isMintingAnySessionTracksBothBackends() async {
    // `isMintingWhisperKitSession` is scoped to WhisperKit; `RecoveryCoordinator`'s
    // isDictationActive check needs a backend-agnostic signal so a record-press
    // still mid-start (beginMinting called, not yet an active kernel session)
    // is never mistaken for "engine free" regardless of which backend it targets.
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    #expect(!c.isMintingAnySession, "not minting before any press")
    c.beginMinting()
    #expect(c.isMintingAnySession, "true while a record-start is minting (Parakeet active)")
    c.endMinting()
    #expect(!c.isMintingAnySession, "false again once minting ends")
  }

  // MARK: - Failure model

  @Test("warm-after-switch failure honors the choice and never reverts")
  func warmAfterSwitchFails() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.warmOutcome[.whisperKit] = .failed(FakeWarmError.failed)
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let failed = await enginePoll {
      if case .failed = c.status.switchPhase { return true }
      return false
    }
    #expect(failed, "a failed warm must surface as switchPhase == .failed")
    #expect(
      fake.active == .whisperKit, "the choice is honored — active is the new engine, not reverted")
    #expect(c.status.selectedReadiness != .ready)
  }

  // MARK: - isSwitching gate

  @Test("isSwitching is held across the whole switch await")
  func isSwitchingHeldAcrossAwait() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let latch = AsyncLatch()
    fake.onSwitchAwait = { await latch.wait() }
    let c = fake.makeStartedCoordinator()
    #expect(c.isSwitching == false)
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let entered = await enginePoll { c.isSwitching }
    #expect(entered, "isSwitching must be true while the switch await is suspended")
    latch.release()
    let cleared = await enginePoll { c.isSwitching == false }
    #expect(cleared, "isSwitching must clear after the switch lands")
  }

  // MARK: - Record-start convergence

  @Test("ensureSelectedReadyForPress awaits the switch+warm, then returns .ready")
  func ensureSelectedReadyForPressAwaitsConvergence() async {
    let fake = FakeEngineDeps(selected: .whisperKit, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    let outcome = await c.ensureSelectedReadyForPress()
    #expect(outcome == .ready)
    #expect(fake.active == .whisperKit, "the selected engine must be active on return")
    #expect(c.status.selectedReadiness == .ready, "and ready")
  }

  @Test("ensureSelectedReadyForPress returns .notInstalled (no hang) when the model is absent")
  func ensureSelectedReadyForPressReturnsOnNotInstalled() async {
    let fake = FakeEngineDeps(selected: .whisperKit, active: .parakeet)
    fake.whisperKitInstalled = false
    let c = fake.makeStartedCoordinator()
    let outcome = await c.ensureSelectedReadyForPress()  // must not deadlock
    // The contract is the OUTCOME (read from live install state); a press on a
    // not-installed engine never attempts a switch. (The cached `blockedReason` is
    // set when the user SELECTS the engine, not on this press's fast-path return.)
    #expect(outcome == .notInstalled)
    #expect(fake.switchCount == 0)
  }

  @Test("ensureSelectedReadyForPress returns .notReady when the selected engine's warm fails")
  func ensureSelectedReadyForPressReturnsNotReadyOnWarmFail() async {
    let fake = FakeEngineDeps(selected: .whisperKit, active: .parakeet)
    fake.warmOutcome[.whisperKit] = .failed(FakeWarmError.failed)
    let c = fake.makeStartedCoordinator()
    let outcome = await c.ensureSelectedReadyForPress()
    #expect(outcome == .notReady, "a failed warm of the selected engine yields .notReady")
    #expect(fake.active == .whisperKit, "the switch still applied (choice honored)")
  }

  @Test(
    "ensureSelectedReadyForPress waits through a transient .loading defer (does not exit early)")
  func ensureSelectedReadyForPressWaitsThroughLoading() async {
    let fake = FakeEngineDeps(
      selected: .whisperKit, active: .parakeet,
      parakeetReadiness: .warming, whisperKitReadiness: .ready)
    let latch = AsyncLatch()
    fake.onWarmAwait = { await latch.wait() }
    let c = fake.makeStartedCoordinator()
    let done = MutableBox(false)
    let pressTask = Task { @MainActor in
      await c.ensureSelectedReadyForPress()
      done.value = true
    }
    // The active engine is mid-load → reconcile defers .loading + joins; the press
    // must NOT exit while .loading is transient (Codex r2 #2).
    let blocked = await enginePoll { c.status.blockedReason == .loading }
    #expect(blocked)
    #expect(done.value == false, "press wait must not exit during a transient .loading defer")
    // The load settles → join re-pokes → switch + warm the selected engine → return.
    latch.release()
    _ = await pressTask.value
    #expect(fake.active == .whisperKit, "the selected engine must be active on return")
    #expect(c.status.selectedReadiness == .ready, "and ready")
  }

  @Test("ensureSelectedReadyForPress refreshes live deps (no stale-status short-circuit)")
  func ensureSelectedReadyForPressRefreshesStaleStatus() async {
    // Start converged on parakeet; `status` seeds + reconciles to parakeet/ready.
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    _ = await enginePoll { c.status.selected == .parakeet && c.status.active == .parakeet }
    // The user changes the engine but the worker hasn't reconciled the poke yet
    // (simulated by mutating the fake WITHOUT poking). An immediate press must NOT
    // short-circuit on the stale converged snapshot — it must drive the live
    // selection to ready (Codex r3).
    fake.selected = .whisperKit
    await c.ensureSelectedReadyForPress()
    #expect(
      fake.active == .whisperKit, "press must honor the live selection, not the stale snapshot")
    #expect(c.status.selectedReadiness == .ready)
  }

  @Test("ensureSelectedReadyForPress does not report ready while a superseded switch is in flight")
  func ensureSelectedReadyForPressWaitsOutSupersededSwitch() async {
    // Converged + ready on parakeet.
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let latch = AsyncLatch()
    fake.onSwitchAwait = { await latch.wait() }
    let c = fake.makeStartedCoordinator()
    _ = await enginePoll { c.status.active == .parakeet && !c.isSwitching }
    // Start a switch to WhisperKit (held mid-flight)...
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let switching = await enginePoll { c.isSwitching }
    #expect(switching)
    // ...then flip back to the still-active+ready parakeet. A press must NOT report
    // .ready while the (now superseded) switch is still in flight (Codex r5).
    fake.selected = .parakeet
    let result = MutableBox<EngineCoordinator.PressReadiness?>(nil)
    let pressTask = Task { @MainActor in result.value = await c.ensureSelectedReadyForPress() }
    _ = await enginePoll(.milliseconds(80)) { false }
    #expect(result.value == nil, "press must keep waiting while a switch is in flight")
    // The switch settles → superseded → re-converge to parakeet → ready.
    latch.release()
    _ = await pressTask.value
    #expect(result.value == .ready)
    #expect(fake.active == .parakeet)
  }

  // MARK: - Trigger completeness (council #4)

  @Test(
    "every poke reason drives a safe divergence to convergence",
    arguments: [
      EngineCoordinator.PokeReason.settingsChanged,
      .driverStateChanged,
      .recoveryComplete,
      .warmCompleted,
      .setupStateChanged,
      .launch,
    ])
  func everyPokeReasonConverges(_ reason: EngineCoordinator.PokeReason) async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let c = fake.makeStartedCoordinator()
    fake.selected = .whisperKit
    c.poke(reason)
    let converged = await enginePoll { fake.active == .whisperKit }
    #expect(converged, "poke(\(reason)) must drive a safe divergence to convergence")
  }

  // MARK: - Telemetry

  #if DEBUG
    @Test("idle apply emits change_applied with from/to + defer_ms/switch_ms")
    func telemetryChangeApplied() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable e in
        MainActor.assumeIsolated { waiter.record(e) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
      let c = fake.makeStartedCoordinator()
      fake.selected = .whisperKit
      c.poke(.settingsChanged)

      // Wait on the telemetry EVENT, not the engine STATE: `fake.active` is set
      // inside the fake switch, but `settings.change_applied` is emitted only
      // after `performSwitch` returns — polling state then reading the box was
      // the signal mismatch (#1283).
      let applied = try await waiter.waitForEvent(named: "settings.change_applied")
      #expect(applied.stringProps["to"] == "whisperKit")
      #expect(applied.stringProps["from"] == "parakeet")
      #expect(applied.boolProps["deferred"] == false)
      #expect(applied.intProps["switch_ms"] != nil)
      #expect(applied.intProps["defer_ms"] != nil)
    }

    @Test("deferred apply emits change_blocked(pipeline_active) then change_applied(deferred)")
    func telemetryBlockedThenDeferredApplied() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable e in
        MainActor.assumeIsolated { waiter.record(e) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
      fake.parakeetActive = true
      let c = fake.makeStartedCoordinator()
      fake.selected = .whisperKit
      c.poke(.settingsChanged)
      _ = await enginePoll { c.status.blockedReason == .pipelineActive }

      // `settings.change_blocked` is emitted synchronously with the blocked
      // state (Codex-confirmed not a mismatch), so the state poll is a valid
      // proxy; read it from the recorded history.
      let blocked = waiter.events.first { $0.name == "settings.change_blocked" }
      #expect(blocked?.stringProps["reason"] == "pipeline_active")
      #expect(blocked?.stringProps["requested"] == "whisperKit")

      fake.parakeetActive = false
      c.poke(.driverStateChanged)
      // Deferred apply: wait on the EVENT, not `fake.active` — the deferred
      // `settings.change_applied` is emitted after performSwitch returns (#1283).
      let applied = try await waiter.waitForEvent(
        matching: {
          $0.name == "settings.change_applied" && $0.stringProps["to"] == "whisperKit"
        }, describedAs: "settings.change_applied(to: whisperKit)")
      #expect(applied.boolProps["deferred"] == true)
    }

    @Test("change_blocked is emitted once per epoch per reason")
    func telemetryBlockedOncePerEpoch() async {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable e in
        MainActor.assumeIsolated { waiter.record(e) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
      fake.parakeetActive = true
      let c = fake.makeStartedCoordinator()
      fake.selected = .whisperKit
      c.poke(.settingsChanged)
      _ = await enginePoll { c.status.blockedReason == .pipelineActive }
      // Repeated pokes while still blocked must NOT re-emit.
      c.poke(.driverStateChanged)
      c.poke(.driverStateChanged)
      _ = await enginePoll(.milliseconds(120)) { false }
      // Negative window: the first blocked event landed synchronously with the
      // blocked state above; the 120ms drain proves no SECOND emit. Count from
      // the recorded history.
      let blockedCount = waiter.events.filter {
        $0.name == "settings.change_blocked" && $0.stringProps["reason"] == "pipeline_active"
      }.count
      #expect(blockedCount == 1, "blocked telemetry must fire once per epoch, got \(blockedCount)")
    }

    @Test("a superseded switch emits engine.switch_superseded")
    func telemetrySuperseded() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable e in
        MainActor.assumeIsolated { waiter.record(e) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
      let latch = AsyncLatch()
      fake.onSwitchAwait = { [weak fake] in
        fake?.selected = .parakeet
        await latch.wait()
      }
      let c = fake.makeStartedCoordinator()
      fake.selected = .whisperKit
      c.poke(.settingsChanged)
      _ = await enginePoll { c.isSwitching }
      latch.release()
      _ = await enginePoll { fake.active == .parakeet && !c.isSwitching }
      // #1599: the prior assertion only checked the event NAME occurred, so a
      // reversed or missing from/to payload would still pass. `want` was
      // whisperKit when the switch was superseded back to parakeet mid-await.
      let event = try #require(waiter.events.first { $0.name == "engine.switch_superseded" })
      #expect(event.stringProps["from"] == "whisperKit")
      #expect(event.stringProps["to"] == "parakeet")
    }

    @Test("a failed warm emits engine.warm(failed) + engine.switch_failed")
    func telemetryWarmFailed() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable e in
        MainActor.assumeIsolated { waiter.record(e) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
      fake.warmOutcome[.whisperKit] = .failed(FakeWarmError.failed)
      let c = fake.makeStartedCoordinator()
      fake.selected = .whisperKit
      c.poke(.settingsChanged)
      // Wait on the EVENTS, not `switchPhase` state: `engine.warm(failed)` and
      // `engine.switch_failed` are emitted after the warm attempt returns, while
      // switchPhase flips inside it — the signal mismatch (#1283). History makes
      // the two waits order-independent.
      let failed = try await waiter.waitForEvent(named: "engine.switch_failed")
      #expect(
        failed.stringProps == [
          "engine": "whisperKit",
          "reason": "warm_failed",
        ])

      let warm = try await waiter.waitForEvent(
        matching: { $0.name == "engine.warm" && $0.stringProps["outcome"] == "failed" },
        describedAs: "engine.warm(outcome: failed)")
      #expect(
        warm.stringProps == [
          "engine": "whisperKit",
          "outcome": "failed",
        ])
      #expect(warm.intProps["duration_ms"] != nil)
    }
  #endif
}

/// A one-shot MainActor latch so a test can hold a switch/warm `await` open and
/// assert mid-flight state, then release it.
@MainActor
final class AsyncLatch {
  private var cont: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { cont = $0 }
  }
  func release() {
    released = true
    cont?.resume()
    cont = nil
  }
}

/// MainActor-isolated mutable cell so a test can observe whether an awaited task
/// has completed without a data race.
@MainActor
final class MutableBox<T> {
  var value: T
  init(_ value: T) { self.value = value }
}
