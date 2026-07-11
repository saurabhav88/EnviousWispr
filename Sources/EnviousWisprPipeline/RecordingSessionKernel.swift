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
enum FinalizingSubStatus: Equatable, Sendable {
  case transcribing
  case polishing
}

/// How the transcript reached the user (PR-1 §B.1.3). The kernel records this
/// from the `deliver` seam's return value.
enum KernelDeliveryOutcome: Equatable, Sendable {
  case pasted
  case clipboardOnly
}

/// The user-visible error surface a terminal state renders (PR-1 §B.1.3).
// periphery:ignore - test seam (read only via the test-only userVisibleError)
enum KernelErrorCategory: Equatable, Sendable {
  case recoverableError
  case interruption
}

/// Why a session reached the `discarded` terminal — surfaced for the
/// PR-1 §B.7.4 telemetry event (PR-4 plan §3.8a). A sibling observable to
/// `state`, the same shape as `deliveredTranscript`; the `discarded` FSM case
/// stays plain (no state-enum payload).
enum DiscardReason: Equatable, Sendable {
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
enum NoSpeechSource: Equatable, Sendable {
  /// VAD gate fired pre-ASR — raw samples had no speech evidence
  /// (`TP:787` — "VAD gate: no speech detected, skipping ASR").
  case vadGate
  /// ASR returned empty text on a path where VAD did NOT firmly say speech
  /// (`TP:902` — "ASR empty (no speech detected)").
  case asrEmptyNoSpeech
  /// #1358: the limb chain produced no lexical content (a bare filler / non-
  /// speech artifact — the recognizer's whole output was a filler like "uh").
  /// The finalization wiring already delivered any recoverable deterministic
  /// floor as non-empty, so an empty result here is genuinely no-speech — end
  /// quietly instead of a `.failed(.emptyAfterProcessing)` heart-path capture
  /// (mirrors the #979 asr-empty Sentry downgrade).
  case emptyAfterProcessing
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
// periphery:ignore - test seam (thrown only by the test simulator)
enum KernelLimbError: Error, Sendable {
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
  private let store: @MainActor (_ text: String, _ transcriptID: UUID) async throws -> Void
  private let deliver: @MainActor (_ text: String) async -> KernelDeliveryOutcome

  // MARK: Wedge-detection tuning

  /// Logical-tick window of progress-signal silence (after the stream has
  /// armed with at least one tick) that the kernel treats as a cadence stall.
  /// Mirrors `LoadProgressWatcher`'s arm-then-silence shape (PR-1 §B.1.7) in
  /// the simulator's logical-tick time base — not a wall-clock deadline.
  private let wedgeStallTicks: Int

  /// Minimum logical-tick duration of a visible recording (PR-4.5 #4 — a
  /// 500 ms floor). A recording
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

  private let zombieZeroPeakTelemetry: @MainActor (ZeroPeakContext) -> Void
  private let recordingStoppedTelemetry: @MainActor (_ sampleCount: Int) -> Void
  private let markPipelineTimingStart: @MainActor () -> Void
  private let markASRTimingStart: @MainActor (_ streaming: Bool) -> Void
  private let markASRTimingEnd: @MainActor () -> Void
  private let telemetryState: KernelTelemetryState

  /// #1247: live read of the persisted Settings opt-in for the DEBUG-only
  /// dictation-audio archive (#1230). A closure (not a frozen `Bool`) so
  /// flipping the toggle off stops archiving on the VERY NEXT dictation, not
  /// only after a relaunch — cloud review (PR #1250) flagged the asymmetric
  /// risk of an off-flip silently continuing to save mic audio until quit.
  /// ORs with the `EW_KEEP_DICTATION_AUDIO` env var at the archive call site.
  private let dictationAudioArchiveOptInProvider: @MainActor () -> Bool

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

  /// Why the audio engine was interrupted for this session, or `nil` if no
  /// interruption reached the recording exit. Stamped by
  /// `externalEngineInterrupted(_:)` under its first-wins accept condition.
  /// The observer reads it at lifecycle-event mapping time so the sink captures
  /// the lost dictation for `.engineLost` only (issue #1174 A3).
  ///
  /// #1408: a non-nil cause NO LONGER implies the session reached
  /// `.audioInterrupted` — a salvageable interruption now falls through to the
  /// normal stop tail and can terminate `.completed`. Read-through to
  /// `KernelTelemetryState.interruptionCause`, the single home shared with the
  /// finalization wiring and the lifecycle sink; it is cleared there, in
  /// `resetForNewSession()`, which `start(config:)` calls before `.preparing`.
  var lastAudioInterruptionCause: EngineInterruptionCause? {
    telemetryState.interruptionCause
  }

  /// #1434: per-session stabilization outcome (set at the pre-capture
  /// stabilization site; nil until it runs). Read by
  /// `KernelHeartPathTelemetryObserver` at stall-emit time via
  /// `captureStabilizationTelemetry` and merged into the post-stop
  /// capture-health record.
  private var formatStabilizedThisSession: Bool?
  private var captureRebuiltForFormatThisSession: Bool?

  /// #1434: kernel-owned stabilization facts for telemetry enrichment. The
  /// stall event fires BEFORE `stopCapture()` (no stop metadata exists yet),
  /// so the observer reads these through the kernel instead of the private
  /// `telemetryState`.
  var captureStabilizationTelemetry: (formatStabilized: Bool?, rebuiltForFormat: Bool?) {
    (formatStabilizedThisSession, captureRebuiltForFormatThisSession)
  }

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
  // periphery:ignore - test seam (read only by the simulator)
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

  /// #1393: monotonic elapsed time since the current recording began, immune
  /// to wall-clock/timezone/NTP changes. Reuses `recordingStartedAtTick`
  /// above rather than adding a second monotonic authority — same stamp
  /// site, same clear site, same "visible-recording start" semantic the
  /// discard gate already relies on. Checked comparison, not wrapping
  /// subtraction: production `currentTick()` cannot realistically regress
  /// below `start` (monotonic `systemUptime`, same-process, non-decreasing
  /// quantization), but a broken or adversarially-injected clock should fail
  /// to `0` for this newly user-facing value, not silently wrap into a huge
  /// duration.
  var recordingElapsedSeconds: TimeInterval? {
    guard let start = recordingStartedAtTick else { return nil }
    let now = currentTick()
    guard now >= start else { return 0 }
    return TimeInterval(now - start) * KernelFinalizationWiring.tickDurationSeconds
  }

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

  /// Fired at most once per recording when the VAD seam reports the recording is
  /// approaching `maxRecordingDuration` (#1060), carrying the remaining seconds.
  /// ADVISORY: the kernel does NOT stop on this (that is the separate stop
  /// stream); it forwards a semantic event the driver maps to a UI banner. No
  /// user-facing copy lives here — copy stays in the App layer.
  var onApproachingMaxDuration: (@MainActor (TimeInterval) -> Void)?

  /// Low-cardinality reason the most recent recording stopped, set when the
  /// recording-exit latches and cleared at session start (#1060). Read by the
  /// driver to label the transcribing pill ("Recording ended, transcribing now"
  /// on `"max_duration"`) and by the App layer for `dictation.completed`
  /// telemetry (`stop_reason`). A reason string, never user content.
  private(set) var lastStopReason: String?

  /// Wall-clock length of the most recent recording in seconds (#1060), captured
  /// when the recording-exit latches and cleared at session start. LIVE metadata
  /// for `dictation.completed` (`recording_seconds`) — distinct from the
  /// processing-time `e2eSeconds`. Never persisted to the transcript.
  private(set) var lastRecordingDurationSeconds: Double?

  /// The resolved-route transports snapshotted at the `.recording` transition
  /// (#1376): the selected vs effective microphone transport, route reason, and
  /// input-selection mode this recording actually resolved. Read by the App
  /// layer for `dictation.completed`. Snapshotted (not read live at emit) so a
  /// mid-flight device change cannot tear the recorded value. Overwritten each
  /// session; never persisted.
  private(set) var lastResolvedRoute: ResolvedRouteTransports?
  /// #1434: non-nil when the most recent completion was a degraded-lead
  /// salvage — the winning trim in ms. Cleared with `lastStopReason` at the
  /// next `→ recording` transition (the App layer reads it at `.complete`).
  private(set) var lastSalvagedLeadTrimMs: Int?
  /// #1434: capture-health facts of the most recent recording, for the App
  /// layer's `dictation.completed` telemetry (mirrors `lastResolvedRoute`).
  private(set) var lastCaptureHealth: CaptureHealthTransports?

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

  /// Test-observation signal for the simulator's drain (companion to
  /// `workEpoch`). `true` only in the window between `deliverRecordingExit`
  /// latching an exit from `.recording` and the forward path consuming it and
  /// transitioning out of `.recording`. The exit delivery bumps `workEpoch`
  /// and resumes the forward-path continuation synchronously inside the
  /// triggering call — *before* the simulator's `drainReadyWork` starts — so
  /// that bump is absorbed and epoch-stability alone can falsely report
  /// quiescence while the resumed-but-not-yet-scheduled forward path still sits
  /// at `.recording`. The drain gates on this signal so it never settles mid
  /// hand-off (the recurring `interleavingSweep` `got recording` flake). No
  /// production reader — observation only.
  // periphery:ignore - test seam (simulator drain gate; no production reader)
  var hasUnconsumedRecordingExit: Bool {
    recordingExitLatched && state == .recording
  }

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
    store: @escaping @MainActor (_ text: String, _ transcriptID: UUID) async throws -> Void,
    deliver: @escaping @MainActor (_ text: String) async -> KernelDeliveryOutcome,
    wedgeStallTicks: Int = 2,
    minimumRecordingTicks: Int = 5,
    zombieZeroPeakTelemetry: @escaping @MainActor (ZeroPeakContext) -> Void = { _ in },
    recordingStoppedTelemetry: @escaping @MainActor (_ sampleCount: Int) -> Void = { _ in },
    markPipelineTimingStart: @escaping @MainActor () -> Void = {},
    markASRTimingStart: @escaping @MainActor (_ streaming: Bool) -> Void = { _ in },
    markASRTimingEnd: @escaping @MainActor () -> Void = {},
    telemetryState: KernelTelemetryState = KernelTelemetryState(),
    dictationAudioArchiveOptInProvider: @escaping @MainActor () -> Bool = { false }
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
    self.zombieZeroPeakTelemetry = zombieZeroPeakTelemetry
    self.recordingStoppedTelemetry = recordingStoppedTelemetry
    self.markPipelineTimingStart = markPipelineTimingStart
    self.markASRTimingStart = markASRTimingStart
    self.markASRTimingEnd = markASRTimingEnd
    self.telemetryState = telemetryState
    self.dictationAudioArchiveOptInProvider = dictationAudioArchiveOptInProvider
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
    // PR-5 Rung 2B (#827): best-effort cache-only preload. Awaited inline
    // (the contract says cheap; second-engine override walks the on-disk
    // model cache, Parakeet inherits the no-op default). `try?` because a
    // throw signals cache-only-preload failure, not full-warmup failure
    // (Rung 2A §4) — the spawned `warmUp()` below is the canonical path.
    //
    // No `cancelPendingUnload()` from preWarm (Codex code-diff r3 P2):
    // cancelling the idle-unload timer here would leak a loaded model when
    // PTT is abandoned (key-up between preWarm and start, or pre-warm
    // failure) — no session terminal fires to re-apply the unload policy,
    // and the model stays warm indefinitely. The cancel lands in
    // `runForwardPath` pre-beginSession only (single site, no PTT/toggle
    // divergence). Parakeet's existing `:192` cancelIdleTimer() inside
    // beginSession stays as the deepest defense-in-depth.
    try? await adapter.warmUpFromCache()
    // PR-5 Rung 2B post-await reentrancy guard: the cache-warm await
    // suspends the MainActor. While suspended, `start(config:)` can mint a
    // new session and cancel the prior sid's task bag; re-check before
    // spawning the heavy warmUp() and awaiting capture pre-warm, otherwise
    // this stale continuation would launch work against a session the
    // kernel has already moved past.
    guard isCurrent(sid), state == .idle || state.isTerminal else {
      log("preWarm aborted post-cache-warm sid=\(sid.raw) state=\(state)")
      return
    }
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
    let preWarmStart = ContinuousClock.now
    do {
      try await audioCapture.preWarm()
      log("preWarm audioCapture.preWarm succeeded sid=\(sid.raw)")
      // GAP 3 app.log parity: emit the OLD TP cold-start preWarm timing
      // (TP:317-321) so debug-mode log scans grep this exact prefix.
      let totalMs = Int((ContinuousClock.now - preWarmStart) / .milliseconds(1))
      Task {
        await AppLogger.shared.log(
          "COLD-START [\(adapter.engineIdentity.displayName)] preWarmAudioInput total=\(totalMs)ms",
          level: .info, category: "Pipeline"
        )
      }
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
    // GAP 2 of seam audit (TP:512-531): wait briefly for BT-codec format
    // stabilization, and rebuild the engine + retry once if it never
    // settled. Always running this is cheap on the PTT (warm) path —
    // `waitForFormatStabilization` returns near-instantly when format
    // is already settled (AudioCaptureManager:355 short-circuits when
    // there's no active source; per-source impls return on the first
    // poll once stable). The 1.5s/0.2s pair matches the existing
    // stabilization sites at AudioCaptureProxy:391 and
    // AudioCaptureManager:334 — re-using a value the codebase has
    // already shipped, not introducing a new arbitrary timeout.
    // Codex r1 on this fix flagged that gating the call on a "pre-warmed"
    // flag could survive an aborted preWarm and skip stabilization on
    // a later cold start; running unconditionally avoids that.
    let stabilized = await audioCapture.waitForFormatStabilization(
      maxWait: 1.5, pollInterval: 0.2)
    guard isCurrent(sid) else { return }
    // #1434/#1445: record the stabilization outcome for the session's
    // capture-health telemetry (read at stall-emit by the observer and merged
    // into the post-stop record at `stopCapture()`). Exactly ONE rebuild
    // attempt below; #1445 adds one diagnostic re-verify after that rebuild
    // (no second rebuild) so a rebuild that re-read a still-stale rate is
    // visible in telemetry instead of being blindly trusted. A still-broken
    // device is owned by the stall watchdog / ASR-empty paths downstream.
    formatStabilizedThisSession = stabilized
    captureRebuiltForFormatThisSession = !stabilized
    if !stabilized {
      audioCapture.rebuildEngine()
      do {
        try await audioCapture.startEnginePhase()
      } catch {
        guard isCurrent(sid) else { return }
        telemetryState.captureFailureError = error
        finishTerminal(.failed(classifyCaptureStartError(error)), sid: sid)
        return
      }
      guard isCurrent(sid) else { return }
      // #1445: re-verify stabilization ONCE after the single rebuild. This is
      // DIAGNOSTIC only — it records the truer post-rebuild outcome for
      // capture-health telemetry (previously the pre-rebuild `false` was
      // trusted blindly). A still-`false` result does NOT trigger a second
      // rebuild or a new terminal; `captureRebuiltForFormatThisSession` stays
      // true so a rebuild remains visible. Control then falls through to the
      // existing stop/cancel latch checks below, which remain the cancel
      // authority.
      //
      // NEAR-INSTANT budget (Codex code-diff P2): because the result is
      // never acted on and capture proceeds regardless, this must NOT re-pay
      // the full 1.5s stabilization budget on the exact affected-device path.
      // A 50 ms snapshot (fast-path read + at most one short poll) captures
      // "did the rebuild settle it" without adding heart-path PTT latency.
      let reverified = await audioCapture.waitForFormatStabilization(
        maxWait: 0.05, pollInterval: 0.05)
      guard isCurrent(sid) else { return }
      formatStabilizedThisSession = reverified
    }
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
    // PR-5 Rung 2B (#827): single kernel-side timer-cancel point, fired
    // immediately before adapter.beginSession. Parakeet's existing :192
    // cancelIdleTimer() inside beginSession stays as defense-in-depth at
    // the adapter level (idempotent per Rung 2A §4).
    //
    // Aborted-session caveat (Codex code-diff r4 P2): if this session
    // ends without a transcript (cancel / no-speech / too-short / failed),
    // `finishTerminal` skips `applyUnloadPolicy` because
    // `transcriptReadyForDelivery` is false — the cancelled timer is not
    // re-armed. For Parakeet today this is the EXISTING pattern (Parakeet
    // already cancels the timer inside its own beginSession on every
    // session, no behavior change). A future Rung 3 adapter that wants
    // unload-timer continuity across aborted sessions MUST re-arm in its
    // own beginSession/cancel/finalize implementation; the kernel does
    // not guarantee re-arming.
    adapter.cancelPendingUnload()
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
      // Forward the opaque crash-recovery directive (nil unless armed) to the
      // helper. The kernel never interprets it — recovery is a limb (#1063 PR1).
      _ = try await audioCapture.beginCapturePhase(recoveryPayload: config.recoveryPayload)
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
    lastStopReason = nil  // #1060: clear prior session's stop reason.
    lastSalvagedLeadTrimMs = nil  // #1434: clear prior session's salvage marker.
    lastCaptureHealth = nil  // #1434: clear prior session's capture health.
    lastRecordingDurationSeconds = nil
    // #1376: snapshot the resolved route AFTER all start retries (this
    // transition is downstream of every startEnginePhase/beginCapturePhase
    // path) so the recorded value reflects the FINAL resolved route.
    lastResolvedRoute = audioCapture.currentResolvedRoute
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
      // #1408: the device died mid-recording. If the capture manager is still
      // alive and holding `capturedSamples`, fall through into the normal stop
      // tail and transcribe what we have — salvage inherits the min-duration
      // gate, VAD finalize, soft-onset preservation, energetic-tail recovery,
      // degraded-lead retry and conditioning for free (plan §3.2). Only
      // `.xpcConnectionLost` (the helper that OWNED the samples is gone) still
      // fails honestly; the crash-recovery spool owns that case. `nil` cause →
      // `false` by optional chaining, so an unstamped interruption fails closed.
      guard lastAudioInterruptionCause?.hasRecoverableAudio == true else {
        if lastAudioInterruptionCause == nil {
          log("audio interruption exit with no stamped cause — refusing salvage")
        }
        finishTerminal(.audioInterrupted, sid: sid)
        return
      }
      break
    case .asrInterruption:
      finishTerminal(.asrInterrupted, sid: sid)
      return
    case .captureStall:
      finishTerminal(.failed(.captureStalled), sid: sid)
      return
    case .userStop, .vadAutoStop, .maxDuration:
      break
    }

    // PR-5 Rung 4.5 (#827): LID perf signpost `t_release` — fires on every
    // accepted-stop reason (manual, VAD-auto-stop, max-duration cap) so
    // perf-trace joining works across all session-ending paths. OLD WK
    // emitted from `requestStop` only (`WhisperKitPipeline.swift:551-552`);
    // the unified kernel transition is the symmetric, complete site.
    // Gated on engine capability (LID support) — Parakeet has no LID and
    // does not emit this signpost.
    if adapter.capabilities.supportsLanguageDetection {
      emitLIDReleaseSignpost(sessionID: audioCapture.currentCaptureSessionID)
    }

    // Stopping. The `stopping` path owns the capture stop: marking
    // `.stopping` before the await tells a concurrent `finishTerminal`
    // (a cancel landing mid-stop) not to fire a second, racing stop — it
    // waits for this one. `resourcesReleased` flips true once the stop
    // genuinely completes, even if the session went terminal meanwhile.
    // #1408: on a SALVAGED interruption this is the SECOND freeze — the first ran
    // in `externalEngineInterrupted` before the exit was delivered. Re-freezing is
    // safe: `currentAudioRoute` derives from `lastRouteDecision`, frozen at
    // capture-resolve time and never re-resolved by a mid-recording device death,
    // so both freezes record the SAME pre-disconnect route. Only `durationMs`
    // advances, by the microseconds between the interrupt and here, which is the
    // truer figure anyway (audio kept arriving until `stopCapture()` below).
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
    // #1434: stamp the ONE capture-health record NOW — before the too-short /
    // no-audio / dead-air early terminals below — so no-audio, asrEmpty, and
    // completed all read the same record (Codex r2 ordering contract).
    telemetryState.captureHealth = KernelCaptureHealthTelemetry(
      stopMetadata: captureResult.metadata,
      formatStabilized: formatStabilizedThisSession,
      captureRebuiltForFormat: captureRebuiltForFormatThisSession
    )
    lastCaptureHealth = CaptureHealthTransports(
      nativeRateHz: captureResult.metadata?.nativeRateHz,
      ringDropCount: captureResult.metadata?.ringDropCount,
      converterErrorCount: captureResult.metadata?.converterErrorCount,
      zeroOutputCount: captureResult.metadata?.zeroOutputCount,
      rateDivergenceDetected: captureResult.metadata?.rateDivergenceDetected,
      formatStabilized: formatStabilizedThisSession,
      captureRebuiltForFormat: captureRebuiltForFormatThisSession
    )
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
      // PR-5 Rung 5 Pass 2 #5: app.log line for sub-minimum discard so
      // debug-build readers can grep app.log for the tap-too-short
      // signature (parity with OLD `WhisperKitPipeline.swift:578-595`,
      // also covers Parakeet's path — kernel-level so backend-agnostic).
      let cnt = captureResult.samples.count
      let buffers = bufferCountThisSession
      Task {
        await AppLogger.shared.log(
          "Recording discarded — too short "
            + "(samples=\(cnt), elapsedSubMinimum=\(elapsedSubMinimum), "
            + "buffers=\(buffers))",
          level: .info, category: "Pipeline"
        )
      }
      discardReason = .tooShort
      finishTerminal(.discarded, sid: sid)
      return
    }
    if captureResult.samples.isEmpty {
      finishTerminal(.failed(.noAudioCaptured), sid: sid)
      return
    }

    // GAP 3 app.log parity: captured-sample-count log (TP:725-729) —
    // gives debug-mode log readers the duration of the visible recording
    // before any VAD / conditioning runs.
    let capturedSampleCount = captureResult.samples.count
    Task {
      await AppLogger.shared.log(
        "Captured \(capturedSampleCount) samples "
          + "(\(String(format: "%.2f", Double(capturedSampleCount) / 16000))s)",
        level: .verbose, category: "Pipeline"
      )
    }

    // VAD no-speech gate (PR-1 §B.6) — keys on *confirmed* no-speech.
    // #964: `.confirmedNoSpeech` means Silero found zero speech segments, which
    // also swallows faint/whispered speech sitting below Silero's 0.5 threshold.
    // Skip ASR only when the raw buffer is ALSO dead air; otherwise fall through
    // and let Parakeet arbitrate (it returns empty on real silence/room noise —
    // verified on synthetic probes plus 65 competitor whisper clips).
    let speechEvidence = vad.speechEvidenceAtStop()
    // Set when we proceed to ASR despite zero VAD segments purely because raw
    // energy beat the dead-air floor — used below to map an empty decode back to
    // a quiet `.noSpeech` instead of a user-visible ASR failure (#964 R2).
    var attemptedFromEnergyDespiteNoSegments = false
    if speechEvidence == .confirmedNoSpeech {
      if Self.rawAudioIsDeadAir(captureResult.samples, peak: rawPeakAudioLevel) {
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
        // GAP 3 app.log parity: emit the VAD filtered log here too — for
        // dead-air `.confirmedNoSpeech`, conditioner never runs (we return
        // below), so the filtered count is 0 by definition. Without this, the
        // no-speech path is missing one of the OLD TP debug lines (TP:772
        // emitted before TP:800's no-speech gate). Codex r1 (P3) on GAP 3.
        Task {
          await AppLogger.shared.log(
            "VAD filtered to 0 samples (0.0% voiced)",
            level: .verbose, category: "Pipeline"
          )
        }
        // GAP 3 app.log parity: VAD-gate skip log (TP:800-804) — gives debug
        // log readers a clear marker for "user pressed without speaking."
        let peak = rawPeakAudioLevel
        let cnt = capturedSampleCount
        Task {
          await AppLogger.shared.log(
            "VAD gate: no speech, skipping ASR "
              + "(samples=\(cnt), peak=\(String(format: "%.4f", peak)))",
            level: .info, category: "Pipeline"
          )
        }
        finishTerminal(.noSpeech, sid: sid)
        return
      }
      // Faint speech: zero VAD segments but raw energy above the dead-air floor.
      // Recover it by transcribing instead of dropping. With zero segments the
      // conditioner returns the raw buffer unchanged (SampleFilter early-out),
      // so Parakeet decodes the full capture.
      attemptedFromEnergyDespiteNoSegments = true
      let peak = rawPeakAudioLevel
      let cnt = capturedSampleCount
      Task {
        await AppLogger.shared.log(
          "VAD gate: zero segments but raw energy above dead-air floor — "
            + "transcribing to recover faint speech "
            + "(samples=\(cnt), peak=\(String(format: "%.4f", peak)))",
          level: .info, category: "Pipeline"
        )
      }
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
    // PR-5 Rung 2B (#827): push the kernel-computed VAD speech segments to
    // the adapter at finalize-time, BEFORE the kernel-side conditioning
    // runs. The second engine (Rung 3) derives engine-specific decode
    // parameters (clipTimestamps) from these; the first engine inherits
    // the no-op default. Sync, must-not-throw, must-not-block (Rung 2A §4).
    //
    // Coordinate space contract (Codex code-diff r4 P2 + PR-5 Rung 5 UAT
    // #827): segments are indexed into `captureResult.samples` (raw capture
    // audio), NOT into the VAD-filtered `conditioned.samples` the adapter
    // receives in `finalize(batchSamples:)` immediately after. The kernel
    // hands the adapter the raw `captureResult.samples` alongside the segments
    // so a clipTimestamps adapter (WhisperKit) batch-decodes the SAME buffer
    // the segments index into — eliminating the shadow-`retainedPCM`
    // divergence that caused the alternating "Audio samples are nil" failure.
    // Adapters that use engine-internal VAD chunking or do not consume
    // segments inherit the no-op default and ignore both.
    //
    // Post-finalizeAtStop guard (Codex code-diff r2 P2): the prior
    // `finalizeAtStop(...)` await at :908 is a suspension point; if cancel
    // or external interruption lands during that await, the kernel can be
    // terminal here. The Rung 2A §4 contract says
    // `observeSpeechSegments(_:rawCaptureSamples:)` fires BEFORE
    // `finalize(batchSamples:)` — a terminal session skips finalize, so it
    // must skip observe too, otherwise a future engine that stores observed
    // segments for use in finalize would see them and apply them to the
    // next session.
    guard isCurrent(sid), !state.isTerminal else { return }
    adapter.observeSpeechSegments(
      vadSegments, rawCaptureSamples: captureResult.samples)
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

    // #950 tail-trim diagnostic. Eligible = the engine decodes the conditioned
    // (VAD-trimmed) batch buffer (Parakeet, via capability) AND this is a batch
    // session; only then does "trailing audio the VAD trim dropped before ASR"
    // mean anything (WhisperKit decodes the raw capture, so the trim does not
    // touch its ASR input). Metadata only; never gates the heart path.
    let tailEligible =
      adapter.capabilities.decodesConditionedBatchSamples && !isStreamingSession
    let droppedTailSamples = tailEligible ? conditioned.droppedTailSampleCount : 0
    // Always set (incl. 0) for eligible batch so the analytics denominator holds;
    // nil (omitted) for streaming / non-conditioned-batch engines.
    let tailDroppedMs: Int? = tailEligible ? droppedTailSamples / 16 : nil
    var tailHadEnergy: Bool? = nil
    var tailPeak: Float = 0
    // #950 tail-preserve: hoist the dropped-tail slice to outer scope — the
    // energy check (below), the sustained-voice gate, and the recovery append all
    // read it. `Array(...)` rebases the slice to the 0-based indexing the window
    // scans assume; materialized ONCE on the cold stop path (not the RT audio
    // thread); sync, cannot throw; empty when nothing was dropped.
    let tailSlice: [Float] =
      droppedTailSamples > 0
      ? Array(captureResult.samples.suffix(droppedTailSamples)) : []
    if droppedTailSamples > 0 {
      tailPeak = tailSlice.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
      tailHadEnergy = !Self.rawAudioIsDeadAir(tailSlice, peak: tailPeak)
    }
    // #950 tail-preserve. Decide once; the outcome carries the refusal reason for
    // tuning telemetry. The heart path is byte-identical to before unless a
    // sustained-voice dropped tail (eligible "filtered" path, in [400,8000]ms,
    // >= 50% voiced) fires the recovery branch. `tailVoicedFraction` is the
    // hallucination guard: a single desk-thump / keyboard transient tiles to a
    // low fraction and is refused before it ever reaches ASR.
    let tailFraction = droppedTailSamples > 0 ? Self.tailVoicedFraction(tailSlice) : 0
    let tailDecision = Self.tailPreserveDecision(
      tailEligible: tailEligible,
      conditioningReason: conditioned.conditioningReason,
      droppedTailSamples: droppedTailSamples,
      droppedTailMs: tailDroppedMs ?? 0,
      voicedFraction: tailFraction)
    let asrSamples: [Float]
    var recoveredTailMs: Int? = nil
    // nil when ineligible (engine/streaming); a real Bool on the eligible path so
    // `false` is a valid false-fire-rate denominator.
    var usedTailPreservation: Bool? = tailEligible ? false : nil
    // Tuning signals (#950 founder upgrade): voiced fraction surfaced whenever a
    // tail was measured; refusal reason set only on the eligible-but-refused path.
    let tailVoicedFractionForTelemetry: Double? =
      (tailEligible && droppedTailSamples > 0) ? tailFraction : nil
    var tailRefusedReason: String? = nil
    switch tailDecision {
    case .preserve:
      // Contiguous: `tailSlice == raw[keptThrough..<rawCount]`, the exact region
      // the trim discarded, appended immediately after the filtered buffer.
      asrSamples = conditioned.samples + tailSlice
      recoveredTailMs = tailDroppedMs
      usedTailPreservation = true
    case .refuse(let reason):
      asrSamples = conditioned.samples
      tailRefusedReason = reason
    case .notEvaluated:
      asrSamples = conditioned.samples
    }
    // GAP 3 app.log parity: VAD filter ratio log (TP:772-776).
    let rawCount = captureResult.samples.count
    let filteredCount = conditioned.filteredSampleCount
    Task {
      await AppLogger.shared.log(
        "VAD filtered to \(filteredCount) samples "
          + "(\(String(format: "%.1f", Double(filteredCount) / Double(max(rawCount, 1)) * 100))% voiced)",
        level: .verbose, category: "Pipeline"
      )
    }
    // PR-5 Rung 5 Pass 2 #6: success-path VAD detail log restoring the
    // OLD `WhisperKitPipeline.swift:643-680` shape — segment count,
    // voiced milliseconds, voiced percentage. Lets a debug-build reader
    // grep app.log for one richer line per recording instead of stitching
    // the verbose-level filter ratio with the conditioner log.
    let segCount = vadSegments.count
    let voicedMs = vadSpeechDurationMs
    let voicedPct =
      rawCount > 0
      ? String(format: "%.1f", Double(filteredCount) / Double(rawCount) * 100)
      : "0.0"
    Task {
      await AppLogger.shared.log(
        "VAD detail: segments=\(segCount), voicedMs=\(voicedMs), "
          + "rawSamples=\(rawCount), filteredSamples=\(filteredCount), "
          + "voicedPct=\(voicedPct)%",
        level: .info, category: "Pipeline"
      )
    }
    telemetryState.asrEmptyDiagnostics = ASREmptyResultDiagnostics(
      backend: adapter.engineIdentity.rawValue,
      mode: isStreamingSession ? "streaming" : "batch",
      hasSpeechEvidence: speechEvidence != .confirmedNoSpeech,
      rawSampleCount: captureResult.samples.count,
      vadSegmentCount: vadSegments.count,
      vadSpeechDurationMs: vadSpeechDurationMs,
      peakAudioLevel: rawPeakAudioLevel,
      vadFilteredSampleCount: conditioned.filteredSampleCount,
      // #950: report the buffer ACTUALLY fed to ASR (filtered + recovered tail
      // when preservation fired), so an asr-empty diagnostic matches the decode.
      // `vadFilteredSampleCount` above stays the conditioner's own count.
      finalSampleCount: asrSamples.count,
      samplesPaddedToMinimum: conditioned.samplesPaddedToMinimum,
      usedRawFallbackAfterVAD: conditioned.usedRawFallbackAfterVAD,
      usedRawSoftOnsetPreservation: conditioned.usedRawSoftOnsetPreservation,
      speechSegments: vadSegments
    )
    // PR-4.5 §8 metadata-only telemetry: sample counts + booleans, no audio
    // content. Lets a future "single-word transcription failed" triage tell
    // whether VAD filtering swallowed the speech (filteredSampleCount low),
    // raw fallback engaged (usedRawFallbackAfterVAD), or padding extended a
    // genuinely short utterance.
    log(
      "conditioner raw=\(captureResult.samples.count) filtered=\(conditioned.filteredSampleCount) "
        + "rawFallback=\(conditioned.usedRawFallbackAfterVAD) softOnset=\(conditioned.usedRawSoftOnsetPreservation) "
        + "padded=\(conditioned.samplesPaddedToMinimum) reason=\(conditioned.conditioningReason) "
        + "final=\(conditioned.finalSampleCount) "
        // #950 tail-trim diagnostic — sid for dogfood correlation, capturedMs to
        // surface flush-loss (short capture + droppedTailMs=0), and the tail peak
        // float (debug-log only, never analytics — privacy boundary).
        + "sid=\(sid.raw) capturedMs=\(captureResult.samples.count / 16) "
        + "droppedTailMs=\(tailDroppedMs.map(String.init) ?? "n/a") "
        + "tailEnergy=\(tailHadEnergy.map(String.init) ?? "n/a") "
        + "tailPeak=\(String(format: "%.4f", tailPeak)) "
        // #950 tail-preserve outcome: did the recovery fire, how much it rescued,
        // the sustained-voice fraction, and (when refused) why. Debug-log only.
        + "tailPreserved=\(usedTailPreservation.map(String.init) ?? "n/a") "
        + "recoveredTailMs=\(recoveredTailMs.map(String.init) ?? "n/a") "
        + "voicedFraction=\(tailVoicedFractionForTelemetry.map { String(format: "%.2f", $0) } ?? "n/a") "
        + "refusedReason=\(tailRefusedReason ?? "n/a")")

    // Transcribing.
    let asrStart = CFAbsoluteTimeGetCurrent()
    markASRTimingStart(isStreamingSession)
    transition(to: .transcribing)
    let outcome = await finalize(sid, batchSamples: asrSamples)
    guard isCurrent(sid), !state.isTerminal else { return }
    let asrEnd = CFAbsoluteTimeGetCurrent()
    markASRTimingEnd()

    // #1230 — one id minted here, before the outcome switch, so it (a) names the
    // debug audio-archive folder for EVERY post-decode outcome and (b) is
    // threaded through `runFinalizing` → `store` → `Transcript(id:)` on the
    // `.transcript` path, making the History entry id == the archive folder name.
    let transcriptID = UUID()
    // #1230 archive metadata collected across the switch cases, read once by the
    // single archive call after it. Setting these is data collection, not a
    // second archive site (mirrors how `telemetryState` is stamped per case).
    // DEBUG-only: the archive that reads them is DEBUG-only, so gating here keeps
    // the release build free of write-only-variable warnings.
    #if DEBUG
      var archiveClassification = "notEvaluated"
      var archiveSpeechEvidence = false
      // #1434: effective archive inputs. Default to the primary decode's
      // values; the salvage-success path rebinds them so the archive labels
      // and replays the SALVAGED delivery (Codex r2 rev 3).
      var archiveEffectiveOutcome = outcome
      var salvageArchiveFed: [Float]? = nil
    #endif

    switch outcome {
    case .transcript(let result):
      // PR-5 Rung 5 Pass 2 #8 — `result.processingTime` is the adapter's
      // pure decode duration (started AFTER LID at
      // `WhisperKitEngineAdapter.swift:630`); `asrEnd - asrStart` would
      // include LID and break parity with OLD
      // `WhisperKitPipeline.swift:1161-1168` `asr_s` semantic. Sentry/app.log
      // ASR-completed payload reads this field; PostHog latency telemetry
      // is already adapter-emitted and unaffected.
      // #1232 tail-clip diagnostics. Pure compute from signals already in hand;
      // never alters delivery. `asrSamples` is the authoritative decoded buffer
      // (the token timings come from decoding IT) in two cases: an eligible
      // Parakeet batch session, OR a streaming session whose finalize fell back
      // to the batch rescue — the rescue decodes the conditioned `asrSamples`, so
      // its tokens map onto that timeline (Codex P2). Streaming that returned
      // text from the live feed, and WhisperKit (decodes its own raw buffer), are
      // NOT authoritative. In every authoritative case padding would inflate the
      // gap, so require unpadded (Codex r4).
      let cameFromBatchRescue =
        adapter.capabilities.decodesConditionedBatchSamples
        && (adapter as? ASREngineTelemetryProviding)?
          .lastASRDiagnostics?.batchRescueAttempted == true
      // The token gap is trustworthy ONLY when the decoded buffer was the VAD-trimmed
      // SPEECH buffer. Every raw-fed path (too-aggressive raw fallback, soft-onset raw
      // preservation, padding, or a SampleFilter no-op on empty/sub-threshold segments)
      // leaves raw trailing silence/noise, so the gap would mislabel a normal dictation
      // as a drop (cloud + local Codex P2, #1238). Pass nil there so the classifier
      // sees no gap and returns .unknown.
      let decodedTailVadConfirmed = TailClipDiagnostics.decodedTailIsVadConfirmed(
        usedRawFallbackAfterVAD: conditioned.usedRawFallbackAfterVAD,
        usedRawSoftOnsetPreservation: conditioned.usedRawSoftOnsetPreservation,
        samplesPaddedToMinimum: conditioned.samplesPaddedToMinimum,
        filteredSampleCount: conditioned.filteredSampleCount,
        rawSampleCount: captureResult.samples.count)
      let decodedInputAuthoritative =
        (tailEligible || cameFromBatchRescue) && decodedTailVadConfirmed
      let decodedInputCount = decodedInputAuthoritative ? asrSamples.count : nil
      let tailClip = TailClipDiagnostics.compute(
        rawSamples: captureResult.samples,
        vadSegments: vadSegments,
        decodedInputSampleCount: decodedInputCount,
        lastTokenEndMs: result.tokenTimingSummary?.lastTokenEndMs)
      let adapterDiag = (adapter as? ASREngineTelemetryProviding)?.lastASRDiagnostics
      telemetryState.asrCompletedTelemetry = KernelASRCompletedTelemetry(
        durationSeconds: result.processingTime,
        charCount: result.text.trimmingCharacters(in: .whitespacesAndNewlines).count,
        mode: isStreamingSession ? "streaming" : "batch",
        language: result.language,
        // PR-5 Rung 5 Pass 2 r2 #B1: carry the incremental-vs-batch outcome into
        // the ASR-completed Sentry breadcrumb (parity with OLD
        // `WhisperKitPipeline.swift:1049-1052`). nil for Parakeet.
        incrementalAccepted: adapterDiag?.incrementalAccepted,
        // #950 tail-trim diagnostic (eligible Parakeet batch only; nil omitted).
        droppedTailMs: tailDroppedMs,
        tailHadEnergy: tailHadEnergy,
        // #950 tail-preserve recovery + tuning signals.
        usedTailPreservation: usedTailPreservation,
        recoveredTailMs: recoveredTailMs,
        tailVoicedFraction: tailVoicedFractionForTelemetry,
        tailRefusedReason: tailRefusedReason,
        tailClipClassification: tailClip.classification.rawValue,
        captureTrailingSilenceMs: tailClip.trailingSilenceMs,
        captureTail200Rms: Double(tailClip.tail200RMS),
        captureTail200Peak: Double(tailClip.tail200Peak),
        asrInputDurationMs: tailClip.asrInputDurationMs,
        asrLastTokenEndMs: tailClip.asrLastTokenEndMs,
        asrLastTokenGapMs: tailClip.asrLastTokenGapMs,
        asrChunked: tailClip.asrChunked,
        // #1309 effective-path streaming telemetry. Requested comes from the
        // kernel's own capability gate; effective/degrade/path from the
        // adapter's diagnostics. WhisperKit-only (nil for Parakeet → omitted).
        streamingRequested: adapterDiag?.streamingEffective != nil ? isStreamingSession : nil,
        streamingEffective: adapterDiag?.streamingEffective,
        streamingDegradeReason: adapterDiag?.streamingDegradeReason,
        streamingFinalPath: adapterDiag?.streamingFinalPath,
        streamingDecodeCount: adapterDiag?.incrementalDecodeCount,
        streamingCoveredSec: adapterDiag?.incrementalSamplesCovered.map {
          Double($0) / AudioConstants.sampleRate
        },
        tailDecodeSec: adapterDiag?.incrementalTailDecodeMs.map { Double($0) / 1000.0 },
        maxUnconfirmedWindowSec: adapterDiag?.streamingMaxUnconfirmedWindowSec,
        stopWhileDecodeInFlight: adapterDiag?.stopWhileDecodeInFlight
      )
      // #1232 debug-log line: the per-dictation tail-clip verdict + lead signals,
      // greppable in app.log next to the conditioner line for live triage.
      log(
        "tailclip class=\(tailClip.classification.rawValue) "
          + "trailingSilenceMs=\(tailClip.trailingSilenceMs.map(String.init) ?? "n/a") "
          + "tail200Peak=\(String(format: "%.4f", tailClip.tail200Peak)) "
          + "tail200Rms=\(String(format: "%.4f", tailClip.tail200RMS)) "
          + "asrInputMs=\(tailClip.asrInputDurationMs.map(String.init) ?? "n/a") "
          + "lastTokenEndMs=\(tailClip.asrLastTokenEndMs.map(String.init) ?? "n/a") "
          + "tokenGapMs=\(tailClip.asrLastTokenGapMs.map(String.init) ?? "n/a") "
          + "chunked=\(tailClip.asrChunked.map(String.init) ?? "n/a")")
      // #1230 — the tail-clip verdict is the diagnostic key for a clipped take.
      #if DEBUG
        archiveClassification = tailClip.classification.rawValue
      #endif
      await runFinalizing(sid, asrText: result.text, transcriptID: transcriptID)
    case .empty(let hadSpeechEvidence):
      mergeAdapterDiagnosticsIntoASREmpty()
      stampCaptureHealthIntoASREmptyDiagnostics()
      // #964 R2: if we reached ASR only because raw energy beat the dead-air
      // floor despite zero VAD segments, an empty decode means fan/room noise —
      // not a failed transcription. Route it to the quiet `.noSpeech` terminal,
      // never the user-visible `.failed(.asrEmpty)` error. The adapter reports
      // `hadSpeechEvidence: true` (it saw samples); the kernel knows the
      // segments were empty, so it owns the final routing decision.
      let effectiveSpeechEvidence =
        hadSpeechEvidence && !attemptedFromEnergyDespiteNoSegments
      // #1230 — distinguishes the asrEmpty vs noSpeech archive label; the audio
      // is saved by the single post-switch archive call (no per-terminal dump).
      #if DEBUG
        archiveSpeechEvidence = effectiveSpeechEvidence
      #endif
      // #1434 degraded-lead salvage ladder. Runs ONLY where today's outcome is
      // the user-visible asrEmpty failure: real speech evidence (the #964
      // energy-only path keeps its quiet noSpeech routing), batch mode, and a
      // conditioned-batch engine (capability gate — WhisperKit's finalize
      // decodes its own retained buffer, so the trimmed-batchSamples retry
      // seam doesn't exist there). A Bluetooth link that is settling can
      // poison the first 1-2 s and collapse the whole TDT decode; retrying
      // at ascending trim candidates recovers the rest (offline-proven on
      // the archived failures).
      var salvageDelivered = false
      if effectiveSpeechEvidence, !isStreamingSession,
        adapter.capabilities.decodesConditionedBatchSamples, !asrSamples.isEmpty
      {
        let salvageAttemptResult = await attemptDegradedLeadSalvage(sid, samples: asrSamples)
        // #1434 cloud review: the ladder's retry decode(s) run AFTER the
        // line-1376 markASRTimingEnd() call for the (empty) primary decode,
        // so a salvaged completion needs its own, later stamp — otherwise
        // pipeline.completed's asr_s and the timing logs record only the
        // primary decode's time, making the retry work invisible in
        // latency telemetry for exactly the recoveries this path exists
        // for. Idempotent: outcome.asrEndedAtSeconds is a plain overwrite.
        markASRTimingEnd()
        if let salvaged = salvageAttemptResult {
          guard isCurrent(sid), !state.isTerminal else { return }
          let trimMs = salvaged.trimSamples * 1000 / Int(AudioConstants.sampleRate)
          lastSalvagedLeadTrimMs = trimMs
          var completed = KernelASRCompletedTelemetry(
            durationSeconds: salvaged.result.processingTime,
            charCount: salvaged.result.text
              .trimmingCharacters(in: .whitespacesAndNewlines).count,
            mode: "batch",
            language: salvaged.result.language)
          completed.salvageAttempted = true
          completed.salvageCandidateCount = salvaged.candidateCount
          completed.salvageSucceededAtTrimMs = trimMs
          completed.salvageRemainingAudioMs =
            (asrSamples.count - salvaged.trimSamples) * 1000 / Int(AudioConstants.sampleRate)
          telemetryState.asrCompletedTelemetry = completed
          #if DEBUG
            // Effective archive inputs (Codex r2 rev 3 / grounded r1 rev 3):
            // the post-switch archive must label + replay the SALVAGED
            // delivery, not the primary empty outcome.
            archiveClassification = "salvagedLeadTrim(trimMs=\(trimMs))"
            archiveEffectiveOutcome = .transcript(salvaged.result)
            salvageArchiveFed = Array(asrSamples[salvaged.trimSamples...])
          #endif
          await runFinalizing(sid, asrText: salvaged.result.text, transcriptID: transcriptID)
          salvageDelivered = true
        } else {
          // The ladder awaited — a supersede/cancel during it owns the session.
          guard isCurrent(sid), !state.isTerminal else { return }
        }
      }
      if !salvageDelivered {
        if !effectiveSpeechEvidence {
          // Stamp BEFORE the transition so the observer reads the source
          // at `.noSpeech` mapping time (PR-4b.2 §3.6 r7).
          lastNoSpeechSource = .asrEmptyNoSpeech
          telemetryState.noSpeechTelemetry = KernelNoSpeechTelemetry(
            mode: isStreamingSession ? "streaming" : "batch",
            rawSampleCount: captureResult.samples.count,
            peakAudioLevel: rawPeakAudioLevel
          )
          // GAP 3 app.log parity: no-speech-no-evidence log (TP:911-915).
          Task {
            await AppLogger.shared.log(
              "No speech detected, returning to idle",
              level: .info, category: "Pipeline"
            )
          }
        } else {
          // GAP 3 app.log parity: ASR-empty-despite-evidence log (TP:894-898).
          let segs = vadSegments.count
          let speechMs = vadSpeechDurationMs
          let peak = rawPeakAudioLevel
          Task {
            await AppLogger.shared.log(
              "ASR empty despite speech evidence "
                + "(segments=\(segs), speechMs=\(speechMs), peak=\(peak))",
              level: .info, category: "Pipeline"
            )
          }
        }
        finishTerminal(
          effectiveSpeechEvidence ? .failed(.asrEmpty) : .noSpeech, sid: sid)
      }
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

    // #1230 — the single dictation-audio archive call. Runs AFTER the outcome
    // switch (so delivery on the `.transcript` path has already happened) and
    // for EVERY post-decode outcome (the switch above is exhaustive over
    // `ASREngineOutcome`), guarded only by "raw samples present." Pre-decode
    // terminals return before this point and are correctly never archived. The
    // actual file IO runs in a detached, failure-isolated task off the kernel's
    // actor — nothing here touches the heart path's latency.
    #if DEBUG
      if !captureResult.samples.isEmpty {
        let archiveID = transcriptID
        let archiveSid = sid.raw.uuidString
        let archiveRaw = captureResult.samples
        // What the engine ACTUALLY decoded, so the #1237 chunk replay is faithful
        // (Codex r6). `asrSamples` (the conditioned batch buffer) is the decode
        // input ONLY for a conditioned-batch decode — a batch session or a
        // streaming session that fell to batch rescue. A streaming WIN decoded the
        // raw live feed (`acceptAudio` forwards `captureResult.samples`, not the
        // conditioned buffer — :1150-1163 / :1878), so raw.wav is authoritative and
        // there is no distinct fed buffer. WhisperKit always decodes the raw
        // capture padded to the transcription minimum.
        let decodesConditionedBatch = adapter.capabilities.decodesConditionedBatchSamples
        let cameFromBatchRescue =
          decodesConditionedBatch
          && (adapter as? ASREngineTelemetryProviding)?
            .lastASRDiagnostics?.batchRescueAttempted == true
        let archiveFed: [Float]
        if let salvageArchiveFed {
          // #1434: a salvaged delivery decoded the TRIMMED buffer — archive
          // that, so the #1237 chunk replay is faithful to what the engine
          // actually transcribed.
          archiveFed = salvageArchiveFed
        } else if Self.dictationFedUsesBatchBuffer(
          decodesConditionedBatch: decodesConditionedBatch,
          isStreaming: isStreamingSession,
          cameFromBatchRescue: cameFromBatchRescue)
        {
          archiveFed = asrSamples
        } else if decodesConditionedBatch {
          archiveFed = []  // streaming win: raw.wav is the decoded audio
        } else {
          archiveFed = WhisperKitPipelineSpeechRouting.paddedASRSamples(
            rawSamples: captureResult.samples,
            minimumSamples: AudioConstants.minimumTranscriptionSamples)
        }
        // #1434: label from the EFFECTIVE outcome (the salvage path rebinds it
        // to the retry's `.transcript`), never the primary `.empty`.
        // A `.transcript` decode whose finalization did NOT reach `.completed`
        // is not a real completion — relabel so it stays distinct in the archive
        // metadata (Codex r6 P3). `runFinalizing` has already run by here, so
        // `state` holds the terminal verdict. #1434: applies to salvaged
        // deliveries too via the effective outcome.
        let archiveOutcome = Self.relabeledArchiveOutcome(
          base: Self.dictationArchiveOutcome(
            for: archiveEffectiveOutcome, effectiveSpeechEvidence: archiveSpeechEvidence),
          effectiveOutcome: archiveEffectiveOutcome,
          reachedCompleted: isCurrent(sid) && state == .completed,
          reachedNoSpeech: isCurrent(sid) && state == .noSpeech)
        let archiveClass = archiveClassification
        let archiveBackend = adapter.engineIdentity.backendType.rawValue
        let archiveSettingsOptIn = dictationAudioArchiveOptInProvider()
        Task.detached(priority: .utility) {
          let path = await DictationAudioArchive.archive(
            transcriptID: archiveID,
            sid: archiveSid,
            raw: archiveRaw,
            fed: archiveFed,
            outcome: archiveOutcome,
            classification: archiveClass,
            backend: archiveBackend,
            settingsOptIn: archiveSettingsOptIn)
          await AppLogger.shared.log(
            path.map { "Dictation audio archived: \($0)" }
              ?? "Dictation audio archive skipped/failed (diagnostic limb, ignored)",
            level: .info, category: "Pipeline"
          )
        }
      }
    #endif
  }

  #if DEBUG
    /// Maps the exhaustive `ASREngineOutcome` to the archive's terminal label.
    /// Compiler-checked exhaustiveness is the coverage freeze: a new outcome
    /// case forces a conscious decision here, and `DictationAudioArchiveTests`
    /// locks the mapping. `effectiveSpeechEvidence` only differentiates the
    /// `.empty` terminal (asrEmpty vs noSpeech); ignored otherwise.
    nonisolated static func dictationArchiveOutcome(
      for outcome: ASREngineOutcome,
      effectiveSpeechEvidence: Bool
    ) -> DictationAudioArchive.Outcome {
      switch outcome {
      case .transcript: return .completed
      case .empty: return effectiveSpeechEvidence ? .asrEmpty : .noSpeech
      case .cancelled: return .cancelled
      case .failed(.wedged): return .wedged
      case .failed: return .failed
      }
    }

    /// Relabel the archive outcome for a `.transcript` decode whose finalization
    /// did NOT reach `.completed`. #1358: a filler-only capture emptied by the
    /// text steps now ends `.noSpeech` (quiet, not a failure) — archive it as
    /// `.noSpeech` so diagnostic triage isn't skewed. An empty-after-polish
    /// `.failed(.emptyAfterProcessing)` or a superseded mid-finalize decode
    /// stays `.finalizationFailed`. Non-`.transcript` and completed decodes keep
    /// their base label. Pure so a test can freeze the mapping (Codex r6 P3,
    /// #1358 code-diff r2).
    nonisolated static func relabeledArchiveOutcome(
      base: DictationAudioArchive.Outcome,
      effectiveOutcome: ASREngineOutcome,
      reachedCompleted: Bool,
      reachedNoSpeech: Bool
    ) -> DictationAudioArchive.Outcome {
      guard case .transcript = effectiveOutcome, !reachedCompleted else { return base }
      return reachedNoSpeech ? .noSpeech : .finalizationFailed
    }

    /// Whether the conditioned batch buffer (`asrSamples`) is the buffer the
    /// engine actually decoded — true ONLY for a conditioned-batch decode: a
    /// batch session, or a streaming session that fell back to batch rescue. A
    /// streaming WIN decodes the raw live feed (`acceptAudio` forwards the raw
    /// capture, not the conditioned buffer), so `asrSamples` is NOT its decode
    /// input and `raw.wav` is the faithful replay. Same `tailEligible ||
    /// cameFromBatchRescue` identity the tail-clip diagnostics use. Returns false
    /// for WhisperKit (decodes raw padded to the transcription minimum).
    nonisolated static func dictationFedUsesBatchBuffer(
      decodesConditionedBatch: Bool,
      isStreaming: Bool,
      cameFromBatchRescue: Bool
    ) -> Bool {
      decodesConditionedBatch && (!isStreaming || cameFromBatchRescue)
    }
  #endif

  /// The finalizing phase — the transcript is in hand, the safe point is in
  /// force (PR-1 §B.5). Cancel / interruption from here are ignored.
  private func runFinalizing(_ sid: SessionID, asrText: String, transcriptID: UUID) async {
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
    // #1358: the finalization wiring already delivered any recoverable
    // deterministic floor (post-ITN text, else lexical raw ASR) as non-empty,
    // so an empty result here is genuinely non-lexical (a bare filler / non-
    // speech artifact). End quietly as no-speech — never a heart-path failure
    // (mirrors the #979 asr-empty downgrade). If the capture was interrupted,
    // `interruptedTerminalFloor` floors this to `.audioInterrupted` to retain
    // the #1408 crash-recovery spool.
    if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lastNoSpeechSource = .emptyAfterProcessing
      finishTerminal(.noSpeech, sid: sid)
      return
    }

    // The unload-policy gate: a non-empty transcript has cleared polish and is
    // about to be stored / delivered. Old pipeline parity
    // (old Parakeet pipeline): `noteTranscriptionComplete` fires
    // here, between polish and storage/paste — failures after this point still
    // get unload, failures before do not (PR-4.5 #8, §5b).
    transcriptReadyForDelivery = true

    do {
      try await store(processed, transcriptID)
    } catch {
      // #1167: the history save is best-effort — `store` absorbs storage
      // failures internally (records them on the finalization outcome +
      // telemetry side-channel and still sets `outcome.transcript`), so it no
      // longer throws on a save failure. Any residual throw can only be
      // cancellation during finalize; honor the safe-point (a transcript is in
      // hand) by falling through to deliver exactly as the success path would.
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
          // Div 5 of seam audit (TP:407): surface the underlying loader's
          // last-observed phase string instead of a generic "kernel" label
          // so the Sentry wedge payload preserves the OLD pipeline's
          // diagnostic richness. Adapters that have no phase surface return
          // the protocol default "warmup".
          observedPhase: adapter.lastObservedPhase,
          signalCountTotal: loadTickCount,
          firstSignalLatencyMs: firstLoadTickAt.map {
            milliseconds(forTicks: $0 &- loadAttemptStartedAtTick)
          },
          totalAttemptDurationMs: milliseconds(forTicks: now &- loadAttemptStartedAtTick)
        )
        bump()
        // #959: a GENUINE load wedge — heavy recovery (tear down the engine),
        // never the cheap model-preserving `cancel()` that ordinary terminals
        // use. The `.wedged` terminal below already surfaces wedge telemetry
        // (`KernelLifecycleTelemetrySink`), so no extra event is emitted here.
        await adapter.recoverFromWedge()
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
        // #959: a GENUINE finalize/decode wedge — heavy recovery, not the cheap
        // `cancel()`. Wedge telemetry is surfaced by the `.failed(.wedged)`
        // terminal path (`KernelLifecycleTelemetrySink`).
        await adapter.recoverFromWedge()
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
  /// VAD auto-stop is NOT bound here: it flows through `vad.subscribeStopSignals()`
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
  func externalEngineInterrupted(_ cause: EngineInterruptionCause) {
    guard !state.isTerminal else { return }
    // Stamp the cause + freeze the recording snapshot ONLY on the interruption
    // that actually latches the exit (first-wins), BEFORE delivering it so the
    // observer reads the right cause at the `→ .audioInterrupted` transition
    // (the exit resolves the recording-loop continuation, which then calls
    // `finishTerminal(.audioInterrupted)`). A later callback in the post-latch /
    // pre-transition window — `state` still `.recording` but `recordingExitLatched`
    // already true — has its exit ignored by `deliverRecordingExit`, so it must
    // NOT overwrite the cause/snapshot the terminal will use (cloud review #1207:
    // an already-owned `.xpcConnectionLost` could otherwise be replaced by a
    // stale `.engineLost` and get falsely captured). The guard
    // mirrors `deliverRecordingExitIfCurrent`'s accept condition. The freeze
    // reports real duration / route / backend (mirrors `routeASRInterruption`).
    if state == .recording, !recordingExitLatched {
      telemetryState.interruptionCause = cause
      freezeRecordingSnapshot()
    }
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
      for await signal in self.vad.subscribeStopSignals() {
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
    // Separate advisory stream (#1060): approaching-cap warnings never stop the
    // recording. Same session-stamp / stale-drop discipline as the stop stream;
    // a stale warning from a finished session is dropped, not forwarded.
    spawn(sid) { [weak self] in
      guard let self else { return }
      for await warning in self.vad.subscribeWarningSignals() {
        guard self.isCurrent(sid) else { return }
        guard warning.sessionID == self.currentSessionID else {
          self.staleVADSignalDrops += 1
          self.log(
            "dropped stale VAD warning from=\(warning.sessionID.raw) "
              + "current=\(self.currentSessionID.raw) totalDrops=\(self.staleVADSignalDrops)")
          continue
        }
        guard self.state == .recording else { continue }
        self.onApproachingMaxDuration?(warning.remainingSeconds)
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
    // #1060: capture wall-clock recording length (live telemetry, not persisted).
    if let start = recordingStartedAtDate {
      lastRecordingDurationSeconds = Date().timeIntervalSince(start)
    }
    // #1060: record the stop reason for the transcribing-pill label + telemetry.
    switch exit {
    case .userStop: lastStopReason = "user"
    case .vadAutoStop: lastStopReason = "vad_auto_stop"
    case .maxDuration: lastStopReason = "max_duration"
    case .captureStall: lastStopReason = "capture_stall"
    case .audioInterruption: lastStopReason = "audio_interruption"
    case .asrInterruption: lastStopReason = "asr_interruption"
    case .cancel: lastStopReason = "cancel"
    }
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
      // Safe point — a delivery outcome (`completed`/`failed`) OR a legitimate
      // no-delivery discovery. #1358: the limb chain can empty the transcript
      // (bare filler / non-speech artifact) → `.noSpeech`; and if that capture
      // was interrupted, `interruptedTerminalFloor` floors `.noSpeech` up to
      // `.audioInterrupted` (retain the #1408 spool), so that floored terminal
      // must be legal too or `finishTerminal` would silently never terminate.
      // None of these is the cancel/interruption COMMAND the safe point blocks.
      switch next {
      case .completed, .failed, .noSpeech, .audioInterrupted:
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

  /// #1408. On a session whose capture was interrupted, any terminal that would
  /// DELETE the crash-recovery spool must instead land on `.audioInterrupted` — a
  /// `.failure` terminal that RETAINS it, and precisely the terminal this session
  /// reached before salvage existed. Salvage may only ever ADD a transcript; it
  /// must never convert "recoverable on the next launch" into "gone."
  ///
  /// Applied ONCE, inside `finishTerminal`, never at the call sites: one of the
  /// terminals is computed from a ternary (`effectiveSpeechEvidence ?
  /// .failed(.asrEmpty) : .noSpeech`), so a call-site floor would silently miss
  /// the post-ASR no-speech path — the exact "salvaged audio transcribed to
  /// nothing" row this guards. Inert outside an interruption: the cause is
  /// cleared at session start, before `.preparing`.
  ///
  /// **One rule: an interrupted recording that ends with no transcript lands on
  /// `.audioInterrupted`, whatever interrupted it.**
  ///
  /// `.discarded` / `.noSpeech` DELETE the spool (`RecordingTerminalKind
  /// .discard`). Letting an interrupted session reach either would destroy the
  /// crash-recovery copy of audio the user can still get back on next launch —
  /// converting "recoverable" into "gone." Safety does not get to depend on which
  /// interruption fired, so this holds for every cause including the duration cap.
  /// `.failed(.noAudioCaptured)` already retains the spool; it is folded in so all
  /// three no-transcript endings agree, rather than one of them keeping a
  /// different overlay for no reason a user could name.
  ///
  /// This used to be TWO rules, the second gated on `cause.isDeviceLoss`, because
  /// `.audioInterrupted` rendered "Microphone disconnected" unconditionally and
  /// that would have been a lie for a duration cap. The cause-aware sentence now
  /// lives at its own single authority (`InterruptionMessages.message(for:)`), so
  /// the floor no longer has to encode a copy decision. What the terminal MEANS
  /// (the spool survives) and what the user READS are separate questions with
  /// separate owners — which is the same split `hasRecoverableAudio` and
  /// `isDeviceLoss` draw one layer up.
  ///
  /// `.cancelled` is NEVER floored: an explicit user cancel is honored, and its
  /// retain/delete disposition belongs to `pendingCancelDisposition`. Every other
  /// `.failed(reason)` (`.asrEmpty`, `.asrFailed`, `.captureStartFailed`,
  /// `.modelLoadFailed`) keeps its own honest reason and is already spool-retaining.
  private func interruptedTerminalFloor(
    _ terminal: RecordingSessionState
  ) -> RecordingSessionState {
    guard lastAudioInterruptionCause != nil else { return terminal }
    switch terminal {
    case .discarded, .noSpeech, .failed(.noAudioCaptured):
      return .audioInterrupted
    default:
      return terminal
    }
  }

  /// Reach a terminal state: transition, run nonblocking cleanup, drain the
  /// task bag (PR-1 §B.1.6, PR-3 plan §3.1a — cancel + clear, never `await`).
  /// Discards the adapter's open session and stops the capture engine if
  /// either is still in flight (PR-1 §B.1.3 cleanup column; Codex P1b / P2-r3).
  private func finishTerminal(_ rawTerminal: RecordingSessionState, sid: SessionID) {
    guard isCurrent(sid) else { return }
    let terminal = interruptedTerminalFloor(rawTerminal)
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
    // #1408: `lastAudioInterruptionCause` is NOT cleared here. Its storage moved
    // to `KernelTelemetryState.interruptionCause`, whose `resetForNewSession()`
    // is the sole clearer — `start(config:)` calls it immediately after this,
    // before `.preparing`. Two clearers for one field is how a stale cause would
    // leak into the next session and make the terminal floor mis-fire on a
    // normal too-short tap.
    isStreamingSession = false
    pasteCount = 0
    forbiddenTransitionRejected = false
    formatStabilizedThisSession = nil
    captureRebuiltForFormatThisSession = nil
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

  /// Driver-facing seam: stamp the frontmost app's bundle identifier into
  /// the current recording snapshot. The driver calls this BEFORE clearing
  /// `KernelSessionContext.targetApp` on terminal so the lifecycle sink's
  /// fallback (`KernelLifecycleTelemetrySink:370`) sees the bundle id from
  /// the snapshot itself, not from a now-nulled context reference. No-op
  /// when no snapshot exists (e.g., terminal reached without ever entering
  /// `.recording`).
  func stampRecordingSnapshotTargetApp(_ bundleID: String?) {
    telemetryState.recordingSnapshot?.targetAppBundleID = bundleID
  }

  private func freezeRecordingSnapshot() {
    let start = recordingStartedAtDate ?? Date()
    telemetryState.recordingSnapshot = KernelRecordingSnapshotTelemetry(
      backend: adapter.engineIdentity.rawValue,
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

    let resolvedRoute = audioCapture.currentResolvedRoute
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
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
        selectedTransport: resolvedRoute?.selected,
        effectiveTransport: resolvedRoute?.effective,
        routeReason: resolvedRoute?.routeReason,
        routeFallbackReason: resolvedRoute?.routeFallbackReason,
        inputSelectionMode: resolvedRoute?.inputSelectionMode,
        outputTransport: resolvedRoute?.outputTransport,
        routeResolutionSource: resolvedRoute?.routeResolutionSource
      )
    )
  }

  private func mergeAdapterDiagnosticsIntoASREmpty() {
    guard var diagnostics = telemetryState.asrEmptyDiagnostics,
      let adapterDiagnostics = (adapter as? ASREngineTelemetryProviding)?.lastASRDiagnostics
    else { return }

    // PR-5 Rung 5 Pass 2 r2 #B2: the copy (incl. the WhisperKit incremental
    // fields previously dropped before Sentry) lives in a pure, unit-tested
    // method so a future field addition can't silently skip the copy again.
    diagnostics.absorbAdapterDiagnostics(adapterDiagnostics)
    telemetryState.asrEmptyDiagnostics = diagnostics
  }

  /// #1434: copy the session's capture-health record into the ASR-empty
  /// diagnostics so the Sentry extra carries rate/counters/stabilization on
  /// exactly the failure class this bug manifests as.
  private func stampCaptureHealthIntoASREmptyDiagnostics() {
    guard var diagnostics = telemetryState.asrEmptyDiagnostics,
      let health = telemetryState.captureHealth
    else { return }
    diagnostics.captureNativeRateHz = health.stopMetadata?.nativeRateHz
    diagnostics.captureRingDropCount = health.stopMetadata?.ringDropCount
    diagnostics.captureConverterErrorCount = health.stopMetadata?.converterErrorCount
    diagnostics.captureZeroOutputCount = health.stopMetadata?.zeroOutputCount
    diagnostics.captureRateDivergenceDetected = health.stopMetadata?.rateDivergenceDetected
    diagnostics.captureFormatStabilized = health.formatStabilized
    diagnostics.captureRebuiltForFormat = health.captureRebuiltForFormat
    telemetryState.asrEmptyDiagnostics = diagnostics
  }

  /// #1434: the degraded-lead salvage ladder. Retries the batch decode at up
  /// to `DegradedLeadDiagnostics.maxCandidates` ascending trim points through
  /// the kernel's own `finalize` wrapper (wedge detection + stale-session
  /// guard re-arm per call; `ParakeetEngineAdapter.finalizeBatch` is stateless
  /// per call with explicit samples). Returns the first non-empty transcript,
  /// or nil (all candidates empty, no candidates, aborted). Failure-side
  /// telemetry is stamped here so the fleet sees misses, not only wins.
  private struct DegradedLeadSalvageSuccess {
    let result: ASRResult
    let trimSamples: Int
    let candidateCount: Int
  }

  private func attemptDegradedLeadSalvage(
    _ sid: SessionID, samples: [Float]
  ) async -> DegradedLeadSalvageSuccess? {
    let candidates = DegradedLeadDiagnostics.trimCandidates(
      samples: samples, sampleRate: AudioConstants.sampleRate)
    let candidatesMs = candidates.map { $0 * 1000 / Int(AudioConstants.sampleRate) }
    telemetryState.asrEmptyDiagnostics?.salvageAttempted = true
    telemetryState.asrEmptyDiagnostics?.salvageCandidateCount = candidates.count
    telemetryState.asrEmptyDiagnostics?.salvageCandidateTrimsMs = candidatesMs
    guard !candidates.isEmpty else {
      log("ASR empty salvage: no candidates (lead not degraded or too little audio)")
      return nil
    }
    log("ASR empty salvage: candidates(ms)=\(candidatesMs)")
    for (index, trim) in candidates.enumerated() {
      // Re-guard before EACH dispatch — a PTT-cancel/new session mid-ladder
      // abandons it (the in-flight decode, if any, is dropped by the finalize
      // wrapper's own stale guard).
      guard isCurrent(sid), !state.isTerminal else {
        telemetryState.asrEmptyDiagnostics?.salvageAbortedReason = "superseded"
        return nil
      }
      let retry = await finalize(sid, batchSamples: Array(samples[trim...]))
      guard isCurrent(sid), !state.isTerminal else {
        telemetryState.asrEmptyDiagnostics?.salvageAbortedReason = "superseded"
        return nil
      }
      switch retry {
      case .transcript(let result):
        log(
          "ASR empty salvage succeeded: trimMs=\(trim * 1000 / Int(AudioConstants.sampleRate)) "
            + "candidate=\(index + 1)/\(candidates.count) chars=\(result.text.count)")
        return DegradedLeadSalvageSuccess(
          result: result, trimSamples: trim, candidateCount: candidates.count)
      case .empty:
        continue
      case .cancelled:
        telemetryState.asrEmptyDiagnostics?.salvageAbortedReason = "superseded"
        return nil
      case .failed:
        // The retry path must not upgrade the terminal (the primary decode
        // already classified this session as empty), but a retry-path
        // regression must not hide either — record the abort reason.
        telemetryState.asrEmptyDiagnostics?.salvageAbortedReason = "retry_failed"
        return nil
      }
    }
    log("ASR empty salvage: all \(candidates.count) candidates decoded empty")
    return nil
  }

  private func peakAudioLevel(in samples: [Float]) -> Float {
    samples.reduce(Float(0)) { max($0, abs($1)) }
  }

  /// Empirical dead-air energy thresholds for the #964 no-speech gate. See
  /// `rawAudioIsDeadAir`. Deliberately LOW — these reject only genuine silence,
  /// not an audible-but-faint utterance (measured -35 dB room noise peaks at
  /// 0.0178, above a real whisper at 0.0109, so signal level alone can't split
  /// faint speech from noise — Parakeet is the arbiter past this floor).
  enum DeadAirFloor {
    /// Peak absolute amplitude (linear, Float32). ~ -44 dBFS.
    static let peak: Float = 0.006
    /// Whole-buffer RMS.
    static let rms: Float = 0.00125
    /// Loudest 40 ms window RMS — catches a faint word inside a mostly-silent
    /// buffer where the whole-buffer RMS stays low.
    static let windowRms: Float = 0.002
    /// 40 ms at 16 kHz.
    static let windowSamples = 640
  }

  /// True when a raw capture buffer is dead air (no recoverable speech) for the
  /// #964 gate: when Silero reports zero segments we skip ASR ONLY if the raw
  /// audio is also below every `DeadAirFloor` threshold. Otherwise the kernel
  /// falls through and lets Parakeet decide. Pure + static so the boundary
  /// cases (just-below / just-above each threshold) unit-test without a kernel.
  nonisolated static func rawAudioIsDeadAir(_ samples: [Float], peak: Float)
    -> Bool
  {
    guard peak < DeadAirFloor.peak else { return false }
    guard !samples.isEmpty else { return true }
    var sumSquares: Float = 0
    for s in samples { sumSquares += s * s }
    let rms = (sumSquares / Float(samples.count)).squareRoot()
    guard rms < DeadAirFloor.rms else { return false }
    // Loudest non-overlapping 40 ms window. A faint word lifts a local window's
    // RMS even when most of the buffer is silence around it; tiled windows keep
    // this bounded at O(n).
    let window = DeadAirFloor.windowSamples
    guard samples.count >= window else { return rms < DeadAirFloor.windowRms }
    var maxWindowRms = rms
    var i = 0
    while i + window <= samples.count {
      var ss: Float = 0
      for j in i..<(i + window) { ss += samples[j] * samples[j] }
      let wr = (ss / Float(window)).squareRoot()
      if wr > maxWindowRms { maxWindowRms = wr }
      i += window
    }
    return maxWindowRms < DeadAirFloor.windowRms
  }

  /// Fraction of non-overlapping 40 ms windows in `slice` whose RMS clears the
  /// dead-air window floor. Continuous lost speech tiles to ~1.0; a lone
  /// transient (desk-thump / keyboard clack) in a mostly-silent tail tiles to
  /// ~0.04. Pure + static, O(n), reuses `DeadAirFloor` — the sustained-voice
  /// gate that keeps energetic NON-speech tails out of ASR (#950 hallucination
  /// guard). Returns 0 for a slice shorter than one window (too short to assess).
  nonisolated static func tailVoicedFraction(_ slice: [Float]) -> Double {
    let window = DeadAirFloor.windowSamples
    guard slice.count >= window else { return 0 }
    var voiced = 0
    var total = 0
    var i = 0
    while i + window <= slice.count {
      var ss: Float = 0
      for j in i..<(i + window) { ss += slice[j] * slice[j] }
      if (ss / Float(window)).squareRoot() >= DeadAirFloor.windowRms { voiced += 1 }
      total += 1
      i += window
    }
    return total == 0 ? 0 : Double(voiced) / Double(total)
  }

  /// Thresholds for the #950 tail-preserve recovery branch.
  enum TailPreserve {
    /// Min dropped-tail ms worth recovering (below this is pad-decay, not a word).
    static let floorMs = 400
    /// Hard cap — never auto-append more than this much trailing audio.
    static let maxRecoverMs = 8000
    /// >= half the tail's 40 ms windows must be voiced (sustained voice, not one spike).
    static let voicedFractionFloor = 0.5
  }

  /// Outcome of the tail-preserve decision. Carries the refusal reason so
  /// telemetry can answer "among eligible dictations with a dropped tail, why was
  /// it NOT recovered?" without duplicating the threshold logic at the call site —
  /// ONE source of truth for the guards.
  enum TailPreserveDecision: Equatable {
    case preserve
    case refuse(reason: String)
    case notEvaluated
  }

  /// Pure, nonisolated, total — boundary-testable like `rawAudioIsDeadAir`. Guard
  /// ORDER defines the reason taxonomy: engine-eligibility first (`.notEvaluated`,
  /// so `usedTailPreservation` stays nil for the denominator), then conditioner
  /// path, then a non-empty tail, then the duration window, then sustained voice.
  /// The first failing guard names the reason.
  nonisolated static func tailPreserveDecision(
    tailEligible: Bool,
    conditioningReason: String,
    droppedTailSamples: Int,
    droppedTailMs: Int,
    voicedFraction: Double,
    floorMs: Int = TailPreserve.floorMs,
    maxRecoverMs: Int = TailPreserve.maxRecoverMs,
    voicedFractionFloor: Double = TailPreserve.voicedFractionFloor
  ) -> TailPreserveDecision {
    guard tailEligible else { return .notEvaluated }
    guard conditioningReason == "filtered" else { return .refuse(reason: "not_filtered") }
    guard droppedTailSamples > 0 else { return .refuse(reason: "no_tail") }
    guard droppedTailMs >= floorMs else { return .refuse(reason: "too_short") }
    guard droppedTailMs <= maxRecoverMs else { return .refuse(reason: "too_long") }
    guard voicedFraction >= voicedFractionFloor else {
      return .refuse(reason: "low_voiced_fraction")
    }
    return .preserve
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

  /// PR-5 Rung 4.5 (#827): emit `t_release` LID perf signpost on accepted-stop.
  /// Timestamp-only variant — `voiced_duration_s`, `lid_window_count`,
  /// `clip_kind` are not known here (LID has not run yet). Matches the OLD
  /// signature's all-optional-tail at `WhisperKitPipeline.swift:1438-1452`.
  /// Format matches `WhisperKitEngineAdapter.logLIDPerfSignpost`.
  private func emitLIDReleaseSignpost(sessionID: UInt64) {
    let ts = String(format: "%.6f", CFAbsoluteTimeGetCurrent())
    let message = "lid_perf_signpost name=t_release timestamp_s=\(ts) session_id=\(sessionID)"
    Task {
      await AppLogger.shared.log(message, level: .info, category: "RecordingSessionKernel")
    }
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
    /// #1358: pre-seed the interruption cause so a test can exercise
    /// `interruptedTerminalFloor` (which reads `lastAudioInterruptionCause`)
    /// without driving a real mid-recording interruption.
    func testSetInterruptionCause(_ cause: EngineInterruptionCause?) {
      telemetryState.interruptionCause = cause
    }

    /// Test-only recording-snapshot accessors. Used by Div 8 coverage to
    /// pre-seed a snapshot (since the kernel only freezes one mid-session)
    /// and to read its `targetAppBundleID` after the driver's terminal
    /// cleanup stamps it.
    func testSetRecordingSnapshot(_ snapshot: KernelRecordingSnapshotTelemetry?) {
      telemetryState.recordingSnapshot = snapshot
    }
    func testGetRecordingSnapshot() -> KernelRecordingSnapshotTelemetry? {
      telemetryState.recordingSnapshot
    }

    /// PR-5 Rung 1: surface the natural `freezeRecordingSnapshot()` path so
    /// the engine-identity propagation sentinel can prove `:1791-1792` reads
    /// `adapter.engineIdentity.rawValue` rather than a hard-coded literal.
    func testTriggerRecordingSnapshotFreeze() {
      freezeRecordingSnapshot()
    }

    /// Test-only finalizing-sub-status setter. Lets unit tests flip the
    /// `.transcribing` ↔ `.polishing` sub-status without driving a real
    /// polish-step `onWillProcess`. The driver's `overlayIntent` routes
    /// overlay-label text through this sub-status (`.processing("Transcribing...")`
    /// vs `"Polishing..."`).
    func testSetFinalizingSubStatus(_ status: FinalizingSubStatus) {
      finalizingSubStatus = status
    }

    /// #1408: surface the terminal floor as a pure function so a test can prove
    /// it covers EVERY terminal whose `RecordingTerminalKind` is `.discard`.
    /// The floor's mapped set and `KernelDictationDriver.endedWithoutSaveKind`'s
    /// discard set are two lists of the same fact; without this seam they can
    /// drift, and a new spool-deleting terminal would silently escape the floor.
    func testInterruptedTerminalFloor(_ terminal: RecordingSessionState)
      -> RecordingSessionState
    {
      interruptedTerminalFloor(terminal)
    }
  #endif
}
