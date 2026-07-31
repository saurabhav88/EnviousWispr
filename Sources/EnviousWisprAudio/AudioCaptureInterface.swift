@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore

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
  /// audio buffers within `Constants.audioCaptureStallWindowMs` of tap install,
  /// or the reactive dead-air detector confirms an all-zero capture. At most
  /// one call per `currentCaptureSessionID` (the two producers share the
  /// manager's `captureStallReported` latch). Never called after a subsequent
  /// `stopCapture` for that session. Telemetry-only: consumers must not treat
  /// this as a control-flow signal.
  var onCaptureStalled: ((CaptureStallContext) -> Void)? { get set }

  /// Fires on the first route resolution and on every subsequent resolution
  /// where sourceType or reason differs from the prior call. No-op on
  /// warm-reuse resolutions that produce the same decision.
  // periphery:ignore - planned route telemetry API (producers wired, consumer pending)
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)? { get set }

  /// Monotonic per-source identifier for the active capture session.
  /// Increments on every `startCapture` / `beginCapturePhase`. Zero if no
  /// session has started yet. Pipeline uses for correlation extras +
  /// dedup-claim keying. Never persisted; not meaningful across launches.
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
  /// in the #1844/#1578 zero-signal DECISION and its read ORDER is a tested
  /// contract: a run already classified reactively must short-circuit before the
  /// bind is consulted at all. Telemetry asking the same question later would
  /// consult it on a path the guard forbids, which is exactly the regression
  /// `KernelFrozenBindGuardTests` caught. A decision input and an observation
  /// are different concerns even when they describe the same fact.
  var boundInputDeviceKind: String? { get }

  /// #1317, superseded as a consumer surface by #1578: a COMPATIBILITY VIEW of
  /// whether the CURRENT trailing all-zero run has a categorical refusal reason.
  /// True once the reactive check refused a candidate buffer somewhere in that
  /// run, for ANY of the classifier's five non-eligible reasons — not mute alone.
  ///
  /// Scoped to the current run: a non-zero sample that breaks the trailing zero
  /// run clears it, so an earlier refusal elsewhere in the same recording cannot
  /// blind a later, unrelated genuine failure.
  ///
  /// `AudioCaptureManager` DERIVES this from `zeroSignalRefusalReason`; it is not
  /// independent storage. New code reads the reason and the
  /// reactively-classified flag below instead — the kernel's STOP path no longer
  /// consults this at all. Default `false` for conformers with no reactive
  /// per-buffer detector, which have nothing to observe.
  var zeroSignalDiscriminatorSawIneligible: Bool { get }

  /// #1578: WHY the current trailing zero run was refused, or `nil` when the
  /// run has no refusal. The compatibility view above answers only THAT a
  /// refusal happened; this carries the categorical reason, which is the fact
  /// #1578 exists to stop discarding.
  var zeroSignalRefusalReason: ZeroSignalEligibility? { get }

  /// #1578: whether the CURRENT zero run was already classified by the reactive
  /// producer. This — never forwarding success — is what suppresses a second
  /// STOP-time classification of the same run.
  var zeroSignalRunWasClassifiedReactively: Bool { get }

  /// #1578: one forward attempt per refused run. `true` means the observation
  /// was delivered immediately; `false` means the consumer rejected it (stale
  /// session, no active target) and the producer must enqueue the context in
  /// its per-session backlog exactly once.
  var onZeroSignalRefused: ((ZeroSignalRefusalContext) -> Bool)? { get set }

  /// #1578: ATOMIC take-and-clear of the pending refusal backlog, MainActor.
  /// Returns every rejected context and empties the backlog in ONE synchronous
  /// step, so a second caller — including a cancel landing while `stopCapture()`
  /// is suspended — gets an empty array rather than a duplicate. Callers MUST
  /// invoke it before any `await` and before the session FSM returns to idle.
  ///
  /// NOT `mutating`: this protocol is class-bound (`: AnyObject`, line 7), and
  /// Swift rejects a `mutating` method declared in a class-bound protocol.
  func takePendingZeroSignalRefusals() -> [ZeroSignalRefusalContext]

  // Configuration properties (read-write)
  var selectedInputDeviceUID: String { get set }
  var preferredInputDeviceIDOverride: String { get set }
  var warmEnginePolicy: WarmEnginePolicy { get set }

  // Core lifecycle
  func startEnginePhase() async throws
  /// `recoveryPayload` is an opaque encoded `RecoverySpoolDirective` the recording
  /// kernel forwards to arm the crash-recovery limb (#1063 PR1); nil ⇒ no spool.
  /// Every caller except the kernel uses the no-arg `beginCapturePhase()`
  /// convenience in the extension below.
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer>
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>  // periphery:ignore - convenience method combining engine + capture phases
  /// Stop the capture session identified by `sessionID`, returning its samples.
  /// Fenced on the armed capture generation (#1579): a mismatched ID is a total
  /// no-op returning empty samples, so an older armed generation cannot clear a
  /// newer armed take's samples, deactivate its source, or finalize its spool.
  ///
  /// Deliberately fenced ONLY on the armed capture counter. It does NOT identify
  /// prepared-but-unarmed ownership — the counter advances in `beginCapturePhase`,
  /// so an engine prepared and then cancelled is still session 0 (#1579 P9).
  /// Callers must separately gate that interval using lifecycle ownership. Unlike
  /// `retireCapturingSource(sessionID:)` below, this must not copy the
  /// source-identity checks: retire is destructive on a specific retained source
  /// object, stop is not. Requiring
  /// source identity or a non-nil source here would refuse a legitimate stop
  /// after a route change, a format restabilisation, a zero-signal retire, or an
  /// idle teardown — and would break the nil-source salvage path that still owes
  /// the caller its accumulated samples.
  ///
  /// Callers pass the id they observed when they took ownership of the stop, NOT
  /// a value re-read at call time. `0` is a legitimate argument: an engine that
  /// was prepared but never armed has not advanced the counter, and that cleanup
  /// must still be allowed through or the prepared engine leaks.
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
  func preWarm() async throws
  func abortPreWarm()
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool

  // VAD (Step 5)
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)
  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
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

  /// #1317: default `false` — test fakes and simulator doubles have no reactive
  /// per-buffer detector, so no run of theirs can carry a refusal reason.
  /// `AudioCaptureManager` overrides it with a value DERIVED from the current
  /// run's categorical reason (#1578), never with separate storage.
  public var zeroSignalDiscriminatorSawIneligible: Bool { false }

  /// #1578: no reactive per-buffer detector means no refusal reason to report.
  public var zeroSignalRefusalReason: ZeroSignalEligibility? { nil }

  /// #1578: same reasoning — a conformer with no reactive classifier never
  /// classified the current run, so STOP-time classification stays permitted.
  public var zeroSignalRunWasClassifiedReactively: Bool { false }

  /// #1578: an explicit `get { nil } set {}` pair, NOT the read-only computed
  /// shape the two properties above use. A settable protocol requirement cannot
  /// be satisfied by a getter alone, so copying that shape here would not
  /// compile. Assignment through an existential is accepted and discarded.
  public var onZeroSignalRefused: ((ZeroSignalRefusalContext) -> Bool)? {
    get { nil }
    set {}
  }

  /// #1578: a conformer with no backlog has nothing to hand over. Synchronous
  /// and non-`mutating`, matching the requirement.
  public func takePendingZeroSignalRefusals() -> [ZeroSignalRefusalContext] {
    []
  }
}

/// #1578: the observation a refused zero run produces — the reason plus the
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

/// #1578: what the kernel's STOP-time seam returns — the classification plus
/// the one fact that decides whether STOP may classify the run again.
public struct ZeroSignalDecisionSnapshot: Sendable, Equatable {
  public let eligibility: ZeroSignalEligibility

  /// Whether the CURRENT run was already classified reactively — NOT whether
  /// its first forward succeeded. A rejected forward is emitted from the
  /// backlog, so a forwarding-success discriminator would invite STOP to emit
  /// it a second time.
  ///
  /// This snapshot deliberately carries NO backlog: consumption belongs to the
  /// atomic take-and-clear, and two owners of one queue is a defect.
  public let currentRunWasClassifiedReactively: Bool

  public init(
    eligibility: ZeroSignalEligibility,
    currentRunWasClassifiedReactively: Bool
  ) {
    self.eligibility = eligibility
    self.currentRunWasClassifiedReactively = currentRunWasClassifiedReactively
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
