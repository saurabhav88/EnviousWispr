@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation

// MARK: - RecordingSessionKernel (epic #827, PR-3; built from PR-1 §B spec)
//
// The single recording-session finite state machine. One kernel owns one
// dictation's full lifecycle — prepare, warm up, record, stop, transcribe,
// finalize — as the 14-state FSM in PR-1 §B.1. It delegates transcription to
// an `ASREngineAdapter` and post-ASR text-processing / storage / delivery to
// injected closure seams (PR-3 plan §14a — closure seams match
// `TranscriptFinalizer`'s own house style; PR-4 wires the production
// `TranscriptFinalizer` into them).
//
// PR-3 ships this production-unwired (epic §14.3): no App-layer caller. It is
// driven only by the deterministic PR-2 simulator through a test-side
// `RecordingSessionDriving` wrapper. PR-4 wires it into the live app.
//
// Transitions are methods, never open `state =` mutation (epic §3.3). A
// forbidden transition is logged and refused — never a silent no-op, never an
// `assertionFailure` (PR-3 plan §3.10).

/// A normalized, recoverable failure reason for the `failed` terminal state
/// (PR-1 §B.1.2 transition table).
public enum RecordingFailureReason: Equatable, Sendable {
  case prepareFailed
  case permissionDenied
  case modelWedged
  case modelLoadFailed
  case captureStartFailed
  case noAudioCaptured
  case asrEmpty
  case asrFailed
  case asrWedged
  case emptyAfterProcessing
  case storageFailed
  case captureStalled
}

/// The 14 recording-session FSM states (PR-1 §B.1.1). Seven are terminal.
public enum RecordingSessionState: Equatable, Sendable {
  case idle
  case preparing
  case warmingUp
  case recording
  case stopping
  case transcribing
  case finalizing
  // Terminal states.
  case completed
  case failed(RecordingFailureReason)
  case cancelled
  case discarded
  case noSpeech
  case audioInterrupted
  case asrInterrupted

  /// `true` for the seven terminal states (PR-1 §B.1.1).
  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      return true
    case .idle, .preparing, .warmingUp, .recording, .stopping, .transcribing,
      .finalizing:
      return false
    }
  }
}

/// The `finalizing` sub-status surfaced for the overlay string (PR-1 §B.4,
/// PR-3 plan §3.5). The kernel owns the observation point; a limb only emits.
public enum FinalizingSubStatus: Equatable, Sendable {
  case transcribing
  case polishing
}

/// How the transcript reached the user (PR-1 §B.1.3). The kernel records this
/// from the `deliver` seam's return value.
public enum KernelDeliveryOutcome: Equatable, Sendable {
  case pasted
  case clipboardOnly
}

/// The user-visible error surface a terminal state renders (PR-1 §B.1.3).
public enum KernelErrorCategory: Equatable, Sendable {
  case recoverableError
  case interruption
}

/// Why a session reached the `discarded` terminal — surfaced for the
/// PR-1 §B.7.4 telemetry event (PR-4 plan §3.8a). A sibling observable to
/// `state`, the same shape as `deliveredTranscript`; the `discarded` FSM case
/// stays plain (no state-enum payload).
public enum DiscardReason: Equatable, Sendable {
  /// Stop latched before the session ever reached `recording` — PTT released
  /// during prepare / warm-up. No transcribable audio.
  case releasedBeforeRecording
  /// Recording reached `recording` but handed off zero buffers — a
  /// sub-minimum-duration accidental tap.
  case tooShort
}

/// Which path led to a `.noSpeech` terminal. Sibling-observable payload for
/// the `KernelLifecycleEvent.noSpeech(NoSpeechSource)` lifecycle event so the
/// observer can route the source-appropriate breadcrumb without losing the
/// old VAD-gate vs ASR-empty no-speech distinction (PR-1 §B.7.2; old
/// the old Parakeet pipeline vs `:902`).
public enum NoSpeechSource: Equatable, Sendable {
  /// VAD gate fired pre-ASR — raw samples had no speech evidence
  /// (`TP:787` — "VAD gate: no speech detected, skipping ASR").
  case vadGate
  /// ASR returned empty text on a path where VAD did NOT firmly say speech
  /// (`TP:902` — "ASR empty (no speech detected)").
  case asrEmptyNoSpeech
}

/// Kernel-side model-load wedge payload. The old pipeline used
/// `LoadProgressWatcherSnapshot`; the kernel has logical progress ticks, so it
/// records the same telemetry keys from that signal stream.
struct KernelModelLoadWedgeTelemetry: Equatable, Sendable {
  let silenceMs: Int
  let observedMaxGapMs: Int
  let observedPhase: String
  let signalCountTotal: Int
  let firstSignalLatencyMs: Int?
  let totalAttemptDurationMs: Int
}

/// A typed limb-seam failure the kernel maps to a `failed` terminal reason
/// (PR-3 plan §14a). The `processText` / `store` seams throw these.
public enum KernelLimbError: Error, Sendable {
  /// Text processing produced empty output (PR-1 §B.1.2 `emptyAfterProcessing`).
  case emptyAfterProcessing
  /// Transcript disk-save threw (epic §3.8 caveat b, deferred #830).
  case storageFailed
}

/// The single recording-session FSM (PR-1 §B.1). `@MainActor @Observable`.
/// Internal — consumed within `EnviousWisprPipeline`; PR-4 wires the App layer
/// through a driver protocol, never by direct mutation.
@MainActor
@Observable
final class RecordingSessionKernel {

  // MARK: Injected dependencies

  private let adapter: any ASREngineAdapter
  private let audioCapture: any AudioCaptureInterface
  private let vad: any VADSignalSource

  /// Logical-time seam (PR-3 plan §14a). Production wiring of a real clock is
  /// PR-4/PR-7; the simulator wires `FakeClock`.
  private let currentTick: @MainActor () -> UInt64
  private let sleepTicks: @MainActor (Int) async -> Void

  /// Limb / storage / delivery seams (PR-3 plan §14a — closure seams, matching
  /// `TranscriptFinalizer`'s house style). `processText` runs the text steps
  /// and signals polish-start via its callback; `store` persists; `deliver`
  /// pastes. PR-4 wires these to a real `TranscriptFinalizer` call site.
  private let processText:
    @MainActor (_ raw: String, _ onPolishStarted: @escaping @MainActor () -> Void)
      async throws -> String
  private let store: @MainActor (_ text: String) async throws -> Void
  private let deliver: @MainActor (_ text: String) async -> KernelDeliveryOutcome

  // MARK: Wedge-detection tuning

  /// Logical-tick window of progress-signal silence (after the stream has
  /// armed with at least one tick) that the kernel treats as a cadence stall.
  /// Mirrors `LoadProgressWatcher`'s arm-then-silence shape (PR-1 §B.1.7) in
  /// the simulator's logical-tick time base — not a wall-clock deadline.
  private let wedgeStallTicks: Int

  /// Minimum logical-tick duration of a visible recording (PR-4.5 #4 — parity
  /// with `TimingConstants.minimumRecordingDuration` = 500 ms). A recording
  /// terminating in less than this many ticks since `→ recording` is silently
  /// discarded as an accidental tap (`discardReason = .tooShort`). Measured
  /// from VISIBLE recording start, NOT from pre-roll capture (PR-4.5 §5b — so
  /// fixing #0 does not silently defeat #4).
  ///
  /// The constructor default is `5` (matches the PR-4 plan's 100 ms-per-tick
  /// scale — `KernelFinalizationWiring.tickDurationSeconds = 0.1`, so 5 ticks
  /// = 500 ms). Existing tests that drive a `FakeClock` and do not advance it
  /// between `start` and `stop` pass `0` explicitly to disable the gate (the
  /// 33-scenario inventory and the direct FSM-invariant tests). Codex r3
  /// flagged a zero default as a silent-regression risk for the eventual
  /// PR-4b production wiring; the non-zero default makes the safety opt-OUT,
  /// not opt-in.
  private let minimumRecordingTicks: Int

  // MARK: Telemetry fan-out

  /// Capture-stall telemetry fan-out (PR-4 plan §3.9). When the capture layer
  /// reports a stall the kernel — besides routing `failed(.captureStalled)`
  /// for control flow — hands the raw `CaptureStallContext` to this seam so a
  /// telemetry observer receives the diagnostic payload the terminal state
  /// cannot carry. A dumb fan-out: the kernel never reads it back, and it
  /// keeps the kernel telemetry-infra-agnostic (the closure is a seam, like
  /// `processText` / `store` / `deliver`). A no-op in the simulator.
  private let captureStallTelemetry: @MainActor (CaptureStallContext) -> Void
  private let zombieZeroPeakTelemetry: @MainActor (ZeroPeakContext) -> Void
  private let recordingStoppedTelemetry: @MainActor (_ sampleCount: Int) -> Void
  private let markPipelineTimingStart: @MainActor () -> Void
  private let markASRTimingStart: @MainActor (_ streaming: Bool) -> Void
  private let markASRTimingEnd: @MainActor () -> Void
  private let telemetryState: KernelTelemetryState

  // MARK: Observable surface

  /// The current FSM state. Callers observe; they never mutate it.
  private(set) var state: RecordingSessionState = .idle

  /// The session identity of the in-flight (or last) session. Minted at every
  /// `idle → preparing` / `terminal → preparing` (PR-1 §B.1.5).
  private(set) var currentSessionID = SessionID()

  /// The `finalizing` sub-status — `polishing` once the polish signal is
  /// observed (PR-1 §B.4).
  private(set) var finalizingSubStatus: FinalizingSubStatus = .transcribing

  /// The text delivered to the user, or `nil` if none.
  private(set) var deliveredTranscript: String?

  /// Why the session was `discarded`, or `nil` if it did not reach `discarded`
  /// (PR-4 plan §3.8a). Set immediately before the `→ discarded` transition so
  /// a state observer reads the correct reason.
  private(set) var discardReason: DiscardReason?

  /// `true` if this session entered the model-load branch (i.e. adapter was
  /// not already `.ready` at the warm-up gate). Set immediately BEFORE the
  /// `→ warmingUp` transition. Read by the kernel-state observer to gate the
  /// `.modelLoading` lifecycle event so a warm session does not emit a
  /// spurious "Model loading" breadcrumb (PR-1 §B.7.2 parity; old
  /// the old Parakeet pipeline was conditional on entering the
  /// load branch at `:363`). Reset on session start.
  private(set) var didLoadModelThisSession: Bool = false

  /// Which path led to `.noSpeech` for this session, or `nil` if the session
  /// did not reach `.noSpeech`. Set immediately BEFORE the `→ noSpeech`
  /// transition at each of the two distinct forward-path sites (VAD gate vs
  /// ASR-empty no-speech). The observer reads this at lifecycle-event mapping
  /// time to choose `.vadGate` or `.asrEmptyNoSpeech`. Reset on session start.
  private(set) var lastNoSpeechSource: NoSpeechSource?

  /// `true` if the kernel started this session in streaming mode. Set
  /// immediately BEFORE `adapter.beginSession(..., streaming:)`. The observer
  /// reads this at `.recording` lifecycle mapping time so the
  /// `recordingCommitted` event carries the same streaming flag the old
  /// the old Parakeet pipeline breadcrumb + `updateRecordingState`
  /// emitted (Codex review #11 r2 — without this thread-through the sink
  /// would misreport every streaming session as batch). Reset on session
  /// start.
  private(set) var isStreamingSession: Bool = false

  /// How delivery happened, or `nil` if nothing was delivered.
  private(set) var deliveryOutcome: KernelDeliveryOutcome?

  /// Real pastes delivered — 0 or 1. `clipboardOnly` delivery counts 0.
  private(set) var pasteCount: Int = 0

  /// `true` while the kernel holds no capture / task resources — `true` at
  /// `idle`, `false` once a session spawns work, `true` again at terminal
  /// cleanup (PR-1 §B.1.3 cleanup column).
  private(set) var resourcesReleased: Bool = true

  /// `true` when the FSM rejected a forbidden transition this session — a
  /// direct test reads it (PR-3 plan §3.10).
  private(set) var forbiddenTransitionRejected = false

  /// Monotonic counter bumped on every transition / work resumption. The
  /// simulator drains kernel work to quiescence by observing this stop
  /// advancing (PR-3 plan §3.3 — deterministic step ordering).
  private(set) var workEpoch: UInt64 = 0

  /// The user-visible error category for the current terminal state, derived
  /// from the FSM state (PR-1 §B.1.3). `nil` for non-error terminals.
  var userVisibleError: KernelErrorCategory? {
    switch state {
    case .audioInterrupted:
      return .interruption
    case .asrInterrupted, .failed:
      return .recoverableError
    default:
      return nil
    }
  }

  // MARK: Session-scoped mutable state

  /// The per-recording config bound at `start(config:)` (PR-4 plan §3.3a). The
  /// forward path reads it for VAD configuration and decode options; a
  /// terminal reads `modelUnloadPolicy`. `nil` before the first session.
  private var sessionConfig: DictationSessionConfig?

  /// `true` once `adapter.beginSession()` succeeded this session. Distinct from
  /// `adapterSessionActive` (which `finalize()` clears) — this stays true for
  /// the whole session so a terminal applies cleanup (adapter discard) once.
  /// **Not** the unload-policy gate — see `transcriptReadyForDelivery` (PR-4.5
  /// #8).
  private var adapterDidBeginSession = false

  /// Running total of stale-VAD-signal drops (PR-4.5 §8 telemetry surface
  /// for #2). A regression that stops stamping the seam shows up here as a
  /// sudden 100% drop rate. Never cleared.
  private(set) var staleVADSignalDrops: Int = 0

  /// Logical-tick value at the `→ recording` transition (PR-4.5 #4). `nil`
  /// outside `.recording`; reset on every session start. Read by the
  /// stop-phase discard gate to compute visible-recording elapsed against
  /// `minimumRecordingTicks`. Visible-only on purpose — PR-4.5 §5b: pre-roll
  /// must not pad accidental taps past the discard threshold.
  private var recordingStartedAtTick: UInt64?

  /// Logical-tick value at the `→ stopping` transition (PR-4.5 #4, Codex r1).
  /// The visible-recording elapsed used by the #4 discard gate is computed
  /// as `(stoppingStartedAtTick - recordingStartedAtTick)`, NOT against
  /// `currentTick()` at the discard check. Otherwise the await on
  /// `audioCapture.stopCapture()` between `.stopping` and the discard check
  /// counts capture-teardown latency as visible-recording time, letting a
  /// 40 ms tap bypass the gate when teardown is slow. Old pipeline
  /// parity: the old Parakeet pipeline reads elapsed BEFORE
  /// `stopCapture()`. `nil` outside `.stopping`+; reset on every session start.
  private var stoppingStartedAtTick: UInt64?
  private var recordingStartedAtDate: Date?

  /// `true` once the polish step returned a non-empty processed transcript —
  /// the kernel-era equivalent of the point at which the old pipeline called
  /// `asrManager.noteTranscriptionComplete(policy:)` (just after polish, before
  /// storage and paste — the old Parakeet pipeline). PR-4.5 #8
  /// gates the unload policy on this so failures BEFORE a transcript was ready
  /// (capture-stall, ASR-wedge, no-speech, cancel, sub-minimum discard, audio /
  /// ASR interrupt mid-recording) do NOT incur a model-unload spike that the
  /// next session would then pay to reload. Stays true through `.completed`
  /// AND through paste/storage failure terminals — both of those have a
  /// transcript in hand, parity with the old pipeline firing unload before
  /// paste.
  private var transcriptReadyForDelivery = false

  /// Rich model-load wedge payload for the lifecycle sink. Set before
  /// `failed(.modelWedged)` so Sentry/PostHog keep the old payload shape.
  private(set) var modelLoadWedgeTelemetry: KernelModelLoadWedgeTelemetry?

  /// User-visible detail for the current `.failed(reason)` state, if any —
  /// the underlying error's `localizedDescription` for the three reasons the
  /// old Parakeet pipeline embedded into its error strings (TP:440-445,
  /// TP:577-588, TP:1045-1051). `nil` when the kernel is not in a
  /// detail-bearing failed state, OR when no underlying error was captured.
  /// Reading scope is intentionally narrow: this is the user-message
  /// enrichment seam, not a general error-introspection API.
  var lastFailureDetail: String? {
    guard case .failed(let reason) = state else { return nil }
    switch reason {
    case .modelLoadFailed:
      return telemetryState.modelLoadError?.localizedDescription
    case .captureStartFailed:
      return telemetryState.captureFailureError?.localizedDescription
    case .asrFailed:
      return telemetryState.transcriptionFailureError?.localizedDescription
    default:
      return nil
    }
  }

  /// The session task bag, keyed by `SessionID` (PR-1 §B.1.6). Reaching a
  /// terminal state cancels and clears it — nonblocking (PR-3 plan §3.1a).
  private var taskBag: [Task<Void, Never>] = []
  private var taskBagSessionID = SessionID()

  /// Stop-latch (PR-1 §B.1.4 invariant 1) — consumed exactly once.
  private var stopLatched = false
  /// Cancel requested before `recording` (during `preparing` / `warmingUp`).
  private var cancelRequested = false

  /// The recording-phase exit channel. The forward path parks on
  /// `awaitRecordingExit()`; one of stop / VAD / interruption resumes it once.
  private var recordingExitContinuation: CheckedContinuation<RecordingExit, Never>?
  private var pendingRecordingExit: RecordingExit?
  private var recordingExitLatched = false

  /// Buffers handed to the adapter this session — the sub-minimum-duration
  /// proxy (PR-1 §B.1.2 `recording → discarded`): zero buffers ⇒ `discarded`.
  private var bufferCountThisSession = 0
  private var bufferSequence: UInt64 = 0

  /// Capture-engine lifecycle. The kernel stops capture exactly once per
  /// session: the normal `stopping` path owns the stop when it runs;
  /// `finishTerminal` owns it for a terminal reached straight from `recording`
  /// (cancel / interruption / stall). `resourcesReleased` flips true only once
  /// the stop has actually completed (Codex P1b, P2-round3).
  private enum CaptureLifecycle { case notStarted, active, stopping, stopped }
  private var captureLifecycle: CaptureLifecycle = .notStarted

  /// `true` between a successful `adapter.beginSession()` and `finalize()`. A
  /// terminal reached in this window without a `finalize()` (zero-buffer
  /// stop, confirmed no-speech, no-audio, interruption) must call
  /// `adapter.cancel()` to discard the adapter's open session (Codex P2-r3).
  private var adapterSessionActive = false

  /// Wedge-detection observed state, per phase. `last*TickAt` is the logical
  /// tick of the most recent progress signal — the wedge watcher measures
  /// silence *since the last tick*, so an adapter that keeps reporting
  /// progress is never misclassified as wedged (Codex review P2).
  private var loadTickCount = 0
  private var finalizeTickCount = 0
  private var loadAttemptStartedAtTick: UInt64 = 0
  private var firstLoadTickAt: UInt64?
  private var maxLoadTickGapTicks: UInt64 = 0
  private var lastLoadTickAt: UInt64 = 0
  private var lastFinalizeTickAt: UInt64 = 0
  private var loadWedgeDetected = false
  private var finalizeWedgeDetected = false
  private var finalizeCompleted = false

  /// The reason the recording phase ended.
  private enum RecordingExit: Sendable {
    case userStop
    case vadAutoStop
    case maxDuration
    case captureStall
    case audioInterruption
    case asrInterruption
    case cancel
  }

  // MARK: Init

  init(
    adapter: any ASREngineAdapter,
    audioCapture: any AudioCaptureInterface,
    vad: any VADSignalSource,
    currentTick: @escaping @MainActor () -> UInt64,
    sleepTicks: @escaping @MainActor (Int) async -> Void,
    processText: @escaping @MainActor (
      _ raw: String, _ onPolishStarted: @escaping @MainActor () -> Void
    ) async throws -> String,
    store: @escaping @MainActor (_ text: String) async throws -> Void,
    deliver: @escaping @MainActor (_ text: String) async -> KernelDeliveryOutcome,
    wedgeStallTicks: Int = 2,
    minimumRecordingTicks: Int = 5,
    captureStallTelemetry: @escaping @MainActor (CaptureStallContext) -> Void = { _ in },
    zombieZeroPeakTelemetry: @escaping @MainActor (ZeroPeakContext) -> Void = { _ in },
    recordingStoppedTelemetry: @escaping @MainActor (_ sampleCount: Int) -> Void = { _ in },
    markPipelineTimingStart: @escaping @MainActor () -> Void = {},
    markASRTimingStart: @escaping @MainActor (_ streaming: Bool) -> Void = { _ in },
    markASRTimingEnd: @escaping @MainActor () -> Void = {},
    telemetryState: KernelTelemetryState = KernelTelemetryState()
  ) {
    self.adapter = adapter
    self.audioCapture = audioCapture
    self.vad = vad
    self.currentTick = currentTick
    self.sleepTicks = sleepTicks
    self.processText = processText
    self.store = store
    self.deliver = deliver
    self.wedgeStallTicks = wedgeStallTicks
    self.minimumRecordingTicks = minimumRecordingTicks
    self.captureStallTelemetry = captureStallTelemetry
    self.zombieZeroPeakTelemetry = zombieZeroPeakTelemetry
    self.recordingStoppedTelemetry = recordingStoppedTelemetry
    self.markPipelineTimingStart = markPipelineTimingStart
    self.markASRTimingStart = markASRTimingStart
    self.markASRTimingEnd = markASRTimingEnd
    self.telemetryState = telemetryState
  }

  // MARK: Driver entry points (PR-1 §A.2 trigger vocabulary)

  /// Start a new recording session. Legal from `idle` or any terminal state;
  /// ignored while a session is active (PR-1 §B.1.2 — "don't interrupt
  /// processing"). `config` freezes per-recording settings (VAD, decode
  /// language, model-unload policy) for this session (PR-4 plan §3.3a).
  func start(config: DictationSessionConfig) {
    guard state == .idle || state.isTerminal else {
      log("start ignored — session active at \(state)")
      return
    }
    let sid = SessionID()
    currentSessionID = sid
    resetSessionState()
    sessionConfig = config
    telemetryState.resetForNewSession(polishEnabled: config.llmProvider != .none)
    transition(to: .preparing)
    spawn(sid) { [weak self] in
      await self?.runForwardPath(sid)
    }
  }

  /// Request a stop. From `recording` it latches the recording-exit; from
  /// `preparing` / `warmingUp` it latches a stop the forward path resolves to
  /// `discarded`; elsewhere it is ignored (PR-1 §B.1.2, invariant 1).
  func requestStop() {
    switch state {
    case .recording:
      deliverRecordingExit(.userStop)
    case .preparing, .warmingUp:
      stopLatched = true
      bump()
    case .idle, .stopping, .transcribing, .finalizing, .completed, .failed,
      .cancelled, .discarded, .noSpeech, .audioInterrupted, .asrInterrupted:
      log("stop ignored at \(state)")
    }
  }

  /// Cancel. From `A⁻` (before `finalizing`) it routes to `cancelled`; from
  /// `finalizing` it is ignored — the safe point is inviolable (PR-1 §B.1.4
  /// invariant 5); elsewhere ignored.
  func cancel() {
    switch state {
    case .recording:
      deliverRecordingExit(.cancel)
    case .preparing, .warmingUp:
      cancelRequested = true
      detachedAdapterCancel()
      bump()
    case .stopping, .transcribing:
      // Cancel from `A⁻` after `recording` — no transcript exists yet, so the
      // safe point does not apply (PR-1 §B.1.2 `A⁻ | cancel → cancelled`).
      // Terminate now; `finishTerminal` discards the adapter's open session
      // (which also unblocks an in-flight `finalize()`), and the forward path
      // drops its in-flight `stopCapture()` / `finalize()` result when it
      // returns (state is terminal). `stopping` is included so a cancel
      // during a slow capture-stop is not lost (Codex P2).
      finishTerminal(.cancelled, sid: currentSessionID)
    case .finalizing:
      log("cancel ignored — safe point (transcript in hand)")
    case .idle, .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      log("cancel ignored at \(state)")
    }
  }

  /// Reset to `idle`. Legal only from a terminal state; from `finalizing` it
  /// is deferred (not implemented as a queue in PR-3 — logged and refused,
  /// the safe point completes then `start` mints fresh); elsewhere ignored.
  func reset() {
    guard state.isTerminal else {
      log("reset ignored / deferred at \(state)")
      return
    }
    // Mint a fresh `SessionID` so any same-session async work still unwinding
    // from the terminal state fails its next `isCurrent(sid)` guard. Without
    // this, those continuations see `.idle` (non-terminal) after the reset and
    // could resume into transcription/finalization, delivering text after the
    // user reset (Codex P1-round5).
    currentSessionID = SessionID()
    transition(to: .idle)
    // Do not claim resources released while a capture stop is still in flight.
    // The detached stop task (gated on `captureLifecycle`, not `SessionID`)
    // flips both fields when `stopCapture()` returns (Codex P2-round6).
    resourcesReleased = (captureLifecycle != .stopping)
  }

  /// Sessionless pre-warm — drives `adapter.readiness` toward `.ready` AND
  /// warms the capture path so a Bluetooth codec negotiation does not eat the
  /// first 0.5–2 s of dictation (PR-1 §B.1.2, §B.2.2; PR-4.5 #1 — parity with
  /// old Parakeet pipeline's `preWarmAudioInput`, `:295-315`). No
  /// `SessionID`, no FSM transition; valid only from `idle` / terminal.
  ///
  /// **Async on purpose (Codex r4):** the real PTT flow
  /// (`RecordingStarter.start()`) `await`s this and then immediately sends
  /// `.toggleRecording`. The `audioCapture.preWarm()` is therefore awaited
  /// end-to-end, so the Bluetooth-codec negotiation completes before
  /// `start(config:)` cancels the old-session task bag (which a spawned-but-
  /// unawaited preWarm task would not survive). Adapter warm-up is heavier
  /// (cold model load = seconds) and stays spawned in the background — the
  /// session's own `warmUp()` path re-checks `adapter.readiness` and reruns
  /// it cold if necessary, so the user does not block on it.
  ///
  /// `audioCapture.preWarm()` warms against whatever device UIDs
  /// `PipelineSettingsSync` has pushed live; the kernel does NOT re-push them
  /// here (no session config is in hand at sessionless pre-warm). The
  /// frozen-device push lands in `runForwardPath` (#3).
  ///
  /// Failures degrade per old behavior (PR-4.5 §8): a capture-warm failure is
  /// logged + swallowed (the session is not stranded; the start path will
  /// retry capture as needed); an adapter-warm failure leaves `.readiness`
  /// non-ready and the session's own warm-up path handles it.
  func preWarm() async throws {
    guard state == .idle || state.isTerminal else {
      log("preWarm ignored — session active at \(state)")
      return
    }
    let sid = currentSessionID
    // Adapter warm-up is spawned (can be a slow cold model load; the session's
    // own warmUp re-checks readiness and reruns cold if needed).
    spawn(sid) { [adapter, weak self] in
      do {
        try await adapter.warmUp()
        self?.log("preWarm adapter.warmUp succeeded sid=\(sid.raw)")
      } catch {
        self?.log("preWarm adapter.warmUp failed sid=\(sid.raw) error=\(error)")
      }
    }
    // Capture pre-warm is awaited end-to-end (Codex r4): the BT codec
    // negotiation MUST complete before `start(config:)` cancels the session
    // task bag, or the negotiation truncates and the user pays the
    // cold-start cost the pre-warm was supposed to hide.
    //
    // PR-4b.4 of #827: rethrow audioCapture.preWarm failures so the PTT
    // starter (`RecordingStarter.start()`) can surface "Microphone
    // unavailable" to the user. Old Parakeet pipeline propagated this same
    // error through `try await preWarmAudioInput()`; swallowing it here
    // would let the start path proceed into `.toggleRecording` and fail
    // downstream in a less informative way.
    do {
      try await audioCapture.preWarm()
      log("preWarm audioCapture.preWarm succeeded sid=\(sid.raw)")
    } catch {
      log("preWarm audioCapture.preWarm failed sid=\(sid.raw) error=\(error)")
      throw error
    }
  }

  // MARK: Forward path

  private func runForwardPath(_ sid: SessionID) async {
    guard let config = sessionConfig else {
      // `start(config:)` always sets `sessionConfig` before spawning this —
      // this guard is defensive only and cannot fire in practice.
      finishTerminal(.failed(.prepareFailed), sid: sid)
      return
    }
    // Push the frozen device UIDs BEFORE the capture source is built (PR-4.5
    // #3 — parity with old Parakeet pipeline `:1434-1439`). The capture
    // layer reads UIDs at source construction (the source is rebuilt between
    // recordings); a mic swap arriving after pre-warm but before
    // `startEnginePhase` would otherwise slip through `PipelineSettingsSync`'s
    // live writes.
    audioCapture.selectedInputDeviceUID = config.selectedInputDeviceUID
    audioCapture.preferredInputDeviceIDOverride = config.preferredInputDeviceIDOverride

    // Preparing: configure VAD from the frozen session config, bind capture
    // callbacks, derive decode options (PR-4 plan §3.3a).
    audioCapture.configureVAD(
      autoStop: config.vadAutoStop,
      silenceTimeout: config.vadSilenceTimeout,
      sensitivity: config.vadSensitivity,
      energyGate: config.vadEnergyGate)
    (vad as? CaptureVADSignalSource)?.configureSession(
      config: config,
      audioCapture: audioCapture
    )
    bindCaptureCallbacks(sid)
    // Stamp the VAD seam with the freshly minted session BEFORE subscribing —
    // a signal that races in between subscribe and stamp would otherwise carry
    // a stale ID and be dropped (PR-4.5 #2; old Parakeet pipeline
    // `:569-570,1276-1285`).
    vad.setCurrentSessionID(sid)
    log("VAD session stamped sid=\(sid.raw)")  // PR-4.5 §8
    subscribeVADSignals(sid)

    guard isCurrent(sid) else { return }
    if stopLatched {
      // PTT released before `recording` — no transcribable audio (PR-1 §B.1.2).
      discardReason = .releasedBeforeRecording
      finishTerminal(.discarded, sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }

    // Warm-up (skipped if the adapter is already ready — the warm path).
    if adapter.readiness != .ready {
      // Stamp BEFORE the transition so the lifecycle-event observer reads
      // the truthy flag at `.warmingUp` mapping time (PR-4b.2 §3.6 OQ-3).
      didLoadModelThisSession = true
      transition(to: .warmingUp)
      let warmResult = await warmUp(sid)
      guard isCurrent(sid) else { return }
      switch warmResult {
      case .ready:
        break
      case .wedged:
        finishTerminal(.failed(.modelWedged), sid: sid)
        return
      case .loadFailed:
        finishTerminal(.failed(.modelLoadFailed), sid: sid)
        return
      case .cancelled:
        finishTerminal(.cancelled, sid: sid)
        return
      case .stopped:
        discardReason = .releasedBeforeRecording
        finishTerminal(.discarded, sid: sid)
        return
      }
    }

    // Capture start.
    do {
      try await audioCapture.startEnginePhase()
    } catch {
      guard isCurrent(sid) else { return }
      telemetryState.captureFailureError = error
      finishTerminal(.failed(classifyCaptureStartError(error)), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }
    // The capture engine is up — every terminal from here must stop capture.
    captureLifecycle = .active
    if stopLatched {
      discardReason = .releasedBeforeRecording
      finishTerminal(.discarded, sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }
    // PR-4.5 #0 (Codex r2): Begin the adapter session BEFORE
    // `beginCapturePhase()`. The previous order opened the adapter AFTER
    // capture started — but `AVAudioEngineSource.PreRollForwarder.activate()`
    // drains real pre-roll DURING `beginCapturePhase`, so the buffer-callback
    // gate (`adapterSessionActive == true`) was still false when the pre-roll
    // arrived, and the buffers were dropped. The Parakeet adapter's
    // `beginSession` does not depend on the capture stream existing yet
    // (`ParakeetEngineAdapter.swift:155-181` — it only configures session-id /
    // streaming flags / clears retainedPCM); reordering is safe.
    //
    // Decode options derive from the frozen session config's language mode
    // (PR-4 plan §3.3a). The kernel owns the streaming-vs-batch policy: the
    // user's `useStreamingASR` setting ANDed with the adapter's static
    // streaming capability (PR-4 plan §3.4). A non-streaming engine (PR-5
    // WhisperKit) is never asked to stream.
    let shouldStream = config.useStreamingASR && adapter.capabilities.supportsStreaming
    // Stamp BEFORE beginSession so the lifecycle observer reads the correct
    // streaming flag at the `.recording` transition (Codex review #11 r2).
    isStreamingSession = shouldStream
    do {
      try await adapter.beginSession(
        sid, options: makeTranscriptionOptions(config), streaming: shouldStream)
    } catch {
      guard isCurrent(sid) else { return }
      finishTerminal(.failed(.asrFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }
    // The adapter now holds an open session — a terminal before `finalize()`
    // must discard it via `adapter.cancel()` (`finishTerminal` does this).
    adapterSessionActive = true
    // The adapter ran a session this run — the terminal applies the
    // model-unload policy exactly once (PR-4 plan §3.2).
    adapterDidBeginSession = true

    // Install the buffer callback BEFORE `beginCapturePhase()` — a direct
    // (non-XPC) capture source snapshots `onBufferCaptured` into the active
    // source at capture-start, so a callback set afterward would never be
    // seen for the whole session (Codex review P1). The callback gates
    // delivery on `adapterSessionActive` (now true; PR-4.5 #0), so the
    // real pre-roll drained by `PreRollForwarder.activate()` during
    // `beginCapturePhase` reaches the adapter via `retainedPCM` for batch
    // rescue.
    audioCapture.onBufferCaptured = makeBufferCallback(sid)
    do {
      _ = try await audioCapture.beginCapturePhase()
    } catch {
      guard isCurrent(sid) else { return }
      audioCapture.onBufferCaptured = nil
      telemetryState.captureFailureError = error
      finishTerminal(.failed(.captureStartFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }
    // Final latch check before `recording` — a stop / cancel that arrived
    // while `beginCapturePhase()` / `beginSession()` was suspended set only
    // `stopLatched` / `cancelRequested` (the FSM was still `warmingUp`); it
    // must be consumed here, not lost on the way into `recording` (Codex P1).
    if stopLatched {
      discardReason = .releasedBeforeRecording
      finishTerminal(.discarded, sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }

    // Recording.
    transition(to: .recording)
    recordingStartedAtDate = Date()
    // Stamp visible-recording start for the #4 discard gate (PR-4.5 #4, §5b).
    // Set ONLY after the transition to .recording; pre-roll buffers fed
    // earlier do not count toward minimum-duration.
    recordingStartedAtTick = currentTick()
    resourcesReleased = false
    (vad as? CaptureVADSignalSource)?.startMonitoring(
      recordingStartTime: Date(),
      isRecording: { [weak self] in
        self?.state == .recording && self?.currentSessionID == sid
      }
    )

    let exit = await awaitRecordingExit()
    guard isCurrent(sid), !state.isTerminal else { return }
    audioCapture.onBufferCaptured = nil

    // `finishTerminal` discards the adapter's open session (`adapterSessionActive`)
    // and stops capture — no per-exit `adapter.cancel()` needed here.
    switch exit {
    case .cancel:
      finishTerminal(.cancelled, sid: sid)
      return
    case .audioInterruption:
      finishTerminal(.audioInterrupted, sid: sid)
      return
    case .asrInterruption:
      finishTerminal(.asrInterrupted, sid: sid)
      return
    case .captureStall:
      finishTerminal(.failed(.captureStalled), sid: sid)
      return
    case .userStop, .vadAutoStop, .maxDuration:
      break
    }

    // Stopping. The `stopping` path owns the capture stop: marking
    // `.stopping` before the await tells a concurrent `finishTerminal`
    // (a cancel landing mid-stop) not to fire a second, racing stop — it
    // waits for this one. `resourcesReleased` flips true once the stop
    // genuinely completes, even if the session went terminal meanwhile.
    freezeRecordingSnapshot()
    markPipelineTimingStart()
    transition(to: .stopping)
    // PR-4.5 #4 (Codex r1): latch the tick BEFORE `stopCapture()`'s await so
    // capture-teardown latency does not count as visible-recording time.
    stoppingStartedAtTick = currentTick()
    captureLifecycle = .stopping
    let captureResult = await audioCapture.stopCapture()
    // Guard BEFORE touching kernel state — if a new session started while
    // `stopCapture()` was suspended, these fields belong to that session now
    // (Codex P2-round4 stale-completion guard).
    guard isCurrent(sid) else { return }
    captureLifecycle = .stopped
    resourcesReleased = true
    guard !state.isTerminal else { return }
    recordingStoppedTelemetry(captureResult.samples.count)
    await (vad as? CaptureVADSignalSource)?.finalizeAtStop(
      rawSampleCount: captureResult.samples.count,
      xpcSegments: captureResult.vadSegments
    )
    let rawPeakAudioLevel = peakAudioLevel(in: captureResult.samples)

    // Minimum-recording-duration discard (PR-4.5 #4) — parity with old
    // the old Parakeet pipeline. The TIME-BASED gate uses
    // visible-recording elapsed measured from `→ recording` (set above at
    // `recordingStartedAtTick`), NOT from pre-roll capture (PR-4.5 §5b:
    // pre-roll fix #0 must not let a 40 ms accidental tap slip past this
    // gate). MUST run BEFORE conditioning (#5) — padding must never turn a
    // sub-minimum tap into valid ASR input.
    //
    // The zero-buffer proxy (PR-3 placeholder for #4) is retained as a
    // belt-and-suspenders trigger so the simulator's `FakeAudioCapture`
    // (which never emits pre-roll automatically) still discards a
    // start-then-immediate-stop scenario as `.tooShort`. In production with
    // PR-4.5 #0's pre-roll path, real captures always have buffers, so the
    // time gate is the load-bearing one; the count gate is a no-op there.
    let elapsedSubMinimum: Bool = {
      guard let started = recordingStartedAtTick,
        let stopped = stoppingStartedAtTick,
        minimumRecordingTicks > 0
      else { return false }
      // PR-4.5 #4 (Codex r1): measure against the latched `.stopping` tick,
      // NOT `currentTick()` — capture-teardown latency must not count toward
      // visible-recording duration.
      return (stopped &- started) < UInt64(minimumRecordingTicks)
    }()
    if elapsedSubMinimum || bufferCountThisSession == 0 {
      discardReason = .tooShort
      finishTerminal(.discarded, sid: sid)
      return
    }
    if captureResult.samples.isEmpty {
      finishTerminal(.failed(.noAudioCaptured), sid: sid)
      return
    }

    // VAD no-speech gate (PR-1 §B.6) — keys on *confirmed* no-speech.
    let speechEvidence = vad.speechEvidenceAtStop()
    if speechEvidence == .confirmedNoSpeech {
      // Stamp BEFORE the transition so the lifecycle-event observer reads
      // the source at `.noSpeech` mapping time (PR-4b.2 §3.6 r7).
      lastNoSpeechSource = .vadGate
      telemetryState.noSpeechTelemetry = KernelNoSpeechTelemetry(
        mode: isStreamingSession ? "streaming" : "batch",
        rawSampleCount: captureResult.samples.count,
        peakAudioLevel: rawPeakAudioLevel
      )
      emitZombieZeroPeakIfNeeded(
        rawSamples: captureResult.samples,
        peakAudioLevel: rawPeakAudioLevel
      )
      finishTerminal(.noSpeech, sid: sid)
      return
    }

    // Condition the captured audio for ASR batch rescue (PR-4.5 #5) — VAD
    // filtering + too-aggressive-filter raw fallback + short-utterance
    // padding, in the order the old Parakeet pipeline (`:732-823`)
    // applied them. Runs AFTER the #4 discard gate so a sub-minimum tap is
    // never padded into valid ASR input (§5b). Conditioner is kernel-side
    // (capture/VAD policy lives here, not in the adapter); the adapter
    // receives the ASR-ready samples via `finalize(batchSamples:)`.
    //
    // VAD segments come from two possible sources (PR-4.5 #5, Codex r1+r2).
    // XPC mode: `AudioCaptureProxy.stopCapture()` bundles them atomically
    // into `captureResult.vadSegments` (`AudioCaptureProxy.swift:282`).
    // Direct mode: `AudioCaptureManager.stopCapture()` returns segments
    // empty — the in-process `SilenceDetector` owns them; the VAD seam
    // (`CaptureVADSignalSource.segmentsProvider`) bridges them in. Prefer
    // the bundled source when present (XPC works out of the box today);
    // fall back to the seam for direct-mode (which PR-4b wires up).
    let xpcSegments = captureResult.vadSegments
    let vadSegments = !xpcSegments.isEmpty ? xpcSegments : vad.speechSegmentsAtStop()
    // Raw audio for the conditioner is `captureResult.samples` (parity with
    // old Parakeet pipeline `rawSamples = captureResult.samples`).
    // The OLD pipeline did NOT include pre-roll in batch decode either — pre-roll
    // reached the streaming ASR via `onBufferCaptured` (still does, via
    // `acceptAudio` → adapter's streaming feed). Codex r4 caught a r3 regression
    // where switching the conditioner input to `adapter.currentBatchAudio`
    // (which includes pre-roll) misaligned with VAD segments indexed against
    // `captureResult.samples` — a segment starting at sample 0 would filter the
    // pre-roll prefix instead of the spoken word. The OLD batch-rescue parity is
    // "post-isCapturing audio only"; preserving it.
    let conditioned = CapturedAudioConditioner.condition(
      rawSamples: captureResult.samples, vadSegments: vadSegments)
    let vadSpeechDurationMs = Self.speechDurationMs(vadSegments)
    telemetryState.asrEmptyDiagnostics = ASREmptyResultDiagnostics(
      backend: ASRBackendType.parakeet.rawValue,
      mode: isStreamingSession ? "streaming" : "batch",
      hasSpeechEvidence: speechEvidence != .confirmedNoSpeech,
      rawSampleCount: captureResult.samples.count,
      vadSegmentCount: vadSegments.count,
      vadSpeechDurationMs: vadSpeechDurationMs,
      peakAudioLevel: rawPeakAudioLevel,
      vadFilteredSampleCount: conditioned.filteredSampleCount,
      finalSampleCount: conditioned.finalSampleCount,
      samplesPaddedToMinimum: conditioned.samplesPaddedToMinimum,
      usedRawFallbackAfterVAD: conditioned.usedRawFallbackAfterVAD,
      speechSegments: vadSegments
    )
    // PR-4.5 §8 metadata-only telemetry: sample counts + booleans, no audio
    // content. Lets a future "single-word transcription failed" triage tell
    // whether VAD filtering swallowed the speech (filteredSampleCount low),
    // raw fallback engaged (usedRawFallbackAfterVAD), or padding extended a
    // genuinely short utterance.
    log(
      "conditioner raw=\(captureResult.samples.count) filtered=\(conditioned.filteredSampleCount) "
        + "rawFallback=\(conditioned.usedRawFallbackAfterVAD) padded=\(conditioned.samplesPaddedToMinimum) "
        + "final=\(conditioned.finalSampleCount)")

    // Transcribing.
    let asrStart = CFAbsoluteTimeGetCurrent()
    markASRTimingStart(isStreamingSession)
    transition(to: .transcribing)
    let outcome = await finalize(sid, batchSamples: conditioned.samples)
    guard isCurrent(sid), !state.isTerminal else { return }
    let asrEnd = CFAbsoluteTimeGetCurrent()
    markASRTimingEnd()

    switch outcome {
    case .transcript(let result):
      telemetryState.asrCompletedTelemetry = KernelASRCompletedTelemetry(
        durationSeconds: asrEnd - asrStart,
        charCount: result.text.trimmingCharacters(in: .whitespacesAndNewlines).count,
        mode: isStreamingSession ? "streaming" : "batch",
        language: result.language
      )
      await runFinalizing(sid, asrText: result.text)
    case .empty(let hadSpeechEvidence):
      mergeAdapterDiagnosticsIntoASREmpty()
      if !hadSpeechEvidence {
        // Stamp BEFORE the transition so the observer reads the source
        // at `.noSpeech` mapping time (PR-4b.2 §3.6 r7).
        lastNoSpeechSource = .asrEmptyNoSpeech
        telemetryState.noSpeechTelemetry = KernelNoSpeechTelemetry(
          mode: isStreamingSession ? "streaming" : "batch",
          rawSampleCount: captureResult.samples.count,
          peakAudioLevel: rawPeakAudioLevel
        )
      }
      finishTerminal(hadSpeechEvidence ? .failed(.asrEmpty) : .noSpeech, sid: sid)
    case .cancelled:
      finishTerminal(.cancelled, sid: sid)
    case .failed(.wedged):
      telemetryState.transcriptionFailureError =
        (adapter as? ASREngineTelemetryProviding)?.lastFailureError ?? ASREngineError.wedged
      finishTerminal(.failed(.asrWedged), sid: sid)
    case .failed(let error):
      telemetryState.transcriptionFailureError =
        (adapter as? ASREngineTelemetryProviding)?.lastFailureError ?? error
      finishTerminal(.failed(.asrFailed), sid: sid)
    }
  }

  /// The finalizing phase — the transcript is in hand, the safe point is in
  /// force (PR-1 §B.5). Cancel / interruption from here are ignored.
  private func runFinalizing(_ sid: SessionID, asrText: String) async {
    transition(to: .finalizing)
    finalizingSubStatus = .transcribing

    let processed: String
    do {
      processed = try await processText(asrText) { [weak self] in
        self?.finalizingSubStatus = .polishing
        self?.bump()
      }
    } catch {
      guard isCurrent(sid) else { return }
      telemetryState.transcriptionFailureError = error
      finishTerminal(.failed(.emptyAfterProcessing), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }

    // Empty after the limb steps — clipboard untouched (PR-1 §B.1.2).
    if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      finishTerminal(.failed(.emptyAfterProcessing), sid: sid)
      return
    }

    // The unload-policy gate: a non-empty transcript has cleared polish and is
    // about to be stored / delivered. Old pipeline parity
    // (old Parakeet pipeline): `noteTranscriptionComplete` fires
    // here, between polish and storage/paste — failures after this point still
    // get unload, failures before do not (PR-4.5 #8, §5b).
    transcriptReadyForDelivery = true

    do {
      try await store(processed)
    } catch {
      guard isCurrent(sid) else { return }
      telemetryState.storageFailureError = error
      finishTerminal(.failed(.storageFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }

    let result = await deliver(processed)
    guard isCurrent(sid) else { return }
    deliveredTranscript = processed
    deliveryOutcome = result
    pasteCount = (result == .pasted) ? 1 : 0
    finishTerminal(.completed, sid: sid)
  }

  // MARK: Warm-up + wedge detection

  private enum WarmUpResult { case ready, wedged, loadFailed, cancelled, stopped }

  private func warmUp(_ sid: SessionID) async -> WarmUpResult {
    loadWedgeDetected = false
    loadTickCount = 0
    loadAttemptStartedAtTick = currentTick()
    firstLoadTickAt = nil
    maxLoadTickGapTicks = 0
    modelLoadWedgeTelemetry = nil

    // Consume the optional load-progress stream. The wedge watcher is armed
    // by the FIRST tick — real progress must be observed before a stall
    // counts (PR-1 §B.1.7). A warm-up that emits no progress signal at all is
    // the signal-free case: no watcher is ever spawned, no wedge detection.
    if let stream = adapter.loadProgress {
      spawn(sid) { [weak self] in
        for await _ in stream {
          guard let self, self.isCurrent(sid) else { return }
          let now = self.currentTick()
          if self.loadTickCount == 0 {
            self.firstLoadTickAt = now
          } else {
            self.maxLoadTickGapTicks = max(
              self.maxLoadTickGapTicks,
              now &- self.lastLoadTickAt
            )
          }
          self.loadTickCount += 1
          self.lastLoadTickAt = now
          self.bump()
          if self.loadTickCount == 1 {
            self.spawn(sid) { [weak self] in
              await self?.detectLoadWedge(sid)
            }
          }
        }
      }
    }

    var thrownError: (any Error)?
    do {
      try await adapter.warmUp()
    } catch {
      // Classified below — `warmUp()` throwing is expected on the wedge path
      // (the watcher cancels the adapter, which unblocks the parked load).
      // Stash the error so the `.loadFailed` terminal can surface
      // `error.localizedDescription` in the user-facing message (parity with
      // the old Parakeet pipeline at TP:440-445).
      thrownError = error
    }
    guard isCurrent(sid) else { return .cancelled }

    if loadWedgeDetected { return .wedged }
    if stopLatched { return .stopped }
    if cancelRequested { return .cancelled }
    if adapter.readiness == .ready { return .ready }
    if let thrownError { telemetryState.modelLoadError = thrownError }
    return .loadFailed
  }

  /// Armed by the first load tick. Each cycle sleeps a `wedgeStallTicks`
  /// window, then measures silence *since the most recent tick*: if the load
  /// emitted no further progress for a full window and is still not ready, it
  /// is a cadence stall (PR-1 §B.1.7 — keyed on absence of progress, never a
  /// wall-clock deadline on completion). An adapter that keeps reporting
  /// progress refreshes `lastLoadTickAt` and is never misclassified — the
  /// loop just keeps watching. On detection it cancels the adapter, which
  /// unblocks the parked load.
  private func detectLoadWedge(_ sid: SessionID) async {
    while isCurrent(sid), !Task.isCancelled, !loadWedgeDetected {
      await sleepTicks(wedgeStallTicks)
      guard isCurrent(sid), !Task.isCancelled, !loadWedgeDetected else { return }
      if adapter.readiness == .ready { return }  // healthy completion
      let now = currentTick()
      let silentTicks = now &- lastLoadTickAt
      if silentTicks >= UInt64(wedgeStallTicks) {
        loadWedgeDetected = true
        let maxGapTicks = max(maxLoadTickGapTicks, silentTicks)
        modelLoadWedgeTelemetry = KernelModelLoadWedgeTelemetry(
          silenceMs: milliseconds(forTicks: silentTicks),
          observedMaxGapMs: milliseconds(forTicks: maxGapTicks),
          observedPhase: "kernel",
          signalCountTotal: loadTickCount,
          firstSignalLatencyMs: firstLoadTickAt.map {
            milliseconds(forTicks: $0 &- loadAttemptStartedAtTick)
          },
          totalAttemptDurationMs: milliseconds(forTicks: now &- loadAttemptStartedAtTick)
        )
        bump()
        await adapter.cancel()
        return
      }
      // A tick landed within the window — the load is still progressing.
    }
  }

  private func milliseconds(forTicks ticks: UInt64) -> Int {
    Int(ticks) * 100
  }

  // MARK: Finalize + wedge detection

  private func finalize(_ sid: SessionID, batchSamples: [Float]?) async -> ASREngineOutcome {
    finalizeWedgeDetected = false
    finalizeCompleted = false
    finalizeTickCount = 0

    if let stream = adapter.finalizeProgress {
      spawn(sid) { [weak self] in
        for await _ in stream {
          guard let self, self.isCurrent(sid) else { return }
          self.finalizeTickCount += 1
          self.lastFinalizeTickAt = self.currentTick()
          self.bump()
          if self.finalizeTickCount == 1 {
            self.spawn(sid) { [weak self] in
              await self?.detectFinalizeWedge(sid)
            }
          }
        }
      }
    }

    let outcome = await adapter.finalize(batchSamples: batchSamples)
    // Guard BEFORE touching kernel state — a `finalize()` unblocked after a
    // cancel, with a new session already started, must not clear the new
    // session's flags (Codex P2-round4 stale-completion guard).
    guard isCurrent(sid) else { return .cancelled }
    finalizeCompleted = true
    // `finalize()` is the adapter's own session-terminal hook — the open
    // session is now closed, so a later `finishTerminal` must NOT also call
    // `adapter.cancel()`.
    adapterSessionActive = false
    if finalizeWedgeDetected { return .failed(.wedged) }
    return outcome
  }

  /// Armed by the first finalize tick. Same cadence model as
  /// `detectLoadWedge` — silence since the most recent finalize tick, not a
  /// fixed window from the first (Codex review P2). A `finalize()` still in
  /// flight after a full silent window is a cadence stall (PR-1 §B.1.7).
  private func detectFinalizeWedge(_ sid: SessionID) async {
    while isCurrent(sid), !Task.isCancelled, !finalizeWedgeDetected {
      await sleepTicks(wedgeStallTicks)
      guard isCurrent(sid), !Task.isCancelled, !finalizeWedgeDetected else { return }
      if finalizeCompleted { return }  // healthy completion
      if currentTick() &- lastFinalizeTickAt >= UInt64(wedgeStallTicks) {
        finalizeWedgeDetected = true
        bump()
        await adapter.cancel()
        return
      }
      // A finalize tick landed within the window — still progressing.
    }
  }

  // MARK: Capture callbacks + buffer handoff

  /// Bind the adapter's mid-recording engine-crash signal (PR-4 plan §3.2).
  ///
  /// PR-4b.1: the three shared `AudioCaptureInterface` callbacks
  /// (`onEngineInterrupted`, `onCaptureStalled`, `onXPCServiceError`) are no
  /// longer claimed here. `AudioCaptureInterface` callbacks are single-owner;
  /// the App-side `AudioEventRouter` + `WedgeRecoveryRouter` stay as the sole
  /// subscribers and forward into the kernel through the driver's
  /// `externalEngineInterrupted` / `externalASRInterrupted` /
  /// `externalCaptureStalled` entry methods (wired in PR-4b.4). Adapter-local
  /// interruption callbacks may still route here, but Parakeet leaves
  /// `ASRManager.onServiceInterrupted` to the App router to avoid
  /// last-writer-wins callback collisions.
  ///
  /// VAD auto-stop is NOT bound here: it flows through `vad.stopSignals`
  /// only, with `CaptureVADSignalSource` the single owner of
  /// `AudioCaptureInterface.onVADAutoStop` (PR-4 plan §3.5).
  private func bindCaptureCallbacks(_ sid: SessionID) {
    // Optional adapter-local backend crash signal. Parakeet does not install
    // this on `ASRManager.onServiceInterrupted`; the App router owns that one.
    adapter.onEngineInterrupted = { [weak self] in
      self?.routeASRInterruption(sid: sid)
    }
  }

  // MARK: External entry points (PR-4b.1)
  //
  // PR-4b.1 removed the kernel's direct subscriptions to the shared
  // `AudioCaptureInterface` callbacks (`onEngineInterrupted`, `onCaptureStalled`,
  // `onXPCServiceError`). The App-side routers stay as sole subscribers; the
  // driver (`KernelDictationDriver` — same module) forwards the calls into
  // these internal entry methods. PR-4b.4 wires the App routers' Parakeet
  // branches.
  //
  // Each method is idempotent — early-return when the kernel is in a terminal
  // state via the existing `RecordingSessionState.isTerminal` (`:60`). The
  // seven terminal states (`completed`, `cancelled`, `discarded`, `noSpeech`,
  // `failed`, `audioInterrupted`, `asrInterrupted`) return true; `.idle` does
  // NOT. Between sessions the kernel sits at `.idle`, which is non-terminal
  // but also non-recording — the no-op at `.idle` is delivered by
  // `deliverRecordingExitIfCurrent`'s `state == .recording` guard (`:1103`),
  // not by `!state.isTerminal`. `routeASRInterruption` similarly switches on
  // state and falls through to `default: return` for non-recording /
  // non-transcribing states.

  /// Route an external audio-interruption (BT disconnect, mic route change)
  /// into the FSM. Replaces the removed direct subscription to
  /// `audioCapture.onEngineInterrupted`. Idempotent: a second call after a
  /// terminal short-circuits via `!state.isTerminal`.
  func externalEngineInterrupted() {
    guard !state.isTerminal else { return }
    deliverRecordingExitIfCurrent(.audioInterruption, sid: currentSessionID)
  }

  /// Route an external ASR-XPC interruption (audio-capture XPC service error,
  /// equivalent in shape to the adapter's own engine-crash) into the FSM.
  /// Mirror of the internal `routeASRInterruption(sid:)` path the removed
  /// `onXPCServiceError` subscription used to invoke.
  func externalASRInterrupted() {
    guard !state.isTerminal else { return }
    routeASRInterruption(sid: currentSessionID)
  }

  /// Route an external capture-stall into the FSM. Replaces the removed
  /// `audioCapture.onCaptureStalled` subscription. The driver fans the
  /// `CaptureStallContext` to the telemetry observer separately (PR-4b.4);
  /// this method only routes the FSM transition. The context's `sessionID`
  /// is a `UInt64` capture counter (different domain from the kernel's UUID
  /// `SessionID`), so the guard is on kernel terminal state, not ID
  /// equality — the App-side `WedgeRecoveryRouter` already filters by
  /// capture session via its own `isCurrentSession(ctx.sessionID)` check.
  func externalCaptureStalled(_ ctx: CaptureStallContext) {
    _ = ctx
    guard !state.isTerminal else { return }
    deliverRecordingExitIfCurrent(.captureStall, sid: currentSessionID)
  }

  /// The buffer-handoff callback (PR-3 plan §3.4 — reuses the shipped
  /// `Task { @MainActor }` per-buffer hop pattern). The audio-thread closure
  /// does the minimum — wrap + hop; the `@MainActor` side gates on
  /// `SessionID` + FSM state, then forwards to the adapter.
  ///
  /// PR-4 plan §3.4: the carrier holds the `AVAudioPCMBuffer` directly. The
  /// audio thread transfers it via `nonisolated(unsafe)` — the buffer is
  /// created on the audio thread, wrapped once, and read only on `@MainActor`,
  /// never from two threads (the shipped pattern, the old Parakeet pipeline).
  private func makeBufferCallback(_ sid: SessionID) -> (@Sendable (AVAudioPCMBuffer) -> Void) {
    return { [weak self] buffer in
      nonisolated(unsafe) let safeBuffer = buffer
      let frameCount = Int(buffer.frameLength)
      Task { @MainActor [weak self] in
        // PR-4.5 #0 pre-roll restoration: accept buffers as soon as the
        // adapter session is open, NOT when the FSM has reached `.recording`.
        // The old Parakeet pipeline (`:535-539`) retained pre-roll fed
        // by `AVAudioEngineSource.PreRollForwarder` (`:329-335`) for the
        // adapter's batch rescue; the fresh kernel's `state == .recording`
        // gate dropped that pre-roll. `adapterSessionActive` is set true the
        // moment `beginSession()` returns (line 529-ish) — its `removeAll`
        // (`ParakeetEngineAdapter.swift:163`) is the session-scoped reset
        // (PR-4.5 §5b — prior-session leakage cannot occur). Tail buffers
        // arriving after `.recording` exit but before `onBufferCaptured = nil`
        // also reach the adapter, parity with the old per-buffer hand-off
        // (old Parakeet pipeline).
        guard let self, self.isCurrent(sid), self.adapterSessionActive else { return }
        self.bufferSequence += 1
        let handoff = AudioBufferHandoff(
          buffer: safeBuffer, frameCount: frameCount,
          sequence: self.bufferSequence, sessionID: sid)
        self.adapter.acceptAudio(handoff)
        self.bufferCountThisSession += 1
        self.bump()
      }
    }
  }

  // MARK: VAD subscription

  private func subscribeVADSignals(_ sid: SessionID) {
    spawn(sid) { [weak self] in
      guard let self else { return }
      for await signal in self.vad.stopSignals {
        guard self.isCurrent(sid) else { return }
        // Stale-callback drop (PR-1 §B.1.4 invariant 7) — a signal stamped
        // with a non-current `SessionID` cannot terminate this session. The
        // count is bumped + logged (PR-4.5 §8): a sudden spike in stale-drops
        // is the early warning sign of finding #2 regressing.
        guard signal.sessionID == self.currentSessionID else {
          self.staleVADSignalDrops += 1
          self.log(
            "dropped stale VAD signal kind=\(signal.kind) "
              + "from=\(signal.sessionID.raw) current=\(self.currentSessionID.raw) "
              + "totalDrops=\(self.staleVADSignalDrops)")
          continue
        }
        switch signal.kind {
        case .autoStopTriggered:
          self.deliverRecordingExitIfCurrent(.vadAutoStop, sid: sid)
        case .maxDurationReached:
          self.deliverRecordingExitIfCurrent(.maxDuration, sid: sid)
        }
      }
    }
  }

  // MARK: Recording-exit channel

  private func awaitRecordingExit() async -> RecordingExit {
    if let pending = pendingRecordingExit {
      pendingRecordingExit = nil
      return pending
    }
    return await withCheckedContinuation { continuation in
      recordingExitContinuation = continuation
    }
  }

  private func deliverRecordingExit(_ exit: RecordingExit) {
    guard !recordingExitLatched else { return }
    recordingExitLatched = true
    bump()
    if let continuation = recordingExitContinuation {
      recordingExitContinuation = nil
      continuation.resume(returning: exit)
    } else {
      pendingRecordingExit = exit
    }
  }

  private func deliverRecordingExitIfCurrent(_ exit: RecordingExit, sid: SessionID) {
    guard isCurrent(sid), state == .recording else { return }
    deliverRecordingExit(exit)
  }

  /// Route an ASR-interruption signal (adapter engine crash OR audio-capture
  /// XPC service error). PR-4.5 #7: the old Parakeet pipeline
  /// (`:1134-1163`) handled this in BOTH `.recording` AND `.transcribing`; the
  /// fresh kernel's `deliverRecordingExitIfCurrent` guarded `state == .recording`
  /// only, so a crash in `.transcribing` was dropped (no terminal, no cleanup,
  /// hung overlay). The `.transcribing → .asrInterrupted` FSM edge is already
  /// legal — only the callback guard blocked it.
  ///
  /// Routing differs by state because the recording-exit continuation is
  /// consumed once: in `.recording` we send through the channel so the
  /// forward-path coroutine sees the exit and runs unified cleanup; in
  /// `.transcribing` the continuation is gone, so we go DIRECTLY to terminal.
  /// Other states (.stopping, .finalizing, terminal) are unchanged from the
  /// prior drop — out of scope for #7.
  private func routeASRInterruption(sid: SessionID) {
    guard isCurrent(sid) else { return }
    // PR-4.5 §8: record the FSM state at callback time. The OLD pipeline's
    // mid-transcribe crash routed cleanly; the kernel's pre-PR-4.5 callback
    // guard silently dropped it. Logging the state at routing makes "crashed
    // but no terminal" futures debuggable from app.log alone.
    log("ASR interruption routed sid=\(sid.raw) state=\(state)")
    switch state {
    case .recording:
      freezeRecordingSnapshot()
      deliverRecordingExit(.asrInterruption)
    case .transcribing:
      freezeRecordingSnapshot()
      finishTerminal(.asrInterrupted, sid: sid)
    default:
      return
    }
  }

  // MARK: Transitions

  /// Apply one FSM transition. A forbidden transition (into a state from an
  /// illegal predecessor) is logged and refused — FSM state is left unchanged
  /// (PR-1 §B.1.2; PR-3 plan §3.10 — not `assertionFailure`, the simulator
  /// drives forbidden transitions deliberately).
  @discardableResult
  private func transition(to next: RecordingSessionState) -> Bool {
    guard isLegalTransition(from: state, to: next) else {
      forbiddenTransitionRejected = true
      log("FORBIDDEN transition \(state) → \(next) — refused, state unchanged")
      return false
    }
    state = next
    bump()
    return true
  }

  /// The legal FSM edges (PR-1 §B.1.2 transition table). Any pair not listed
  /// here is a forbidden transition — `transition(to:)` refuses it. Encoded as
  /// the per-from-state allowed `to` set rather than a blanket "any active
  /// jump is fine" (Codex P2-round3): a gross jump like `preparing → completed`
  /// or `recording → finalizing` must be rejected.
  private func isLegalTransition(
    from current: RecordingSessionState, to next: RecordingSessionState
  ) -> Bool {
    if current == next { return false }
    switch current {
    case .idle:
      // Only `start` — `idle → preparing`.
      if case .preparing = next { return true }
      return false
    case .preparing:
      switch next {
      case .warmingUp, .recording, .failed, .discarded, .cancelled,
        .audioInterrupted, .asrInterrupted:
        return true
      default:
        return false
      }
    case .warmingUp:
      switch next {
      case .recording, .failed, .discarded, .cancelled, .audioInterrupted,
        .asrInterrupted:
        return true
      default:
        return false
      }
    case .recording:
      switch next {
      case .stopping, .failed, .discarded, .cancelled, .audioInterrupted,
        .asrInterrupted:
        return true
      default:
        return false
      }
    case .stopping:
      switch next {
      case .transcribing, .failed, .noSpeech, .discarded, .cancelled,
        .audioInterrupted, .asrInterrupted:
        return true
      default:
        return false
      }
    case .transcribing:
      switch next {
      case .finalizing, .failed, .noSpeech, .cancelled, .audioInterrupted,
        .asrInterrupted:
        return true
      default:
        return false
      }
    case .finalizing:
      // Safe point — only `completed` or a `failed` delivery outcome.
      switch next {
      case .completed, .failed:
        return true
      default:
        return false
      }
    case .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      // A terminal state may only move to `idle` (reset) or `preparing`
      // (start of a new session).
      switch next {
      case .idle, .preparing:
        return true
      default:
        return false
      }
    }
  }

  /// Reach a terminal state: transition, run nonblocking cleanup, drain the
  /// task bag (PR-1 §B.1.6, PR-3 plan §3.1a — cancel + clear, never `await`).
  /// Discards the adapter's open session and stops the capture engine if
  /// either is still in flight (PR-1 §B.1.3 cleanup column; Codex P1b / P2-r3).
  private func finishTerminal(_ terminal: RecordingSessionState, sid: SessionID) {
    guard isCurrent(sid) else { return }
    guard transition(to: terminal) else { return }
    audioCapture.onBufferCaptured = nil
    // PR-4b.1: `onEngineInterrupted`, `onCaptureStalled`, and `onXPCServiceError`
    // are no longer owned by the kernel — the App-side routers stay as sole
    // subscribers, so the kernel must not nil-clear them on session terminal
    // (doing so would steal them from the App router for the lifetime of the
    // app). `onVADAutoStop` is similarly NOT cleared here — `CaptureVADSignalSource`
    // is the single owner (PR-4 plan §3.5).
    adapter.onEngineInterrupted = nil
    drainTaskBag()

    // Discard the adapter's open session — the only discard hook is
    // `cancel()`. A terminal after `beginSession()` but without a `finalize()`
    // would otherwise leave a real adapter mid-session (Codex P2-round3).
    if adapterSessionActive {
      adapterSessionActive = false
      detachedAdapterCancel()
    }

    // Apply the model-unload policy once per session that produced a
    // transcript-ready-for-delivery (PR-4.5 #8, parity with old
    // the old Parakeet pipeline). A session that crashed in
    // capture-stall / ASR-wedge / no-speech / cancel / sub-minimum / audio /
    // ASR interrupt did NOT produce a transcript — applying the unload policy
    // would force a cold reload on the next session for no value. The
    // `adapterDidBeginSession` reset still runs so a future session re-applies
    // cleanup correctly.
    let shouldApplyUnload = transcriptReadyForDelivery
    if adapterDidBeginSession {
      adapterDidBeginSession = false
    }
    transcriptReadyForDelivery = false
    if shouldApplyUnload {
      let policy = sessionConfig?.modelUnloadPolicy ?? .never
      log("model unload applied policy=\(policy) terminal=\(terminal) sid=\(sid.raw)")  // PR-4.5 §8
      adapter.applyUnloadPolicy(policy)
    } else {
      log("model unload SKIPPED (no transcript-ready) terminal=\(terminal) sid=\(sid.raw)")  // PR-4.5 §8
    }

    // Stop the capture engine. `resourcesReleased` flips true only once the
    // stop genuinely completes, so the cleanup surface never lies.
    switch captureLifecycle {
    case .active:
      // No stop in flight — this terminal owns it.
      captureLifecycle = .stopping
      resourcesReleased = false
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.bump()
        _ = await self.audioCapture.stopCapture()
        // Gate on the capture lifecycle, not `SessionID`. A new session that
        // started while this stop was suspended sets `captureLifecycle` to
        // `.active` via `beginCapturePhase()`, so this guard refuses to
        // overwrite its fresh state (Codex P2-round4). It still fires when the
        // session was reset to idle meanwhile — `reset()` mints a new
        // `SessionID` but leaves `captureLifecycle` at `.stopping`, so this
        // task completes its own bookkeeping rather than being orphaned
        // (Codex P2-round6).
        guard self.captureLifecycle == .stopping else { return }
        self.captureLifecycle = .stopped
        self.resourcesReleased = true
        self.bump()
      }
    case .stopping:
      // The `stopping` forward path already owns the stop; it flips
      // `resourcesReleased` true when its `stopCapture()` returns.
      resourcesReleased = false
    case .notStarted, .stopped:
      resourcesReleased = true
    }
    log("terminal \(terminal)")
  }

  // MARK: Task bag

  private func spawn(_ sid: SessionID, _ work: @escaping @MainActor () async -> Void) {
    if taskBagSessionID != sid {
      // A new session is taking over the bag — cancel the prior session's
      // stragglers (e.g. a `preWarm()` warm-up still running when `start()`
      // mints the first session), do not silently drop their handles
      // (Codex P2-round4). Their late completions are still `SessionID`-gated.
      for task in taskBag { task.cancel() }
      taskBag.removeAll()
      taskBagSessionID = sid
    }
    let task = Task { @MainActor in await work() }
    taskBag.append(task)
  }

  /// Cancel every task in the bag and clear the bag reference — nonblocking
  /// (PR-3 plan §3.1a). A task that ignores cooperative cancellation outlives
  /// the session; its late completion carries the old `SessionID` and is
  /// dropped on arrival (FSM invariant 7).
  private func drainTaskBag() {
    for task in taskBag { task.cancel() }
    taskBag.removeAll()
  }

  // MARK: Helpers

  private func isCurrent(_ sid: SessionID) -> Bool {
    currentSessionID == sid
  }

  private func resetSessionState() {
    stopLatched = false
    cancelRequested = false
    recordingExitContinuation = nil
    pendingRecordingExit = nil
    recordingExitLatched = false
    bufferCountThisSession = 0
    bufferSequence = 0
    captureLifecycle = .notStarted
    adapterSessionActive = false
    adapterDidBeginSession = false
    transcriptReadyForDelivery = false
    recordingStartedAtTick = nil
    stoppingStartedAtTick = nil
    recordingStartedAtDate = nil
    loadTickCount = 0
    finalizeTickCount = 0
    loadAttemptStartedAtTick = 0
    firstLoadTickAt = nil
    maxLoadTickGapTicks = 0
    lastLoadTickAt = 0
    lastFinalizeTickAt = 0
    loadWedgeDetected = false
    finalizeWedgeDetected = false
    finalizeCompleted = false
    modelLoadWedgeTelemetry = nil
    finalizingSubStatus = .transcribing
    deliveredTranscript = nil
    deliveryOutcome = nil
    discardReason = nil
    didLoadModelThisSession = false
    lastNoSpeechSource = nil
    isStreamingSession = false
    pasteCount = 0
    forbiddenTransitionRejected = false
  }

  /// Derive decode options from the frozen session config's language mode
  /// (PR-4 plan §3.3a — mirrors the old Parakeet pipeline's `applySessionConfig`).
  private func makeTranscriptionOptions(_ config: DictationSessionConfig)
    -> TranscriptionOptions
  {
    var options = TranscriptionOptions()
    switch config.languageMode {
    case .auto:
      options.language = nil
    case .locked(let code):
      options.language = code
    }
    return options
  }

  private func freezeRecordingSnapshot() {
    let start = recordingStartedAtDate ?? Date()
    telemetryState.recordingSnapshot = KernelRecordingSnapshotTelemetry(
      backend: ASRBackendType.parakeet.rawValue,
      audioRoute: audioCapture.currentAudioRoute,
      wasStreaming: isStreamingSession,
      startTime: start,
      durationMs: Int(Date().timeIntervalSince(start) * 1000),
      targetAppBundleID: nil
    )
  }

  private func emitZombieZeroPeakIfNeeded(rawSamples: [Float], peakAudioLevel: Float) {
    guard peakAudioLevel == 0.0,
      rawSamples.count >= AudioConstants.minimumTranscriptionSamples
    else { return }

    zombieZeroPeakTelemetry(
      ZeroPeakContext(
        sessionID: audioCapture.currentCaptureSessionID,
        durationMs: rawSamples.count * 1000 / Int(AudioConstants.sampleRate),
        route: audioCapture.currentAudioRoute,
        sampleCount: rawSamples.count,
        isActivelyCapturing: audioCapture.isActivelyCapturing,
        captureSourceType: audioCapture.captureSourceType,
        inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
          ? nil : audioCapture.preferredInputDeviceIDOverride,
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID()
      )
    )
  }

  private func mergeAdapterDiagnosticsIntoASREmpty() {
    guard var diagnostics = telemetryState.asrEmptyDiagnostics,
      let adapterDiagnostics = (adapter as? ASREngineTelemetryProviding)?.lastASRDiagnostics
    else { return }

    diagnostics.streamingResultChars = adapterDiagnostics.streamingResultChars
    diagnostics.streamingFinalizeFailed = adapterDiagnostics.streamingFinalizeFailed
    diagnostics.streamingFinalizeErrorType = adapterDiagnostics.streamingFinalizeErrorType
    diagnostics.streamingBuffersDispatched = adapterDiagnostics.streamingBuffersDispatched
    diagnostics.streamingBuffersFed = adapterDiagnostics.streamingBuffersFed
    diagnostics.batchRescueAttempted = adapterDiagnostics.batchRescueAttempted
    diagnostics.batchRescueResultChars = adapterDiagnostics.batchRescueResultChars
    telemetryState.asrEmptyDiagnostics = diagnostics
  }

  private func peakAudioLevel(in samples: [Float]) -> Float {
    samples.reduce(Float(0)) { max($0, abs($1)) }
  }

  private static func speechDurationMs(_ segments: [SpeechSegment]) -> Int {
    segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000
      / Int(AudioConstants.sampleRate)
  }

  private func classifyCaptureStartError(_ error: Error) -> RecordingFailureReason {
    // The capture seam surfaces permission revocation distinctly from a
    // generic engine-start failure (PR-1 §B.1.2).
    let description = String(describing: error).lowercased()
    if description.contains("permission") { return .permissionDenied }
    return .captureStartFailed
  }

  private func bump() {
    workEpoch &+= 1
  }

  /// Fire `adapter.cancel()` without blocking the caller (best-effort load /
  /// finalize cancellation, D6). Bumps `workEpoch` so the simulator's
  /// quiescence drain accounts for this detached work.
  private func detachedAdapterCancel() {
    bump()
    Task { @MainActor [weak self] in
      await self?.adapter.cancel()
      self?.bump()
    }
  }

  private func log(_ message: String) {
    // Kernel logs carry FSM states / SessionIDs / counters only — never
    // transcript text (PR-3 plan §3.10 privacy boundary).
    Task { await AppLogger.shared.log("[kernel] \(message)", level: .debug, category: "Kernel") }
  }

  #if DEBUG
    // MARK: Test-only seams (PR-3 plan §3.10, §3.1a)
    //
    // These exist ONLY so the direct FSM-invariant tests can exercise the
    // forbidden-transition guard and the task-bag drain. Production callers use
    // the trigger entry points and never touch these.

    /// Drive a raw transition to exercise the forbidden-transition guard.
    @discardableResult
    func testForceTransition(to next: RecordingSessionState) -> Bool {
      transition(to: next)
    }

    /// The count of task references still held on the kernel — the §3.1a
    /// "no active task references remain after a terminal state" invariant.
    var testActiveTaskCount: Int { taskBag.count }

    /// Test-only telemetry-error setters. Unit tests that need to assert the
    /// `lastFailureDetail` mapping reach the underlying telemetry fields
    /// through these hooks rather than driving a real warm-up / capture /
    /// transcription failure.
    func testSetModelLoadError(_ error: (any Error)?) {
      telemetryState.modelLoadError = error
    }
    func testSetCaptureFailureError(_ error: (any Error)?) {
      telemetryState.captureFailureError = error
    }
    func testSetTranscriptionFailureError(_ error: (any Error)?) {
      telemetryState.transcriptionFailureError = error
    }
  #endif
}
