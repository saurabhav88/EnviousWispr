@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore

/// #4601 §3a: the microphone-start budget. One absolute deadline is minted from the record press
/// (dictation) or the meeting start, before the first route or probe read, and every later step of
/// that start (pre-warm, the take's own prepare, stabilization and the one rebuild) spends what is
/// left of it. Nothing renews it. Waits that are not microphone work do not spend it: a press
/// waiting for its engine turn mints its deadline after that wait, and the kernel moves the
/// deadline later by the speech model's load time (founder 2026-11-15 for the engine turn; the
/// model load follows the same rule, #4601 whole-diff review).
public enum MicrophoneStartBudget {
  /// An absolute microphone-start deadline.
  public typealias Deadline = ContinuousClock.Instant

  public static let duration: Duration = .seconds(5)

  /// The deadline of a start whose origin (the press, or the meeting start) is `origin`.
  public static func deadline(from origin: ContinuousClock.Instant) -> ContinuousClock.Instant {
    origin + duration
  }
}

/// Abstraction over audio capture — enables swapping between in-process and XPC implementations.
@MainActor
public protocol AudioCaptureInterface: AnyObject {
  // Observable state (read-only externally)
  // periphery:ignore - protocol requirement; prod reads concrete impls
  var isCapturing: Bool { get }
  var audioLevel: Float { get }
  var capturedSamples: [Float] { get }
  /// Low-cardinality audio route label for Sentry. Set after route resolution.
  var currentAudioRoute: String { get }
  /// The resolved-route transports observed for the current session (selected
  /// vs effective transport, route reason, input-selection mode, output
  /// transport), derived from the resolver decision. `nil` before the first
  /// route resolution. Telemetry-only observation — nothing branches capture on
  /// it (#1376).
  var currentResolvedRoute: ResolvedRouteTransports? { get }
  /// #1714: see the defaulted implementation below.
  var currentInputResolutionSource: String? { get }

  // Callback properties (read-write)
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
  /// Fires when a live recording is lost to an audio-engine interruption. The
  /// `EngineInterruptionCause` lets the consumer route the lost-dictation
  /// capture for `.engineLost` only, suppressing the three already-owned causes
  /// (issue #1174 A3).
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)? { get set }
  var onVADAutoStop: (() -> Void)? { get set }
  /// Fires when the manager's hard sample-count backstop (3660s) trips — a
  /// NORMAL auto-stop, not a loss (#1408 A3; it used to masquerade as
  /// `onEngineInterrupted(.maxDurationReached)`). The graceful 3600s wall-clock
  /// cap lives host-side in `VADMonitorLoop` and never fires this; this
  /// callback exists so the backstop reaches the same typed `.maxDuration`
  /// stop route when the graceful cap wedges. Single-owner:
  /// `CaptureVADSignalSource` claims it alongside `onVADAutoStop`.
  var onMaxDurationReached: (() -> Void)? { get set }

  // Telemetry callbacks (round-4 additions for #285 heart-path Sentry coverage).
  // Producer: the sole capture backend (`HALDeviceInputSource`, via
  // `AudioCaptureManager`). Consumers: pipeline + app-shell layers.
  // All callbacks fire on the MainActor.

  /// Fires once per capture session when the liveness watchdog observes zero
  /// audio buffers within `Constants.audioCaptureStallWindowMs` of tap install
  /// (#4841: the only producer; exact zeros never report a stall). At most one
  /// call per `currentCaptureSessionID` (the manager's `captureStallReported`
  /// latch). Never called after a subsequent
  /// `stopCapture` for that session. Telemetry-only: consumers must not treat
  /// this as a control-flow signal.
  var onCaptureStalled: ((CaptureStallContext) -> Void)? { get set }

  /// Fires on the first route resolution and on every subsequent resolution
  /// where sourceType or reason differs from the prior call. No-op on
  /// warm-reuse resolutions that produce the same decision.
  // periphery:ignore - planned route telemetry API (producers wired, consumer pending)
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)? { get set }

  /// Manager-owned ID for the current capture or preparation attempt.
  /// The live manager claims it before taking over the source. The pipeline
  /// uses it for correlation and dedup. Never persisted across launches.
  var currentCaptureSessionID: UInt64 { get }

  /// Authoritative "is a capture session in-flight right now." Backed by
  /// source/proxy internal state (not pipeline UI state which lags at
  /// start/stop boundaries). Used as the telemetry gate for XPC interrupt
  /// classification.
  var isActivelyCapturing: Bool { get }

  /// Low-cardinality string identifying the concrete capture backend driving
  /// the current session. Value: `"hal_device_input"` (the sole in-process
  /// backend since #1543). Used by
  /// pipeline-layer Sentry extras. Delegates to the active source in direct
  /// mode; constant for the proxy.
  var captureSourceType: String { get }

  /// #1844: the device the capture source ACTUALLY OPENED for the attempt that
  /// recorded — the value its `prepare()` returned — plus the UID needed to
  /// re-verify that identity later. NOT a settings-derived resolution, and not a
  /// live re-read of `preferredInputDeviceIDOverride`/`selectedInputDeviceUID`,
  /// which a mid-session settings change can already have moved past and which
  /// names a microphone HAL may never have opened (it falls back to the system
  /// default when the explicit device is absent). The pipeline layer's
  /// zero-signal device discriminator (§3.0) reads this so its STOP-time backstop
  /// evaluates the device the session actually captured from — only the concrete
  /// capture layer knows exactly when and how many times an engine-start attempt
  /// actually ran. Default `nil` (fail closed).
  ///
  /// COPY this value; do not re-read the source later. Teardown clears the
  /// source's bind, and several teardown paths precede the STOP-time read. Never
  /// treat a `deviceID` match alone as identity — that is what `deviceUID` is for.
  var zeroSignalDiscriminatorDevice: BoundInputDevice? { get }

  /// #1845: which BUILT-IN-family input the bind opened (`built_in_mic` /
  /// `jack_input`), or nil for every other transport. DERIVED once at bind time
  /// from the bound UID and stored, deliberately NOT computed by reading
  /// `zeroSignalDiscriminatorDevice` at emit time.
  ///
  /// The separation is load-bearing, not stylistic. That accessor participates
  /// in the #1844 zero-signal DECISION, read once per STOP; telemetry asking the
  /// same question later would add a second read on a path
  /// `KernelFrozenBindGuardTests` guards. A decision input and an observation
  /// are different concerns even when they describe the same fact.
  var boundInputDeviceKind: String? { get }

  /// #4841: the current run of exact-zero LIVE samples in this take, or `nil`
  /// outside active capture. Drained pre-roll is excluded from both the length
  /// and the since-start test, so a warm microphone's ring cannot shift which
  /// silent-mic notice threshold applies. Observation only: exact zeros never
  /// end a take. MainActor, like the capture ingest that maintains it.
  var exactZeroRun: ExactZeroRun? { get }

  /// #1810: samples this session drained out of the pre-roll ring, clamped
  /// non-negative. Read at STOP so `classifyZeroSignalAtStop` measures only the
  /// live capture.
  ///
  /// **Read here rather than off `CaptureResult.metadata`, and that is the fix for a
  /// cloud-review finding rather than a style choice.** `stopCapture()`'s documented
  /// `activeSource == nil` early return — reachable when an engine interruption is
  /// followed by the user switching "Keep engine warm" off — returns samples with NO
  /// metadata, so a metadata-carried drain silently reverted to 0 on exactly that
  /// path and reinstated the early abort this change exists to remove. The manager
  /// caches the value per session, so it survives the source being torn down.
  var drainedPreRollSampleCount: Int { get }

  // Configuration properties (read-write)
  var selectedInputDeviceUID: String { get set }
  var preferredInputDeviceIDOverride: String { get set }
  /// #2664: per-device input-channel preference (device UID -> 0-based channel).
  /// Mirrored from settings like the two device fields above; the manager reads
  /// it at source construction and at every warm-reuse decision.
  var inputChannelByDeviceUID: [String: Int] { get set }
  var warmEnginePolicy: WarmEnginePolicy { get set }

  // Core lifecycle
  /// `startDeadline` is the take's microphone-start deadline (`MicrophoneStartBudget`); the
  /// rebuild retry passes the same instant.
  func startEnginePhase(startDeadline: ContinuousClock.Instant) async throws
  /// `recoveryPayload` is an opaque encoded `RecoverySpoolDirective` the recording
  /// kernel forwards to arm the crash-recovery limb (#1063 PR1); nil ⇒ no spool.
  /// Every caller except the kernel uses the no-arg `beginCapturePhase()`
  /// convenience in the extension below.
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer>
  /// #1807 — like `beginCapturePhase(recoveryPayload:)`, but also carries the
  /// SAME recording's plain recovery session id, supplied independently of the
  /// opaque `recoveryPayload` — never derived from it, since decoding the
  /// payload is exactly what can fail. The kernel mints both from the same arm
  /// (`RecoveryCoordinator.makeDirective`) and already carries the plain id on
  /// `DictationSessionConfig`, so this costs it nothing to forward. Lets a
  /// coordinator-side writer-completion join still name the session on a
  /// decode failure or a disabled/low-disk refusal, not only on success.
  /// Defaulted below to forward to the payload-only overload — every other
  /// conformer (test fakes, simulator doubles) needs no change.
  /// `AudioCaptureManager` overrides it with the real, id-aware implementation.
  func beginCapturePhase(
    recoverySessionID: String?, recoveryPayload: Data?
  ) async throws -> AsyncStream<AVAudioPCMBuffer>
  /// #1807 round 2 — the kernel calls this when it decides NOT to call
  /// `beginCapturePhase` at all for an armed `recoverySessionID` (a terminal
  /// before capture start: permission denial, an engine-start failure, an
  /// ASR-adapter-start failure, and any future early exit in
  /// `RecordingSessionKernel.runForwardPath`). Also fires from inside
  /// `beginCapturePhase` itself when IT exits before reaching
  /// `startRecoverySpooling` (e.g. no active source). Without this, a session
  /// that armed but never actually spooled leaves its `pendingSessions` entry
  /// waiting on a writer ack that will never arrive — safe for one launch
  /// (§7/§9's accepted "writer completion never arrives" fallback), but never
  /// closed until the next relaunch resets the in-memory table. Defaulted to
  /// a no-op — only `AudioCaptureManager` needs it.
  func recoveryCaptureDidNotStart(recoverySessionID: String)
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>  // periphery:ignore - convenience method combining engine + capture phases
  /// Stop the capture session identified by `sessionID`, returning its samples.
  /// The live manager claims the ID during preparation (#1854). Pass the ID
  /// captured when taking ownership of cleanup. A mismatched ID returns empty
  /// samples without changing the current capture, source, or recovery spool.
  ///
  /// A matching stop still drains the take's accumulated samples after a route
  /// change, format restabilisation, zero-signal retirement, or idle teardown.
  /// Source identity is required for `retireCapturingSource(sessionID:)`, which
  /// tears down a particular retained source. Cleanup uses the captured ID even
  /// if that source is gone.
  func stopCapture(sessionID: UInt64) async -> CaptureResult
  func rebuildEngine()
  /// Retire (tear down) the source that captured the session identified by
  /// `sessionID`, so the next press opens a fresh one. Fenced + idempotent: a
  /// no-op unless `sessionID` is still the current capture session AND the
  /// retained source that captured it is still the running active source
  /// (#1520 / heartpath 5b — a completed zero-signal take must not hand a dead
  /// Bluetooth link to later takes, and a stale finish must never tear down a
  /// newer take's source).
  @discardableResult
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult
  /// `startDeadline`: the press's microphone-start deadline, shared with the take's own prepare.
  func preWarm(startDeadline: ContinuousClock.Instant) async throws
  func abortPreWarm()
  /// #4601 §5: give up the start that is still being prepared, at once: a waiting route, probe or
  /// open resumes now with cancellation and nothing it was preparing is kept. Unlike
  /// `abortPreWarm()` it never tears down a microphone that is already open and idle (the
  /// Keep engine warm policy still owns that). Synchronous; a no-op with nothing pending.
  func abandonPendingStart()
  /// #4601 §3a: whether the start whose deadline is `startDeadline` was given up by
  /// `abandonPendingStart()` at or after its press. The kernel asks once its session exists (so no
  /// later abandon can belong to this press) before it moves the deadline past model loading.
  func isStartAbandoned(startDeadline: ContinuousClock.Instant) -> Bool
  /// #3878: this session's take ended before capture started (a refused or failed start), so
  /// apply the Keep engine warm policy to any prepared or warm source now, as if a recording had
  /// just stopped. A no-op while capturing or with no source. Never throws or suspends.
  func releaseUnstartedCapture()
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool

  // VAD (Step 5)
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int)
  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  func getVADSegments() async -> [SpeechSegment]
}

extension AudioCaptureInterface {
  /// Begin capture without arming crash recovery — the default for every caller
  /// except the recording kernel (which forwards the session's recovery
  /// directive). Keeps all existing no-arg call sites source-compatible after
  /// the `recoveryPayload:` requirement was added (#1063 PR1). Public so
  /// cross-module existential callers (kernel, app shell, tests) resolve it.
  public func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await beginCapturePhase(recoveryPayload: nil)
  }

  /// #1807: default for every conformer that has no reason to track the plain
  /// session id separately from the payload (test fakes, simulator doubles) —
  /// forwards to the payload-only overload, ignoring `recoverySessionID`.
  /// `AudioCaptureManager` overrides this with the real implementation.
  public func beginCapturePhase(
    recoverySessionID: String?, recoveryPayload: Data?
  ) async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await beginCapturePhase(recoveryPayload: recoveryPayload)
  }

  /// #1807 round 2: no-op default — test fakes and simulator doubles have no
  /// writer-completion join to notify. `AudioCaptureManager` overrides it.
  public func recoveryCaptureDidNotStart(recoverySessionID: String) {}

  /// #4601 §3a: default for conformers with no pending-start abandonment (test fakes, simulator
  /// doubles). `AudioCaptureManager` overrides it with its own record.
  public func isStartAbandoned(startDeadline: ContinuousClock.Instant) -> Bool { false }

  /// #1317: fail-closed default so every existing conformer (test fakes,
  /// simulator doubles) that has no reason to track this stays
  /// source-compatible. The real capture backend (`AudioCaptureManager`)
  /// overrides it with the bind its own `prepare()` returned (#1844).
  public var zeroSignalDiscriminatorDevice: BoundInputDevice? { nil }
  public var boundInputDeviceKind: String? { nil }

  /// #1714: WHY the microphone this session is using was chosen —
  /// `pinned_uid`, `system_default` or `list_fallback`. Default `nil` so every
  /// existing conformer (test fakes, simulator doubles) stays source-compatible;
  /// `AudioCaptureManager` overrides it. A low-cardinality telemetry string, and
  /// the ONLY public surface #1714 adds. Observation-only: nothing may branch
  /// capture on it, and a nil value degrades attribution, never recording.
  public var currentInputResolutionSource: String? { nil }

  /// #4841: a conformer with no live exact-zero counter reports no run, so the
  /// silent-mic notice never shows for it.
  public var exactZeroRun: ExactZeroRun? { nil }

  /// #1810: a conformer with no pre-roll ring drained nothing, so the stop-time bar
  /// is the shipping one. Defaulted — unlike `AudioInputSource`'s undefaulted twin —
  /// because the fakes conforming HERE genuinely have no ring, whereas a real capture
  /// SOURCE that drains one and reports nothing is the failure that member exists to
  /// prevent.
  public var drainedPreRollSampleCount: Int { 0 }
}

/// #4841: one reading of the live exact-zero run. `sampleCount` is the length
/// of the current run of exact-zero samples in this take's live capture (16 kHz
/// mono); `sinceTakeStart` is true when every live sample so far was exactly
/// zero. Drained pre-roll counts toward neither.
public struct ExactZeroRun: Sendable, Equatable {
  public let sampleCount: Int
  public let sinceTakeStart: Bool

  public init(sampleCount: Int, sinceTakeStart: Bool) {
    self.sampleCount = sampleCount
    self.sinceTakeStart = sinceTakeStart
  }
}

/// #1578: the observation a refused whole-zero take produces at STOP — the reason plus the
/// minimum context needed to make it countable by transport and failure shape.
/// Lives in `EnviousWisprAudio` beside the protocol that carries it, not in
/// Core, which this change deliberately leaves untouched.
public struct ZeroSignalRefusalContext: Sendable, Equatable {
  public let sessionID: UInt64
  public let reason: ZeroSignalEligibility
  public let transport: String
  public let failureShape: CaptureStallFailureMode

  public init(
    sessionID: UInt64,
    reason: ZeroSignalEligibility,
    transport: String,
    failureShape: CaptureStallFailureMode
  ) {
    self.sessionID = sessionID
    self.reason = reason
    self.transport = transport
    self.failureShape = failureShape
  }
}

/// #1578: what the kernel's STOP-time seam returns — the device classification,
/// read once per STOP (#4841: STOP is the only classifier).
public struct ZeroSignalDecisionSnapshot: Sendable, Equatable {
  public let eligibility: ZeroSignalEligibility

  public init(eligibility: ZeroSignalEligibility) {
    self.eligibility = eligibility
  }
}

/// Heartpath 5b (#1520): the observational outcome of `retireCapturingSource`.
/// Only `.retired` means a source was actually torn down; the other five are
/// fenced no-ops (the take was still zero-signal, but the retained source was
/// no longer the running active source to retire). The kernel emits this as the
/// `retire_action` telemetry property and arms the recovery watch ONLY on
/// `.retired`, so a no-op is never credited with a later recovery.
public enum ZeroSignalRetireResult: String, Sendable, Equatable {
  case retired
  case staleSession = "stale_session"
  case capturedSourceGone = "captured_source_gone"
  case activeSourceGone = "active_source_gone"
  case sourceReplaced = "source_replaced"
  case sourceNotRunning = "source_not_running"
}
