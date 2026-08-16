import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
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

  /// Wait for the SUT's own conclusion signal, then drain (#1868).
  ///
  /// A protocol REQUIREMENT rather than an extension-only method so a
  /// protocol-typed caller dispatches to the kernel wrapper's real
  /// implementation. As a plain extension member this would statically
  /// dispatch to the default below and silently do nothing extra, which is
  /// the failure this exists to remove.
  func drainUntilConcluded() async

  /// Inject a limb / finalizer / storage failure (PR-3 plan §14a). The
  /// kernel-wrapper records it; its `processText` / `store` seams read it.
  /// No-op for the stub (PR-2's `.limb` step was data-only).
  func inject(_ limb: LimbDirective)
}

extension RecordingSessionDriving {
  /// Default — a synchronous SUT (`StubRecordingSession`) has no async work.
  func drainReadyWork() async {}
  /// Default — a synchronous SUT concludes inline, so there is no separate
  /// conclusion signal to wait on and quiescence IS conclusion.
  func drainUntilConcluded() async { await drainReadyWork() }
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
  /// #1707: forces `processText` to collapse a non-empty decode to empty —
  /// the deterministic stand-in for a real filler-only/polish-collapsed
  /// result, so a test can drive `runFinalizing`'s
  /// `finishTerminal(.noSpeech(.emptyAfterProcessing))` path from `.finalizing`
  /// without depending on this harness's identity `processText` running real
  /// text-processing logic (it does not — PR-3's fake polish is identity).
  var forceEmptyAfterProcessing = false
  /// #1755 chunk 2: forces the harness `processText` to THROW (the
  /// `KernelLimbError.emptyAfterProcessing` seam) — the deterministic stand-in
  /// for a text-processing step failing outright while valid raw ASR exists,
  /// driving `runFinalizing`'s catch.
  var processTextThrows = false
}

/// #1755 chunk 2: records every text the kernel's `store` seam receives, in
/// order. Reference type for the same pre-`self` capture constraint as
/// `StopTimeZeroSignalTelemetryLog` — observation only, no policy.
final class StoreLog {
  var storedTexts: [String] = []
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

  private let storeLog = StoreLog()
  /// #1755 chunk 2: every text the kernel handed the `store` seam, in order.
  var storedTexts: [String] { storeLog.storedTexts }

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
    // #1844: OPTIONAL so a test can pass nil and reach the kernel's PRODUCTION
    // default closure, which is the only way to prove that closure reads the frozen
    // bind. #1578 widened it from a Boolean to the decision snapshot; the default
    // is the eligible/not-yet-classified pair, which is exactly what `{ true }`
    // meant before, so every existing scenario is unchanged and none of them
    // starts depending on this machine's real microphone.
    zeroSignalDecisionSnapshot: (@MainActor () -> ZeroSignalDecisionSnapshot)? = {
      ZeroSignalDecisionSnapshot(eligibility: .eligible, currentRunWasClassifiedReactively: false)
    },
    /// #1578: collects refusals the kernel drains or classifies at STOP.
    zeroSignalRefusalSink: @escaping @MainActor ([ZeroSignalRefusalContext]) -> Void = { _ in }
  ) {
    self.vad = vad
    let limb = self.limb
    let telemetryState = self.telemetryState
    let stopTimeTelemetryLog = self.stopTimeTelemetryLog
    let storeLog = self.storeLog
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
        if limb.processTextThrows { throw KernelLimbError.emptyAfterProcessing }
        if limb.forceEmptyAfterProcessing { return "" }
        return raw
      },
      store: { [storeLog] text, _ in
        storeLog.storedTexts.append(text)
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
        // #2087: unreachable — `FakePasteTarget` returns only `.pasted` or
        // `.clipboardOnly`. Deliberately NOT folded in with `.clipboardOnly`
        // above: suppression means nothing was written anywhere, and quietly
        // reporting a clipboard write is the exact lie `.suppressed` exists to
        // prevent. Fail loudly and propagate the truth, so a future fixture that
        // produces this is caught rather than believed.
        case .suppressed:
          Issue.record("FakePasteTarget returned .suppressed; a paste attempt cannot suppress")
          return .suppressed
        }
      },
      // PR-4.5 #4 (Codex r3): the simulator's 37-scenario inventory does not
      // advance the FakeClock between start and stop, so a positive
      // minimum-recording threshold would discard most scenarios. The
      // dedicated #4 coverage lives in `ConductorParitySeamTests`.
      engineMutationScope: .alwaysAllowedForTesting,
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
      zeroSignalDecisionSnapshot: zeroSignalDecisionSnapshot,
      zeroSignalRefusalSink: zeroSignalRefusalSink,
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
    // #2087: mapped to its own case, never folded into `.none`. Suppressed
    // means the user still HAS their text (held for recovery); `.none` means
    // no delivery outcome exists at all.
    case .suppressed: result.pasteOutcome = .suppressed
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

  /// #1707: direct test-only knob (not a `LimbDirective` — this is not a
  /// realistic limb failure, it's a deterministic stand-in for "polish
  /// collapsed a real decode to nothing," used to drive the
  /// `runFinalizing`-from-`.finalizing` empty path).
  func testForceEmptyAfterProcessing() {
    limb.forceEmptyAfterProcessing = true
  }

  /// #1755 chunk 2: direct test-only knob — makes the harness `processText`
  /// throw, standing in for a real text-processing failure over valid raw ASR.
  func testProcessTextThrows() {
    limb.processTextThrows = true
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
    while iterations < Self.livelockYieldCap {
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
    // #1857: exhausting the livelock net is NOT quiescence. Returning silently
    // made a give-up indistinguishable from a settle, so the caller's terminal
    // assertions then failed as bare `nil`s with no hint that the drain never
    // finished. Report it here, where the state that explains it is still live.
    Issue.record(Self.giveUpMessage(kernel: kernel, what: "drainReadyWork", reached: "quiescence"))
  }

  /// Yield until the kernel PUBLISHES a terminal, then drain the remaining ready
  /// work. #1857: `drainReadyWork` is a quiescence heuristic, not a terminal
  /// wait. A continuation resumed synchronously inside the triggering step is
  /// absorbed into the drain's initial `workEpoch` (the same bump-absorption
  /// shape `hasUnconsumedRecordingExit` gates for the recording-exit hand-off),
  /// so under full-suite MainActor contention the drain can return while the
  /// session is still in flight — and every terminal assertion then reads `nil`.
  /// That is the `retryRescuedCompletionSurvivesClipboardFallback` flake, and it
  /// is exactly the "other continuations resumed inside a step's `apply`" case
  /// `drainReadyWork`'s own Scope note predicted. Waiting on the kernel's own
  /// conclusion signal removes the class for every terminal-asserting caller
  /// rather than widening the stability window (see swift-testing-patterns.md
  /// `yield-settle-needs-inflight-signal-not-count`: do not increase N).
  ///
  /// PRECONDITION: conclusion must be reachable by cooperative scheduling alone.
  /// A scenario whose terminal depends on a REAL wall-clock deadline elapsing
  /// (e.g. a live `retryDecodeTimeoutSeconds`) can never satisfy a yield-only
  /// wait — those callers keep a declared deadline-fallback poll instead.
  func drainUntilConcluded() async {
    var iterations = 0
    while kernel.recordingOutcome == nil, iterations < Self.livelockYieldCap {
      await Task.yield()
      iterations += 1
    }
    guard kernel.recordingOutcome != nil else {
      Issue.record(
        Self.giveUpMessage(kernel: kernel, what: "drainUntilConcluded", reached: "a terminal"))
      return
    }
    await drainReadyWork()
  }

  /// Safety net against a kernel livelock, not a deadline — see `drainReadyWork`.
  private static let livelockYieldCap = 20000

  private static func giveUpMessage(
    kernel: RecordingSessionKernel, what: String, reached: String
  ) -> Comment {
    """
    \(what) gave up after \(livelockYieldCap) yields without reaching \(reached). \
    This is the livelock net firing, not a settle — treat every assertion that \
    follows as unreliable. Observed: state=\(String(describing: kernel.state)), \
    recordingOutcome=\(String(describing: kernel.recordingOutcome)), \
    hasUnconsumedRecordingExit=\(kernel.hasUnconsumedRecordingExit), \
    workEpoch=\(kernel.workEpoch).
    """
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
      case .asrEmptyDespiteAudio: return .asrEmptyDespiteAudio
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
    // #1558: the simulator's FSM taxonomy does not distinguish a no-device
    // start failure from a generic capture-start failure — both drive the FSM
    // identically here. The user-facing distinction is proven in
    // TerminalNoticeReasonMappingTests / KernelLifecycleTelemetrySinkTests.
    case .noMicrophoneFound: return .captureStartFailed
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
