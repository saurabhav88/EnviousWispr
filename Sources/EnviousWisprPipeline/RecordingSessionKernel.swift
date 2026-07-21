@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
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
  /// #1558 (cloud review P2 #1563): a start-stage failure where NO usable input
  /// device was found — distinct from the generic `.captureStartFailed` so the
  /// toggle/menu path surfaces the actionable "No microphone found." notice, the
  /// same as the prewarm (PTT) path already does AppKit-side.
  case noMicrophoneFound
  case noAudioCaptured
  case asrEmpty
  case asrFailed
  case asrWedged
  case emptyAfterProcessing
  case captureStalled
  /// #1317: the mic HARNESS delivered all-zero audio from a running,
  /// unmuted device — distinct from `.captureStalled` (no buffers at all).
  /// Fires only for `.allZeroFromStart`; `.becameZeroMidCapture` completes
  /// normally with the salvaged prefix (§3.5).
  case zeroSignal
}

/// The 5 recording-session FSM states (#1548, heartpath D1). None is terminal:
/// the session's ending CATEGORY moved to the sibling `RecordingOutcome`
/// observable, and a concluded session returns to `.idle` with
/// `recordingOutcome` set. `state` is pure lifecycle POSITION.
///
/// - `arming`: preparing + warming the model + opening the mic. The pill shows
///   immediately here (recording pill when the model is warm, caching pill on a
///   genuine cold load) — #1548 D2 removed the first-buffer gate. Was
///   `preparing` + `warmingUp`.
/// - `live`: capture is established and the take is being timed. Entered
///   sequentially the moment capture is established, NOT on a first buffer
///   (#1548 D2). Was `recording`.
/// - `delivering`: transcribe + finalize, sub-phase carried by
///   `deliveringPhase`. Was `transcribing` + `finalizing`.
public enum RecordingSessionState: CaseIterable, Equatable, Sendable {
  case idle
  case arming
  case live
  case stopping
  case delivering
}

/// The ending category of a session + its payload (#1548 D1). A sibling
/// `@Observable` on the kernel; `recordingOutcome != nil` is the
/// session-concluded barrier that replaced `state.isTerminal`. A DECLARED enum
/// (D-024: ending identity is named, never inherited from FSM position).
/// Internal — the App layer reads only the driver's mapped types (§2.5); the
/// driver + observer (same module) are the only consumers.
enum RecordingOutcome: Equatable, Sendable {
  case completed
  case failed(RecordingFailureReason)
  case cancelled
  /// The reason moved here from the deleted `discardReason` sibling.
  case discarded(DiscardReason)
  /// The source moved here from the deleted `lastNoSpeechSource` sibling.
  case noSpeech(NoSpeechSource)
  /// A direct interruption may have no stamped cause (the observer defaults to
  /// `.engineLost`), so the cause is optional (`:1133`).
  case audioInterrupted(EngineInterruptionCause?)
  /// `wasRecording` folds in the observer's old `priorState == .recording`
  /// distinction — true when the session was `.live` at interruption.
  case asrInterrupted(wasRecording: Bool)
  /// #1548: no audio ever arrived — the 800 ms no-buffer watchdog fired with
  /// `bufferCountThisSession == 0` (a dead mic). Projects to the existing
  /// `.failed(.noAudioCaptured)` telemetry + "No audio captured" copy.
  case noTransport
}

/// The `delivering` sub-phase (#1548 D1). Nests the existing
/// `FinalizingSubStatus` so today's Transcribing/Polishing overlay label
/// survives, and carries the cancel/ASR-interrupt SAFE POINT: cancel is
/// accepted only in `.transcribing`; every `.finalizing(_)` is beyond it.
enum DeliveringPhase: Equatable, Sendable {
  case transcribing
  case finalizing(FinalizingSubStatus)
}

/// The `finalizing` sub-status surfaced for the overlay string (PR-1 §B.4,
/// PR-3 plan §3.5). The kernel owns the observation point; a limb only emits.
/// Now nested inside `DeliveringPhase.finalizing` (#1548 D1).
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

  /// #1707 Phase 2: oracle for the shared-backend overlap Live UAT
  /// (§3.2a-i). Always compiled — a plain timestamp-recording class; release
  /// builds never construct/wire a real instance, so this stays `nil` and a
  /// no-op in production.
  private let batchDecodeFaultController: BatchDecodeFaultController?

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
  /// Heartpath 5b (#1520): the shared app-level capture-telemetry state. The
  /// kernel arms the dead-mic recovery watch here on a real retire; the
  /// lifecycle sink resolves it on a later success. MUST be the same instance
  /// the lifecycle sink holds or the watch cannot correlate across takes.
  private let captureTelemetry: CaptureTelemetryState
  /// Heartpath 5b (#1520): emit `audio.dead_mic_retire_attempted`. Injected
  /// closure (not a direct emitter dependency), wired by the factory to
  /// `HeartPathTelemetryEmitter.deadMicRetireAttempted`.
  private let deadMicRetireAttemptTelemetry: @MainActor (DeadMicRetireAttemptContext) -> Void
  /// Heartpath 5b (#1520): emit `audio.dead_mic_recovery` for a later-retire
  /// resolution produced at the retire site. Wired to the SAME emitter method
  /// the lifecycle sink's later-success resolution uses.
  private let deadMicRecoveryTelemetry: @MainActor (DeadMicRecoveryOutcome) -> Void
  /// #1317 §3.6 N4: STOP-time zero-signal classification runs INSIDE the
  /// kernel after `stopCapture()` and does not traverse the reactive
  /// `WedgeRecoveryRouter` funnel that the app-side detector's event rides —
  /// so it submits its own event through this closure, wired to the SAME
  /// `HeartPathTelemetryEmitter.stallFired` authority the reactive path
  /// uses. The emitter's per-mode dedup makes a duplicate submission (both
  /// paths agreeing on the same session + mode) safe.
  private let stopTimeZeroSignalTelemetry: @MainActor (CaptureStallContext) -> Void
  /// #1317 §3.0/§3.6: the STOP-time device-alive/not-muted discriminator,
  /// injected (not a direct `AudioDeviceEnumerator`/`ZeroSignalDeviceDiscriminator`
  /// call) so deterministic kernel tests can substitute a fake instead of
  /// depending on the test machine's real microphone state. The production
  /// default checks `audioCapture.zeroSignalDiscriminatorDeviceID` — the
  /// device the CAPTURE LAYER froze at its own engine-start moment (cloud
  /// review P2 round 2, PR #1512: only that layer sees its own internal
  /// retries, so the kernel defers to it instead of independently freezing
  /// its own snapshot, which could still race a mid-startup device switch).
  /// Alive/mute status is still re-checked live against that frozen device
  /// on every call — only the device IDENTITY is frozen, not its mute
  /// state — EXCEPT that `zeroSignalDiscriminatorSawIneligible` (cloud
  /// review round 2, second P2) short-circuits to ineligible if the device
  /// was EVER seen muted during this session's own zero-signal candidate
  /// buffers, so a since-unmuted live re-check can't override an earlier
  /// genuine mute.
  private let zeroSignalDeviceEligible: @MainActor () -> Bool
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

  /// The ending category of the current (or last) session, or `nil` while a
  /// session is in flight (#1548 D1). `recordingOutcome != nil` is the
  /// session-concluded barrier that replaced `state.isTerminal`. Set exactly
  /// once per session, synchronously inside `finishTerminal`, AFTER conclusion
  /// legality is verified and BEFORE the `→ .idle` transition; cleared at the
  /// two new-session sites (`start`'s `resetSessionState` + `reset()`).
  private(set) var recordingOutcome: RecordingOutcome?

  /// The `delivering` sub-phase (#1548 D1) — `.transcribing`, then
  /// `.finalizing(.transcribing)`, then `.finalizing(.polishing)` once the
  /// polish signal is observed. Carries the cancel SAFE POINT (cancel accepted
  /// only in `.transcribing`). Nests the old `finalizingSubStatus` (PR-1 §B.4).
  private(set) var deliveringPhase: DeliveringPhase = .transcribing

  /// The text delivered to the user, or `nil` if none.
  private(set) var deliveredTranscript: String?

  /// `true` if this session entered the model-load branch (i.e. adapter was
  /// not already `.ready` at the warm-up gate). Set immediately BEFORE the
  /// `→ warmingUp` transition. Read by the kernel-state observer to gate the
  /// `.modelLoading` lifecycle event so a warm session does not emit a
  /// spurious "Model loading" breadcrumb (PR-1 §B.7.2 parity; old
  /// the old Parakeet pipeline was conditional on entering the
  /// load branch at `:363`). Reset on session start.
  private(set) var didLoadModelThisSession: Bool = false

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

  /// #1707: read-through to this session's ASR-interruption salvage outcome
  /// (Codex code-diff r2) — distinct from `lastStopReason`, which only ever
  /// records the ORIGINAL exit regardless of whether the salvage that
  /// followed succeeded.
  var lastASRSalvageOutcome: ASRSalvageOutcome? {
    telemetryState.asrSalvageOutcome
  }

  /// #1707 Phase 2: read-through to this session's post-capture-decode retry
  /// outcome, or `nil` if no Phase-2 retry ever started. Feeds the
  /// success-side `dictation.completed` reporting chain (driver read-through
  /// → `DictationCompletedReporting` → `TelemetryService`) and the
  /// `.asrFailed`/`.asrInterrupted` Sentry breadcrumbs.
  var asrRetryOutcome: ASRRetryOutcome? {
    telemetryState.asrRetryOutcome
  }

  /// #1317: which zero-signal failure mode this session was classified as, or
  /// `nil` if it never was. Stamped once by the winning classification
  /// (reactive `.zeroSignal` exit OR STOP-time), cleared per session in
  /// `KernelTelemetryState.resetForNewSession`. Drives both the
  /// `.zeroSignal` pill (`allZeroFromStart`) and the partial-capture
  /// disclosure (`becameZeroMidCapture`) — read-through to
  /// `KernelTelemetryState.zeroSignalFailureMode`, the single home (§3.5).
  var zeroSignalFailureMode: CaptureStallFailureMode? {
    telemetryState.zeroSignalFailureMode
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

  /// #1707 Phase 2: `true` once this session has spent its one live retry
  /// over a post-capture decode failure. A defensive re-entry guard, not a
  /// race condition to protect against for the ordinary case — `finalize()`
  /// is called exactly once per session by construction. Reset on session
  /// start.
  private var hasUsedPhase2Retry: Bool = false

  /// #1707 Phase 2: this adapter's own retry-decode timeout budget (Codex r3:
  /// Pipeline-owned retry POLICY, read straight from the adapter seam — no
  /// per-backend switch or identity-case literal at this kernel reader site
  /// at all, closed-set or otherwise). Codex r8/r9: length-aware — the
  /// budget scales with the audio being retried, so a genuinely long
  /// recording is not rejected on a one-size-fits-all deadline.
  private func asrRetryDeadlineSec(forSampleCount sampleCount: Int) -> Double {
    adapter.retryDecodeTimeoutSeconds(forSampleCount: sampleCount)
  }

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

  /// The user-visible error category for the concluded session, derived from
  /// `recordingOutcome` (#1548 D1). `nil` for non-error outcomes / in flight.
  // periphery:ignore - test seam (read only by the simulator)
  var userVisibleError: KernelErrorCategory? {
    switch recordingOutcome {
    case .audioInterrupted:
      return .interruption
    case .asrInterrupted, .failed, .noTransport:
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

  /// #1393: monotonic elapsed time since the CURRENT recording began, immune
  /// to wall-clock/timezone/NTP changes. Reuses `recordingStartedAtTick`
  /// above rather than adding a second monotonic authority — same stamp
  /// site, same clear site, same "visible-recording start" semantic the
  /// discard gate already relies on. Checked comparison, not wrapping
  /// subtraction: production `currentTick()` cannot realistically regress
  /// below `start` (monotonic `systemUptime`, same-process, non-decreasing
  /// quantization), but a broken or adversarially-injected clock should fail
  /// to `0` for this newly user-facing value, not silently wrap into a huge
  /// duration.
  ///
  /// Gated on `state == .recording` (cloud review P2, PR #1507): the overlay
  /// panel's FIRST `.recording` push (`RecordingStarter.start()`) installs
  /// its provider before `start(config:)` ever runs — while `.recording` is
  /// still `recordingStartedAtTick` from the PRIOR session, not yet cleared
  /// by this session's `resetSessionState()`. Without this gate, a second
  /// PTT press would briefly render the previous recording's stale elapsed
  /// time during prewarm instead of `0:00`. Both StatusView and the overlay
  /// already independently gate their OWN reads on `pipelineState ==
  /// .recording`, so this is redundant-but-safe for them and is the actual
  /// fix for the two overlay call sites that read before that guard exists.
  var recordingElapsedSeconds: TimeInterval? {
    guard state == .live, let start = recordingStartedAtTick else { return nil }
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

  /// #1317 (cloud review P2, PR #1512): `DispatchTime.now().uptimeNanoseconds`
  /// at the `→ recording` transition. `CaptureStallContext.armedAtUptimeNs`
  /// shares this clock domain (not `recordingStartedAtDate`'s wall clock) —
  /// the STOP-time zero-signal backstop needs a real arm time so
  /// `SentryAudioExtras.buildCaptureExtras`'s `capture.stall.window_ms`
  /// reflects THIS recording's length, not machine uptime. `nil` outside
  /// `.recording`; reset on every session start alongside `recordingStartedAtDate`.
  private var recordingStartedAtUptimeNs: UInt64?

  /// Fired at most once per recording when the VAD seam reports the recording is
  /// approaching `maxRecordingDuration` (#1060), carrying the remaining seconds.
  /// ADVISORY: the kernel does NOT stop on this (that is the separate stop
  /// stream); it forwards a semantic event the driver maps to a UI banner. No
  /// user-facing copy lives here — copy stays in the App layer.
  var onApproachingMaxDuration: (@MainActor (TimeInterval) -> Void)?

  /// #1707 Phase 3 (§3.2, row 21) — `EngineRecoveryGate.tryBeginMutation()`/
  /// `endMutation()`, injected exactly like `onApproachingMaxDuration` above
  /// (this type never references `EngineRecoveryGate` by concrete type).
  /// Guards `preWarm()`'s spawned adapter warm-up — the single most
  /// surprising gap this phase closes: that warm-up runs BEFORE the session
  /// reaches `.arming` (`state == .idle` still holds), so a recovery replay
  /// could otherwise be racing an unsupervised warm-up here. Defaults keep
  /// every existing test/legacy construction unchanged (always able to
  /// proceed).
  var tryBeginEngineMutation: @MainActor () -> Bool = { true }
  /// Returns whether recovery was denied while this mutation was in flight
  /// and is now owed a wake-up.
  var endEngineMutation: @MainActor () -> Bool = { false }
  /// Called when `endEngineMutation()` returns true — wakes a stranded
  /// recovery attempt. Bound to `RecoveryCoordinator.requestRecoveryRecheck`.
  var wakeRecoveryIfOwed: @MainActor () -> Void = {}

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

  // #1558: the UI-only `lastFailureDetail` accessor was deleted. It existed to
  // enrich a user-facing "Model load failed: <detail>" string; that string is
  // gone (the presenter authors the sentence, the raw error goes to Sentry
  // only). The underlying telemetry fields (`modelLoadError`,
  // `captureFailureError`, `transcriptionFailureError`) remain — they still
  // feed `KernelLifecycleTelemetrySink`'s Sentry capture.

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
    recordingExitLatched && state == .live
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
    /// #1317: the all-zero harness-glitch exit, dedicated (not `.captureStall`,
    /// which discards the captured result — this exit runs the normal stop
    /// path so a `.becameZeroMidCapture` prefix survives, §3.2).
    case zeroSignal(CaptureStallFailureMode)
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
    captureTelemetry: CaptureTelemetryState? = nil,
    deadMicRetireAttemptTelemetry: @escaping @MainActor (DeadMicRetireAttemptContext) -> Void = {
      _ in
    },
    deadMicRecoveryTelemetry: @escaping @MainActor (DeadMicRecoveryOutcome) -> Void = { _ in },
    stopTimeZeroSignalTelemetry: @escaping @MainActor (CaptureStallContext) -> Void = { _ in },
    // #1317 (cloud review P2 round 2, PR #1512): nil default resolves inside
    // `init` against the `audioCapture` PARAMETER's own
    // `zeroSignalDiscriminatorDeviceID` — the device the capture layer
    // itself froze at its engine-start moment (see that protocol property's
    // doc for why the kernel defers to it instead of independently
    // resolving `preferredInputDeviceIDOverride`/`selectedInputDeviceUID`).
    zeroSignalDeviceEligible: (@MainActor () -> Bool)? = nil,
    recordingStoppedTelemetry: @escaping @MainActor (_ sampleCount: Int) -> Void = { _ in },
    markPipelineTimingStart: @escaping @MainActor () -> Void = {},
    markASRTimingStart: @escaping @MainActor (_ streaming: Bool) -> Void = { _ in },
    markASRTimingEnd: @escaping @MainActor () -> Void = {},
    telemetryState: KernelTelemetryState = KernelTelemetryState(),
    dictationAudioArchiveOptInProvider: @escaping @MainActor () -> Bool = { false },
    // #1707 Phase 2: oracle for the shared-backend overlap Live UAT
    // (§3.2a-i). Defaulted `nil` so every existing test construction site is
    // unaffected. `BatchDecodeFaultController` is always compiled (a plain
    // timestamp-recording class) — only its actual fault-actuating methods
    // are `#if DEBUG`-gated, and release builds never construct/wire a real
    // instance, so this stays a no-op in production.
    batchDecodeFaultController: BatchDecodeFaultController? = nil
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
    self.captureTelemetry = captureTelemetry ?? CaptureTelemetryState()
    self.deadMicRetireAttemptTelemetry = deadMicRetireAttemptTelemetry
    self.deadMicRecoveryTelemetry = deadMicRecoveryTelemetry
    self.stopTimeZeroSignalTelemetry = stopTimeZeroSignalTelemetry
    // #1317 (cloud review P2 round 2, PR #1512): the default reads
    // `audioCapture.zeroSignalDiscriminatorDeviceID` — the device the
    // capture layer itself froze at the moment its engine actually started
    // (including any of ITS OWN retries, which this kernel cannot see) —
    // instead of independently re-resolving `preferredInputDeviceIDOverride`/
    // `selectedInputDeviceUID`, which only reflects the kernel's OWN view
    // and can already differ from what actually got captured. Also checks
    // `zeroSignalDiscriminatorSawIneligible` FIRST (cloud review round 2,
    // second P2): a live re-check here would only see the device's CURRENT
    // mute state, which can already have changed since a genuinely-muted
    // silent stretch — that earlier ineligible result must stick.
    self.zeroSignalDeviceEligible =
      zeroSignalDeviceEligible
      ?? {
        guard !audioCapture.zeroSignalDiscriminatorSawIneligible else { return false }
        guard let deviceID = audioCapture.zeroSignalDiscriminatorDeviceID else { return false }
        return ZeroSignalDeviceDiscriminator.isEligible(deviceID: deviceID)
      }
    self.recordingStoppedTelemetry = recordingStoppedTelemetry
    self.markPipelineTimingStart = markPipelineTimingStart
    self.markASRTimingStart = markASRTimingStart
    self.markASRTimingEnd = markASRTimingEnd
    self.telemetryState = telemetryState
    self.dictationAudioArchiveOptInProvider = dictationAudioArchiveOptInProvider
    self.batchDecodeFaultController = batchDecodeFaultController
  }

  // MARK: Driver entry points (PR-1 §A.2 trigger vocabulary)

  /// Start a new recording session. Legal from `idle` or any terminal state;
  /// ignored while a session is active (PR-1 §B.1.2 — "don't interrupt
  /// processing"). `config` freezes per-recording settings (VAD, decode
  /// language, model-unload policy) for this session (PR-4 plan §3.3a).
  func start(config: DictationSessionConfig) {
    // Legal from `.idle` — which is also where a concluded session rests
    // (`recordingOutcome != nil`); `resetSessionState()` below clears the
    // outcome barrier for the new session (#1548 D1).
    guard state == .idle else {
      log("start ignored — session active at \(state)")
      return
    }
    let sid = SessionID()
    currentSessionID = sid
    resetSessionState()
    sessionConfig = config
    telemetryState.resetForNewSession(polishEnabled: config.llmProvider != .none)
    transition(to: .arming)
    spawn(sid) { [weak self] in
      await self?.runForwardPath(sid)
    }
  }

  /// Request a stop. From `.live` it latches the recording-exit; from `.arming`
  /// it latches a stop the forward path's checkpoint resolves to `discarded`
  /// (#1548 D2); elsewhere ignored (PR-1 §B.1.2, invariant 1).
  func requestStop() {
    switch state {
    case .live:
      deliverRecordingExit(.userStop)
    case .arming:
      // First-wins (Codex code-diff P2): if a capture-stall or zero-signal already
      // latched a recording exit while capture was establishing, that failure WON —
      // a stop arriving afterward must be fully inert. NOT even
      // `detachedAdapterCancel()` runs, which would mark the adapter cancelled and
      // lose a `.becameZeroMidCapture` prefix's salvage. The latched exit is
      // consumed at the post-establish checkpoint. This is the single source of the
      // stop-vs-latched-exit ordering, paired with the `!stopLatched` guards in
      // `externalCaptureStalled`; together they make `stopLatched` and
      // `recordingExitLatched` mutually exclusive before Live.
      guard !recordingExitLatched else { return }
      // Latched; the forward path's checkpoint consumes `stopLatched` and concludes
      // `.discarded(.releasedBeforeRecording)`. `detachedAdapterCancel()` breaks a
      // model-warmup await that has no deadline (WhisperKit) — without it, a stop
      // during a slow cold load would strand the session until the load finished
      // (impl-design consult, Dec 1).
      stopLatched = true
      detachedAdapterCancel()
      bump()
    case .idle, .stopping, .delivering:
      log("stop ignored at \(state)")
    }
  }

  /// Cancel. Before the safe point it routes to `cancelled`; inside
  /// `delivering(.finalizing(_))` it is ignored — the safe point is inviolable
  /// (PR-1 §B.1.4 invariant 5); elsewhere ignored (#1548 D1).
  func cancel() {
    switch state {
    case .live:
      deliverRecordingExit(.cancel)
    case .arming:
      // First-wins (Codex code-diff P2): a latched capture failure wins; a cancel
      // arriving afterward is fully inert, including `detachedAdapterCancel()` (see
      // `requestStop`).
      guard !recordingExitLatched else { return }
      cancelRequested = true
      detachedAdapterCancel()
      // The forward path's checkpoint consumes `cancelRequested` and concludes
      // `.cancelled` (#1548 D2).
      bump()
    case .stopping:
      // Cancel after `.live`, before a transcript exists — the safe point does
      // not apply. Terminate now; `finishTerminal` discards the adapter's open
      // session (which also unblocks an in-flight `finalize()`), and the forward
      // path drops its in-flight `stopCapture()` / `finalize()` result when it
      // returns (`recordingOutcome != nil`). `stopping` is included so a cancel
      // during a slow capture-stop is not lost (Codex P2).
      finishTerminal(.cancelled, sid: currentSessionID)
    case .delivering:
      switch deliveringPhase {
      case .transcribing:
        // Before the transcript is in hand — cancel honored (§5.2).
        finishTerminal(.cancelled, sid: currentSessionID)
      case .finalizing:
        log("cancel ignored — safe point (transcript in hand)")
      }
    case .idle:
      log("cancel ignored at \(state)")
    }
  }

  /// Reset to a fresh idle. Legal only once the session has concluded
  /// (`recordingOutcome != nil`); while in flight it is deferred (logged and
  /// refused — the safe point completes then `start` mints fresh) (#1548 D1).
  func reset() {
    guard recordingOutcome != nil else {
      log("reset ignored / deferred at \(state)")
      return
    }
    // Mint a fresh `SessionID` so any same-session async work still unwinding
    // fails its next `isCurrent(sid)` guard. Without this, those continuations
    // could resume after the reset and deliver text the user cancelled (Codex
    // P1-round5). Clear ONLY the outcome barrier — NOT the full
    // `resetSessionState()`, which would reset `captureLifecycle` and drop an
    // in-flight terminal-cleanup stop (#1548 §3.1). `state` is already `.idle`
    // (a conclusion returns there), so no transition is needed.
    currentSessionID = SessionID()
    recordingOutcome = nil
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
    guard state == .idle else {
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
    guard isCurrent(sid), state == .idle else {
      log("preWarm aborted post-cache-warm sid=\(sid.raw) state=\(state)")
      return
    }
    // Adapter warm-up is spawned (can be a slow cold model load; the session's
    // own warmUp re-checks readiness and reruns cold if needed).
    //
    // #1707 Phase 3 (§3.2, row 21): hold a mutation claim for the FULL
    // awaited warm-up — this runs while `state == .idle`, BEFORE the session
    // is confirmed active, so recovery must never race it. A denied claim
    // (recovery holds the engine) skips this attempt; the session's own
    // in-session `warmUp(_:)` (row 22, already structurally safe) re-checks
    // readiness and reruns cold if needed, so no bespoke retry machinery is
    // needed for this best-effort pre-warm.
    spawn(sid) { [adapter, weak self] in
      // `self` gone ⇒ proceed anyway (matches this task's existing tolerance
      // for a deallocated kernel — `self?.log(...)` below already no-ops).
      guard self?.tryBeginEngineMutation() ?? true else {
        TelemetryService.shared.recoveryEngineActionDeferred(site: "preWarm")
        return
      }
      defer {
        if let self, self.endEngineMutation() { self.wakeRecoveryIfOwed() }
      }
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
      finishTerminal(.discarded(.releasedBeforeRecording), sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }

    // Warm-up (skipped if the adapter is already ready — the warm path).
    if adapter.readiness != .ready {
      // Stamp the model-load flag — the observer fires `.modelLoading` on this
      // flip while Arming (#1548 D1: warmingUp folded into arming, no state
      // transition here), and the overlay reads it for the cold-boot pill.
      didLoadModelThisSession = true
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
        finishTerminal(.discarded(.releasedBeforeRecording), sid: sid)
        return
      }
    }

    // Capture start.
    do {
      try await audioCapture.startEnginePhase()
    } catch {
      guard isCurrent(sid) else { return }
      // #1525 PR J-1: the write-site static type is `any Error` (an untyped
      // `throws` surface), so an intersection cast is required before
      // narrowing — a miss leaves the property nil and the read-side
      // `KernelFallbackSentryError` fallback fires (§4).
      telemetryState.captureFailureError = error as? (any Error & StableSentryErrorIdentity)
      finishTerminal(.failed(Self.classifyCaptureStartError(error)), sid: sid)
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
    // stabilization site in AudioCaptureManager — re-using a value the
    // codebase has already shipped, not introducing a new arbitrary timeout.
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
        // #1525 PR J-1: see the identical cast note at the first
        // `startEnginePhase()` catch above.
        telemetryState.captureFailureError = error as? (any Error & StableSentryErrorIdentity)
        finishTerminal(.failed(Self.classifyCaptureStartError(error)), sid: sid)
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
    // First-wins invariant (Codex code-diff P2): a stop/cancel and a latched
    // recording exit are mutually exclusive before Live — `requestStop`/`cancel`
    // bail when `recordingExitLatched`, and `externalCaptureStalled` bails when
    // `stopLatched`. So `stopLatched` here implies no exit is pending, and this
    // discard cannot clobber a capture failure.
    if stopLatched {
      finishTerminal(.discarded(.releasedBeforeRecording), sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }
    // PR-4.5 #0 (Codex r2): Begin the adapter session BEFORE
    // `beginCapturePhase()`. The previous order opened the adapter AFTER
    // capture started — but the source's `PreRollForwarder.activate()`
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
      // #1525 PR J-1: see the identical cast note at the capture-start
      // catches above.
      telemetryState.captureFailureError = error as? (any Error & StableSentryErrorIdentity)
      finishTerminal(.failed(.captureStartFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }
    // Capture established (#1548 D2). Acknowledge the press immediately:
    // transition to `.live` sequentially with no first-buffer gate. "First
    // converted buffer arrived" is now plain telemetry (`bufferCountThisSession`),
    // not a state the machine waits behind.
    //
    // Concluded-session barrier (Codex r2 defect 1): a `.noBuffers`/zero exit can
    // conclude the session while `beginCapturePhase()` is suspended — `sid` stays
    // current but `state` is already `.idle`. Without the `recordingOutcome == nil`
    // check the resumed path would attempt the illegal `idle → live` transition.
    guard isCurrent(sid), recordingOutcome == nil else { return }
    // First-wins invariant (Codex code-diff P2): a stop/cancel and a latched
    // recording exit are mutually exclusive before Live (see the source guards in
    // `requestStop`/`cancel` and `externalCaptureStalled`). So `stopLatched` here
    // implies no pending capture-failure exit — this discard is safe, and a
    // capture failure that won instead falls through to Live where
    // `awaitRecordingExit` consumes it.
    if stopLatched {
      // PTT released before Live — no transcribable audio (PR-1 §B.1.2).
      finishTerminal(.discarded(.releasedBeforeRecording), sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }
    guard transition(to: .live) else { return }
    beginLiveRecording(sid)

    let exit = await awaitRecordingExit()
    guard isCurrent(sid), recordingOutcome == nil else { return }
    audioCapture.onBufferCaptured = nil

    // `finishTerminal` discards the adapter's open session (`adapterSessionActive`)
    // and stops capture — no per-exit `adapter.cancel()` needed here.
    switch exit {
    case .cancel:
      finishTerminal(.cancelled, sid: sid)
      return
    case .audioInterruption:
      // #1408: the device died mid-recording. With capture in-process (#1543)
      // the manager is always still alive and holding `capturedSamples`, so
      // every stamped cause is recoverable: fall through into the normal stop
      // tail and transcribe what we have — salvage inherits the min-duration
      // gate, VAD finalize, soft-onset preservation, energetic-tail recovery,
      // degraded-lead retry and conditioning for free (plan §3.2). `nil` cause →
      // `false` by optional chaining, so an unstamped interruption fails closed.
      guard lastAudioInterruptionCause?.hasRecoverableAudio == true else {
        if lastAudioInterruptionCause == nil {
          log("audio interruption exit with no stamped cause — refusing salvage")
        }
        finishTerminal(.audioInterrupted(lastAudioInterruptionCause), sid: sid)
        return
      }
      break
    case .asrInterruption:
      // #1707: the ASR helper died, but capture (in-process, #1543) is
      // unaffected and still holds every captured sample — fall through into
      // the normal stop tail, same shape as `.audioInterruption` above. The
      // stop tail's own recovery-capability check (before `finalize`) is what
      // actually confirms the engine can decode; on failure it floors to
      // exactly this session's ORIGINAL terminal (`wasRecording: true`, since
      // the interruption genuinely happened at `.live`), so a failed salvage
      // is byte-identical to pre-#1707 behavior.
      break
    case .captureStall:
      finishTerminal(.failed(.captureStalled), sid: sid)
      return
    case .zeroSignal(let mode):
      switch mode {
      case .noBuffers:
        // Unreachable by construction: `externalCaptureStalled` routes
        // `.noBuffers` to `.captureStall`, never to `.zeroSignal` (§3.2).
        // Fail safely rather than silently mis-terminating — and do NOT stamp
        // the side-channel, so `.noBuffers` can never reach the zero-signal
        // recovery switch below (PR3 grounded review Q6).
        finishTerminal(.failed(.captureStalled), sid: sid)
        return
      case .allZeroFromStart, .becameZeroMidCapture:
        // #1317. Stamp the side-channel BEFORE the terminal — the pill mapper
        // and the driver's partial-capture disclosure both read it (§3.5).
        //
        // PR3: BOTH confirmed zero-signal modes now fall through into the
        // normal stop tail. `.allZeroFromStart` used to take an immediate
        // terminal here, which was behaviourally identical while there was no
        // rebuild — but that early return never reaches `stopCapture()` (its
        // capture stop happens inside `finishTerminal`'s detached cleanup
        // Task, :2715), so it could never own the single post-stop rebuild
        // site. Its terminal now fires below, after the stop completes and
        // after the rebuild request, still BEFORE the VAD no-speech gate that
        // would otherwise swallow an exact-zero capture as quiet-room silence
        // (§3.6 N1). `.becameZeroMidCapture` continues into ASR so the
        // captured prefix is transcribed (§3.4).
        telemetryState.zeroSignalFailureMode = mode
      }
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
    var captureResult = await audioCapture.stopCapture()
    // Guard BEFORE touching kernel state — if a new session started while
    // `stopCapture()` was suspended, these fields belong to that session now
    // (Codex P2-round4 stale-completion guard).
    guard isCurrent(sid) else { return }
    captureLifecycle = .stopped
    resourcesReleased = true
    guard recordingOutcome == nil else { return }
    // Heartpath 5b (#1520): capture the session-ownership token NOW, while THIS
    // take's source is still current, so a stale finish after the awaits below
    // can only retire the source it actually captured, never a newer take's.
    let capturedCaptureSessionID = audioCapture.currentCaptureSessionID
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
      captureRebuiltForFormat: captureRebuiltForFormatThisSession,
      nativeChannelCount: captureResult.metadata?.nativeChannelCount
    )
    recordingStoppedTelemetry(captureResult.samples.count)
    await (vad as? CaptureVADSignalSource)?.finalizeAtStop(
      rawSampleCount: captureResult.samples.count
    )
    // Heartpath 5b (#1520): a cancel during `.stopping` concludes the session
    // WITHOUT minting a new kernel session id, so `isCurrent(sid)` alone is
    // insufficient after this await — `recordingOutcome == nil` is the load-bearing
    // half against a sessionless prewarm installing a source while this
    // continuation unwinds.
    guard isCurrent(sid), recordingOutcome == nil else { return }
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
    // #1548 D2 (§3.7): pair the zero-buffer proxy with `captureResult.samples`.
    // With in-process capture (#1543) the manager can already hold non-empty
    // audio while `bufferCountThisSession` is still 0 (the kernel callback runs
    // on a separate MainActor task and has simply not fired yet), so a bare count
    // check would discard real salvageable audio. Requiring BOTH keeps a
    // genuinely-empty tap discarding while letting manager-held audio reach the
    // salvage tail. The elapsed-time gate stays authoritative for too-short takes.
    if elapsedSubMinimum
      || (bufferCountThisSession == 0 && captureResult.samples.isEmpty)
    {
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
      finishTerminal(.discarded(.tooShort), sid: sid)
      return
    }
    if captureResult.samples.isEmpty {
      finishTerminal(.failed(.noAudioCaptured), sid: sid)
      return
    }

    // Heartpath 5b (#1520): the pure sample fact (sample-shape-only, device-
    // independent), computed ONCE below both early terminals. It drives TWO
    // independent decisions: the eligibility-gated stamp just below (terminal +
    // telemetry + salvage, unchanged) AND the signal-only source retire further
    // down (independent of eligibility — the #1520 gap).
    let signalZeroMode = Self.classifyZeroSignalAtStop(captureResult.samples)

    // #1317 §3.6 STOP-win row: only when the reactive detector never fired
    // for this session (raced by STOP, or the capture was too short to reach
    // its own confidence threshold). MUST run before the no-speech gate
    // below (N1) — that gate would otherwise swallow an all-zero capture as
    // ordinary quiet-room silence. `zeroSignalDeviceEligible` resolves the
    // SAME bound/selected/default precedence the reactive detector uses —
    // the device the session actually captured from (Codex code-diff
    // review: checking unconditionally the system default would misclassify
    // a selected non-default mic that's genuinely muted while the system
    // default happens to be alive+unmuted).
    if telemetryState.zeroSignalFailureMode == nil,
      let mode = signalZeroMode,
      zeroSignalDeviceEligible()
    {
      telemetryState.zeroSignalFailureMode = mode
      stopTimeZeroSignalTelemetry(
        CaptureStallContext(
          sessionID: audioCapture.currentCaptureSessionID,
          armedAtUptimeNs: recordingStartedAtUptimeNs ?? DispatchTime.now().uptimeNanoseconds,
          firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
          route: audioCapture.currentAudioRoute,
          sourceType: "stop_time_classification",
          engineStartedSuccessfully: true,
          tapInstalled: true,
          formatMismatchObserved: false,
          inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
            ? nil : audioCapture.preferredInputDeviceIDOverride,
          inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
          failureMode: mode,
          selectedTransport: audioCapture.currentResolvedRoute?.selected,
          effectiveTransport: audioCapture.currentResolvedRoute?.effective,
          routeReason: audioCapture.currentResolvedRoute?.routeReason,
          routeFallbackReason: audioCapture.currentResolvedRoute?.routeFallbackReason,
          inputSelectionMode: audioCapture.currentResolvedRoute?.inputSelectionMode,
          outputTransport: audioCapture.currentResolvedRoute?.outputTransport,
          routeResolutionSource: audioCapture.currentResolvedRoute?.routeResolutionSource,
          // #1523: stamp the bound device's channel count on the zero-signal
          // terminal. This is the near-silent-capture event §3a correlates a
          // >1-channel count against (voice on a later channel → AUHAL takes
          // channel 0 → silence), so the count belongs precisely here.
          nativeChannelCount: captureResult.metadata?.nativeChannelCount
        ))
    }

    // Map the eligibility-gated stamp ONCE — it drives both the retire's stamp arm
    // and the terminal below. `.noBuffers` is the ordinary capture stall (owned by
    // the stall watchdog, never stamped); `nil` is the healthy session. Exhaustive
    // on purpose (no `default`): a future failure mode must make a deliberate choice.
    let zeroSignalRecoveryMode: CaptureStallFailureMode?
    switch telemetryState.zeroSignalFailureMode {
    case .allZeroFromStart: zeroSignalRecoveryMode = .allZeroFromStart
    case .becameZeroMidCapture: zeroSignalRecoveryMode = .becameZeroMidCapture
    case .noBuffers, nil: zeroSignalRecoveryMode = nil
    }

    // Heartpath 5b (#1520): retire the source when THIS take was zero-signal by
    // EITHER confirmation route — the stop-time signal fact (`signalZeroMode`, which
    // fires even when the device-eligibility guess refused, closing the #1520 gap)
    // OR the reactive detector's eligibility-gated stamp (which can confirm a
    // mid-capture zero run whose shape the stop-time samples no longer show — e.g. a
    // real-speech prefix whose zero suffix was already drained). Fenced + idempotent
    // in the manager, which logs truthfully; `capturedCaptureSessionID` (snapshotted
    // before the post-stop awaits) pins it to this take so a stale finish can never
    // retire a newer take's source.
    if let shapeMode = signalZeroMode ?? zeroSignalRecoveryMode {
      let retireResult = audioCapture.retireCapturingSource(sessionID: capturedCaptureSessionID)
      // Route from THIS take's frozen snapshot (`lastResolvedRoute`, set at
      // go-live after all start retries), NOT a live `currentResolvedRoute` read:
      // in the fenced `.staleSession` / `.sourceReplaced` races a live read would
      // describe a NEWER source and misattribute the failed take's transport.
      let takeRoute = lastResolvedRoute
      let effectiveTransport = takeRoute?.effective ?? "unknown"
      // The retire ran on the sample fact alone (no eligibility-gated stamp) —
      // the #1520 signature. Derived from the already-computed stamp outcome,
      // never a re-call of `zeroSignalDeviceEligible()` (which reads a
      // possibly-changed live mute state).
      let healthGuessRefused = signalZeroMode != nil && zeroSignalRecoveryMode == nil
      deadMicRetireAttemptTelemetry(
        DeadMicRetireAttemptContext(
          transport: effectiveTransport,
          selectedTransport: takeRoute?.selected,
          failureShape: shapeMode.rawValue,
          healthGuessRefused: healthGuessRefused,
          warmPolicy: audioCapture.warmEnginePolicy.rawValue,
          retireAction: retireResult.rawValue,
          routeFallbackReason: takeRoute?.routeFallbackReason))
      // Arm the recovery watch ONLY when teardown actually ran — a fenced no-op
      // can never be credited a later recovery. A watch already pending means the
      // previous retire's later take also retired: emit that as recovered=false.
      if retireResult == .retired {
        if let priorOutcome = captureTelemetry.armDeadMicWatch(
          DeadMicRetireWatch(shape: shapeMode.rawValue, transport: effectiveTransport),
          sessionID: capturedCaptureSessionID)
        {
          deadMicRecoveryTelemetry(priorOutcome)
        }
      }
    }

    // #1317 / heartpath 5b — the eligibility-gated TERMINAL (unchanged): only an
    // ELIGIBLE `.allZeroFromStart` takes the honest `.zeroSignal` terminal — ahead of
    // the VAD no-speech gate that would otherwise report an exact-zero capture as
    // quiet-room silence (§3.6 N1); an ineligible/quiet all-zero falls through and
    // stays `.noSpeech`. Placement stays below the too-short / no-audio gates:
    // capture samples include PRE-ROLL, so a sub-500ms visible tap can still carry
    // >= 16000 samples; terminating as zero-signal above them would hijack sessions
    // that correctly discard as `.tooShort` today.

    if zeroSignalRecoveryMode == .allZeroFromStart {
      finishTerminal(.failed(.zeroSignal), sid: sid)
      return
    }
    // `.becameZeroMidCapture` / `nil`: fall through. On mid-capture the non-zero
    // prefix is trimmed just below and still transcribed and pasted (§3.4).

    // #1317 fast-follow (cloud review PR #1512 + live UAT repro): trim the
    // confirmed trailing zero suffix out of the salvaged capture ONCE, here —
    // the single point downstream of BOTH ways `.becameZeroMidCapture` gets
    // confirmed (the reactive mid-capture detector, stamped at
    // `telemetryState.zeroSignalFailureMode` above before `captureResult`
    // even existed; or the STOP-time backstop just above) and upstream of
    // every consumer that would otherwise average the zero suffix into a
    // real-speech decision — the no-speech dead-air gate below, whose
    // whole-buffer RMS a long zero suffix can dilute under a quiet real
    // utterance's own floor (the reported bug: real words silently
    // discarded). Device-eligibility for the STOP-time branch was already
    // checked in the `if` above; the reactive branch was already
    // eligibility-gated when `AudioCaptureManager` stamped it (§3.0).
    if telemetryState.zeroSignalFailureMode == .becameZeroMidCapture {
      let suffixCount = Self.trailingZeroSuffixCount(captureResult.samples)
      if suffixCount > 0 {
        captureResult = CaptureResult(
          samples: Array(captureResult.samples.dropLast(suffixCount)),
          vadSegments: captureResult.vadSegments,
          metadata: captureResult.metadata)
      }
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
        telemetryState.noSpeechTelemetry = KernelNoSpeechTelemetry(
          mode: isStreamingSession ? "streaming" : "batch",
          rawSampleCount: captureResult.samples.count,
          peakAudioLevel: rawPeakAudioLevel
        )
        // #1317 N2: a classified zero-signal session emits ONLY the new
        // failure-mode event — never the legacy zombie telemetry too.
        // `zombie_engine_zero_peak` stays the fallback for an exact-zero
        // capture that was NOT confidently classified (mute/liveness
        // ambiguity fails closed above, §3.6).
        if telemetryState.zeroSignalFailureMode == nil {
          emitZombieZeroPeakIfNeeded(
            rawSamples: captureResult.samples,
            peakAudioLevel: rawPeakAudioLevel
          )
        }
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
        finishTerminal(.noSpeech(.vadGate), sid: sid)
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
    // VAD segments come from the in-process path (PR-4.5 #5, Codex r1+r2).
    // `AudioCaptureManager.stopCapture()` returns segments
    // empty — the in-process `SilenceDetector` owns them; the VAD seam
    // (`CaptureVADSignalSource.segmentsProvider`) bridges them in. Prefer
    // the bundled source when present (XPC works out of the box today);
    // fall back to the seam for direct-mode (which PR-4b wires up).
    let xpcSegments = captureResult.vadSegments
    let rawVadSegments = !xpcSegments.isEmpty ? xpcSegments : vad.speechSegmentsAtStop()
    // #1317 fast-follow (Grounded Review r1): an OPEN segment (speech never
    // resolved to silence before the recording ended) finalizes its end at
    // the ORIGINAL full sample count — the zero-signal reactive detector's
    // 1s confidence window can fire before the VAD silence timeout (1.5s
    // default) ever closes it. Clamp every segment into the buffer's ACTUAL
    // (possibly zero-suffix-trimmed above) coordinate space so
    // `vadSpeechDurationMs` / the adapter's `voicedDurationSec` / LID window
    // count never count samples that no longer exist — `SampleFilter` and
    // WhisperKit's own backend already clamp defensively so this was never a
    // crash risk, only a silently-inflated-duration one.
    let vadSegments = Self.clampSegments(rawVadSegments, to: captureResult.samples.count)
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
    guard isCurrent(sid), recordingOutcome == nil else { return }
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

    // #1707 GitHub Codex code-diff r16: an ASR-interruption recovery always
    // decodes in batch mode — `readyForBatchDecode` is the only recovery
    // outcome that ever reaches a real decode below (`.failed`/`.cancelled`
    // both terminate before `finalize()` runs, so a wrongly-batch
    // conditioning result on those paths is simply discarded, never
    // decoded). `isStreamingSession` itself isn't corrected until the
    // recovery switch resolves (further down this function), which is AFTER
    // this conditioning block already ran — so conditioning must consult
    // the salvage source directly, not wait for that later correction, or a
    // streaming session recovered from a crash skips the #950 tail-preserve
    // rescue entirely and can permanently lose genuine speech VAD trimmed
    // off the tail.
    let effectivelyBatch =
      !isStreamingSession || telemetryState.interruptedSalvageSource == .asr
    // #950 tail-trim diagnostic. Eligible = the engine decodes the conditioned
    // (VAD-trimmed) batch buffer (Parakeet, via capability) AND this is a batch
    // session; only then does "trailing audio the VAD trim dropped before ASR"
    // mean anything (WhisperKit decodes the raw capture, so the trim does not
    // touch its ASR input). Metadata only; never gates the heart path.
    let tailEligible =
      adapter.capabilities.decodesConditionedBatchSamples && effectivelyBatch
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
      // #1707 GitHub Codex code-diff r16: `effectivelyBatch`, not the
      // not-yet-corrected `isStreamingSession` — an asr-empty diagnostic for
      // a recovered-streaming session must not mislabel itself "streaming"
      // when the decode it describes is actually batch.
      mode: effectivelyBatch ? "batch" : "streaming",
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

    // Transcribing — enter `.delivering` with the `.transcribing` sub-phase
    // (cancel + ASR-interrupt still accepted; the safe point is not yet in force).
    let asrStart = CFAbsoluteTimeGetCurrent()
    markASRTimingStart(isStreamingSession)
    deliveringPhase = .transcribing
    transition(to: .delivering)
    // #1707: an ASR-interruption salvage must confirm the engine is actually
    // ready before decoding — the connection that crashed is the SAME one
    // `finalize` would otherwise call into. For every other exit the adapter
    // was never touched, so this check is a no-op cost (WhisperKit) or is
    // skipped entirely (the guard below is false).
    if telemetryState.interruptedSalvageSource == .asr {
      // #1707 Codex code-diff r6: the app.log file sink only carries
      // second-granularity ISO8601 timestamps, and the nearby
      // "Pipeline timing: ASR started" line fires from `markASRTimingStart`
      // above, BEFORE this await even begins — neither can bracket the
      // recovery window. Measure it directly with a high-resolution Swift
      // clock and log the precomputed elapsed value so no external timing
      // (log-scraping or state-polling) has to infer it.
      let recoveryStart = CFAbsoluteTimeGetCurrent()
      let recovery = await adapter.recoverFromASRInterruption()
      let recoveryMs = Int((CFAbsoluteTimeGetCurrent() - recoveryStart) * 1000)
      log("ASR recovery latency: \(recoveryMs)ms outcome=\(recovery) sid=\(sid.raw)")
      guard isCurrent(sid), recordingOutcome == nil else { return }
      switch recovery {
      case .readyForBatchDecode:
        // #1707 Codex code-diff r2: stamped optimistically here; if decode
        // then fails, `interruptedTerminalFloor` upgrades this to
        // `.decodeFailed` — the floor is the one place that sees the FINAL
        // outcome regardless of which terminal call site produced it.
        telemetryState.asrSalvageOutcome = .rewarmSucceeded
        // #1707 GitHub Codex cloud review: `readyForBatchDecode` means
        // exactly what it says — the finalize below always decodes in
        // batch mode now, regardless of whether THIS session originally
        // started streaming. `isStreamingSession` is a session-start-time
        // flag (set once in `beginSession`) that a mid-session ASR crash
        // never revisits; left stale at `true` for an originally-streaming
        // session, it would wrongly skip the #1434 degraded-lead salvage
        // ladder below (gated on `!isStreamingSession`) for exactly the
        // Bluetooth-poisoned-lead failure that ladder exists to rescue.
        // The adapter's own `streamingActive = false` (set at the top of
        // `recoverFromASRInterruption()`) already made this same correction
        // one layer down; this is the kernel-level twin of that fix.
        isStreamingSession = false
      case .failed:
        telemetryState.asrSalvageOutcome = .rewarmFailed
        finishTerminal(.asrInterrupted(wasRecording: true), sid: sid)
        return
      case .cancelled:
        telemetryState.asrSalvageOutcome = .cancelled
        finishTerminal(.asrInterrupted(wasRecording: true), sid: sid)
        return
      }
    }
    let outcome = await finalize(sid, batchSamples: asrSamples)
    guard isCurrent(sid), recordingOutcome == nil else { return }
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
      // #1707 Phase 2: the core fields (duration/char-count/mode/language) are
      // stamped via the shared helper both this ordinary success path and the
      // retry-success path (§3.3) use, so a retry-rescued completion can never
      // skip this telemetry the way a bare `runFinalizing` call would. This
      // branch then layers its own tail-clip/streaming/salvage-specific fields
      // on top — a retry has no separate tail-trim/streaming event of its own,
      // so those stay nil there (never duplicated from a stale first attempt).
      stampAcceptedTranscriptTelemetry(
        result: result, mode: isStreamingSession ? "streaming" : "batch")
      var completedTelemetry = telemetryState.asrCompletedTelemetry!
      // PR-5 Rung 5 Pass 2 r2 #B1: carry the incremental-vs-batch outcome into
      // the ASR-completed Sentry breadcrumb (parity with OLD
      // `WhisperKitPipeline.swift:1049-1052`). nil for Parakeet.
      completedTelemetry.incrementalAccepted = adapterDiag?.incrementalAccepted
      // #950 tail-trim diagnostic (eligible Parakeet batch only; nil omitted).
      completedTelemetry.droppedTailMs = tailDroppedMs
      completedTelemetry.tailHadEnergy = tailHadEnergy
      // #950 tail-preserve recovery + tuning signals.
      completedTelemetry.usedTailPreservation = usedTailPreservation
      completedTelemetry.recoveredTailMs = recoveredTailMs
      completedTelemetry.tailVoicedFraction = tailVoicedFractionForTelemetry
      completedTelemetry.tailRefusedReason = tailRefusedReason
      completedTelemetry.tailClipClassification = tailClip.classification.rawValue
      completedTelemetry.captureTrailingSilenceMs = tailClip.trailingSilenceMs
      completedTelemetry.captureTail200Rms = Double(tailClip.tail200RMS)
      completedTelemetry.captureTail200Peak = Double(tailClip.tail200Peak)
      completedTelemetry.asrInputDurationMs = tailClip.asrInputDurationMs
      completedTelemetry.asrLastTokenEndMs = tailClip.asrLastTokenEndMs
      completedTelemetry.asrLastTokenGapMs = tailClip.asrLastTokenGapMs
      completedTelemetry.asrChunked = tailClip.asrChunked
      // #1309 effective-path streaming telemetry. Requested comes from the
      // kernel's own capability gate; effective/degrade/path from the
      // adapter's diagnostics. WhisperKit-only (nil for Parakeet → omitted).
      completedTelemetry.streamingRequested =
        adapterDiag?.streamingEffective != nil ? isStreamingSession : nil
      completedTelemetry.streamingEffective = adapterDiag?.streamingEffective
      completedTelemetry.streamingDegradeReason = adapterDiag?.streamingDegradeReason
      completedTelemetry.streamingFinalPath = adapterDiag?.streamingFinalPath
      completedTelemetry.streamingDecodeCount = adapterDiag?.incrementalDecodeCount
      completedTelemetry.streamingCoveredSec = adapterDiag?.incrementalSamplesCovered.map {
        Double($0) / AudioConstants.sampleRate
      }
      completedTelemetry.tailDecodeSec =
        adapterDiag?.incrementalTailDecodeMs.map { Double($0) / 1000.0 }
      completedTelemetry.maxUnconfirmedWindowSec = adapterDiag?.streamingMaxUnconfirmedWindowSec
      completedTelemetry.stopWhileDecodeInFlight = adapterDiag?.stopWhileDecodeInFlight
      telemetryState.asrCompletedTelemetry = completedTelemetry
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
          guard isCurrent(sid), recordingOutcome == nil else { return }
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
          guard isCurrent(sid), recordingOutcome == nil else { return }
        }
      }
      if !salvageDelivered {
        if !effectiveSpeechEvidence {
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
          effectiveSpeechEvidence ? .failed(.asrEmpty) : .noSpeech(.asrEmptyNoSpeech),
          sid: sid)
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
      // #1707 Phase 2: give this ONE specific failure (a post-capture decode
      // failure over already-captured audio) exactly one retry before
      // discarding. A pre-capture `beginSession` failure never reaches this
      // switch at all (it fires from a structurally separate catch block), so
      // `hasUsedPhase2Retry` is never even consulted there — zero retries by
      // construction, not by an explicit check.
      guard !hasUsedPhase2Retry else {
        finishTerminal(.failed(.asrFailed), sid: sid)
        break  // fall through to the shared archive tail, matching every other case
      }
      hasUsedPhase2Retry = true
      telemetryState.asrRetryOutcome = .attempted  // breadcrumb BEFORE the await
      let retryInput =
        adapter.capabilities.decodesConditionedBatchSamples
        ? asrSamples : captureResult.samples
      // Oracle timestamp — nil no-op unless a Live UAT test wired a real
      // controller (never happens in release).
      batchDecodeFaultController?.recordRetryStarted()
      let retryOutcome = await withOrderedDeadline(
        seconds: asrRetryDeadlineSec(forSampleCount: retryInput.count),  // measured, length-aware — see §11.1
        operation: { [adapter] in await adapter.retryDecode(inputSamples: retryInput) },
        // No genuine in-flight-decode cancellation exists on either backend.
        // `onTimeout` is honest about this: it bumps the adapter's own
        // retry-generation token (checked INSIDE the adapter's commit step) so
        // a late-arriving result cannot mutate whatever session/state exists
        // by the time it finishes, without pretending to actively stop anything.
        onTimeout: { [weak self, weak adapter] in
          self?.batchDecodeFaultController?.recordRetryTimeoutFired()
          adapter?.bumpRetryGeneration()
        }
      )
      // GitHub cloud review (PR #1725): moved AFTER the currency guard —
      // `markASRTimingEnd()` writes into the kernel's single shared
      // `KernelFinalizationOutcome` instance (`outcome.asrEndedAtSeconds`),
      // not a per-session value. The original pre-guard placement (Codex
      // r2) meant an abandoned session A's retry, resolving after session B
      // has already started and stamped its OWN `asrStartedAtSeconds`,
      // would overwrite B's `asrEndedAtSeconds` with A's stale timestamp
      // before this guard could reject A as stale — corrupting B's ASR
      // latency telemetry even though B's own terminal state stays correct.
      // Only the CURRENT session's telemetry ever reads this field (a
      // stale session's own `finishTerminal` never runs), so stamping it
      // only once currency is confirmed loses nothing for the live case
      // and eliminates the cross-session write for the stale one.
      guard isCurrent(sid), recordingOutcome == nil else { return }
      markASRTimingEnd()
      // Codex r5: a TIMEOUT (`nil`) is NOT a confirmed second failure — the
      // real decode call is still running in the background (no genuine
      // in-flight cancellation exists on either backend, per the comment
      // above) and could still succeed after our still-unmeasured placeholder
      // deadline (§11.1) gave up waiting, especially for a long recording.
      // Conflating "we stopped waiting" with "the decode genuinely produced
      // nothing" would delete recoverable user audio. Leave
      // `asrRetryOutcome` at `.attempted` (never promote to
      // `.retryExhausted`) so `recoveryEnding`/`shouldDeleteOnLiveEnding`
      // retain the spool exactly as a plain `.failed`. GitHub cloud review
      // (PR #1725): `.cancelled` gets the SAME non-exhausted treatment
      // below — only `.empty`/`.failed` are a confirmed decode conclusion
      // with nothing useful; `.cancelled` means we have no conclusion at
      // all, same as the timeout case here.
      guard let retryOutcome else {
        finishTerminal(.failed(.asrFailed), sid: sid)
        return
      }
      switch retryOutcome {
      case .transcript(let retryResult):
        telemetryState.asrRetryOutcome = .retrySucceeded
        // Every Phase-2 retry is batch-only by construction (§3.1's
        // `retryDecode` doc comment) — using `isStreamingSession` here would
        // mislabel a batch retry as "streaming" whenever the ORIGINAL,
        // non-retry attempt happened to be a streaming session.
        stampAcceptedTranscriptTelemetry(result: retryResult, mode: "batch")
        #if DEBUG
          // The archive tail below still reads the ORIGINAL failed outcome
          // unless rebound here — mirrors the salvage-ladder's identical
          // rebind (Codex r1 finding): a successfully delivered, retry-
          // rescued dictation must archive as its own success, not as the
          // primary decode's failure.
          archiveClassification = "phase2RetrySucceeded"
          archiveEffectiveOutcome = .transcript(retryResult)
          // Codex r2 finding: for an originally-STREAMING Parakeet session,
          // the retry's own diagnostics report `batchRescueAttempted ==
          // false` (this is a Phase-2 retry, not the adapter's internal
          // streaming-then-batch-rescue fallback), so the archive tail's
          // heuristic would otherwise misclassify this as a streaming win
          // and archive an empty fed buffer. Reuse the salvage ladder's own
          // override slot — the same "what did this delivery actually
          // decode" escape hatch, mutually exclusive with the salvage
          // ladder's own use of it (that lives in the sibling `.empty` case
          // of this same switch).
          salvageArchiveFed = retryInput
        #endif
        await runFinalizing(sid, asrText: retryResult.text, transcriptID: transcriptID)
      case .failed(let retryError):
        // Codex r3: the retry's OWN failure, not the stale primary-decode
        // error `transcriptionFailureError` was set to before this retry
        // started (`:2172`) — otherwise the Sentry `.asrFailed` capture
        // attributes retry exhaustion to the wrong failure whenever the two
        // attempts fail for different reasons. The terminal choice itself
        // does not differentiate (RULE: discard-not-differentiate) — only
        // this error-attribution field does.
        telemetryState.transcriptionFailureError =
          (adapter as? ASREngineTelemetryProviding)?.lastFailureError ?? retryError
        telemetryState.asrRetryOutcome = .retryExhausted
        finishTerminal(.failed(.asrFailed), sid: sid)
      case .empty:  // genuinely resolved with nothing useful; exhausted
        telemetryState.asrRetryOutcome = .retryExhausted
        finishTerminal(.failed(.asrFailed), sid: sid)
      case .cancelled:
        // GitHub cloud review (PR #1725): `.cancelled` is NOT a confirmed
        // second failure the way `.empty`/`.failed` are — both adapters can
        // return it from a genuine backend `CancellationError` (a real
        // Task/XPC cancellation mid-decode) with THIS session still
        // current, not only from the staleness guard's own supersede path.
        // Either way we have no confirmed decode conclusion, exactly the
        // nil-timeout case above — leave `asrRetryOutcome` at `.attempted`
        // so the spool is retained, never promoted to `.retryExhausted`.
        finishTerminal(.failed(.asrFailed), sid: sid)
      }
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
        // metadata (Codex r6 P3). `runFinalizing`/`finishTerminal` have already
        // run by here, so `recordingOutcome` holds the ending verdict (state has
        // returned to `.idle`, #1548 D1). #1434: applies to salvaged deliveries
        // too via the effective outcome.
        let reachedNoSpeech: Bool = {
          if case .noSpeech = recordingOutcome { return true }
          return false
        }()
        let archiveOutcome = Self.relabeledArchiveOutcome(
          base: Self.dictationArchiveOutcome(
            for: archiveEffectiveOutcome, effectiveSpeechEvidence: archiveSpeechEvidence),
          effectiveOutcome: archiveEffectiveOutcome,
          reachedCompleted: isCurrent(sid) && recordingOutcome == .completed,
          reachedNoSpeech: isCurrent(sid) && reachedNoSpeech)
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
  /// force (PR-1 §B.5). Cancel / interruption from here are ignored. Stays in
  /// `.delivering`; the sub-phase advances to `.finalizing(_)`, which is what
  /// `isLegalConclusion` reads to enforce the safe point (#1548 D1).
  private func runFinalizing(_ sid: SessionID, asrText: String, transcriptID: UUID) async {
    deliveringPhase = .finalizing(.transcribing)
    bump()

    let processed: String
    do {
      processed = try await processText(asrText) { [weak self] in
        self?.deliveringPhase = .finalizing(.polishing)
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
      finishTerminal(.noSpeech(.emptyAfterProcessing), sid: sid)
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

  /// #1707 Phase 3 (§3.2, row 22 — confirmed already safe, no code change):
  /// no `EngineRecoveryGate` mutation claim here. This warm-up runs ONLY from
  /// within an active recording session (the kernel reaches `.arming` — and
  /// therefore this call — before any spawn, and a live session already
  /// structurally precludes a recovery claim from existing, since recovery's
  /// atomic handshake requires `!isDictationActive()`). Documented, not
  /// gated (RULE: close-the-window-never-handle-it).
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
    // #1658 PR J-2: preserve an already-stable model-load error unchanged;
    // normalize the XPC last-resort raw NSError into an explicit stable
    // identity so its own domain#code survives to Sentry.
    if let thrownError {
      telemetryState.modelLoadError =
        SentryCaptureBoundaryError.normalizingModelLoadFailure(thrownError)
    }
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
  /// PR-4b.1: the shared `AudioCaptureInterface` callbacks
  /// (`onEngineInterrupted`, `onCaptureStalled`) are no
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
  // `AudioCaptureInterface` callbacks (`onEngineInterrupted`,
  // `onCaptureStalled`). The App-side routers stay as sole subscribers; the
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
  // not by `recordingOutcome == nil`. `routeASRInterruption` similarly switches on
  // state and falls through to `default: return` for non-recording /
  // non-transcribing states.

  /// Route an external audio-interruption (BT disconnect, mic route change)
  /// into the FSM. Replaces the removed direct subscription to
  /// `audioCapture.onEngineInterrupted`. Idempotent: a second call after a
  /// terminal short-circuits via `recordingOutcome == nil`.
  func externalEngineInterrupted(_ cause: EngineInterruptionCause) {
    guard recordingOutcome == nil else { return }
    // Stamp the cause + freeze the recording snapshot ONLY on the interruption
    // that actually latches the exit (first-wins), BEFORE delivering it so the
    // observer reads the right cause at conclusion (the exit resolves the
    // recording-loop continuation, which then concludes `.audioInterrupted`). A
    // later callback in the post-latch / pre-conclusion window — `state` still
    // `.live` but `recordingExitLatched` already true — has its exit ignored by
    // `deliverRecordingExit`, so it must NOT overwrite the cause/snapshot the
    // conclusion will use (cloud review #1207: an already-owned `.deviceRemoved`
    // could otherwise be replaced by a stale `.engineLost` and mislabel the
    // loss). The guard mirrors `deliverRecordingExitIfCurrent`'s accept
    // condition. An interruption OUTSIDE `.live` (during Arming / Stopping)
    // takes the driver's fallback path, NOT this FSM route (§5.2 parity).
    if state == .live, !recordingExitLatched {
      telemetryState.interruptionCause = cause
      freezeRecordingSnapshot()
    }
    deliverRecordingExitIfCurrent(.audioInterruption, sid: currentSessionID)
  }

  /// Route an external ASR-XPC interruption (the ASR helper crashing,
  /// equivalent in shape to the adapter's own engine-crash) into the FSM.
  /// Mirror of the internal `routeASRInterruption(sid:)` path.
  func externalASRInterrupted() {
    guard recordingOutcome == nil else { return }
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
  ///
  /// #1317 §3.2 / #1548 D2: routes by `ctx.failureMode` AND lifecycle state.
  /// - `.noBuffers` + no buffer ever (`bufferCountThisSession == 0`) → dead mic:
  ///   `finishTerminal(.noTransport)` ("No audio captured", spool retained).
  /// - `.noBuffers` after a buffer arrived → `.captureStall` (routed via the
  ///   pending slot from `.arming`, `deliverRecordingExitIfCurrent` from `.live`).
  /// - `.allZeroFromStart` / `.becameZeroMidCapture` → the dedicated `.zeroSignal`
  ///   exit through the recording-exit channel from both `.arming` and `.live`.
  func externalCaptureStalled(_ ctx: CaptureStallContext) {
    guard recordingOutcome == nil else { return }
    switch ctx.failureMode {
    case .noBuffers:
      guard state == .arming || state == .live else { return }
      // First-wins (Codex r2 defect 2): a stop/cancel/recording-exit may already
      // own the result while `recordingOutcome` is still nil. `finishTerminal`
      // only checks `recordingOutcome == nil`, so a direct `.noTransport` here
      // would override a latched stop. Honor the earlier winner.
      guard !stopLatched, !cancelRequested, !recordingExitLatched else { return }
      if bufferCountThisSession == 0 {
        // Dead mic — no audio ever arrived. "No audio captured", spool retained.
        finishTerminal(.noTransport, sid: currentSessionID)
      } else {
        // A buffer arrived, then the stream stalled. `.captureStall` must survive
        // even if the watchdog fires while still `.arming` (pre-roll bumped the
        // count but `beginCapturePhase` is suspended) — `deliverRecordingExitIfCurrent`
        // rejects anything outside `.live`, so route through the pending slot
        // from `.arming` (Codex r2 defect 3).
        switch state {
        case .arming: deliverRecordingExit(.captureStall)
        case .live: deliverRecordingExitIfCurrent(.captureStall, sid: currentSessionID)
        case .idle, .stopping, .delivering: break
        }
      }
    case .allZeroFromStart, .becameZeroMidCapture:
      // First-wins (Codex code-diff P2): symmetric with the `.noBuffers` branch —
      // a stop/cancel or recording-exit that already won must not be overwritten by
      // a later zero-signal, and the post-`beginCapturePhase` checkpoint honors an
      // exit latched here over a later stop.
      guard !stopLatched, !cancelRequested, !recordingExitLatched else { return }
      // A zero-signal can fire while still `.arming` (pre-roll sample callbacks
      // run during a suspended `beginCapturePhase`, Codex r1 Q2c). Route it
      // through the general recording-exit channel from both states; the pending
      // slot preserves an exit delivered before `awaitRecordingExit()` installs
      // its continuation (§3.4). No Arming-specific latch.
      switch state {
      case .arming: deliverRecordingExit(.zeroSignal(ctx.failureMode))
      case .live: deliverRecordingExitIfCurrent(.zeroSignal(ctx.failureMode), sid: currentSessionID)
      case .idle, .stopping, .delivering: break
      }
    }
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
        // by the source's `PreRollForwarder` for the
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
        // #1548 D2: "first converted buffer arrived" is plain telemetry now —
        // `bufferCountThisSession` records it. The forward path owns the
        // `.arming → .live` transition; a buffer no longer drives the state.
        self.bump()
      }
    }
  }

  /// Establish the Live-specific facts of a session (#1548 D2) — recording-start
  /// stamps, resolved-route snapshot, VAD start. Lifted from the deleted
  /// `commitLiveFromFirstBuffer`; the forward path calls it once, immediately
  /// after the `.arming → .live` transition. It does NOT clear prior-session
  /// markers (`lastStopReason`, `lastSalvagedLeadTrimMs`, `lastCaptureHealth`,
  /// `lastRecordingDurationSeconds`) — that moved to `resetSessionState()` so a
  /// zero-signal exit queued before Live keeps its reason (§3.4).
  private func beginLiveRecording(_ sid: SessionID) {
    guard isCurrent(sid), state == .live, recordingOutcome == nil else { return }
    recordingStartedAtDate = Date()
    recordingStartedAtUptimeNs = DispatchTime.now().uptimeNanoseconds
    // #1376: snapshot the resolved route AFTER all start retries so the recorded
    // value reflects the FINAL resolved route.
    lastResolvedRoute = audioCapture.currentResolvedRoute
    // Stamp visible-recording start for the #4 discard gate (PR-4.5 #4, §5b).
    // Set ONLY after the transition to `.live`; pre-roll buffers fed earlier do
    // not count toward minimum-duration.
    recordingStartedAtTick = currentTick()
    resourcesReleased = false
    (vad as? CaptureVADSignalSource)?.startMonitoring(
      recordingStartTime: Date(),
      isRecording: { [weak self] in
        self?.state == .live && self?.currentSessionID == sid
      }
    )
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
        guard self.state == .live else { continue }
        self.onApproachingMaxDuration?(warning.remainingSeconds)
      }
    }
  }

  // MARK: Recording-exit channel

  private func awaitRecordingExit() async -> RecordingExit {
    if let pending = pendingRecordingExit {
      pendingRecordingExit = nil
      // Duration ownership (Codex r2 defect 4): a zero exit queued from `.arming`
      // was delivered before `beginLiveRecording` stamped `recordingStartedAtDate`,
      // so `deliverRecordingExit` could not record the length. Stamp it HERE, on
      // the consume path, now that Live timing exists — keeping `beginLiveRecording`
      // Live-facts-only.
      if lastRecordingDurationSeconds == nil, let start = recordingStartedAtDate {
        lastRecordingDurationSeconds = Date().timeIntervalSince(start)
      }
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
    case .zeroSignal(let mode): lastStopReason = "zero_signal_\(mode.rawValue)"
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
    guard isCurrent(sid), state == .live else { return }
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
    log("ASR interruption routed sid=\(sid.raw) state=\(state)/\(deliveringPhase)")
    switch state {
    case .live:
      // #1707: stamp the salvage source ONLY if this call is the winning
      // exit (mirrors `externalEngineInterrupted`'s first-wins guard) — a
      // second interruption arriving in the post-latch window must not
      // overwrite an already-stamped `.engine(cause)` with `.asr`.
      if !recordingExitLatched {
        telemetryState.interruptedSalvageSource = .asr
      }
      freezeRecordingSnapshot()
      deliverRecordingExit(.asrInterruption)
    case .delivering where deliveringPhase == .transcribing:
      // Pre-transcript delivering — the continuation is gone, so conclude
      // directly. `wasRecording: false` (not `.live`) folds in the observer's
      // old `priorState == .recording` distinction (§3.7).
      freezeRecordingSnapshot()
      finishTerminal(.asrInterrupted(wasRecording: false), sid: sid)
    default:
      // `.arming` / `.stopping` / `delivering(.finalizing(_))` (safe point) —
      // unchanged prior drop (out of scope for #7 / #1548).
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

  /// The legal FSM edges (#1548 D1 — the 5-state table). Any pair not listed
  /// here is a forbidden transition — `transition(to:)` refuses it. The ending
  /// CATEGORY moved to `recordingOutcome`, so every conclusion is now
  /// `<active> → idle`; which OUTCOME is legal from which state is enforced
  /// separately by `isLegalConclusion` (the category-legality the old 14-state
  /// table used to carry on the terminal edges).
  private func isLegalTransition(
    from current: RecordingSessionState, to next: RecordingSessionState
  ) -> Bool {
    if current == next { return false }
    switch current {
    case .idle:
      // Only `start` — `idle → arming`.
      return next == .arming
    case .arming:
      // Capture established (`→ live`, #1548 D2 — sequential, no first-buffer
      // gate) or a conclusion (`→ idle`, outcome set).
      return next == .live || next == .idle
    case .live:
      // Stop accepted (`→ stopping`) or a conclusion (`→ idle`).
      return next == .stopping || next == .idle
    case .stopping:
      // ASR begins (`→ delivering`) or a conclusion (`→ idle`).
      return next == .delivering || next == .idle
    case .delivering:
      // Only a conclusion (`→ idle`); the transcribing/finalizing sub-phase is
      // carried by `deliveringPhase`, not by an FSM transition.
      return next == .idle
    }
  }

  /// Which ending OUTCOME is legal from which state (#1548 D1) — the
  /// category-legality the old 14-state transition table enforced on its
  /// terminal edges, now that every conclusion is `<active> → idle`. Mirrors
  /// the old table's terminal edges EXACTLY (plus `.noTransport` from Arming AND
  /// Live, #1548 D2), so no session the old code could conclude is stranded here.
  /// Evaluates the
  /// POST-`interruptedTerminalFloor` outcome (r3 Q2.2): the floor can raise a
  /// no-transcript ending to `.audioInterrupted` from `stopping` /
  /// `delivering(_)`, so `.audioInterrupted` is legal there. `finishTerminal`
  /// refuses an illegal pair BEFORE setting `recordingOutcome`.
  private func isLegalConclusion(
    outcome: RecordingOutcome,
    from current: RecordingSessionState,
    deliveringPhase phase: DeliveringPhase
  ) -> Bool {
    switch current {
    case .idle:
      // Nothing concludes from a resting/already-concluded idle.
      return false
    case .arming:
      // Old preparing/warmingUp terminal edges + the new no-transport exit.
      switch outcome {
      case .failed, .discarded, .cancelled, .noTransport:
        return true
      case .completed, .noSpeech, .audioInterrupted, .asrInterrupted:
        return false
      }
    case .live:
      // Old recording terminal edges, plus `.noTransport` (#1548 D2 — the
      // dead-mic no-buffer watchdog can fire while `.live` now the first-buffer
      // gate is gone; §3.3). `.asrInterrupted` is `wasRecording: true` ONLY from
      // `.live` (impl-design consult, Decision 4 — the payload is legality-checked
      // so a wrong flag cannot corrupt `was_recording`).
      switch outcome {
      case .failed, .discarded, .cancelled, .audioInterrupted, .noTransport:
        return true
      case .asrInterrupted(wasRecording: true):
        return true
      case .asrInterrupted(wasRecording: false), .completed, .noSpeech:
        return false
      }
    case .stopping:
      // Old stopping terminal edges (incl. the floored `.audioInterrupted`).
      switch outcome {
      case .failed, .noSpeech, .discarded, .cancelled, .audioInterrupted:
        return true
      case .asrInterrupted(wasRecording: false):
        return true
      case .asrInterrupted(wasRecording: true):
        // #1707: legal here ONLY for the typed ASR-interruption salvage this
        // session is actually running (the floor emits this exact payload
        // when the recovery capability fails before decode even starts) —
        // never for an ordinary caller forging the live-time payload from a
        // later phase.
        return telemetryState.interruptedSalvageSource == .asr
      case .completed, .noTransport:
        return false
      }
    case .delivering:
      switch phase {
      case .transcribing:
        // Old transcribing terminal edges. `.asrInterrupted(false)` is the
        // pre-existing direct producer (routed from `delivering(.transcribing)`
        // by a genuinely NEW interruption at that phase); `.asrInterrupted(true)`
        // is #1707's salvage-recovery-failure floor target, typed-gated below.
        switch outcome {
        case .failed, .noSpeech, .cancelled, .audioInterrupted:
          return true
        case .asrInterrupted(wasRecording: false):
          return true
        case .asrInterrupted(wasRecording: true):
          return telemetryState.interruptedSalvageSource == .asr
        case .completed, .discarded, .noTransport:
          return false
        }
      case .finalizing:
        // Old finalizing terminal edges — the SAFE POINT: no `.cancelled`, no
        // fresh `.asrInterrupted` signal can reach here (kernel routing
        // ignores an interruption arriving at this phase, §5.2). #1707: the
        // ONE typed exception — `runFinalizing`'s own empty-after-processing
        // path can still call `finishTerminal(.noSpeech(...))` from here even
        // after a successful salvage decode, and the floor (applied inside
        // `finishTerminal`, BEFORE this check) remaps that to
        // `.asrInterrupted(wasRecording: true)` for the `.asr` source — so
        // this phase must accept exactly that remapped outcome, still gated
        // on the typed source, never a raw new interruption.
        switch outcome {
        case .completed, .failed, .noSpeech, .audioInterrupted:
          return true
        case .asrInterrupted(wasRecording: true):
          return telemetryState.interruptedSalvageSource == .asr
        case .cancelled, .discarded, .asrInterrupted(wasRecording: false), .noTransport:
          return false
        }
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
  /// `.discarded` / `.noSpeech` DELETE the spool (they project to a delete ending;
  /// #1464). Letting an interrupted session reach either would destroy the
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
  /// lives at its own single authority (#1558: the driver stamps a typed
  /// `TerminalNoticeReason` and `DictationNarrator` authors the copy), so
  /// the floor no longer has to encode a copy decision. What the terminal MEANS
  /// (the spool survives) and what the user READS are separate questions with
  /// separate owners — which is the same split `hasRecoverableAudio` and
  /// `isDeviceLoss` draw one layer up.
  ///
  /// `.cancelled` is NEVER floored: an explicit user cancel is honored, and its
  /// retain/delete disposition belongs to the driver's `pendingCancelOrigin`. Every other
  /// `.failed(reason)` (`.asrEmpty`, `.asrFailed`, `.captureStartFailed`,
  /// `.modelLoadFailed`) keeps its own honest reason and is already spool-retaining.
  /// #1707: extended for the ASR-interruption salvage source. `.engine`
  /// keeps the original, narrower protection (deletion-class outcomes only —
  /// every other `.failed(reason)` already retains the spool on its own
  /// honest terminal). `.asr` is WIDER by design: the salvage promises the
  /// SAME terminal every failure mode already produced before salvage
  /// existed, not just the deletion-class subset — restoring
  /// `.asrInterrupted(wasRecording: true)` for any outcome that isn't a
  /// genuine delivery or an explicit user cancel, including reasons (a later,
  /// independent stop-tail failure) that have nothing to do with the
  /// recovery attempt itself. Exhaustive switches (no `default`) so a future
  /// `RecordingOutcome` case forces a deliberate choice here.
  private func interruptedTerminalFloor(
    _ outcome: RecordingOutcome
  ) -> RecordingOutcome {
    switch telemetryState.interruptedSalvageSource {
    case nil:
      return outcome
    case .engine(let cause):
      switch outcome {
      case .discarded, .noSpeech, .failed(.noAudioCaptured):
        return .audioInterrupted(cause)
      case .completed, .cancelled, .failed, .audioInterrupted, .asrInterrupted, .noTransport:
        return outcome
      }
    case .asr:
      switch outcome {
      case .completed:
        return outcome
      case .cancelled:
        // #1707 Codex code-diff r3: a genuine user cancel while recovery or
        // decode is still in flight must overwrite whatever the salvage
        // signal held so far — nil (recovery hadn't returned yet) or
        // `.rewarmSucceeded` (readiness was already confirmed, decode never
        // ran) both misclassify a user-initiated stop as an ASR outcome.
        // Codex code-diff r8: this stamps the queryable signal
        // (`KernelDictationDriver.lastASRSalvageOutcome`) but this `.cancelled`
        // RecordingOutcome itself reaches no production telemetry emitter —
        // `KernelLifecycleTelemetrySink`'s `.cancelled` case deliberately emits
        // nothing (r7, PR-1 §B.7.4's only-one-new-event rule), and that has
        // applied uniformly to every salvage source since before #1707, not
        // just this one. Extending it would mean revisiting that cross-cutting
        // policy, out of scope here.
        telemetryState.asrSalvageOutcome = .cancelled
        return outcome
      case .discarded, .noSpeech, .failed, .audioInterrupted, .asrInterrupted, .noTransport:
        // #1707 Codex code-diff r2: only UPGRADE the telemetry signal — a
        // recovery that already failed/cancelled (stamped at the call site
        // before decode was ever attempted) must not be overwritten here;
        // this branch is reached for BOTH that case (a no-op re-floor of the
        // terminal the call site already chose) and the genuinely new case
        // (recovery succeeded, decode/delivery is what failed).
        if telemetryState.asrSalvageOutcome == .rewarmSucceeded {
          telemetryState.asrSalvageOutcome = .decodeFailed
        }
        return .asrInterrupted(wasRecording: true)
      }
    }
  }

  /// Conclude the session: set the ending `recordingOutcome`, return the FSM to
  /// `.idle`, run nonblocking cleanup, drain the task bag (PR-1 §B.1.6, PR-3
  /// plan §3.1a — cancel + clear, never `await`). Discards the adapter's open
  /// session and stops the capture engine if either is still in flight (PR-1
  /// §B.1.3 cleanup column; Codex P1b / P2-r3). `recordingOutcome != nil` is
  /// the session-concluded barrier (#1548 D1).
  ///
  /// Fixed order (§5.3 r4): floor + `isLegalConclusion` validate → set
  /// `recordingOutcome` → `→ .idle` → drain.
  private func finishTerminal(_ rawOutcome: RecordingOutcome, sid: SessionID) {
    // Set-once barrier: `isCurrent` fences stale sessions; `recordingOutcome ==
    // nil` prevents a double conclusion.
    guard isCurrent(sid), recordingOutcome == nil else { return }
    let outcome = interruptedTerminalFloor(rawOutcome)
    guard isLegalConclusion(outcome: outcome, from: state, deliveringPhase: deliveringPhase) else {
      forbiddenTransitionRejected = true
      log("FORBIDDEN conclusion \(outcome) from \(state)/\(deliveringPhase) — refused")
      return
    }
    let terminal = outcome  // local alias for the existing telemetry logs below
    recordingOutcome = outcome
    // #1548 D2: wake a forward path parked in `awaitRecordingExit()` when the
    // session is concluded DIRECTLY — the dead-mic `.noTransport` branch of
    // `externalCaptureStalled` calls `finishTerminal` while the forward path sits
    // on the recording-exit continuation. Without this the continuation leaks and
    // the forward task stays suspended forever. The resumed path bails immediately
    // on the `recordingOutcome != nil` barrier (the guard right after
    // `awaitRecordingExit()`), so the resume value is discarded — it exists only to
    // release the continuation. This replaces the removed `wasArming` /
    // `resolveArming(.aborted)` wake, which served the same role for the deleted
    // Arming waiter.
    if let continuation = recordingExitContinuation {
      recordingExitContinuation = nil
      continuation.resume(returning: .userStop)
    }
    guard transition(to: .idle) else { return }
    audioCapture.onBufferCaptured = nil
    // PR-4b.1: `onEngineInterrupted` and `onCaptureStalled`
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
    recordingStartedAtUptimeNs = nil
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
    deliveringPhase = .transcribing
    recordingOutcome = nil
    // #1548 D2 (§3.4): clear prior-session markers HERE (was in
    // `commitLiveFromFirstBuffer` at Live entry). Clearing them at session start
    // instead of Live entry means a zero-signal exit queued from `.arming` — which
    // sets `lastStopReason`/`lastRecordingDurationSeconds` before Live — keeps its
    // reason instead of having it wiped when the session reaches `.live`.
    lastStopReason = nil  // #1060
    lastSalvagedLeadTrimMs = nil  // #1434
    lastCaptureHealth = nil  // #1434
    lastRecordingDurationSeconds = nil  // #1060
    deliveredTranscript = nil
    deliveryOutcome = nil
    didLoadModelThisSession = false
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
    hasUsedPhase2Retry = false  // #1707 Phase 2
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

  /// #1707 Phase 2: shared "accepted transcript" telemetry-population step.
  /// Used by BOTH the ordinary `.transcript` success branch (which layers its
  /// own tail-clip/streaming/salvage-specific fields on top afterward) and the
  /// retry-success branch (§3.3, which adds nothing further — a retry has no
  /// separate tail-trim/streaming event of its own to report, and duplicating
  /// the first attempt's now-stale diagnostic values would be misleading, not
  /// merely incomplete). Without this shared step, a retry-rescued completion
  /// calling `runFinalizing` directly would never populate this telemetry at
  /// all, since `runFinalizing` itself only processes/stores/delivers/completes.
  private func stampAcceptedTranscriptTelemetry(result: ASRResult, mode: String) {
    telemetryState.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: result.processingTime,
      charCount: result.text.trimmingCharacters(in: .whitespacesAndNewlines).count,
      mode: mode,
      language: result.language
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
    diagnostics.captureNativeChannelCount = health.stopMetadata?.nativeChannelCount
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
      guard isCurrent(sid), recordingOutcome == nil else {
        telemetryState.asrEmptyDiagnostics?.salvageAbortedReason = "superseded"
        return nil
      }
      let retry = await finalize(sid, batchSamples: Array(samples[trim...]))
      guard isCurrent(sid), recordingOutcome == nil else {
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

  /// The pure peak/RMS/non-overlapping-640-tile dead-air math now lives in
  /// `EnviousWisprCore.RawAudioDeadAirClassifier` (#1317 PR1) so
  /// `EnviousWisprAudio`'s app-side all-zero detector shares the same
  /// authority instead of a second implementation. This alias + forwarder
  /// keep every existing kernel and test call site (`DeadAirFloor.peak`,
  /// `rawAudioIsDeadAir(...)`) source-compatible.
  typealias DeadAirFloor = RawAudioDeadAirClassifier.DeadAirFloor

  /// True when a raw capture buffer is dead air (no recoverable speech) for the
  /// #964 gate. Forwards to the shared `EnviousWisprCore` classifier.
  nonisolated static func rawAudioIsDeadAir(_ samples: [Float], peak: Float)
    -> Bool
  {
    RawAudioDeadAirClassifier.isDeadAir(samples, peak: peak)
  }

  /// #1317 fast-follow: exact count of trailing exact-zero samples — the one
  /// authority both `classifyZeroSignalAtStop` (below) and the post-capture
  /// `.becameZeroMidCapture` trim in `runForwardPath` use, so the trim
  /// boundary can never disagree with the classification decision that named
  /// the session `.becameZeroMidCapture` in the first place.
  nonisolated static func trailingZeroSuffixCount(_ samples: [Float]) -> Int {
    var count = 0
    for s in samples.reversed() {
      if s == 0 { count += 1 } else { break }
    }
    return count
  }

  /// #1317 fast-follow (Grounded Review r1): clamps every segment's
  /// start/end into `[0, sampleCount]`, dropping a segment that no longer
  /// has any span once clamped. Pure so the boundary cases (in-range,
  /// dangling past the boundary, entirely past the boundary) unit-test
  /// without a kernel. See the call site in `runForwardPath` for why an
  /// open VAD segment can reference a sample count the buffer no longer has.
  nonisolated static func clampSegments(_ segments: [SpeechSegment], to sampleCount: Int)
    -> [SpeechSegment]
  {
    segments.compactMap { segment in
      let start = max(0, min(segment.startSample, sampleCount))
      let end = max(start, min(segment.endSample, sampleCount))
      guard end > start else { return nil }
      return SpeechSegment(startSample: start, endSample: end)
    }
  }

  /// #1317 §3.6 STOP-win row: one-shot classification of a COMPLETE capture
  /// against the same all-zero rules the app-side streaming detector applies
  /// buffer-by-buffer (§3.1) — the backstop for a session whose STOP raced
  /// the detector, or whose capture was too short to reach the detector's
  /// own confidence threshold before it ended. Pure + nonisolated so the
  /// boundary cases unit-test without a kernel. Sample-shape only — the
  /// caller still runs the §3.0 device-alive/not-muted discriminator before
  /// trusting the result.
  nonisolated static func classifyZeroSignalAtStop(_ samples: [Float]) -> CaptureStallFailureMode? {
    guard samples.count >= AudioConstants.minimumTranscriptionSamples else { return nil }
    if samples.allSatisfy({ $0 == 0 }) {
      return .allZeroFromStart
    }
    let suffixZeroCount = Self.trailingZeroSuffixCount(samples)
    guard suffixZeroCount >= AudioConstants.minimumTranscriptionSamples else { return nil }
    let prefixCount = samples.count - suffixZeroCount
    guard prefixCount > 0 else { return nil }
    // #1317 (cloud review P2): a slice view, not `Array(samples[..<prefixCount])`
    // — a 60-minute capture's prefix can be hundreds of MB; copying it just to
    // compute peak/dead-air stats doubles the already-held buffer in the stop
    // path. `isDeadAir` is generic over `RandomAccessCollection` for exactly
    // this call.
    let prefix = samples[0..<prefixCount]
    let prefixPeak = prefix.reduce(Float(0)) { max($0, abs($1)) }
    guard !RawAudioDeadAirClassifier.isDeadAir(prefix, peak: prefixPeak) else { return nil }
    return .becameZeroMidCapture
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

  // Pure classification (no instance state) — `nonisolated static` so it is
  // directly unit-testable via `@testable`.
  nonisolated static func classifyCaptureStartError(_ error: Error) -> RecordingFailureReason {
    // #1558 (cloud review P2 #1563): a missing input device on the toggle/menu
    // start path throws `AudioError.noBuiltInMicrophoneFound`. Classify it
    // distinctly so it surfaces "No microphone found." (parity with the prewarm
    // path's AppKit-side handling), not the generic capture error.
    if let audioError = error as? AudioError, case .noBuiltInMicrophoneFound = audioError {
      return .noMicrophoneFound
    }
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

    /// #1548 D1 test seam — force a CONCLUSION (set `recordingOutcome`, return
    /// the FSM to `.idle`) without driving a full session. Replaces old tests
    /// that forced a terminal STATE (`testForceTransition(to: .completed)` etc.).
    /// Bypasses `isLegalConclusion` so a test can stage any outcome directly.
    func testForceConclude(_ outcome: RecordingOutcome) {
      recordingOutcome = outcome
      state = .idle
      bump()
    }

    /// #1548 D1 test seam — set the FSM state directly to one of the 5 cases
    /// (no legality check), for consumer-mapping tests that need a specific
    /// in-flight state without driving the forward path.
    func testForceState(_ next: RecordingSessionState) {
      state = next
      bump()
    }

    /// The count of task references still held on the kernel — the §3.1a
    /// "no active task references remain after a terminal state" invariant.
    var testActiveTaskCount: Int { taskBag.count }

    // #1558: the three `testSet*Error` hooks that fed the deleted
    // `lastFailureDetail` mapping test were removed with it — dead scaffolding.
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

    /// Test-only delivering-sub-phase setter. Lets unit tests flip the
    /// `.transcribing` ↔ `.polishing` finalizing sub-status without driving a
    /// real polish-step `onWillProcess`. The driver's `overlayIntent` routes
    /// overlay-label text through `deliveringPhase` (#1548 D1). Sets the nested
    /// `.finalizing(status)` sub-phase.
    func testSetFinalizingSubStatus(_ status: FinalizingSubStatus) {
      deliveringPhase = .finalizing(status)
    }

    /// Test-only `deliveringPhase` setter — flip the whole sub-phase
    /// (`.transcribing` vs `.finalizing(_)`) to exercise the cancel safe point.
    func testSetDeliveringPhase(_ phase: DeliveringPhase) {
      deliveringPhase = phase
    }

    /// #1564 (E2): test-only `lastStopReason` setter so a driver test can prove
    /// the transcribing pill maps to `.transcribingMaxDurationReached` after a
    /// 60-minute auto-stop (`"max_duration"`) and `.transcribing` otherwise.
    func testSetLastStopReason(_ reason: String?) {
      lastStopReason = reason
    }

    /// #1408: surface the terminal floor as a pure function so a test can prove it
    /// covers EVERY outcome that would delete the spool. The floor's mapped set and
    /// the coordinator's spool-deleting endings (`KernelDictationDriver.recovery
    /// Ending` → `RecoveryCoordinator.shouldDeleteOnLiveEnding`, #1464) are two lists
    /// of the same fact; without this seam they can drift, and a new spool-deleting
    /// outcome would silently escape the floor.
    func testInterruptedTerminalFloor(_ outcome: RecordingOutcome)
      -> RecordingOutcome
    {
      interruptedTerminalFloor(outcome)
    }

    /// #1548 D1 test seam — surface `isLegalConclusion` against the kernel's
    /// CURRENT `state` + `deliveringPhase` so a suite can walk the FSM to a state
    /// and assert which outcomes may legally conclude from it (the safe-point
    /// legality the old 14-state `isLegalTransition` terminal edges used to
    /// carry, #1358). Mirrors how `finishTerminal` calls it.
    func testIsLegalConclusion(_ outcome: RecordingOutcome) -> Bool {
      isLegalConclusion(outcome: outcome, from: state, deliveringPhase: deliveringPhase)
    }
  #endif
}
