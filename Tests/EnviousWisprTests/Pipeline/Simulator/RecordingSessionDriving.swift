import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

@testable import EnviousWisprPipeline

// MARK: - SUT seam (epic #827, PR-2 plan §3.0, §3b)
//
// `RecordingSessionDriving` is the test-side seam the `ScenarioRunner` drives.
// It is a pure driver/observer surface derived from the PR-1 §B.1.2 transition
// table — trigger inputs in, observable state + effects out. It lives in the
// test target (production code must never depend on a test target).
//
// In PR-2 the only conformer is `StubRecordingSession` (harness self-test).
// In PR-3 a test-side wrapper conforms the real `RecordingSessionKernel` to
// this seam; the wrapper MUST be trivial forwarding/observation — it may NOT
// implement session policy (session filtering, terminal-state dedup,
// cancellation ordering, stale-callback dropping, cleanup). Those are kernel
// behaviors asserted AGAINST the kernel. Codex code-diff review on PR-3 checks
// the wrapper for "no behavior except forwarding/observation."

/// The observable session effects the assertion library checks (PR-2 plan §3.8).
struct SessionEffects: Sendable {
  /// Real pastes delivered — `>1` is always a retry-storm failure.
  var pasteCount: Int = 0
  /// Whether delivery was a real paste, the clipboard fallback, or none.
  var pasteOutcome: PasteOutcome = .none
  /// The text delivered to the user, or `nil` if none.
  var transcript: String?
  /// `true` once the session task bag is drained and capture is stopped.
  var resourcesReleased: Bool = false
  /// The user-visible error surface, or `nil`.
  var userVisibleError: ErrorCategory?

  init() {}
}

/// The trigger + observation surface the simulator drives (PR-2 plan §3.0).
@MainActor
protocol RecordingSessionDriving: AnyObject {
  /// The current FSM state, mapped onto the harness vocabulary.
  var state: FSMState { get }
  /// The observable session effects.
  var effects: SessionEffects { get }
  /// Apply one lifecycle trigger. PR-3's wrapper dispatches this to the
  /// kernel's real start / stop / cancel / reset / preWarm entry points.
  func apply(_ trigger: SessionTrigger) async

  /// Run every ready async task the SUT spawned to quiescence, so the next
  /// scenario step observes a settled state (PR-3 plan §3.3 — deterministic
  /// step ordering against a real FSM). No-op for the synchronous stub.
  func drainReadyWork() async

  /// Inject a limb / finalizer / storage failure (PR-3 plan §14a). The
  /// kernel-wrapper records it; its `processText` / `store` seams read it.
  /// No-op for the stub (PR-2's `.limb` step was data-only).
  func inject(_ limb: LimbDirective)
}

extension RecordingSessionDriving {
  /// Default — a synchronous SUT (`StubRecordingSession`) has no async work.
  func drainReadyWork() async {}
  /// Default — the stub does not model limb failures.
  func inject(_ limb: LimbDirective) {}
}

// MARK: - StubRecordingSession
//
// The trivial PR-2 conformer, used ONLY to exercise the harness mechanics in
// `ScenarioRunnerTests`. It implements no real FSM: a test supplies a handler
// closure that mutates `state` / `effects` per trigger. This is a self-test
// fixture, not a kernel stand-in.

@MainActor
final class StubRecordingSession: RecordingSessionDriving {
  private(set) var state: FSMState = .idle
  private(set) var effects = SessionEffects()

  /// Every trigger applied, in order — lets the self-test prove dispatch.
  private(set) var triggerLog: [SessionTrigger] = []

  /// Test-supplied scripting. Receives each trigger and the stub itself, and
  /// mutates `mutableState` / `mutableEffects` to model a response.
  private let handler: @MainActor (SessionTrigger, StubRecordingSession) -> Void

  init(handler: @escaping @MainActor (SessionTrigger, StubRecordingSession) -> Void) {
    self.handler = handler
  }

  func apply(_ trigger: SessionTrigger) async {
    triggerLog.append(trigger)
    handler(trigger, self)
  }

  /// Scripting hooks the handler uses to drive the stub's observable surface.
  func setState(_ newState: FSMState) {
    state = newState
  }

  func setEffects(_ newEffects: SessionEffects) {
    effects = newEffects
  }
}

// MARK: - KernelRecordingSession
//
// The PR-3 conformer: a TRIVIAL forwarding/observation wrapper around the real
// `RecordingSessionKernel` (PR-3 plan §3.3). It MAY forward triggers, map the
// kernel's state onto `FSMState`, read the kernel's observable surface into
// `SessionEffects`, and drain the kernel's async work to quiescence. It MUST
// NOT implement session policy — session filtering, terminal-state dedup,
// cancellation ordering, stale-callback dropping, cleanup, or any latch logic
// are kernel behaviors asserted AGAINST the kernel. Codex code-diff review
// checks this file for "no behavior except forwarding/observation."

/// Mutable limb-failure state set by `.limb(...)` scenario steps. A reference
/// box so the kernel's `processText` / `store` closures, captured at kernel
/// construction, read the value set by a later `inject(_:)` call.
@MainActor
final class LimbInjectionBox {
  var degradeToRaw = false
  var storageWriteFails = false
}

/// #1317: reference-type holder so `stopTimeZeroSignalTelemetry`'s closure
/// (constructed before `self` fully exists, same constraint `LimbInjectionBox`
/// works around) can append fired contexts without capturing `self`.
final class StopTimeZeroSignalTelemetryLog {
  var fired: [CaptureStallContext] = []
}

/// Heartpath 5b (#1520): records the kernel's dead-mic telemetry closures so a
/// test can assert what fired without a real emitter. Reference type for the
/// same pre-`self` capture constraint as `StopTimeZeroSignalTelemetryLog`.
final class DeadMicTelemetryLog {
  var retireAttempts: [DeadMicRetireAttemptContext] = []
  var recoveries: [DeadMicRecoveryOutcome] = []
}

@MainActor
final class KernelRecordingSession: RecordingSessionDriving {
  private let kernel: RecordingSessionKernel
  private let vad: FakeVADSignalSource
  private let limb = LimbInjectionBox()

  /// The wrapped kernel — exposed only so the direct FSM-invariant tests can
  /// inspect kernel internals (`RecordingSessionKernelTests`).
  var testKernel: RecordingSessionKernel { kernel }

  /// The kernel's per-session telemetry side-channel, held so a test can read
  /// what the kernel stamped (#1408: `interruptionCause`). Production shares ONE
  /// instance across the kernel, the finalization wiring, and the lifecycle sink;
  /// this wrapper mirrors that by constructing it once and passing it in.
  let telemetryState = KernelTelemetryState()

  private let stopTimeTelemetryLog = StopTimeZeroSignalTelemetryLog()
  /// #1317: `CaptureStallContext`s the kernel's STOP-time classification
  /// submitted via `stopTimeZeroSignalTelemetry`, in fire order. Lets a test
  /// assert exactly one classified event fired (dedup) without a real
  /// `HeartPathTelemetryEmitter`.
  var stopTimeZeroSignalTelemetryFired: [CaptureStallContext] { stopTimeTelemetryLog.fired }

  /// Heartpath 5b (#1520): the shared capture-telemetry state, passed to the
  /// kernel so arm-on-retire works. Production shares the SAME instance with the
  /// lifecycle sink; kernel-only tests exercise the arm + later-retire path.
  let captureTelemetry = CaptureTelemetryState()
  private let deadMicLog = DeadMicTelemetryLog()
  var deadMicRetireAttempts: [DeadMicRetireAttemptContext] { deadMicLog.retireAttempts }
  var deadMicRecoveries: [DeadMicRecoveryOutcome] { deadMicLog.recoveries }

  init(
    engine: FakeEngine,
    capture: FakeAudioCapture,
    vad: FakeVADSignalSource,
    clock: FakeClock,
    paste: FakePasteTarget,
    // #1408: the floor's regression guard needs the minimum-recording gate ARMED
    // (the inventory zeroes it, see the note at the `minimumRecordingTicks`
    // argument below). Defaulted so every existing scenario is unchanged.
    minimumRecordingTicks: Int = 0,
    // #1317: deterministic by default (`true`) — real scenarios exercising
    // the muted/unknown fail-closed path override this explicitly. Avoids
    // every other test in the 37-scenario inventory depending on the test
    // machine's real microphone/mute state via the kernel's production
    // default (real CoreAudio calls).
    zeroSignalDeviceEligible: @escaping @MainActor () -> Bool = { true }
  ) {
    self.vad = vad
    let limb = self.limb
    let telemetryState = self.telemetryState
    let stopTimeTelemetryLog = self.stopTimeTelemetryLog
    let captureTelemetry = self.captureTelemetry
    let deadMicLog = self.deadMicLog
    self.kernel = RecordingSessionKernel(
      adapter: engine,
      audioCapture: capture,
      vad: vad,
      currentTick: { clock.now },
      sleepTicks: { await clock.sleep(ticks: $0) },
      processText: { raw, onPolishStarted in
        // PR-3's fake polish is identity — there is no real LLM. A degraded
        // limb (`polishFails` etc.) still returns the raw text, the heart
        // path's guaranteed floor (PR-1 §B.5). The seam is exercised either
        // way so the kernel's polish-signal observation point is covered.
        onPolishStarted()
        _ = limb.degradeToRaw
        return raw
      },
      store: { _, _ in
        // #1167: a throwing save models the best-effort store seam. The kernel
        // ABSORBS the throw (records it on the finalization outcome) and still
        // proceeds to deliver + `.completed` — it no longer routes a terminal
        // storage failure. The `KernelLimbError.storageFailed` test seam is
        // retained to exercise that the kernel swallows a store throw.
        if limb.storageWriteFails { throw KernelLimbError.storageFailed }
      },
      deliver: { text in
        switch paste.attemptPaste(text) {
        case .pasted: return .pasted
        case .clipboardOnly, .none: return .clipboardOnly
        }
      },
      // PR-4.5 #4 (Codex r3): the simulator's 37-scenario inventory does not
      // advance the FakeClock between start and stop, so a positive
      // minimum-recording threshold would discard most scenarios. The
      // dedicated #4 coverage lives in `ConductorParitySeamTests`.
      minimumRecordingTicks: minimumRecordingTicks,
      captureTelemetry: captureTelemetry,
      deadMicRetireAttemptTelemetry: { [deadMicLog] ctx in
        deadMicLog.retireAttempts.append(ctx)
      },
      deadMicRecoveryTelemetry: { [deadMicLog] outcome in
        deadMicLog.recoveries.append(outcome)
      },
      stopTimeZeroSignalTelemetry: { [stopTimeTelemetryLog] ctx in
        stopTimeTelemetryLog.fired.append(ctx)
      },
      zeroSignalDeviceEligible: zeroSignalDeviceEligible,
      telemetryState: telemetryState)
  }

  // MARK: RecordingSessionDriving — observation

  var state: FSMState { Self.map(kernel) }

  var effects: SessionEffects {
    var result = SessionEffects()
    result.pasteCount = kernel.pasteCount
    switch kernel.deliveryOutcome {
    case .pasted: result.pasteOutcome = .pasted
    case .clipboardOnly: result.pasteOutcome = .clipboardOnly
    case nil: result.pasteOutcome = .none
    }
    result.transcript = kernel.deliveredTranscript
    result.resourcesReleased = kernel.resourcesReleased
    switch kernel.userVisibleError {
    case .recoverableError: result.userVisibleError = .recoverableError
    case .interruption: result.userVisibleError = .interruption
    case nil: result.userVisibleError = nil
    }
    return result
  }

  // MARK: RecordingSessionDriving — driving

  func apply(_ trigger: SessionTrigger) async {
    switch trigger {
    case .start:
      // PR-4 §3.3a: the kernel's `start` now takes a `DictationSessionConfig`.
      // The simulator passes the test default — `FakeAudioCapture.configureVAD`
      // is inert, so no scenario behavior changes.
      //
      // PR-4.5 #2: the kernel now stamps the VAD seam itself via
      // `vad.setCurrentSessionID(sid)` in `runForwardPath` (was a simulator-only
      // manual stamp before; that hid the production gap where the kernel never
      // wired the call).
      kernel.start(config: .testDefault())
    case .stop:
      kernel.requestStop()
    case .cancel:
      kernel.cancel()
    case .reset:
      kernel.reset()
    case .preWarm:
      // PR-4b.4 of #827: `kernel.preWarm()` now throws on
      // `audioCapture.preWarm()` failure (App starter relies on this for
      // the "Microphone unavailable" recovery path). Simulator scenarios
      // never inject a preWarm failure into `FakeAudioCapture`, so the
      // throw cannot fire here; swallow defensively to keep this
      // simulator's `apply(_:)` non-throwing (the contract scenarios
      // built against).
      do {
        try await kernel.preWarm()
      } catch {
        // unreachable in current scenarios; if a future scenario adds
        // preWarm fault injection, surface via the existing failure
        // observation path.
      }
    }
  }

  func inject(_ limbDirective: LimbDirective) {
    switch limbDirective {
    case .polishFails, .customWordsFails, .fillerRemovalFails:
      limb.degradeToRaw = true
    case .storageWriteFails:
      limb.storageWriteFails = true
    }
  }

  /// Yield until the kernel's `workEpoch` stops advancing — the FSM has settled
  /// for everything `workEpoch` covers (the kernel bumps it on every transition,
  /// task resumption, and progress tick). The 64-yield stability requirement is
  /// margin for a ready kernel task that loses the scheduler lottery to
  /// unrelated parallel tests across several yields under MainActor contention —
  /// not a deadline. The 20000-iteration cap is a safety net against a kernel
  /// livelock (it surfaces as a stuck-state assertion failure, not a hang).
  ///
  /// Epoch-stability ALONE is not sufficient for the recording-exit hand-off: a
  /// recording-exit delivered by the previous step (`stop` / `cancel` from
  /// `.recording`) bumps `workEpoch` and resumes the forward-path continuation
  /// synchronously inside that step — *before* this drain starts — so the bump
  /// is absorbed into the initial `last` and offers no protection. Under
  /// full-suite MainActor contention the resumed forward-path task can then lose
  /// the scheduler lottery for the whole 64-yield window, and the drain would
  /// return while the FSM is still observably `.recording`. The next step's
  /// `cancel` is then swallowed by the already-latched stop and the scenario
  /// flakes (the recurring `interleavingSweep` `got recording` failure). So gate
  /// the return on the kernel's own hand-off signal: never declare quiescence
  /// while a delivered recording-exit is still unconsumed. The forward path is a
  /// ready task on a cooperative serial executor, so it cannot be starved
  /// forever — the signal clears within a bounded number of yields, well under
  /// the livelock cap.
  ///
  /// Scope: this gate addresses the recording-exit hand-off, the only window the
  /// observed flakes hit (every recurrence was `got recording`). The same
  /// bump-absorption shape exists in principle at other continuations resumed
  /// inside a step's `apply` — `FakeClock.advance(by:)` resuming a `slowLoad` /
  /// `slowFinalize` sleep, a VAD `AsyncStream.yield` — but none has manifested.
  /// If a future flake reports a stale `transcribing` / `warmingUp` after an
  /// `advanceClock` or VAD step, those are the next signals to gate the same way.
  func drainReadyWork() async {
    var last = kernel.workEpoch
    var stable = 0
    var iterations = 0
    while iterations < 20000 {
      await Task.yield()
      iterations += 1
      let now = kernel.workEpoch
      if now == last {
        stable += 1
      } else {
        stable = 0
        last = now
      }
      if stable >= 64, !kernel.hasUnconsumedRecordingExit { return }
    }
  }

  // MARK: State mapping — pure, mechanical (no policy)

  /// #1548 D1 impedance: the kernel is now a 5-state FSM + a sibling
  /// `recordingOutcome`; `FSMState` keeps its 14-value vocabulary (plan §2.2
  /// non-goal). A concluded session (`recordingOutcome != nil`, state `.idle`)
  /// maps to the matching terminal; an in-flight session maps its state, with
  /// Arming splitting on `didLoadModelThisSession` (preparing vs warmingUp) and
  /// Delivering splitting on `deliveringPhase` (transcribing vs finalizing).
  /// `.noTransport` projects to `.failed(.noAudioCaptured)` (locked projection);
  /// tests that assert `.noTransport` specifically read `kernel.recordingOutcome`.
  private static func map(_ kernel: RecordingSessionKernel) -> FSMState {
    if let outcome = kernel.recordingOutcome {
      switch outcome {
      case .completed: return .completed
      case .failed(let reason): return .failed(map(reason))
      case .cancelled: return .cancelled
      case .discarded: return .discarded
      case .noSpeech: return .noSpeech
      case .audioInterrupted: return .audioInterrupted
      case .asrInterrupted: return .asrInterrupted
      case .noTransport: return .failed(.noAudioCaptured)
      }
    }
    switch kernel.state {
    case .idle: return .idle
    case .arming: return kernel.didLoadModelThisSession ? .warmingUp : .preparing
    case .live: return .recording
    case .stopping: return .stopping
    case .delivering:
      switch kernel.deliveringPhase {
      case .transcribing: return .transcribing
      case .finalizing: return .finalizing
      }
    }
  }

  private static func map(_ reason: RecordingFailureReason) -> FSMFailureReason {
    switch reason {
    case .prepareFailed: return .prepareFailed
    case .permissionDenied: return .permissionDenied
    case .modelWedged: return .modelWedged
    case .modelLoadFailed: return .modelLoadFailed
    case .captureStartFailed: return .captureStartFailed
    case .noAudioCaptured: return .noAudioCaptured
    case .asrEmpty: return .asrEmpty
    case .asrFailed: return .asrFailed
    case .asrWedged: return .asrWedged
    case .emptyAfterProcessing: return .emptyAfterProcessing
    case .captureStalled: return .captureStalled
    case .zeroSignal: return .zeroSignal
    }
  }
}
