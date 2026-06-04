import Foundation

@testable import EnviousWisprPipeline

// MARK: - Scenario DSL (epic #827, PR-2 plan §3.4, §3.8)
//
// A scenario is declarative data: an ordered step list plus a full
// `ExpectedOutcome`. The `ScenarioRunner` (this target) executes the steps
// against a `RecordingSessionDriving` SUT. In PR-2 the SUT is `StubRecordingSession`
// (harness self-test); from PR-3 it is the real kernel behind a test-side
// wrapper, and the 33-scenario inventory becomes merge-blocking.

/// A session-lifecycle trigger — the kernel's public entry points
/// (PR-1 §B.1.2 transition table).
enum SessionTrigger: Equatable, Sendable {
  case start
  case stop
  case cancel
  case reset
  case preWarm
}

/// A directive to the `FakeEngine` mid-scenario.
enum EngineDirective: Sendable {
  /// Reconfigure the fake engine's behavior before the next session step.
  case setBehavior(FakeEngineBehavior)
  /// Emit one load-progress tick (when the engine exposes a load stream).
  case emitLoadTick
  /// Emit one finalize-progress tick (when the engine exposes a finalize stream).
  case emitFinalizeTick
  /// Model the engine exposing NO load-progress stream — `loadProgress` becomes
  /// `nil` (the documented signal-free warm-up path, PR-1 §B.2.2; A19).
  case setLoadProgressAbsent(Bool)
  /// Model the engine exposing no finalize-progress stream.
  case setFinalizeProgressAbsent(Bool)
  /// Request an engine switch mid-session (A18). Models a factory-preference
  /// change (the factory is PR-6) — it does NOT mutate the running adapter.
  /// The kernel binds its adapter at `preparing` and holds it for the
  /// session's lifetime, so the active session keeps its original engine
  /// (PR-3 plan §3.6).
  case requestMidSessionSwitch
}

/// A directive to the `FakePasteTarget` mid-scenario.
enum PasteDirective: Sendable {
  /// Force the next paste to fail and fall back to clipboard-only (L4).
  case fail
  /// Restore normal paste success.
  case succeed
}

/// A limb / finalizer failure to inject (L1–L3, L6). The limb pipeline
/// (`TextProcessingRunner`, `TranscriptFinalizer`) and transcript storage are
/// production code the kernel calls; PR-2 has no fake for them. PR-3 wires the
/// kernel's finalizer seam and keys failure injection on THIS directive — not
/// on the scenario ID. Shipping the directive now keeps the scenario data
/// complete and stops PR-3 from special-casing IDs.
enum LimbDirective: Sendable {
  /// LLM polish fails — finalized text falls back to the pre-polish text.
  case polishFails
  /// Custom-words injection fails — ASR runs with default options.
  case customWordsFails
  /// Filler-removal fails — the pre-filler-removal text is delivered.
  case fillerRemovalFails
  /// The transcript disk-save throws (epic §3.8 caveat b — regression lock on
  /// current `"Failed to save transcript"` behavior, deferred #830).
  case storageWriteFails
}

/// A directive to the `FakeAudioCapture` mid-scenario.
enum CaptureDirective: Sendable {
  /// Deliver one synthetic audio buffer (amplitude 0.1 — above the #964
  /// dead-air floor).
  case deliverBuffer
  /// Deliver one synthetic buffer below the #964 dead-air floor — a genuinely
  /// silent capture (amplitude 0.001).
  case deliverSilentBuffer
  /// Stall the capture stream (no buffers).
  case stall
  /// Raise an engine interruption (mic disconnect / route change).
  case interrupt
  /// Change the audio route mid-session.
  case routeChange
  /// Deny / revoke microphone permission.
  case permissionDenied
  /// Fail capture start.
  case startFailure
  /// Crash the XPC capture service.
  case xpcCrash
}

/// A directive to the `FakeVADSignalSource` mid-scenario.
enum VADDirective: Sendable {
  case autoStop
  case maxDuration
  case evidence(VADSpeechEvidence)
  /// Emit an auto-stop signal stamped with a PRIOR session's `SessionID` —
  /// the stale-callback injection for R2 (PR-3 plan §3.6). The kernel must
  /// drop it (FSM invariant 7) and leave the current session running.
  case staleAutoStop
}

/// One step in a scenario's ordered script.
enum ScenarioStep: Sendable {
  case trigger(SessionTrigger)
  case advanceClock(ticks: Int)
  case engine(EngineDirective)
  case capture(CaptureDirective)
  case vad(VADDirective)
  case paste(PasteDirective)
  /// Inject a limb / finalizer / storage failure. PR-2 carries this as data;
  /// PR-3's kernel-finalizer wiring is the consumer.
  case limb(LimbDirective)
  /// Assert the SUT's observable state matches, mid-scenario.
  case expectState(FSMState)
}

/// Whether the transcript reached the user by a real paste or the clipboard
/// fallback (PR-2 plan §3.8 — load-bearing for `L4`).
enum PasteOutcome: Equatable, Sendable {
  case pasted
  case clipboardOnly
  case none
}

/// What text a scenario expects delivered (PR-2 plan §3.8). Carries the
/// payload, not just a delivered/not bool — `FakeEngine`'s output string is
/// known, so a scenario may assert `.exact`.
enum TranscriptExpectation: Equatable, Sendable {
  case none
  case nonEmpty
  case exact(String)
}

/// The complete expected result of a scenario (PR-2 plan §3.8). Every scenario
/// carries one so PR-3 does not infer assertions while wiring the kernel.
struct ExpectedOutcome: Sendable {
  /// Exactly one terminal state, from `FSMState` (PR-1 §B.1.1).
  let terminalState: FSMState
  /// 0 or 1 — anything above 1 is always a failure (no retry storm).
  let pasteCount: Int
  /// `.pasted` | `.clipboardOnly` | `.none`.
  let pasteOutcome: PasteOutcome
  /// What text the scenario expects delivered.
  let transcript: TranscriptExpectation
  /// Task bag drained, capture stopped — always `true` at any terminal state.
  let resourcesReleased: Bool
  /// `nil`, or the user-visible error surface category.
  let userVisibleError: ErrorCategory?

  init(
    terminalState: FSMState,
    pasteCount: Int,
    pasteOutcome: PasteOutcome,
    transcript: TranscriptExpectation,
    resourcesReleased: Bool = true,
    userVisibleError: ErrorCategory? = nil
  ) {
    self.terminalState = terminalState
    self.pasteCount = pasteCount
    self.pasteOutcome = pasteOutcome
    self.transcript = transcript
    self.resourcesReleased = resourcesReleased
    self.userVisibleError = userVisibleError
  }
}

/// A scenario tag — drives which scenarios the interleaving sweep reruns.
enum ScenarioTag: Sendable {
  /// Concurrency-sensitive — rerun under the 64-schedule interleaving sweep
  /// (PR-2 plan §3.5).
  case concurrencySensitive
}

/// One named, ID'd heart-path scenario (PR-2 plan §3.8).
struct Scenario: Sendable {
  /// Canonical ID — e.g. `A1`, `R1`, `C3`, `L4`. `ScenarioInventoryTests`
  /// asserts the exact ID set, not a count.
  let id: String
  /// One-line plain description.
  let name: String
  /// The ordered step script.
  let steps: [ScenarioStep]
  /// The full expected result.
  let expected: ExpectedOutcome
  /// Tags — e.g. `.concurrencySensitive`.
  let tags: [ScenarioTag]

  init(
    id: String,
    name: String,
    steps: [ScenarioStep],
    expected: ExpectedOutcome,
    tags: [ScenarioTag] = []
  ) {
    self.id = id
    self.name = name
    self.steps = steps
    self.expected = expected
    self.tags = tags
  }

  /// `true` if the scenario is rerun under the interleaving sweep.
  var isConcurrencySensitive: Bool {
    tags.contains { if case .concurrencySensitive = $0 { return true } else { return false } }
  }
}

extension Scenario {
  /// Return a copy of this scenario with one interleaving schedule applied to
  /// its step script (PR-2 plan §3.5; Codex code-diff — the sweep must
  /// genuinely vary execution, not run 64 identical copies).
  ///
  /// ONLY `clockGranularity` is applied here: it rewrites every `advanceClock`
  /// cadence, which varies execution timing WITHOUT changing the scenario's
  /// meaning. The trigger order is the scenario's identity and is never
  /// rewritten — repositioning a `cancel` across a `stop` boundary would turn
  /// "cancel during finalizing" into "cancel while recording" while still
  /// expecting the original outcome (Codex round-2 finding). The other three
  /// DOF — `cancellationTiming`, `suspensionOrder`, `lateAsyncBeforeTerminal` —
  /// are task-scheduling DOF with meaning only against the real kernel's
  /// suspension points; PR-3 consumes them from the `InterleavingSchedule`
  /// directly when it interleaves kernel tasks. PR-2's sweep therefore varies
  /// clock cadence (and carries the full schedule for PR-3); PR-3 widens it.
  func applying(_ schedule: InterleavingSchedule) -> Scenario {
    let rewritten: [ScenarioStep] = steps.map { step in
      guard case .advanceClock(let ticks) = step else { return step }
      let newTicks: Int
      switch schedule.clockGranularity {
      case .zeroTick:
        // No logical time advances — the genuine zero-tick race class. A
        // scenario whose warm-up/finalize is clock-gated then completes only
        // via the runner's end-of-scenario `FakeClock.drainPending()`, which
        // models the operation completing with no logical time elapsed.
        newTicks = 0
      case .singleTick:
        newTicks = 1
      case .multiTick:
        newTicks = max(ticks, ticks * 2)
      case .finalizeWithoutProgress:
        newTicks = ticks
      }
      return .advanceClock(ticks: newTicks)
    }

    return Scenario(
      id: "\(id)#seed-\(String(schedule.seed, radix: 16))",
      name: name,
      steps: rewritten,
      expected: expected,
      tags: tags)
  }
}
