import EnviousWisprAudio
import Foundation

@testable import EnviousWisprPipeline

// MARK: - ScenarioRunner + assertion library (epic #827, PR-2 plan §3.4)
//
// The runner executes a `Scenario`'s ordered steps against a
// `RecordingSessionDriving` SUT, driving the fakes, then checks the full
// `ExpectedOutcome`. Deterministic: one run per scenario is the pass
// (epic §3a). In PR-2 the SUT is `StubRecordingSession` and only the harness
// mechanics are exercised; from PR-3 the SUT is the real kernel and the
// 37-scenario inventory becomes merge-blocking.

/// The fakes + SUT bundle one scenario runs against.
@MainActor
struct SimulatorContext {
  let sut: RecordingSessionDriving
  let engine: FakeEngine
  let capture: FakeAudioCapture
  let vad: FakeVADSignalSource
  let clock: FakeClock
  let paste: FakePasteTarget
}

/// The result of running one scenario — the failure list IS the verdict.
struct ScenarioResult: Sendable {
  let scenarioID: String
  let failures: [String]

  var passed: Bool { failures.isEmpty }
}

@MainActor
struct ScenarioRunner {

  init() {}

  /// Execute `scenario` against `context` and check its `ExpectedOutcome`.
  func run(_ scenario: Scenario, context: SimulatorContext) async -> ScenarioResult {
    var failures: [String] = []

    for (index, step) in scenario.steps.enumerated() {
      await apply(step, context: context, stepIndex: index, into: &failures)
      // Apply the SUT's ready-work settling heuristic before the next step
      // (PR-3 plan §3.3). NOT proof every ready task has run — see the #1868 note
      // below and `KernelRecordingSession.drainReadyWork`. No-op for the stub.
      await context.sut.drainReadyWork()
    }

    // Teardown drain, THEN check (PR-3 plan §3.7 — drain/check contract).
    // `drainPending()` releases every still-pending `FakeClock.sleep`: for the
    // base inventory a correctly-sized scenario has none, so this is pure
    // leak cleanup; for the `zeroTick` interleaving class (which zeroes every
    // `advanceClock`) it is the modelled completion mechanism — a clock-gated
    // operation completes with zero logical time elapsed (Scenario.swift
    // zeroTick contract). Checking before this drain was tried and rejected
    // in PR-3: it strands every `zeroTick`-swept clock-gated scenario in a
    // non-terminal state. `vad.finish()` closes the signal stream so the
    // kernel's VAD-subscription task exits; when a terminal is expected, the
    // conclusion-aware branch below waits for publication, or records a give-up
    // and returns once its cap is exhausted. It waits; it does not make the
    // forward path reach a terminal.
    context.clock.drainPending()
    context.vad.finish()
    // #1868: `drainReadyWork` is a QUIESCENCE heuristic, not a completion
    // signal. Its own Scope note predicted recurrence at continuations other
    // than the recording-exit hand-off, and CI hit exactly that: A14 ("adapter
    // fails after audio captured, retry also exhausted") settled while the
    // finalize-then-retry continuation was still a ready task, so the check
    // below read a stale `transcribing` and reported a stuck session on a
    // healthy kernel. A14 has no `advanceClock` and no VAD step, so the
    // trigger is any continuation losing the scheduler lottery for the whole
    // 64-yield window, not only a clock-resumed one.
    //
    // Where the scenario asserts a TERMINAL state, wait for the kernel's own
    // conclusion signal instead — the thing being asserted is the thing to
    // wait on. Do NOT widen the stability window (swift-testing-patterns.md
    // `yield-settle-needs-inflight-signal-not-count`).
    //
    // Gated on `isTerminal` because A16 ("stop without active session")
    // expects `.idle`: no session is ever minted, so no conclusion is ever
    // published and a wait would burn the livelock cap and record a failure.
    // `drainUntilConcluded` ends in `drainReadyWork`, so this is a superset.
    if scenario.expected.terminalState.isTerminal {
      await context.sut.drainUntilConcluded()
    } else {
      await context.sut.drainReadyWork()
    }

    failures.append(contentsOf: checkOutcome(scenario.expected, context: context))
    return ScenarioResult(scenarioID: scenario.id, failures: failures)
  }

  // MARK: Step execution

  private func apply(
    _ step: ScenarioStep,
    context: SimulatorContext,
    stepIndex: Int,
    into failures: inout [String]
  ) async {
    switch step {
    case .trigger(let trigger):
      await context.sut.apply(trigger)

    case .advanceClock(let ticks):
      context.clock.advance(by: ticks)

    case .engine(let directive):
      switch directive {
      case .setBehavior(let behavior):
        context.engine.behavior = behavior
      case .emitLoadTick:
        context.engine.emitLoadTick()
      case .emitFinalizeTick:
        context.engine.emitFinalizeTick()
      case .setLoadProgressAbsent(let absent):
        context.engine.loadProgressAbsent = absent
      case .setFinalizeProgressAbsent(let absent):
        context.engine.finalizeProgressAbsent = absent
      case .requestMidSessionSwitch:
        // A18 — a factory-preference change request (PR-6 owns the factory).
        // Inert against the running adapter; the active session is unaffected.
        context.engine.noteMidSessionSwitchRequest()
      case .setRetryDecodeResult(let outcome):
        context.engine.retryDecodeResult = outcome
      }

    case .capture(let directive):
      apply(captureDirective: directive, context: context)

    case .vad(let directive):
      switch directive {
      case .autoStop:
        context.vad.emit(.autoStopTriggered)
      case .maxDuration:
        context.vad.emit(.maxDurationReached)
      case .evidence(let evidence):
        context.vad.evidence = evidence
      case .staleAutoStop:
        // R2 — a stop signal stamped with a prior session's `SessionID`.
        context.vad.emitStale(.autoStopTriggered)
      }

    case .paste(let directive):
      switch directive {
      case .fail:
        context.paste.shouldFailPaste = true
      case .succeed:
        context.paste.shouldFailPaste = false
      }

    case .limb(let directive):
      // PR-3 consumes the limb directive: the kernel-wrapper records it and
      // its `processText` / `store` seams read it (PR-3 plan §14a).
      context.sut.inject(directive)

    case .expectState(let expected):
      // #1857: a MID-scenario terminal expectation is the same assertion the
      // teardown check makes, so it needs the same wait. The preceding step's
      // per-step `drainReadyWork()` is an epoch-stability heuristic — a resumed
      // synchronously inside that step is absorbed into the drain's initial
      // `workEpoch`, so under contention this check can read the in-flight state
      // and report a stuck session on a healthy kernel. That is the historical
      // `step N: expected <terminal>, got recording` signature.
      //
      // Gated on `isTerminal` for the same reason the teardown is: `.idle` and
      // the in-flight states publish no conclusion, and waiting for one would
      // burn the livelock cap. `drainUntilConcluded` ends in `drainReadyWork`,
      // so the terminal branch is a superset of what ran before.
      if expected.isTerminal {
        await context.sut.drainUntilConcluded()
      }
      if context.sut.state != expected {
        failures.append(
          "step \(stepIndex): expected state \(expected), got \(context.sut.state)")
      }
    }
  }

  private func apply(captureDirective: CaptureDirective, context: SimulatorContext) {
    // PR-4b.1: the kernel no longer subscribes to `audioCapture.onEngineInterrupted`
    // or `onCaptureStalled`. The simulator routes these
    // signals through the kernel's new internal entry methods (
    // `externalEngineInterrupted` / `externalASRInterrupted` /
    // `externalCaptureStalled`) instead of firing the now-unsubscribed capture
    // callbacks. The `StubRecordingSession` self-test never wired these
    // directives (the stub has no kernel), so the kernel-cast falls through to
    // a no-op there — same shape as before the migration.
    let kernel = (context.sut as? KernelRecordingSession)?.testKernel
    switch captureDirective {
    case .deliverBuffer:
      context.capture.deliverBuffer()
    case .deliverSilentBuffer:
      // Below the #964 dead-air floor (peak/rms/window-rms all < threshold) so
      // the kernel's no-speech gate still skips ASR on a genuinely silent tap.
      context.capture.deliverBuffer(amplitude: 0.001)
    case .stall:
      // A stall fires the liveness-watchdog signal — not merely an absence
      // of buffers (C3 / C4). Routed through the kernel's external entry to
      // match the production path PR-4b.4 wires (App router → driver → kernel).
      kernel?.externalCaptureStalled(context.capture.makeStallContext())
    case .interrupt, .routeChange:
      // The audio-interruption channel (C5). A verified device removal (the
      // Bluetooth headset walked away) → captured, and (#1408) salvaged: the
      // capture manager is still alive and still holding the samples.
      kernel?.externalEngineInterrupted(.deviceRemoved)
    case .permissionDenied:
      context.capture.permissionDenied = true
    case .startFailure:
      context.capture.failCaptureStart = true
    case .xpcCrash:
      // The ASR-interruption channel — distinct from the audio-interruption
      // path (C6, not C5).
      kernel?.externalASRInterrupted()
    }
  }

  // MARK: Assertion library — checks the full ExpectedOutcome

  private func checkOutcome(
    _ expected: ExpectedOutcome, context: SimulatorContext
  ) -> [String] {
    var failures: [String] = []
    let state = context.sut.state
    let effects = context.sut.effects

    // Final state. For almost every scenario `expected.terminalState` is one
    // of the seven terminal states; the lone exception is the no-session
    // scenario (A16 — "stop without active session"), whose expected final
    // state is `.idle` because no session was ever minted. The stuck-session
    // check therefore fires only when a terminal state was expected.
    if state != expected.terminalState {
      failures.append(
        "final state: expected \(expected.terminalState), got \(state)")
    }
    if expected.terminalState.isTerminal && !state.isTerminal {
      failures.append("no terminal state reached — session is stuck at \(state)")
    }

    // Paste count — >1 is always a retry-storm failure.
    if effects.pasteCount != expected.pasteCount {
      failures.append(
        "paste count: expected \(expected.pasteCount), got \(effects.pasteCount)")
    }
    if effects.pasteCount > 1 {
      failures.append("duplicate paste — count \(effects.pasteCount) exceeds 1")
    }

    // Paste outcome.
    if effects.pasteOutcome != expected.pasteOutcome {
      failures.append(
        "paste outcome: expected \(expected.pasteOutcome), got \(effects.pasteOutcome)")
    }

    // Transcript expectation.
    failures.append(
      contentsOf: checkTranscript(expected.transcript, delivered: effects.transcript))

    // Resource release — always true at any terminal state.
    if effects.resourcesReleased != expected.resourcesReleased {
      failures.append(
        "resources released: expected \(expected.resourcesReleased), "
          + "got \(effects.resourcesReleased)")
    }

    // User-visible error category.
    if effects.userVisibleError != expected.userVisibleError {
      failures.append(
        "user-visible error: expected \(String(describing: expected.userVisibleError)), "
          + "got \(String(describing: effects.userVisibleError))")
    }

    return failures
  }

  private func checkTranscript(
    _ expectation: TranscriptExpectation, delivered: String?
  ) -> [String] {
    switch expectation {
    case .none:
      return delivered == nil
        ? []
        : ["transcript: expected none delivered, got \(delivered ?? "")"]
    case .nonEmpty:
      if let delivered, !delivered.isEmpty { return [] }
      return ["transcript: expected non-empty, got \(String(describing: delivered))"]
    case .exact(let text):
      return delivered == text
        ? []
        : ["transcript: expected \"\(text)\", got \(String(describing: delivered))"]
    }
  }
}
