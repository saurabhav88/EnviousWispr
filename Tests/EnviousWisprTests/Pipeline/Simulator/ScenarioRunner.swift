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
// 38-scenario inventory becomes merge-blocking.

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
      // Drain the SUT's ready async work to quiescence so the next step
      // observes a settled FSM (PR-3 plan §3.3). No-op for the stub.
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
    // kernel's VAD-subscription task exits; the final `drainReadyWork()` lets
    // the released forward-path work run to its terminal state.
    context.clock.drainPending()
    context.vad.finish()
    await context.sut.drainReadyWork()

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
      if context.sut.state != expected {
        failures.append(
          "step \(stepIndex): expected state \(expected), got \(context.sut.state)")
      }
    }
  }

  private func apply(captureDirective: CaptureDirective, context: SimulatorContext) {
    // PR-4b.1: the kernel no longer subscribes to `audioCapture.onEngineInterrupted`,
    // `onCaptureStalled`, or `onXPCServiceError`. The simulator routes these
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
    case .interruptUnrecoverable:
      // #1408 (C7): the audio XPC helper that OWNED `capturedSamples` is gone.
      // Salvage must refuse — there is nothing left in memory to transcribe.
      kernel?.externalEngineInterrupted(.xpcConnectionLost)
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
