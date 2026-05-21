import Foundation

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
