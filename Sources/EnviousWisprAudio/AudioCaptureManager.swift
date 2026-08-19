@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import os

/// Manages audio capture from the microphone — thin coordinator over AudioInputSource backends.
///
/// Owns app-facing state (capturedSamples, audioLevel, isCapturing) and the
/// `AudioCaptureInterface` contract. Delegates all hardware interaction to the
/// active `AudioInputSource` (always `HALDeviceInputSource`, the sole backend).
///
/// **Ownership boundaries:**
/// - Sources own hardware/session/engine lifecycle, conversion, tap logic, recovery
/// - Manager owns capture state exposed to the rest of the app
/// - Manager does NOT contain conversion logic, tap logic, or route-specific recovery
@MainActor
@Observable
public final class AudioCaptureManager: AudioCaptureInterface {
  /// Current recording state. `internal(set)` (not `private(set)`) solely so
  /// the #1408 A3 backstop test can arm `ingestSamples` without real hardware;
  /// production writes stay inside this file.
  public internal(set) var isCapturing = false

  /// #1844: the device the active source ACTUALLY OPENED for this attempt — the
  /// value `prepare()` returned, adopted in `adoptBoundState(_:)`. It is no
  /// longer derived from settings, and it can no longer be adopted before the
  /// bind exists: the awaited call produces it (#1317's PR #1512 froze a
  /// settings-derived device one synchronous turn BEFORE `prepare()` committed,
  /// so a HAL fallback bind — the user's explicit microphone absent, HAL opening
  /// the system default instead — produced a health verdict about a microphone
  /// the session never recorded from, or none at all).
  ///
  /// Exposed via `AudioCaptureInterface.zeroSignalDiscriminatorDevice` so the
  /// pipeline layer's STOP-time backstop reads this SAME frozen value instead of
  /// independently re-resolving (which cannot see this class's retries) — it does
  /// so AFTER capture has already ended, on a normal `stopCapture()` OR any
  /// interruption teardown path, both of which run their own cleanup BEFORE the
  /// kernel's read happens (the kernel falls through a salvageable interruption
  /// into the SAME normal stop tail that reads this).
  ///
  /// INVARIANT: no teardown path may clear this field — the next
  /// `startEnginePhase()` overwrites it for the next session, and nothing ever
  /// reads a stale cross-session value in between, so clearing it early only ever
  /// loses the CURRENT session's read (cloud review round 6 P1 caught this in
  /// `stopCapture()`; round 7 P2 caught the same class in the interruption path —
  /// audit every write site against this invariant before adding a new one). The
  /// per-attempt invalidation in `startEnginePhase()` is the ONE exception and is
  /// not a teardown: it runs before the attempt, not after it.
  ///
  /// nil means "no attempt has succeeded yet" and fails closed. It can only come
  /// from that explicit invalidation, never from a source — a successful
  /// `prepare()` cannot answer "no device" (`BoundInputDevice` is non-optional).
  private var effectiveDiscriminatorDevice: BoundInputDevice?

  public var zeroSignalDiscriminatorDevice: BoundInputDevice? { effectiveDiscriminatorDevice }

  /// #1845: derived once in `adoptBoundState`, alongside the route refresh, so
  /// no consumer re-reads the bind to answer it. See the protocol requirement
  /// for why this is not a computed projection of the property above.
  public private(set) var boundInputDeviceKind: String?

  /// #1317 (ported in-process from the former app-side capture proxy at the C1
  /// collapse, #1543): WHY the CURRENT trailing all-zero run was refused by the
  /// device discriminator. The kernel's STOP-time backstop reads this guard-first
  /// so a refused silent stretch is not later misclassified as the harness glitch.
  /// Scoped to the current run, not session-wide: a non-zero sample that breaks
  /// the trailing zero run clears it, so an earlier resolved refusal cannot blind
  /// the backstop to a later, unrelated genuine zero-signal failure. Reset in
  /// `beginCapturePhase`; per the `effectiveDiscriminatorDevice` invariant no
  /// teardown path may clear it early.
  ///
  /// #1578 replaces the former Boolean latch with its categorical reason, so WHY
  /// and whether a refusal happened cannot drift apart.
  private var currentZeroSignalRefusalReason: ZeroSignalEligibility?

  /// #1578: whether the CURRENT zero run has already produced its reactive refusal
  /// observation. Classification still runs on every candidate batch so a later
  /// `.eligible` verdict preserves the shipping stall behavior. This flag suppresses
  /// only duplicate refusal forwarding, backlog admission, and STOP-time
  /// reclassification. Forwarding acceptance never controls it.
  private var currentRunWasClassifiedReactively = false

  /// #1578: refusal contexts whose one forward attempt was REJECTED (no
  /// subscriber, or a stale-session rejection). Per SESSION, not per run:
  /// clearing this on non-zero recovery would erase a refusal that genuinely
  /// happened just because the microphone came back. Drained atomically at a
  /// terminal.
  private var pendingZeroSignalRefusals: [ZeroSignalRefusalContext] = []

  public var zeroSignalDiscriminatorSawIneligible: Bool {
    currentZeroSignalRefusalReason != nil
  }

  public var zeroSignalRefusalReason: ZeroSignalEligibility? {
    currentZeroSignalRefusalReason
  }

  public var zeroSignalRunWasClassifiedReactively: Bool {
    currentRunWasClassifiedReactively
  }

  /// #1578: the manager MUST store this itself. The protocol extension's default
  /// is an explicit no-op setter for conformers with no reactive detector, so
  /// inheriting it here would silently swallow the production subscriber.
  public var onZeroSignalRefused: ((ZeroSignalRefusalContext) -> Bool)?

  /// #1578: ONE owner for the three fields above, so a future third reset point
  /// cannot clear two of them and miss the other.
  ///
  /// `clearBacklog` is the entire difference between the two call sites, and it
  /// is load-bearing: session start clears everything, while non-zero recovery
  /// clears only the current-run facts. A recovery that also emptied the backlog
  /// would delete a rejected refusal for the very reason it should be kept — the
  /// microphone started working again.
  private func resetZeroSignalState(clearBacklog: Bool) {
    currentZeroSignalRefusalReason = nil
    currentRunWasClassifiedReactively = false
    if clearBacklog {
      pendingZeroSignalRefusals.removeAll(keepingCapacity: true)
    }
  }

  /// #1578: ATOMIC take-and-clear. Synchronous and MainActor-isolated, so a
  /// second caller — a cancel landing while `stopCapture()` is suspended — gets
  /// an empty array instead of a duplicate. Append order is preserved.
  public func takePendingZeroSignalRefusals() -> [ZeroSignalRefusalContext] {
    let pending = pendingZeroSignalRefusals
    pendingZeroSignalRefusals.removeAll(keepingCapacity: true)
    return pending
  }

  /// Current audio level (0.0 - 1.0) for waveform visualization.
  public private(set) var audioLevel: Float = 0.0

  /// Accumulated audio samples from the current recording.
  public private(set) var capturedSamples: [Float] = []

  /// Optional callback to forward converted audio buffers (e.g., to streaming ASR).
  /// Called on the audio thread — must be @Sendable.
  public var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?

  /// Called on the main actor when the audio engine is interrupted (e.g., device disconnect).
  /// The pipeline should transition to an error state when this fires.
  public var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?

  /// Called when service-side VAD detects sustained silence after speech.
  /// No-op for in-process capture — VAD runs in the pipeline's monitorVAD() loop instead.
  public var onVADAutoStop: (() -> Void)?

  /// #1408 A3: called on the main actor when the hard sample-count backstop
  /// trips (a normal auto-stop, never a loss — it used to fire
  /// `onEngineInterrupted(.maxDurationReached)`). The manager has already
  /// stopped appending (`isCapturing = false`, its memory protection, which
  /// holds even with a dead host); the consumer routes this into the same typed
  /// `.maxDuration` stop the graceful wall-clock cap uses.
  public var onMaxDurationReached: (() -> Void)?

  /// #1408 A3: the backstop threshold, instance-scoped so tests can inject a
  /// tiny limit (the production value is 58,560,000 samples — unreachable in a
  /// unit test). Production never touches it.
  var maxRecordingSamplesLimit: Int = AudioCaptureManager.maxRecordingSamples

  /// Optional fine-grained lifecycle signal used by the XPC service to publish
  /// phase ticks while a proxy is waiting on a lifecycle reply.
  public var onLifecycleSignal: (@Sendable (String) -> Void)? {
    didSet {
      activeSource?.onLifecycleSignal = onLifecycleSignal
    }
  }

  // MARK: - Round-4 telemetry callbacks (issue #285)

  /// Stall watchdog callback. Two in-process producers fire it — the HAL
  /// no-buffer watchdog (forwarded from `source.onCaptureStalled`) and the
  /// reactive all-zero dead-air detector below — both gated by the shared
  /// `captureStallReported` latch so the documented at-most-once-per-session
  /// contract holds.
  public var onCaptureStalled: ((CaptureStallContext) -> Void)?

  /// Fired by `resolveSource()` — initial resolution + changed-only afterwards.
  public var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?

  /// Monotonic, APP-LIFETIME session id, incremented once per capture session in
  /// `beginCapturePhase`. Manager-owned (NOT delegated to the active source's
  /// `captureGeneration`, which resets to 1 on every new `HALDeviceInputSource`
  /// — a warm teardown or route change would then repeat ids and collide the
  /// pipeline's per-session dedup, #1543 Codex review P2). This restores the
  /// app-lifetime uniqueness the deleted proxy's counter provided. Returns 0
  /// before the first session; never persisted; not meaningful across launches.
  public var currentCaptureSessionID: UInt64 { captureSessionCounter }
  private var captureSessionCounter: UInt64 = 0

  /// Delegates to the active source so the pipeline can attribute Sentry
  /// events to the concrete backend (HALDeviceInput).
  /// Falls back to the cached last-known value after stopCapture tears the
  /// source down (see `cachedSourceType` rationale at field declaration).
  public var captureSourceType: String {
    activeSource?.captureSourceType ?? cachedSourceType
  }

  /// Authoritative capture-active predicate.
  public var isActivelyCapturing: Bool { isCapturing }

  /// Persistent UID of the selected input device. Empty string means system default.
  public var selectedInputDeviceUID: String = ""

  /// User override for input device. Empty string means "Auto" (smart selection enabled).
  public var preferredInputDeviceIDOverride: String = ""

  /// Hard emergency recording-duration ceiling in seconds. Prevents unbounded
  /// memory growth. MUST stay strictly above the graceful soft cap
  /// (`TimingConstants.maxRecordingDuration`, 3600s) so the graceful stop+transcribe
  /// always wins; this 60s margin keeps the hard teardown a true backstop only
  /// reached if the soft stop wedges (#1060). Raised 600→3660.
  public nonisolated static let maxRecordingDurationSeconds: Double = 3660
  /// Maximum sample count derived from maxRecordingDurationSeconds at 16kHz.
  public nonisolated static let maxRecordingSamples: Int = Int(
    maxRecordingDurationSeconds * targetSampleRate)

  /// Target format: 16kHz, mono, Float32 — required by both Parakeet and WhisperKit.
  public nonisolated static let targetSampleRate: Double = 16000

  /// The active capture source. Created on startEnginePhase / preWarm.
  /// Always a HALDeviceInputSource — the sole capture backend.
  private var activeSource: (any AudioInputSource)?

  /// Heartpath 5b (#1520): the source object that captured the current session,
  /// RETAINED (not `ObjectIdentifier` — an address token can alias a freshly
  /// allocated source after the captured one deallocates). Compared by `===` in
  /// `retireCapturingSource` so a stale finish can only retire the exact source it
  /// captured, never a newer take's source. Cleared the moment that source is torn
  /// down or replaced, so no torn-down source is retained past its lifetime.
  private var captureSessionSource: (any AudioInputSource)?

  #if DEBUG
    /// #1317 proof-bench: the single DEBUG-only all-zero injector, handed to every
    /// source on install so it can substitute digital silence at the forwarder.
    /// Compiled out of release.
    let debugZeroFillController = DebugZeroFillController()

    /// #1317 proof-bench: monotonic, manager-owned resource generation — the
    /// freshness oracle for `fresh_pipe_proven`. NOT `ObjectIdentifier(activeSource)`
    /// (rebuild destroys resources while retaining the object) and NOT the
    /// capture-session id (which advances per capture even on warm reuse). Increments
    /// only on new-source install and destructive `rebuildEngine()`.
    private(set) var debugSourceIncarnation: UInt64 = 0

    /// #1844 test seam: when set, `resolveSource()` builds its source from this
    /// closure instead of constructing a real `HALDeviceInputSource`, so the
    /// bound-device adoption tests can drive `startEnginePhase()` against a stub
    /// with a controlled `prepare()` return. Installed via
    /// `installSourceFactoryForTesting`; nil in production, always.
    /// Takes the already-resolved route decision so an armed factory can honour
    /// the user's actual device choice instead of re-reading settings — a second
    /// read there would be the stale-selection defect this whole issue avoids.
    private var debugSourceFactory: ((CaptureRouteDecision) -> any AudioInputSource)?

    /// #1317 proof-bench (DEBUG only): arm the injector from the in-process
    /// DEBUG fault endpoint (#1543). Translates the Core wire enum into the
    /// controller's associated-value `Mode` here so the injector type stays
    /// module-internal. `package` access: reachable from `DebugFaultEndpoint` in
    /// `EnviousWisprAppKit` (same SPM package).
    /// `n` is intentionally NOT validated here: the controller's range math is
    /// provably safe for any `Int`, including negatives (`zeroAfter` short-circuits
    /// on `startSeen >= threshold`; `zeroNext` guards `startSeen < budget`), so a
    /// negative budget zeroes-all or nothing but never emits a negative range.
    /// Proven by `DebugZeroFillControllerTests.negativeBudgetIsSafe`. Do not re-add
    /// an `n >= 0` guard — a Codex round claimed a crash here that does not exist.
    package func debugArmZeroFill(mode: DebugZeroFillArm.Mode, n: Int, trialID: String) {
      let controllerMode: DebugZeroFillController.Mode
      switch mode {
      case .zeroFromStart: controllerMode = .zeroFromStart
      case .zeroAfterSamples: controllerMode = .zeroAfter(threshold: n)
      case .zeroNextSamples: controllerMode = .zeroNext(budget: n)
      case .disarmed:
        debugZeroFillController.disarm()
        return
      }
      debugZeroFillController.arm(mode: controllerMode, trialID: trialID)
    }

    /// #1317 proof-bench (DEBUG only): snapshot the injector status plus the
    /// manager's monotonic source-incarnation generation (the `fresh_pipe_proven`
    /// oracle). Combines both manager-owned facts in one atomic read.
    package func debugFaultStatusSnapshot() -> DebugFaultServiceStatus {
      let s = debugZeroFillController.status()
      return DebugFaultServiceStatus(
        armed: s.armed, hit: s.hit, trialID: s.trialID, mode: s.mode,
        zeroedSampleCount: s.zeroedSampleCount, sourceIncarnation: debugSourceIncarnation,
        captureSourceType: activeSource?.captureSourceType ?? "none")
    }
  #endif

  /// Issue #285 — mirror of `activeSource.captureSourceType` captured at session
  /// start, so pipeline Sentry extras still resolve a real backend tag after
  /// `stopCapture()` synchronously tears down the source (warmEnginePolicy ==
  /// .off). Without this cache, post-stop reads fall back to `"unknown"`. (The
  /// session id no longer needs a cache — it is the manager-owned
  /// `captureSessionCounter`, which persists across teardown, #1543.)
  private var cachedSourceType: String = "unknown"

  /// #1810 twin of `cachedSourceType`: the session's pre-roll drain, snapshotted
  /// before any teardown path can nil `activeSource`, so the kernel's STOP-time
  /// classification reads the same number the reactive detector used.
  private var cachedDrainedPreRollSampleCount: Int = 0

  /// Route resolver — decides which source to use based on BT state + user preference.
  private var routeResolver = CaptureRouteResolver()

  /// Idle teardown timer: shuts down the warm engine after inactivity.
  private var warmEngineTeardownTask: Task<Void, Never>?

  /// How long to keep the engine warm after recording stops.
  /// Setting this property automatically reconciles with the current engine state.
  public var warmEnginePolicy: WarmEnginePolicy = .seconds30 {
    didSet {
      guard oldValue != warmEnginePolicy else { return }
      reconcileWarmEnginePolicy()
    }
  }

  /// When the engine entered idle-warm state. Used to recalculate remaining
  /// timeout when the policy changes mid-idle.
  private var idleSince: ContinuousClock.Instant?
  private let clock = ContinuousClock()

  /// The last route decision — for telemetry and debugging.
  private var lastRouteDecision: CaptureRouteDecision?

  /// Low-cardinality audio route label derived from the last route decision.
  public var currentAudioRoute: String {
    lastRouteDecision?.reason.coarseAudioRouteLabel ?? "unknown"
  }

  /// The resolved-route transports for the current session (#1376). FROZEN at
  /// resolve time (mirrors the proxy) — NOT a computed property, so an in-flight
  /// input-device setting change (which `PipelineSettingsSync` applies for the
  /// NEXT recording while the current source keeps its old device) cannot make a
  /// later failure-terminal telemetry read report the wrong transport. Nil
  /// before the first resolution.
  ///
  /// NO LONGER TELEMETRY-ONLY (#1788): `effective` is now a CAPTURE-POLICY input,
  /// selecting the mid-take all-zero ceiling via `allZeroCeilingSamples`. The
  /// freezing described above is what makes that safe — the ceiling is chosen from
  /// the route the session actually bound, not from a live re-read that a mid-take
  /// device switch could have already changed. Nil still falls to the shipping 1.0s
  /// ceiling, so a session that never resolved behaves exactly as before.
  public private(set) var currentResolvedRoute: ResolvedRouteTransports?

  /// Adopt a fresh route decision: freeze it plus its derived transports (using
  /// the device selection that produced THIS decision), then fire
  /// `onRouteResolved` changed-only. The single write path so `lastRouteDecision`
  /// and `currentResolvedRoute` never disagree.
  private func resolvedRouteTransports(
    for decision: CaptureRouteDecision,
    actualBoundTransport: String? = nil
  ) -> ResolvedRouteTransports {
    ResolvedRouteTransports.derive(
      decision: decision,
      preferredInputDeviceIDOverride: preferredInputDeviceIDOverride,
      actualBoundTransport: actualBoundTransport
    )
  }

  private func adoptRouteDecision(
    _ decision: CaptureRouteDecision,
    prior: CaptureRouteDecision?,
    actualBoundTransport: String? = nil
  ) {
    lastRouteDecision = decision
    currentResolvedRoute = resolvedRouteTransports(
      for: decision, actualBoundTransport: actualBoundTransport)
    guard CaptureRouteDecision.routeResolvedChanged(from: prior, to: decision) else { return }
    onRouteResolved?(decision, prior.map { $0.sourceType != decision.sourceType } ?? false)
  }

  private func refreshResolvedRoute(actualBoundTransport: String?) {
    guard let decision = lastRouteDecision else { return }
    currentResolvedRoute = resolvedRouteTransports(
      for: decision, actualBoundTransport: actualBoundTransport)
  }

  // MARK: - Reactive dead-air detector state (#1317, ported in-process at C1 #1543)

  /// Per-capture-generation all-zero harness-glitch detector. Fed the
  /// authoritative captured samples on the MainActor via `ingestSamples` —
  /// the in-process equivalent of the proxy's per-buffer MainActor hop, so the
  /// detector is never mutated from the HAL consumer thread. Reset at every
  /// fresh `beginCapturePhase`.
  private var deadAirDetector = DeadAirStreamingDetector()

  /// How many leading exact-zero samples the mid-take all-zero detector tolerates
  /// before it concludes the microphone is dead. ONE owner, ONE code path in every
  /// configuration — release and DEBUG differ only in whether an override is
  /// consulted, never in how the verdict is computed (#1788).
  ///
  /// Release, and DEBUG with no override set, is `minimumTranscriptionSamples`
  /// (16,000 = 1.0s) on every transport EXCEPT Bluetooth, which gets 3.0s (#1788 —
  /// see `allZeroFromStartCeilingSamples(forEffectiveTransport:)` for why, and note
  /// the DEBUG override still wins over both so a measurement run can see past
  /// either).
  ///
  /// The DEBUG override exists because a Bluetooth wake slower than the ceiling is
  /// otherwise CENSORED — the take aborts before the wake completes, so the tail we
  /// most need to see is the one we structurally cannot observe. Raising it makes
  /// that tail measurable. Diagnostic recipe: gotchas-audio.md
  /// FACT: bt-mic-warmup-delay-is-industry-wide-not-eviouswispr-specific.
  ///
  ///     defaults write com.enviouswispr.app.dev EWDebugAllZeroCeilingSamples -int 160000
  ///
  /// A non-positive or absent value yields the shipping ceiling, so an
  /// unconfigured DEBUG build cannot behave differently from production.
  ///
  /// #1810: the base ceiling is a bar on LIVE capture, and the detector is fed the
  /// drained pre-roll first, so the drained count is added back here. The override
  /// gets the same treatment deliberately — a DEBUG bar that meant something
  /// different from the shipping bar would make every local measurement
  /// incomparable with the fleet, which is the whole reason the override exists.
  var allZeroCeilingSamples: Int {
    let drained = drainedPreRollSampleCount
    #if DEBUG
      let override = UserDefaults.standard.integer(
        forKey: "EWDebugAllZeroCeilingSamples")
      if override > 0 { return override + drained }
    #endif
    return Self.allZeroFromStartCeilingSamples(
      forEffectiveTransport: currentResolvedRoute?.effective) + drained
  }

  /// Clamped pre-roll drain for this capture session, and the clamp is the point.
  /// `AudioInputSource.drainedPreRollSampleCount` is typed `Int`, so a stub or a
  /// future conformer can return a negative; a negative would SHRINK the ceiling
  /// and make the abort fire EARLIER, which is the one direction #1810 promises is
  /// impossible. Read through this property, never the source's raw value.
  ///
  /// Falls back to `cachedDrainedPreRollSampleCount` for the same reason
  /// `captureSourceType` falls back to `cachedSourceType`: `stopCapture()`'s
  /// `activeSource == nil` early return, and the `warmEnginePolicy == .off` teardown,
  /// both leave the STOP-time reader with no source to ask.
  public var drainedPreRollSampleCount: Int {
    max(0, activeSource?.drainedPreRollSampleCount ?? cachedDrainedPreRollSampleCount)
  }

  /// THE #1788 FIX, and the only transport conditional in it.
  ///
  /// Bluetooth alone negotiates a voice link before audio flows, so it alone tolerates
  /// 3.0s of exact silence mid-take instead of 1.0s. Every other value — `"built_in"`,
  /// `"usb"`, `"unknown"`, and `nil` — returns the shipping ceiling, so a wired user's
  /// behaviour is byte-identical to before and an UNREADABLE transport fails to
  /// today's behaviour rather than to the longer one.
  ///
  /// Pure and static so the wired-unchanged guarantee is unit-testable without opening
  /// real hardware: `currentResolvedRoute` is `private(set)` with only private
  /// production writers, so a test cannot inject a route through the manager.
  ///
  /// Scope, deliberately narrow: this governs the MID-TAKE all-zero abort only, and
  /// it returns a bar on LIVE capture — `allZeroCeilingSamples` adds the drained
  /// pre-roll back on top (#1810). `RecordingSessionKernel.classifyZeroSignalAtStop`
  /// still keeps 1.0s on every transport, so a genuinely dead Bluetooth mic released
  /// before 3.0s ends with the same honest failure; #1810 gave that stop-time bar the
  /// same pre-roll correction, so both now mean 1.0s of live capture rather than 1.0s
  /// minus whatever silent pre-roll was drained. `.becameZeroMidCapture` keeps its own
  /// threshold and takes NO pre-roll correction — it counts a trailing zero suffix, so
  /// the drain is irrelevant to it. Do not "harmonise" the three.
  nonisolated static func allZeroFromStartCeilingSamples(
    forEffectiveTransport effectiveTransport: String?
  ) -> Int {
    effectiveTransport == "bluetooth"
      ? AudioConstants.bluetoothAllZeroMidTakeCeilingSamples
      : AudioConstants.minimumTranscriptionSamples
  }

  #if DEBUG
    /// One-shot per capture generation so the zero-prefix line is emitted once,
    /// not on every subsequent batch. Reset in `beginCapturePhase`.
    private var didLogZeroPrefixThisSession = false
  #endif

  /// The ONE shared latch the HAL no-buffer watchdog and the dead-air detector
  /// both check-and-set before calling `onCaptureStalled`, so the callback's
  /// documented at-most-once-per-session contract holds across the two
  /// independent firing paths. Reset per session in `beginCapturePhase`.
  private var captureStallReported = false

  /// Uptime stamp frozen when live capture begins — the `armedAtUptimeNs`
  /// baseline for a dead-air `CaptureStallContext`. Zero outside a session.
  private var captureStartUptimeNs: UInt64 = 0

  // MARK: - Crash-recovery spool state (#1063; ported in-process at C1 #1543)

  /// The live spool writer, built from the recovery directive at
  /// `beginCapturePhase` and fed the authoritative captured samples on a poll
  /// loop. nil when recovery is off / failed to arm. MainActor-confined.
  private var recoverySpoolWriter: RecoverySpoolWriter?
  /// Poll task feeding new captured samples to the writer. Cancelled on stop.
  private var recoveryFeedTask: Task<Void, Never>?
  /// High-water mark of `capturedSamples` already handed to the writer, so the
  /// clean-stop tail is `captureResult.samples[recoveryFedSampleCount...]`.
  private var recoveryFedSampleCount: Int = 0
  /// Single-finalize guard across the clean-stop vs low-disk race (the writer
  /// is also idempotent; this avoids even queuing the second call).
  private var recoveryFinalized: Bool = false

  public init() {}

  // MARK: - AudioCaptureInterface

  public func startEnginePhase() async throws {
    // #1844: invalidate FIRST, so a throwing `prepare()` cannot leave a prior
    // session's device observable. Safe against the #1317 round-6 invariant
    // because a new `startEnginePhase()` requires the kernel to be `.idle`,
    // reached only through `finishTerminal` — after the stop-time read.
    effectiveDiscriminatorDevice = nil
    // Re-evaluate route on every recording start — BT state may have changed.
    onLifecycleSignal?("manager_resolve_source_entered")
    let source = resolveSource()
    source.onLifecycleSignal = onLifecycleSignal
    onLifecycleSignal?("manager_prepare_entered")
    // The awaited call PRODUCES the value adopted below: the ordering #1844
    // existed to fix is now a data dependency, not a convention.
    adoptBoundState(try await prepareAndAttribute(source))
    onLifecycleSignal?("manager_prepare_completed")
  }

  // MARK: - #1714: input-resolution attribution

  /// The latest COLD attempt, kept because a THROWING prepare returns no bind at
  /// all — without this, a resolution or bind failure could never be attributed.
  private var latestInputResolutionAttempt: FinalizedInputResolutionAttempt?

  /// #1714: the outbound observer, installed once by the composition root so
  /// this module never imports Services. Separate from the SOURCE-level
  /// callback above, which the manager consumes for its own state — one
  /// callback cannot serve both without the manager losing ownership.
  ///
  /// Synchronous, nonthrowing, observation-only.
  package var onFinalizedInputResolutionAttempt:
    (@MainActor (InputResolutionAttemptTelemetry) -> Void)?

  /// #1714: forward the RETAINED attempt, never the callback argument.
  ///
  /// Reading `latestInputResolutionAttempt` rather than the parameter is
  /// deliberate: it makes the manager's own state the single authority for what
  /// gets reported, so an emitted event can never describe an attempt the
  /// manager did not itself record.
  private func forwardLatestInputResolutionAttempt() {
    guard let attempt = latestInputResolutionAttempt else { return }
    onFinalizedInputResolutionAttempt?(InputResolutionAttemptTelemetry(attempt))
  }

  /// WHY the current session's microphone was chosen. Manager-owned writes only.
  public private(set) var currentInputResolutionSource: String?

  /// The ONE place a source is prepared (#1714). Both production call sites —
  /// recording start and pre-warm — route through here so the clear, the
  /// callback wiring, retention across a throw, and successful-bind adoption
  /// cannot drift apart.
  ///
  /// Ordering is the whole point, and it is this:
  ///   1. clear BOTH prior facts, so a failure can never expose a previous
  ///      session's answer;
  ///   2. install the callback, which stores the attempt SYNCHRONOUSLY — that is
  ///      what survives a throw;
  ///   3. on success, the RETURNED BIND wins over the callback's provisional
  ///      value (`RULE: read-the-bind-prepare-returned-never-re-derive-it`), and
  ///      it is also the only source of truth on the warm path, which fires no
  ///      callback at all.
  private func prepareAndAttribute(_ source: any AudioInputSource) async throws -> BoundInputDevice {
    latestInputResolutionAttempt = nil
    currentInputResolutionSource = nil
    source.onInputResolutionAttemptFinalized = { [weak self] attempt in
      guard let self else { return }
      self.latestInputResolutionAttempt = attempt
      // Provisional: nil when resolution selected nothing, which is honest —
      // there is no device to attribute. The returned bind overwrites this on
      // success.
      self.currentInputResolutionSource = attempt.resolution.resolutionSource?.rawValue
      // The manager's own state is stored FIRST, so an external observer can
      // never see the manager mid-update.
      self.forwardLatestInputResolutionAttempt()
    }
    let bound = try await source.prepare()
    currentInputResolutionSource = bound.resolutionSource
    return bound
  }

  /// #1844: the ONE place the manager adopts post-bind facts. Takes the value, not
  /// the source, so there is nothing to downcast and no way to read a stale bind.
  private func adoptBoundState(_ bound: BoundInputDevice) {
    effectiveDiscriminatorDevice = bound
    boundInputDeviceKind = AudioDeviceEnumerator.builtInInputKind(forUID: bound.deviceUID)
    refreshResolvedRoute(actualBoundTransport: bound.transportLabel)
  }

  /// In-process capture path. `recoveryPayload` is an opaque encoded
  /// `RecoverySpoolDirective`; when present and enabled it arms the
  /// crash-recovery spool limb (ported in-process at the C1 XPC collapse,
  /// #1543 — the helper used to own this). Fail-open: any decode/preflight
  /// failure leaves recovery off and capture byte-identical.
  public func beginCapturePhase(recoveryPayload: Data?) async throws
    -> AsyncStream<AVAudioPCMBuffer>
  {
    guard let source = activeSource else {
      throw AudioError.formatCreationFailed(
        source: "AudioCaptureManager.beginCapturePhase.no_active_source")
    }

    // #1579: retire any predecessor spool FIRST — before the sample reset below
    // and before the `await source.startCapture()` further down. Two reasons, and
    // the order matters for both. During that await an unstopped predecessor's
    // feed still sees `isCapturing == true` and could reach the new take's
    // buffer; and `capturedSamples` is cleared on the very next line, so anything
    // the predecessor's 1s poll had not yet consumed would be unrecoverable if
    // this ran afterwards (cloud review P2 — the previous placement was below the
    // reset while its own comment claimed otherwise).
    retirePredecessorRecoverySpool()

    // Pre-allocate sample buffer
    capturedSamples = []
    capturedSamples.reserveCapacity(16000 * 30)
    audioLevel = 0.0

    // Reset per-session reactive dead-air + stall-latch state (#1317 / #1543).
    deadAirDetector = DeadAirStreamingDetector()
    // #1810: the previous session's drain must not survive into this one's ceiling.
    cachedDrainedPreRollSampleCount = 0
    // #1578: session start is the ONE place the backlog is cleared without a
    // consumer having taken it — a new session must never inherit the previous
    // one's undelivered refusals.
    resetZeroSignalState(clearBacklog: true)
    captureStallReported = false
    #if DEBUG
      didLogZeroPrefixThisSession = false
    #endif

    // Wire source callbacks → manager state.
    // Source identity check prevents stale callbacks from a replaced source
    // (e.g., pre-warm source replaced by startEnginePhase) from modifying state.
    let sourceID = ObjectIdentifier(source)
    source.onSamples = { [weak self] samples, level in
      Task { @MainActor in
        guard let self, self.isCapturing,
          self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
        else { return }
        self.ingestSamples(samples, level: level)
      }
    }
    source.onBufferCaptured = onBufferCaptured
    // (The `ingestSamples` body lives below `stopCapture()` — extracted so the
    // #1408 A3 backstop is unit-testable with an injected `maxRecordingSamplesLimit`.)
    // #1408: the SOURCE names the cause; the manager only forwards it. This used
    // to be inferred from the source's class, which cannot distinguish a device
    // that was verified gone (`.deviceRemoved`) from a source that merely failed
    // to recover (`.engineLost`). Only the source runs the
    // `kAudioDevicePropertyDeviceIsAlive` check, so only the source can answer.
    // Passing the cause as a parameter also means the closure captures no
    // `source` reference at all.
    source.onInterrupted = { [weak self] cause in
      guard let self,
        self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
      else { return }
      self.isCapturing = false
      // #1317 (cloud review P2, round 7): NOT cleared here — see the
      // field's doc comment. A teardown-time clear here can race the
      // kernel's STOP-time read the same way `stopCapture()` did (round 6
      // P1): the kernel falls through interruption exits into the SAME
      // normal stop tail when the interruption's audio is salvageable.
      self.audioLevel = 0.0
      self.onEngineInterrupted?(cause)
    }

    // Forward heart-path telemetry callbacks (issue #285) — direct capture
    // mode must surface the same stall signals
    // the XPC proxy already exposes. Stale callbacks from a replaced source
    // are rejected via the sourceID guard.
    source.onCaptureStalled = { [weak self] ctx in
      guard let self,
        self.activeSource.map({ ObjectIdentifier($0) }) == sourceID,
        !self.captureStallReported
      else { return }
      self.captureStallReported = true
      // #1543 (Codex review P2): the HAL source stamps its per-instance
      // generation and a coarse `route: "hal_device_input"`. Overlay the
      // manager's app-lifetime session id (so dedup + `isCurrentSession` see the
      // same unique id the dead-air path uses) and the frozen route decision
      // (so built-in vs Bluetooth stalls bucket correctly with transport detail).
      self.onCaptureStalled?(self.enrichStallContext(ctx))
    }

    source.onLifecycleSignal = onLifecycleSignal
    onLifecycleSignal?("manager_start_capture_entered")
    let stream = try await source.startCapture()
    onLifecycleSignal?("manager_start_capture_completed")
    isCapturing = true
    // App-lifetime session id (#1543): one increment per live capture session,
    // read by the dead-air ctx, correlation extras, dedup, and the stall filter.
    captureSessionCounter &+= 1
    captureSessionSource = source  // heartpath 5b: retain the object that owns this session
    captureStartUptimeNs = DispatchTime.now().uptimeNanoseconds
    // Crash-recovery limb: arm the spool from the directive AFTER capture is
    // live (the feed loop guards on `isCapturing`). Fail-open — never throws,
    // never gates the returned stream (heart path is byte-identical).
    startRecoverySpooling(payload: recoveryPayload)
    #if DEBUG
      // Bake-off manager-side evidence companion (#1377 §3.5): pairs the app's
      // REQUEST (backend + requested device) with each source's own
      // `CAPTURE_EVIDENCE` (actual bound device). Capture is in-process, so
      // `captureSourceType` is always the real backend.
      // #1844 instance 3: the REQUESTED device is the one HAL was actually
      // handed — `CaptureRouteResolver`'s `effectiveDeviceUID`, written on both
      // `resolveSource()` branches. The old expression read the raw settings
      // pair, which is not what the source receives, so the manager's evidence
      // line could disagree with the source's own on the very fallback case
      // this issue is about.
      let requestedUID = lastRouteDecision?.effectiveDeviceUID ?? ""
      Self.btRouteLog(
        "CAPTURE_EVIDENCE [manager] backend=\(source.captureSourceType) requestedUID=\(requestedUID.isEmpty ? "auto" : requestedUID) generation=\(source.captureGeneration)"
      )
    #endif
    // Mirror source backend tag so pipeline-layer Sentry extras still resolve
    // after stopCapture tears `activeSource` down synchronously.
    cachedSourceType = source.captureSourceType
    cachedDrainedPreRollSampleCount = max(0, source.drainedPreRollSampleCount)
    return stream
  }

  // periphery:ignore - protocol conformance (AudioCaptureInterface); convenience for single-phase callers
  public func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard !isCapturing else {
      return AsyncStream { $0.finish() }
    }
    try await startEnginePhase()
    return try await beginCapturePhase()
  }

  public func stopCapture(sessionID: UInt64) async -> CaptureResult {
    // #1579 layer 2: ARMED-session identity fence. MUST precede every existing
    // stop-path read and mutation — a stale stop that got this far would clear a
    // newer take's samples and deactivate its source. A mismatch returns empty and
    // changes nothing; both production callers discard a stale result. `0` stays
    // valid: it is the id of a prepared-but-never-armed engine, whose cleanup must
    // be allowed through or the engine leaks. This guard cannot identify that
    // prepared interval; callers must separately gate it using lifecycle ownership.
    guard sessionID == captureSessionCounter else {
      Self.btRouteLog("Stop skipped: stale capture session")
      return CaptureResult(samples: [])
    }

    guard let source = activeSource else {
      let samples = capturedSamples
      capturedSamples = []
      // #1579 (defect 1c): finalize the spool HERE too. This early return used to
      // skip `stopRecoverySpooling` entirely, leaving an armed spool with no
      // terminal marker. Reachable in production: an engine interruption clears
      // `isCapturing` without clearing `activeSource`, the user then switches
      // "Keep engine warm" off, reconciliation is now permitted and tears the
      // source down — and the kernel's stop lands here. `RecoverySpoolStore`
      // scans every file without requiring a marker and the replayer accepts a
      // truncated prefix, so the leftover could be replayed as a real recording.
      // Only best-effort deletion on the live ending masked it, and that does not
      // run if the process dies first. Reached only after the identity fence, so
      // this is always THIS session's spool. Idempotent via `recoveryFinalized`.
      stopRecoverySpooling(tail: samples)
      return CaptureResult(samples: samples)
    }

    // Snapshot the backend tag BEFORE any teardown path so the pipeline's
    // post-stop Sentry extras still resolve when warmEnginePolicy == .off nils
    // activeSource synchronously (#285).
    cachedSourceType = source.captureSourceType
    cachedDrainedPreRollSampleCount = max(0, source.drainedPreRollSampleCount)
    // #1434: capture-health snapshot must ALSO precede teardown — with
    // warmEnginePolicy == .off, scheduleWarmEngineTeardown() below destroys
    // the render context this reads from.
    let stopMetadata = source.captureStopMetadata

    isCapturing = false
    // #1317 (cloud review P1, round 6): do NOT clear `effectiveDiscriminatorDevice`
    // here — the kernel's STOP-time backstop reads `zeroSignalDiscriminatorDevice`
    // AFTER this `stopCapture()` call returns. The next `startEnginePhase()`
    // already invalidates and re-adopts it for the next session.
    audioLevel = 0.0

    // Deactivate capture but keep engine warm. The tap stays installed and the
    // pre-roll ring buffer continues capturing audio. On the next recording,
    // prepare() sees the engine is already running and skips startup.
    // This eliminates first-word clipping by ensuring the ring buffer has
    // audio from before the user pressed the key.
    onLifecycleSignal?("manager_deactivate_capture_entered")
    source.deactivateCapture()
    onLifecycleSignal?("manager_deactivate_capture_completed")

    // Keep activeSource alive — resolveSource() will reuse it if still running.
    // BT state changes are handled by resolveSource() re-evaluating the route.

    // Schedule full teardown after idle period. Engine stays warm for rapid-fire
    // dictation but doesn't run indefinitely.
    scheduleWarmEngineTeardown()

    // Samples accumulated via onSamples callback -> manager.capturedSamples.
    // In-process path returns empty vadSegments; pipeline owns its own SilenceDetector.
    let samples = capturedSamples
    capturedSamples = []
    captureStartUptimeNs = 0

    // Crash-recovery limb (AFTER the authoritative result is frozen so it never
    // delays delivery): append the tail beyond what the poll loop fed, then
    // finalize with the clean marker. Uses `samples`, never the now-cleared
    // live buffer. Fail-open. (#1543)
    stopRecoverySpooling(tail: samples)
    return CaptureResult(samples: samples, metadata: stopMetadata)
  }

  /// Append a batch of converted samples and enforce the hard sample-count
  /// backstop (#1408 A3). Extracted from the `onSamples` wiring so the backstop
  /// is unit-testable with an injected `maxRecordingSamplesLimit`; the wiring
  /// closure owns the source-identity check, this owns the state change.
  ///
  /// The backstop is the LAST-DITCH memory protection behind the graceful
  /// 3600s wall-clock cap (`VADMonitorLoop`, host-side): it stops appending
  /// locally (`isCapturing = false` — the closure's guard goes quiet, so the
  /// callback fires at most once) even when the host that would drive a normal
  /// stop is gone, then signals a NORMAL `.maxDuration` stop through
  /// `onMaxDurationReached` — never an engine interruption; no cause is
  /// stamped, no loss is claimed. A later `stopCapture()` still returns the
  /// accumulated samples (it has no `isCapturing` guard).
  func ingestSamples(_ samples: [Float], level: Float) {
    guard isCapturing else { return }
    audioLevel = level
    capturedSamples.append(contentsOf: samples)
    // #1317 (#1543): reactive all-zero harness-glitch detection on the same
    // MainActor-isolated authoritative samples that accumulate above — the
    // in-process equivalent of the proxy's per-buffer MainActor hop.
    feedDeadAirDetector(samples)
    if capturedSamples.count >= maxRecordingSamplesLimit {
      isCapturing = false
      audioLevel = 0.0
      Task {
        await AppLogger.shared.log(
          "Max recording duration reached (\(Self.maxRecordingDurationSeconds)s) — auto-stopping",
          level: .info, category: "Audio"
        )
      }
      onMaxDurationReached?()
    }
  }

  public func rebuildEngine() {
    guard let source = activeSource else { return }
    rebuildActiveSource(source)
  }

  /// Heartpath 5b (#1520): retire the source that captured `sessionID` so the next
  /// press opens a fresh one (re-establishing a dead Bluetooth link). Fenced three
  /// ways and idempotent — a no-op unless this is still the current capture session
  /// AND the retained captured source is still the running active source, so a
  /// stale finish from an older take can never tear down a newer take's source.
  /// Whether the take was silent is decided by the kernel; this method is
  /// device-blame-free.
  @discardableResult
  public func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult {
    guard sessionID == captureSessionCounter else {
      Self.btRouteLog("Zero-signal retire skipped: stale capture session")
      return .staleSession
    }
    guard let capturedSource = captureSessionSource else {
      Self.btRouteLog("Zero-signal retire skipped: captured source already gone")
      return .capturedSourceGone
    }
    defer { clearCaptureSessionSource(ifMatching: capturedSource) }
    guard let source = activeSource else {
      Self.btRouteLog("Zero-signal retire skipped: active source already gone")
      return .activeSourceGone
    }
    guard source === capturedSource else {
      Self.btRouteLog("Zero-signal retire skipped: source was replaced")
      return .sourceReplaced
    }
    guard source.isRunning else {
      Self.btRouteLog("Zero-signal retire skipped: source already torn down")
      return .sourceNotRunning
    }
    rebuildActiveSource(source)
    Self.btRouteLog("Zero-signal source retired")
    return .retired
  }

  /// The single destructive teardown of the active source, shared by
  /// `rebuildEngine()` and `retireCapturingSource`. Only a real rebuild advances
  /// the incarnation: with no active source nothing is destroyed, so a bump here
  /// would falsely satisfy `fresh_pipe_proven`.
  private func rebuildActiveSource(_ source: any AudioInputSource) {
    source.rebuild()
    clearCaptureSessionSource(ifMatching: source)
    #if DEBUG
      debugSourceIncarnation += 1  // destructive rebuild of the active source's resources
    #endif
  }

  /// Drop the retained capture-session source once it is torn down or replaced, so
  /// no torn-down source is retained for the rest of the app's life. Matches by
  /// reference so an older teardown never clears a newer session's retained source.
  private func clearCaptureSessionSource(ifMatching source: any AudioInputSource) {
    guard let captured = captureSessionSource, captured === source else { return }
    captureSessionSource = nil
  }

  #if DEBUG
    /// Test seam (heartpath 5b): install `captured` as the retained capture source
    /// for session `sessionID`, with `active` (defaulting to `captured`) as the
    /// live active source — without real hardware. Mirrors the `isCapturing`
    /// internal(set) "arm without hardware" pattern the other manager unit tests
    /// use, because `beginCapturePhase` needs a real device format a stub cannot
    /// provide. Lets `AudioCaptureManagerRetireFenceTests` exercise the retire
    /// fence against the REAL manager state, not a `FakeAudioCapture`.
    func installCapturedSourceForTesting(
      _ captured: any AudioInputSource, active: (any AudioInputSource)? = nil, sessionID: UInt64
    ) {
      captureSessionSource = captured
      activeSource = active ?? captured
      // #1810: mirror the production snapshot. `stopCapture()` caches the drain from
      // the source BEFORE any teardown path can nil `activeSource`; a seam that
      // installed a source without it would let a test read a fallback that
      // production always populates.
      cachedDrainedPreRollSampleCount = max(0, captured.drainedPreRollSampleCount)
      captureSessionCounter = sessionID
    }

    /// Test seam (#1810): drop the active source WITHOUT touching the cached
    /// per-session facts, which is the state `stopCapture()`'s documented
    /// `activeSource == nil` early return and the `warmEnginePolicy == .off` teardown
    /// both leave behind. A stub cannot reach it through `stopCapture()`, which needs
    /// a real device format. Exists so the PR #2200 cloud-review finding has a guard
    /// rather than a promise.
    func tearDownActiveSourceForTesting() {
      activeSource = nil
    }

    /// Test seam (#1844): force `resolveSource()` to build its source from
    /// `factory` instead of a real `HALDeviceInputSource`, so the adoption tests drive
    /// `startEnginePhase()` with a stub whose `prepare()` returns a controlled
    /// bind — no hardware, no real AUHAL unit. nil restores normal resolution.
    /// Consumed in `resolveSource()`; production never sets it.
    func installSourceFactoryForTesting(
      _ factory: ((CaptureRouteDecision) -> any AudioInputSource)?
    ) {
      debugSourceFactory = factory
    }

    /// #1714 Live UAT seam: force the resolver to see NO system default, so the
    /// list-fallback rung — the whole point of this issue — actually runs on a
    /// real build with real hardware.
    ///
    /// Recording a normal dictation proves nothing about the fallback: with a
    /// working default present, resolution returns at the unchanged default rung
    /// and the new code never executes. This is the only way the Live UAT can
    /// reach its own subject.
    ///
    /// Everything except the default lookup stays REAL — a real
    /// `HALDeviceInputSource`, real enumeration, real AUHAL binding. Only the
    /// one question "what is the default input device?" is forced to nil.
    ///
    /// Returns `false` and changes nothing while capture is active. Otherwise it
    /// tears down any idle warm source SYNCHRONOUSLY before returning, because
    /// `warmReuseBind` returns before resolution — an armed-but-warm source
    /// would skip the branch entirely and the UAT would report a pass having
    /// tested nothing.
    @discardableResult
    package func debugSetDefaultInputAbsent(_ absent: Bool) -> Bool {
      guard !isCapturing else { return false }
      warmEngineTeardownTask?.cancel()
      warmEngineTeardownTask = nil
      if let existing = activeSource {
        rebuildActiveSource(existing)
        activeSource = nil
      }
      debugSourceFactory =
        absent
        ? { decision in
          let source = HALDeviceInputSource()
          source.targetDeviceUID = decision.effectiveDeviceUID
          source.inputDeviceResolver = InputDeviceResolver(
            defaultInputDeviceID: { nil },
            inputDeviceSnapshot: AudioDeviceEnumerator.inputDeviceSnapshot
          )
          return source
        } : nil
      return true
    }

    /// #1714 test seam: build a source from a GIVEN decision.
    ///
    /// Lets the arming tests observe the factory by its EFFECT — does the built
    /// source have its default lookup forced? — rather than by peeking at a
    /// stored closure. A test that only checked the closure was stored would
    /// pass even if nothing ever consumed it.
    ///
    /// Deliberately NOT a wrapper around `resolveSource()`: that runs
    /// `CaptureRouteResolver.resolve()`, which reads the live default OUTPUT
    /// device. On a CI runner with no audio hardware those tests could pass
    /// vacuously or fail for reasons unrelated to arming. Taking the decision as
    /// an argument keeps the seam to exactly the construction step under test.
    func buildSourceForTesting(_ decision: CaptureRouteDecision) -> any AudioInputSource {
      buildSource(for: decision)
    }

    /// Test seam (heartpath 5b): drop the live active source while KEEPING the
    /// retained capture-session source, so `retireCapturingSource` reaches the
    /// `.activeSourceGone` branch. The installer's optional `active` argument
    /// treats nil as "use captured" and cannot construct this state directly.
    func clearActiveSourceForTesting() {
      activeSource = nil
    }

    /// Test seam (#1579): arm the recovery spool directly. `startRecoverySpooling`
    /// is private and only reachable through `beginCapturePhase`, which needs a
    /// real device format a stub cannot provide — the same constraint that forced
    /// `installCapturedSourceForTesting`. Lets the predecessor-retirement tests
    /// assert against the REAL spool files rather than manager internals.
    func armRecoverySpoolingForTesting(payload: Data?) {
      startRecoverySpooling(payload: payload)
    }

    /// Test oracle (#1579): whether a live feed task is currently retained. A
    /// retired predecessor must leave none.
    var debugHasLiveRecoveryFeedTask: Bool {
      guard let task = recoveryFeedTask else { return false }
      return !task.isCancelled
    }

    /// Test oracle (#1579): the currently armed writer, so a test can hold a
    /// reference across the action under test and then barrier on its write queue.
    /// The manager clears its own reference on every finalize path, so a test that
    /// grabs the writer afterwards would get nil and silently assert nothing.
    var debugRecoverySpoolWriter: RecoverySpoolWriter? { recoverySpoolWriter }
  #endif

  public func preWarm() async throws {
    let preWarmStart = ContinuousClock.now
    let source = resolveSource()
    let resolveMs = Self.ms(ContinuousClock.now - preWarmStart)
    guard !source.isRunning else {
      Self.btRouteLog(
        "COLD-START preWarm(): engine already running (warm hit) resolveSource=\(resolveMs)ms")
      return
    }
    do {
      // #1844: pre-warm runs OUTSIDE any session, so it must not adopt a
      // health-check snapshot — the discarded bind is a visible decision.
      //
      // #1714: but it MUST still attribute. Pre-warm is where cold resolution
      // normally happens; the recording that follows usually takes warm reuse,
      // so attributing only on the recording's own prepare would report almost
      // nothing. The bind is discarded for HEALTH purposes only — the shared
      // helper still retains the attempt and exposes its source.
      _ = try await prepareAndAttribute(source)
    } catch {
      Task {
        await AppLogger.shared.log(
          "Audio pre-warm failed: \(error.localizedDescription)",
          level: .info, category: "Audio"
        )
      }
      // Issue #289: propagate so callers can abort the start cleanly.
      throw error
    }
    let prepareMs = Self.ms(ContinuousClock.now - preWarmStart)
    let stabStart = ContinuousClock.now
    let stabilized = await source.waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    let stabMs = Self.ms(ContinuousClock.now - stabStart)
    let totalMs = Self.ms(ContinuousClock.now - preWarmStart)
    Self.btRouteLog(
      "COLD-START preWarm(): total=\(totalMs)ms | resolve=\(resolveMs)ms prepare=\(prepareMs)ms formatStab=\(stabMs)ms stabilized=\(stabilized)"
    )
  }

  /// Convert Duration to milliseconds for logging.
  nonisolated private static func ms(_ d: Duration) -> Int {
    let (seconds, attoseconds) = d.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }

  public func abortPreWarm() {
    activeSource?.abortPrepare()
  }

  public func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
    -> Bool
  {
    guard let source = activeSource else { return true }
    return await source.waitForFormatStabilization(maxWait: maxWait, pollInterval: pollInterval)
  }

  // MARK: - Warm Engine Management

  /// Schedule engine teardown based on the current warm engine policy.
  /// Called after every recording stops. Cancelled if a new recording starts.
  private func scheduleWarmEngineTeardown() {
    warmEngineTeardownTask?.cancel()
    warmEngineTeardownTask = nil

    switch warmEnginePolicy {
    case .off:
      performEngineTeardown()
      return
    case .always:
      idleSince = clock.now
      return
    case .seconds10, .seconds30, .seconds60:
      break
    }

    let timeout = policyTimeout(warmEnginePolicy)
    idleSince = clock.now
    warmEngineTeardownTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, let self, !self.isCapturing else { return }
      self.performEngineTeardown()
    }
  }

  /// In-flight engine stop task. Stored so resolveSource() can cancel it
  /// if a new recording starts before the stop completes, preventing two
  /// engines from running simultaneously on the same hardware.
  private var engineStopTask: Task<Void, Never>?

  /// Tear down the warm engine. Clears activeSource synchronously before
  /// awaiting stop to prevent stale async completions from clobbering new state.
  private func performEngineTeardown() {
    idleSince = nil
    guard let source = activeSource else { return }
    activeSource = nil
    clearCaptureSessionSource(ifMatching: source)  // heartpath 5b: don't retain a torn-down source
    Self.btRouteLog("Warm engine teardown")
    engineStopTask = Task { [weak self] in
      _ = await source.stop()
      self?.engineStopTask = nil
    }
  }

  /// Reconcile engine state when the policy changes while idle.
  /// Called automatically by the warmEnginePolicy setter.
  private func reconcileWarmEnginePolicy() {
    // If capturing, new policy applies on next stopCapture.
    guard !isCapturing else { return }
    // If engine is not warm, nothing to reconcile.
    guard activeSource != nil else { return }

    warmEngineTeardownTask?.cancel()
    warmEngineTeardownTask = nil

    switch warmEnginePolicy {
    case .off:
      performEngineTeardown()
    case .always:
      // Keep warm indefinitely, preserve idleSince.
      break
    case .seconds10, .seconds30, .seconds60:
      let timeout = policyTimeout(warmEnginePolicy)
      let elapsed = idleSince.map { clock.now - $0 } ?? .zero
      if elapsed >= timeout {
        performEngineTeardown()
      } else {
        let remaining = timeout - elapsed
        warmEngineTeardownTask = Task { [weak self] in
          try? await Task.sleep(for: remaining)
          guard !Task.isCancelled, let self, !self.isCapturing else { return }
          self.performEngineTeardown()
        }
      }
    }
  }

  /// Map a timed policy case to a Duration.
  private func policyTimeout(_ policy: WarmEnginePolicy) -> Duration {
    switch policy {
    case .seconds10: .seconds(10)
    case .seconds30: .seconds(30)
    case .seconds60: .seconds(60)
    default: .seconds(30)
    }
  }

  // MARK: - Source Management

  /// Resolve and create the appropriate capture source based on BT state and user preference.
  /// Re-evaluates on every call — BT state may change between recordings.
  /// The ONE place a capture source is constructed (#1714). Extracted so the
  /// DEBUG arming tests can exercise construction from a given decision without
  /// running `CaptureRouteResolver.resolve()`, which reads live output hardware.
  private func buildSource(for decision: CaptureRouteDecision) -> any AudioInputSource {
    #if DEBUG
      if let debugSourceFactory {
        return debugSourceFactory(decision)  // #1844/#1714 seam; nil in production
      }
    #endif
    return Self.makeSource(for: decision)
  }

  private func resolveSource() -> any AudioInputSource {
    // Cancel idle teardown — we're about to record
    warmEngineTeardownTask?.cancel()
    warmEngineTeardownTask = nil
    // Cancel any in-flight engine stop from a previous teardown.
    engineStopTask?.cancel()
    engineStopTask = nil
    // Snapshot the prior decision for the changed-only `onRouteResolved` fire.
    let priorRouteDecision = lastRouteDecision

    // If a source is already running (warm engine), check route compatibility
    if let existing = activeSource, existing.isRunning {
      let decision = routeResolver.resolve(
        preferredInputDeviceUID: preferredInputDeviceIDOverride
      )
      // Non-switch consumer of `CaptureSourceType` (#1377 §6 audit point) — a
      // new candidate must be added here explicitly; the compiler cannot force
      // this equality-style mapping the way it forces the `switch` below.
      let existingSourceType = Self.sourceType(of: existing)

      // Check full config signature, not just source type.
      // Device changes between recordings must trigger rebuild.
      var configMatch = existingSourceType == decision.sourceType
      // A warm HAL source must not be reused once the resolved target device
      // changes (or the bound device drifts from the resolved target).
      if configMatch, let halSource = existing as? HALDeviceInputSource {
        let wantsTarget = decision.effectiveDeviceUID
        let normalize: (String?) -> String = { ($0?.isEmpty ?? true) ? "" : $0! }
        configMatch =
          normalize(halSource.targetDeviceUID) == normalize(wantsTarget)
          && halSource.boundDeviceMatchesResolvedTargetForReuse()
      }

      if configMatch {
        // Route and config unchanged, reuse warm source. This applies to the
        // bench too (#1377): a candidate must be measured with the SAME warm-
        // engine behavior a real user gets — keeping the source warm across
        // recordings holds the Bluetooth SCO link open, so the codec switch
        // fires once at idle teardown (correct, like WisprFlow), NOT on every
        // record. Config changes that DO warrant a rebuild (candidate switch →
        // different sourceType; device change; a stale forced capture-session
        // target) are already caught by the `configMatch` checks above.
        let actualBoundTransport = (existing as? HALDeviceInputSource)?.actualBoundTransport
        adoptRouteDecision(
          decision, prior: priorRouteDecision, actualBoundTransport: actualBoundTransport)
        Self.btRouteLog("Reusing warm \(Self.backendLabel(for: decision.sourceType)) source")
        return existing
      }
      // Route changed (e.g., BT connected/disconnected) — synchronous teardown.
      // Must be synchronous to avoid racing with new source's prepare() on same hardware.
      Self.btRouteLog("Route changed while warm — tearing down old source")
      existing.rebuild()
      activeSource = nil
      clearCaptureSessionSource(ifMatching: existing)  // heartpath 5b
    }

    let decision = routeResolver.resolve(
      preferredInputDeviceUID: preferredInputDeviceIDOverride
    )
    adoptRouteDecision(decision, prior: priorRouteDecision)

    // Structured telemetry log
    Self.btRouteLog(
      "Route decision: source=\(decision.sourceType), reason=\(decision.reason.rawValue) — \(decision.rationale)"
    )
    Task {
      await AppLogger.shared.log(
        "Capture route: \(decision.reason.rawValue) → \(Self.backendLabel(for: decision.sourceType))",
        level: .info, category: "Audio"
      )
    }

    let source = buildSource(for: decision)

    // heartpath 5b: a stopped prior source overwritten here must not stay retained
    // by the capture-session fence.
    if let prior = activeSource {
      clearCaptureSessionSource(ifMatching: prior)
    }
    #if DEBUG
      source.debugZeroFillController = debugZeroFillController
      debugSourceIncarnation += 1  // new source installed at the activeSource authority
    #endif
    activeSource = source
    return source
  }

  /// Builds the concrete source a route decision selects. Extracted from
  /// `resolveSource()` so the #1844 DEBUG factory seam has exactly one production
  /// path to stand in for, rather than duplicating the construction switch.
  private static func makeSource(for decision: CaptureRouteDecision) -> any AudioInputSource {
    switch decision.sourceType {
    case .halDeviceInput:
      let halSource = HALDeviceInputSource()
      halSource.targetDeviceUID = decision.effectiveDeviceUID
      return halSource
    }
  }

  /// Maps a concrete `any AudioInputSource` instance to its `CaptureSourceType`
  /// tag. The non-switch consumer `resolveSource()` uses for warm-reuse
  /// compatibility (#1377 §6 audit point) — maps each concrete type explicitly
  /// so a future second backend cannot be silently read as a match.
  private static func sourceType(of source: any AudioInputSource) -> CaptureSourceType? {
    if source is HALDeviceInputSource { return .halDeviceInput }
    return nil
  }

  /// Human-readable backend label for logging. Single authority so a new
  /// candidate cannot be silently mislabeled by a stale two-way ternary
  /// (#1377 §6 audit point — non-switch consumers compile silently on a new
  /// enum case and must be audited, not trusted to the compiler).
  private static func backendLabel(for sourceType: CaptureSourceType) -> String {
    switch sourceType {
    case .halDeviceInput: return "HALDeviceInput"
    }
  }

  // MARK: - BT Route Logging (Step 6 instrumentation)

  /// Default sink path; cross-process write target shared by main app + XPC service.
  /// Phase R4: bounded by `RotatingFileSink` at 5 MB × 3 files = 15 MB ceiling.
  nonisolated private static let btRouteLogURL: URL = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/EnviousWispr/bt-route.log")

  /// Bounded sink for BT route diagnostics. `nonisolated static` matches the
  /// prior surface so existing sync callers keep their call shape; the sink
  /// itself uses `OSAllocatedUnfairLock` + `flock` for safety across the main
  /// app and XPC service writing concurrently.
  nonisolated static let btRouteSink = RotatingFileSink(
    path: btRouteLogURL,
    maxSize: 5 * 1_024 * 1_024,
    maxFiles: 3)

  /// Direct file write for BT route diagnostics. os_log info level is suppressed on macOS 26 beta,
  /// and AppLogger.shared is process-local (XPC service has its own instance).
  nonisolated static func btRouteLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [BTRoute] \(message)\n"
    btRouteSink.append(line)
  }

  // MARK: - VAD Interface (Step 5)

  /// No-op for in-process capture. The in-process path manages VAD entirely through
  /// pipeline-owned properties (vadAutoStop, vadSensitivity, etc.) and the pipeline's
  /// monitorVAD() loop. The capture manager never runs VAD itself.
  /// Exists solely for AudioCaptureInterface protocol conformance.
  public func configureVAD(
    autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool
  ) {
    // Intentional no-op — see comment above.
  }

  /// Returns a slice of capturedSamples starting at fromIndex plus the current total count.
  /// Both values are from the same snapshot moment for consistency.
  public func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    let totalCount = capturedSamples.count
    let clampedIndex = max(0, min(fromIndex, totalCount))
    if clampedIndex >= totalCount {
      return (samples: [], totalCount: totalCount)
    }
    let slice = Array(capturedSamples[clampedIndex..<totalCount])
    return (samples: slice, totalCount: totalCount)
  }

  /// Returns empty — in-process VAD segments are owned by the pipeline's SilenceDetector,
  /// not by the capture manager. Only meaningful for the XPC path.
  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  public func getVADSegments() async -> [SpeechSegment] {
    return []
  }

  // MARK: - Reactive dead-air detection (#1317, ported in-process at C1 #1543)

  /// Feed this batch's raw samples into the per-generation all-zero
  /// harness-glitch detector; when it crosses a confidence threshold, run the
  /// §3.0 device discriminator and — only if it returns `.eligible` — fire
  /// `onCaptureStalled` with the matching failure mode. Any of the five
  /// non-eligible reasons fails closed: no fire, today's honest no-speech path
  /// is untouched, the run's reason is frozen so the kernel's STOP-time backstop
  /// stays fail-closed, and the next batch re-evaluates (device state can
  /// legitimately change mid-recording). MainActor-isolated (called from
  /// `ingestSamples`), so the detector is never mutated off the consumer thread.
  private func feedDeadAirDetector(_ samples: [Float]) {
    guard !deadAirDetector.fired, !captureStallReported, !samples.isEmpty else { return }
    let suffixBefore = deadAirDetector.consecutiveExactZeroSuffix
    samples.withUnsafeBufferPointer { deadAirDetector.ingest($0) }
    // A non-zero sample anywhere in this batch breaks the trailing zero-run —
    // `consecutiveExactZeroSuffix` after ingest is then strictly less than
    // `suffixBefore + samples.count`. Any earlier refusal applied to THAT run,
    // not this new one, so it must not suppress detection of a later, unrelated
    // zero-signal failure.
    if deadAirDetector.consecutiveExactZeroSuffix != suffixBefore + samples.count {
      // #1578: current-run facts only. Anything already REJECTED stays in the
      // backlog — the run it described really happened, and recovery does not
      // undo it.
      resetZeroSignalState(clearBacklog: false)
    }
    #if DEBUG
      emitZeroPrefixDiagnosticIfNeeded()
    #endif

    let mode: CaptureStallFailureMode
    if deadAirDetector.isAllZeroFromStart(ceilingSamples: allZeroCeilingSamples) {
      mode = .allZeroFromStart
    } else if deadAirDetector.isBecameZeroMidCapture {
      mode = .becameZeroMidCapture
    } else {
      return
    }

    // Evaluate against the bind this attempt's `prepare()` RETURNED (#1844),
    // not a live re-read — the live UID properties can already reflect a device
    // the user switched to mid-recording, and a settings-derived value can name
    // a microphone HAL never opened. The optional goes straight to the
    // classifier: #1578 made it the single owner of the missing-bind outcome,
    // so translating `nil` here would put that policy in two places.
    let reason = ZeroSignalDeviceDiscriminator.classify(bound: effectiveDiscriminatorDevice)

    guard reason == .eligible else {
      // This candidate was refused for one of the classifier's five non-eligible
      // reasons. Freeze the first reason so STOP cannot later reinterpret the run
      // from a changed live device state.
      //
      // ONE observation per RUN, though the classification above still runs per
      // BATCH. `feedDeadAirDetector` fires on every incoming batch and a zero run
      // spans many of them; this flag — not callback success, not backlog
      // membership, not either stall latch — is what silences the second and
      // later refusals of the same run.
      guard !currentRunWasClassifiedReactively else { return }

      // Set BOTH fields before calling out: a subscriber that synchronously
      // re-enters capture must find this run already classified.
      currentZeroSignalRefusalReason = reason
      currentRunWasClassifiedReactively = true

      // Same authorities `fireDeadAirStall` uses for the same two facts — the
      // detector-selected shape and the resolved effective transport — so the
      // refusal event and the stall event can never disagree about a take.
      let context = ZeroSignalRefusalContext(
        sessionID: currentCaptureSessionID,
        reason: reason,
        transport: currentResolvedRoute?.effective ?? "unknown",
        failureShape: mode
      )
      // ONE attempt. A missing subscriber and an explicit `false` are the same
      // answer — not delivered — so the context is preserved for a terminal
      // drain rather than lost. Note this deliberately sets neither
      // `deadAirDetector.fired` nor `captureStallReported`: a refusal is an
      // observation, and latching either one would suppress a later GENUINE
      // failure in the same take.
      if onZeroSignalRefused?(context) != true {
        pendingZeroSignalRefusals.append(context)
      }
      return
    }

    deadAirDetector.fired = true
    fireDeadAirStall(mode: mode)
  }

  #if DEBUG
    /// Is the wake a clean measurement OF THE DELIVERED STREAM? True only when the
    /// stream lost nothing AND at least one sample was routed before the first
    /// non-zero one. Both failure modes under-report, never over-report, so the
    /// fallback label is `floor`.
    ///
    /// The label deliberately says `stream_measured`, NOT `exact`. r7 pointed out
    /// that a callback-free startup followed by a few zeros still satisfies
    /// `wakeSamples > 0` while covering only the zeros AFTER callbacks began, so a
    /// true press-to-audio figure would need a second timebase. That was tried in
    /// r2 and deleted for being late by the whole pre-roll batch, and two numbers
    /// that disagree is how a future session trusts the wrong one. So the honest fix
    /// is naming: NO sample-derived wake can be exact with respect to press-to-audio,
    /// and a word that claimed otherwise was the actual defect. Every value here is
    /// a lower bound; `stream_measured` says only that the delivered stream was
    /// gap-free and carried an observed silent prefix.
    ///
    /// The second condition is the whole of r5 and r6, and it reduces to
    /// `wakeSamples > 0`. A sample clock cannot measure an interval containing no
    /// samples: a wake of zero means the first sample that ever existed was already
    /// non-zero, so a link that woke during a callback-free startup is
    /// indistinguishable from one that was awake all along. A measured zero prefix
    /// is the only evidence that the stream was running while the link was still
    /// silent.
    ///
    /// r6 killed the previous formulation, which asked `routedCountAtActivation > 0`
    /// — that field is the rebase offset for pre-roll the ring OVERWROTE, not a
    /// count of samples that preceded activation, so it is legitimately 0 whenever
    /// nothing was dropped. It also treated a pre-roll latch at index 0 as proof,
    /// when index 0 is exactly the ambiguous case. Both errors are gone rather than
    /// special-cased, because the quantity actually being asked about is the wake
    /// itself. An unknown gap count or an unavailable wake fails CLOSED.
    nonisolated static func wakeIsStreamMeasured(gapCount: Int?, wakeSamples: Int?) -> Bool {
      guard let gapCount, let wakeSamples else { return false }
      return gapCount == 0 && wakeSamples > 0
    }

    /// Report the exact-zero prefix once per capture generation (#1788).
    ///
    /// On Bluetooth this is the A2DP->SCO/HFP link wake time. It is a DEBUG
    /// diagnostic on purpose and permanently: production telemetry carries no
    /// such field, and without this line a future Bluetooth investigation has to
    /// re-derive wake timing by hand, which is how #1788 started. Writes to
    /// `app.log` only (requires in-app Debug Mode) — never PostHog, never Sentry,
    /// never the network. Emits a duration, a sample count and a transport label,
    /// so it is inside the privacy boundary by construction.
    private func emitZeroPrefixDiagnosticIfNeeded() {
      guard !didLogZeroPrefixThisSession,
        let zeroPrefixSamples = deadAirDetector.zeroPrefixSampleCount
      else { return }
      didLogZeroPrefixThisSession = true
      let zeroPrefixMs = Double(zeroPrefixSamples) / AudioConstants.sampleRate * 1000
      // #1788, after THREE review rounds on the same class: every earlier version
      // of this line measured when the diagnostic OBSERVED the wake, not when the
      // wake happened. A sample count taken from the detector misses pre-roll the
      // ring overwrote; a wall clock read here is late by the whole pre-roll batch,
      // because pre-roll arrives all at once AT activation. The only quantity that
      // corresponds to occurrence is the sample's own position in the stream,
      // latched by `PreRollForwarder` the moment it arrived — and that holds only
      // while the stream is gap-free, which the `gaps` field below reports.
      let wake =
        activeSource?.wakeDiagnostic
        ?? (firstNonZeroRoutedIndex: nil, routedCountAtActivation: nil)
      let wakeSamples: Int? = {
        // Latched during pre-roll: already stream-absolute and immune to the ring.
        if let preRoll = wake.firstNonZeroRoutedIndex { return preRoll }
        // Otherwise the wake was live; rebase the detector's exact live index onto
        // the stream. Nothing is dropped in the live phase.
        guard let base = wake.routedCountAtActivation else { return nil }
        return base + zeroPrefixSamples
      }()
      let wakeMs = wakeSamples.map { Double($0) / AudioConstants.sampleRate * 1000 }
      let wakeField =
        wakeMs.map { String(format: "%.0f", $0) } ?? "unavailable"
      let transport = currentResolvedRoute?.effective ?? "unknown"
      let ceiling = allZeroCeilingSamples
      // EVERY value on this line is a LOWER BOUND on press-to-audio latency: a
      // sample clock cannot see an interval in which no samples exist, and no
      // second clock is carried (see `wakeIsStreamMeasured`). `wake_is` reports
      // only whether the DELIVERED stream was a clean measurement, which needs two
      // things — cloud review found one per round until both were stated here
      // rather than assumed:
      //  1. the stream lost nothing — `CaptureStopMetadata.inputTimelineGapCount`
      //     owns that enumeration and its window (r3, r4, r5), so a new lossy
      //     edge needs no new field here;
      //  2. at least one sample was routed BEFORE the first non-zero one, i.e.
      //     `wakeSamples > 0` (r5, corrected in r6 — see
      //     `wakeIsStreamMeasured`). A sample
      //     clock cannot measure an interval containing no samples, so a zero wake
      //     cannot distinguish a link that was already awake from one that woke
      //     during a callback-free startup. No second clock: that was tried in r2
      //     and deleted for being late by the whole pre-roll batch.
      // Both failures under-report, never over-report, so the honest label is
      // `floor` and `exact` is claimed only when both hold. Of 13 Bluetooth
      // readings taken before this, 8 read 0 and the log alone could NOT tell a
      // genuinely warm link from a delayed first buffer — that ambiguity is what
      // this closes.
      let gaps = activeSource?.captureStopMetadata?.inputTimelineGapCount
      let gapField = gaps.map(String.init) ?? "unknown"
      let basis =
        Self.wakeIsStreamMeasured(gapCount: gaps, wakeSamples: wakeSamples)
        ? "stream_measured" : "floor"
      Task {
        await AppLogger.shared.log(
          "ZERO_PREFIX_MEASURE transport=\(transport) "
            + "wake_ms=\(wakeField) wake_is=\(basis) timeline_gaps=\(gapField) "
            + "detector_zero_prefix_ms=\(String(format: "%.0f", zeroPrefixMs)) "
            + "detector_zero_prefix_samples=\(zeroPrefixSamples) "
            + "ceiling_samples=\(ceiling)",
          level: .info, category: "Audio")
      }
    }
  #endif

  /// Overlay the manager's app-lifetime session id + frozen route decision onto
  /// a HAL-built stall context before forwarding (#1543 Codex review P2). The
  /// HAL source cannot see either; source-stamped health fields are preserved.
  private func enrichStallContext(_ ctx: CaptureStallContext) -> CaptureStallContext {
    ctx.enrichedWithManagerRoute(
      sessionID: currentCaptureSessionID,
      route: currentAudioRoute,
      selectedTransport: currentResolvedRoute?.selected,
      effectiveTransport: currentResolvedRoute?.effective,
      routeReason: currentResolvedRoute?.routeReason,
      routeFallbackReason: currentResolvedRoute?.routeFallbackReason,
      inputSelectionMode: currentResolvedRoute?.inputSelectionMode,
      outputTransport: currentResolvedRoute?.outputTransport,
      routeResolutionSource: currentResolvedRoute?.routeResolutionSource)
  }

  /// Build and fire the dead-air `CaptureStallContext`. Sets the shared
  /// `captureStallReported` latch first so the HAL no-buffer watchdog and this
  /// path together honor the at-most-once-per-session contract.
  private func fireDeadAirStall(mode: CaptureStallFailureMode) {
    captureStallReported = true
    let ctx = CaptureStallContext(
      sessionID: currentCaptureSessionID,
      armedAtUptimeNs: captureStartUptimeNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: currentAudioRoute,
      sourceType: captureSourceType,
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: preferredInputDeviceIDOverride.isEmpty
        ? nil : preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      failureMode: mode,
      selectedTransport: currentResolvedRoute?.selected,
      effectiveTransport: currentResolvedRoute?.effective,
      routeReason: currentResolvedRoute?.routeReason,
      routeFallbackReason: currentResolvedRoute?.routeFallbackReason,
      inputSelectionMode: currentResolvedRoute?.inputSelectionMode,
      outputTransport: currentResolvedRoute?.outputTransport,
      routeResolutionSource: currentResolvedRoute?.routeResolutionSource
    )
    onCaptureStalled?(ctx)
  }

  // MARK: - Crash-recovery spool (#1063; ported in-process at C1 #1543)

  /// Decode the directive and arm the spool writer + feed loop. Fail-open: any
  /// decode/preflight failure leaves recovery off and capture byte-identical.
  /// Retire any live predecessor spool: write its terminal marker and cancel its
  /// feed. Single owner (#1579 §3c), called from BOTH the start of
  /// `beginCapturePhase` (so nothing of the new take can reach an old writer) and
  /// the top of `startRecoverySpooling` (so a direct arm is safe on its own).
  /// Idempotent — `finalizeRecovery` no-ops once the writer is gone.
  private func retirePredecessorRecoverySpool() {
    // Feed the tail the poll loop had not reached yet, so a superseded spool is
    // still complete up to the moment it was superseded. `finalizeRecovery` marks
    // it `.interrupted` rather than `.cleanFinalized`: this session did not end
    // cleanly, and the marker must not claim it did.
    if let writer = recoverySpoolWriter, !recoveryFinalized,
      capturedSamples.count > recoveryFedSampleCount
    {
      writer.append(Array(capturedSamples[recoveryFedSampleCount...]))
      recoveryFedSampleCount = capturedSamples.count
    }
    if recoverySpoolWriter != nil { finalizeRecovery(.interrupted) }
    // A task can outlive its writer (the writer is cleared on every finalize
    // path); cancel unconditionally so no stale feed survives.
    recoveryFeedTask?.cancel()
    recoveryFeedTask = nil
  }

  private func startRecoverySpooling(payload: Data?) {
    // #1579 (defect 1b): RETIRE any predecessor before resetting, never drop it.
    // The old code nil'd `recoverySpoolWriter` and left `recoveryFeedTask` alive.
    // That task holds its writer strongly and guards only on `isCapturing` +
    // `writer.isHealthy` — both true again once this new session arms — so it
    // would wake and append THIS session's samples into the PREVIOUS session's
    // encrypted spool. Worse, it advances the shared `recoveryFedSampleCount`,
    // so the new writer then skips the range the stale task consumed:
    // contamination in both directions. Routed through `finalizeRecovery` rather
    // than repeated inline — that is the single owner of "cancel the feed, write
    // the terminal marker, clear the writer" (#1579 §3c).
    retirePredecessorRecoverySpool()

    recoveryFinalized = false
    recoveryFedSampleCount = 0
    recoverySpoolWriter = nil
    guard let payload,
      let directive = try? JSONDecoder().decode(RecoverySpoolDirective.self, from: payload),
      directive.enabled
    else { return }
    // Low-disk preflight: don't start a spool when free space is already below
    // the watermark the heart path needs (History save / ASR temp / model cache).
    guard Self.hasSufficientDiskSpace(forSpoolAt: directive.spoolPath) else { return }

    let writer = RecoverySpoolWriter(
      recoverySessionID: directive.recoverySessionID,
      spoolURL: URL(fileURLWithPath: directive.spoolPath),
      cipher: RecoverySpoolCipher(directive: directive),
      settings: directive.settingsSnapshot)
    writer.start()
    recoverySpoolWriter = writer
    startRecoveryFeed(writer: writer, spoolPath: directive.spoolPath)
  }

  /// Poll the authoritative `capturedSamples` and append new ranges to the
  /// writer — mirrors the crash-recovery feed the helper ran. Lossless (the
  /// same buffer `stopCapture` returns), off the RT thread, batched at
  /// ~`chunkIntervalSeconds`, durable-flushed ~every `flushIntervalSeconds`.
  private func startRecoveryFeed(writer: RecoverySpoolWriter, spoolPath: String) {
    recoveryFeedTask = Task { @MainActor [weak self] in
      var pollCount = 0
      let flushEvery = max(
        1,
        Int(
          (RecoveryConstants.flushIntervalSeconds / RecoveryConstants.chunkIntervalSeconds)
            .rounded()))
      while !Task.isCancelled {
        guard let self else { return }
        guard self.isCapturing, writer.isHealthy else { return }

        let currentCount = self.capturedSamples.count
        if currentCount > self.recoveryFedSampleCount {
          let chunk = Array(self.capturedSamples[self.recoveryFedSampleCount..<currentCount])
          writer.append(chunk)
          self.recoveryFedSampleCount = currentCount
        }

        pollCount += 1
        if pollCount % flushEvery == 0 {
          writer.flush()
          // Low-disk watermark re-check: stop spooling with an honest terminal
          // marker before recovery can starve the disk the heart path needs.
          if !Self.hasSufficientDiskSpace(forSpoolAt: spoolPath) {
            self.finalizeRecovery(.lowDiskWatermark)
            return
          }
        }

        try? await Task.sleep(for: .seconds(RecoveryConstants.chunkIntervalSeconds))
      }
    }
  }

  /// Clean stop: feed the final tail beyond what the poll loop wrote, then
  /// finalize with the clean marker. Runs once (guarded).
  private func stopRecoverySpooling(tail: [Float]) {
    guard !recoveryFinalized, let writer = recoverySpoolWriter else { return }
    recoveryFinalized = true
    recoveryFeedTask?.cancel()
    recoveryFeedTask = nil
    if tail.count > recoveryFedSampleCount {
      writer.append(Array(tail[recoveryFedSampleCount...]))
    }
    writer.flush()
    writer.finalize(reason: .cleanFinalized)
    recoverySpoolWriter = nil
  }

  /// Finalize the spool for a non-clean reason (low disk). Guarded so clean-stop
  /// and this cannot both write a terminal marker.
  private func finalizeRecovery(_ reason: RecoverySpoolTerminationReason) {
    guard !recoveryFinalized, let writer = recoverySpoolWriter else { return }
    recoveryFinalized = true
    recoveryFeedTask?.cancel()
    recoveryFeedTask = nil
    writer.finalize(reason: reason)
    recoverySpoolWriter = nil
  }

  /// True when the spool volume has at least the low-disk watermark free. Reads
  /// the spool's parent directory (the file may not exist yet). Fail-open: an
  /// unreadable value arms recovery anyway — the writer's backpressure cap is
  /// the backstop.
  private static func hasSufficientDiskSpace(forSpoolAt path: String) -> Bool {
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    guard
      let values = try? dir.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let available = values.volumeAvailableCapacityForImportantUsage
    else { return true }
    return available >= RecoveryConstants.lowDiskWatermarkBytes
  }
}
