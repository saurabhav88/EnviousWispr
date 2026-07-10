@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import os

/// Manages audio capture from the microphone — thin coordinator over AudioInputSource backends.
///
/// Owns app-facing state (capturedSamples, audioLevel, isCapturing) and the
/// `AudioCaptureInterface` contract. Delegates all hardware interaction to the
/// active `AudioInputSource` (`AVAudioEngineSource` or `AVCaptureSessionSource`).
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

  /// Stall watchdog callback (forwarded to active source in Phase B implementation).
  public var onCaptureStalled: ((CaptureStallContext) -> Void)?

  /// AVCaptureSession interruption context (forwarded from `AVCaptureSessionSource`).
  public var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?

  /// Only the XPC proxy invokes this; direct-mode manager leaves nil.
  public var onXPCServiceError: ((XPCErrorContext) -> Void)?

  /// Only the XPC proxy invokes this; direct-mode manager leaves nil.
  public var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?

  /// Only the XPC proxy invokes this (#1194); direct-mode manager leaves nil.
  public var onAudioStartRetryResolved: ((AudioStartRetryContext) -> Void)?

  /// Fired by `resolveSource()` — initial resolution + changed-only afterwards.
  public var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?

  /// Monotonic counter, increments on each begin/start-capture.
  /// Delegates to the active source's session counter so dedup and correlation
  /// extras at the pipeline layer always read the live value. Returns 0 when
  /// no source has been resolved yet.
  public var currentCaptureSessionID: UInt64 {
    activeSource?.captureGeneration ?? cachedCaptureGeneration
  }

  /// Delegates to the active source so the pipeline can attribute Sentry
  /// events to the concrete backend (AVAudioEngine vs AVCaptureSession).
  /// Falls back to the cached last-known value after stopCapture tears the
  /// source down (see `cachedSourceType` rationale at field declaration).
  public var captureSourceType: String {
    activeSource?.captureSourceType ?? cachedSourceType
  }

  /// Authoritative capture-active predicate.
  public var isActivelyCapturing: Bool { isCapturing }

  /// Whether noise suppression via Apple Voice Processing is enabled.
  public var noiseSuppressionEnabled = false

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

  /// The active capture source. Created on buildEngine/startEnginePhase.
  /// Either AVAudioEngineSource (no BT) or AVCaptureSessionSource (BT output active).
  private var activeSource: (any AudioInputSource)?

  /// Issue #285 — mirror of `activeSource.captureGeneration` / `captureSourceType`
  /// captured at session start, so pipeline Sentry extras still resolve a real
  /// session id + backend tag after `stopCapture()` synchronously tears down
  /// the source (warmEnginePolicy == .off). Without this cache, post-stop
  /// reads fall back to `0` / `"unknown"` and break stall-vs-no-audio dedup.
  private var cachedCaptureGeneration: UInt64 = 0
  private var cachedSourceType: String = "unknown"

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
  /// before the first resolution. Telemetry-only observation.
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
      selectedInputDeviceUID: selectedInputDeviceUID,
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

  public init() {}

  // MARK: - AudioCaptureInterface

  public func startEnginePhase() async throws {
    // Re-evaluate route on every recording start — BT state may have changed.
    onLifecycleSignal?("manager_resolve_source_entered")
    let source = resolveSource()
    source.onLifecycleSignal = onLifecycleSignal
    onLifecycleSignal?("manager_prepare_entered")
    try await source.prepare()
    if let halSource = source as? HALDeviceInputSource {
      refreshResolvedRoute(actualBoundTransport: halSource.actualBoundTransport)
    }
    onLifecycleSignal?("manager_prepare_completed")
  }

  /// In-process capture path. `recoveryPayload` is accepted for protocol
  /// conformance but IGNORED: the crash-recovery spool runs in the XPC audio
  /// helper (`AudioServiceHandler`), which owns the authoritative
  /// `capturedSamples` in the default (`useXPCAudioService`) topology. The
  /// in-process path is a dev/fallback path and gets recovery in a later phase;
  /// the heart path here is byte-identical regardless. (#1063 PR1.)
  public func beginCapturePhase(recoveryPayload: Data?) async throws
    -> AsyncStream<AVAudioPCMBuffer>
  {
    _ = recoveryPayload  // intentionally unused in-process (see doc above)
    guard let source = activeSource else {
      throw AudioError.formatCreationFailed(
        source: "AudioCaptureManager.beginCapturePhase.no_active_source")
    }

    // Pre-allocate sample buffer
    capturedSamples = []
    capturedSamples.reserveCapacity(16000 * 30)
    audioLevel = 0.0

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
    // to be inferred from the source's class (`source is AVCaptureSessionSource
    // ? .captureSessionLost : .engineLost`), which cannot distinguish a device
    // that was verified gone (`.deviceRemoved`) from an engine that merely failed
    // to recover (`.engineLost`) — both live inside `AVAudioEngineSource`. Only
    // the source runs the `kAudioDevicePropertyDeviceIsAlive` check, so only the
    // source can answer. Passing the cause as a parameter also means the closure
    // captures no `source` reference at all.
    source.onInterrupted = { [weak self] cause in
      guard let self,
        self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
      else { return }
      self.isCapturing = false
      self.audioLevel = 0.0
      self.onEngineInterrupted?(cause)
    }

    // Forward heart-path telemetry callbacks (issue #285) — direct capture
    // mode must surface the same stall / AVCaptureSession interruption signals
    // the XPC proxy already exposes. Stale callbacks from a replaced source
    // are rejected via the sourceID guard.
    source.onCaptureStalled = { [weak self] ctx in
      guard let self,
        self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
      else { return }
      self.onCaptureStalled?(ctx)
    }
    source.onCaptureSessionInterruption = { [weak self] ctx in
      guard let self,
        self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
      else { return }
      self.onCaptureSessionInterruption?(ctx)
    }

    source.onLifecycleSignal = onLifecycleSignal
    onLifecycleSignal?("manager_start_capture_entered")
    let stream = try await source.startCapture()
    onLifecycleSignal?("manager_start_capture_completed")
    isCapturing = true
    #if DEBUG
      // Bake-off manager-side evidence companion (#1377 §3.5): pairs the app's
      // REQUEST (backend + requested device + active policy) with each source's
      // own `CAPTURE_EVIDENCE` (actual bound device). In-process only, so
      // `captureSourceType` is the real backend, never the `"xpc_proxy"` mask.
      let requestedUID = effectiveInputDeviceUID()
      Self.btRouteLog(
        "CAPTURE_EVIDENCE [manager] backend=\(source.captureSourceType) requestedUID=\(requestedUID.isEmpty ? "auto" : requestedUID) policy=\(routeResolver.policy) generation=\(source.captureGeneration)"
      )
    #endif
    // Mirror source identity so pipeline-layer Sentry extras still resolve
    // after stopCapture tears `activeSource` down synchronously.
    cachedCaptureGeneration = source.captureGeneration
    cachedSourceType = source.captureSourceType
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

  public func stopCapture() async -> CaptureResult {
    guard let source = activeSource else {
      let samples = capturedSamples
      capturedSamples = []
      return CaptureResult(samples: samples)
    }

    // Snapshot identity BEFORE any teardown path so the pipeline's post-stop
    // Sentry extras still resolve when warmEnginePolicy == .off nils activeSource
    // synchronously (#285).
    cachedCaptureGeneration = source.captureGeneration
    cachedSourceType = source.captureSourceType
    // #1434: capture-health snapshot must ALSO precede teardown — with
    // warmEnginePolicy == .off, scheduleWarmEngineTeardown() below destroys
    // the render context this reads from.
    let stopMetadata = source.captureStopMetadata

    isCapturing = false
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
    activeSource?.rebuild()
  }

  public func buildEngine(noiseSuppression: Bool) {
    noiseSuppressionEnabled = noiseSuppression
    // buildEngine is called at app startup for VP config. Create an engine source
    // for now — startEnginePhase will re-resolve if BT state requires capture session.
    // If re-resolved to capture session, this engine source is discarded (no resources held —
    // buildEngine only creates an AVAudioEngine object, doesn't start it or install taps).
    if let engineSource = activeSource as? AVAudioEngineSource {
      engineSource.buildEngine(noiseSuppression: noiseSuppression)
    } else {
      // Tear down any existing non-engine source before replacing
      activeSource?.rebuild()
      let engineSource = AVAudioEngineSource()
      engineSource.buildEngine(noiseSuppression: noiseSuppression)
      activeSource = engineSource
    }
  }

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
      try await source.prepare()
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
  private func resolveSource() -> any AudioInputSource {
    // Cancel idle teardown — we're about to record
    warmEngineTeardownTask?.cancel()
    warmEngineTeardownTask = nil
    // Cancel any in-flight engine stop from a previous teardown.
    engineStopTask?.cancel()
    engineStopTask = nil
    #if DEBUG
      // Bake-off control plane (#1377 slice 2a): a runtime override pins a
      // candidate engine for the bench, refreshed every resolve so the harness
      // can switch candidates between recordings. Nil → `.automatic` — the only
      // path release ever takes, since there is no release setter for `policy`.
      routeResolver.policy = CaptureRouteResolver.debugPolicyOverride() ?? .automatic
    #endif
    // Snapshot the prior decision for the changed-only `onRouteResolved` fire.
    let priorRouteDecision = lastRouteDecision

    // If a source is already running (warm engine), check route compatibility
    if let existing = activeSource, existing.isRunning {
      let decision = routeResolver.resolve(
        preferredInputDeviceUID: preferredInputDeviceIDOverride,
        noiseSuppression: noiseSuppressionEnabled
      )
      // Non-switch consumer of `CaptureSourceType` (#1377 §6 audit point) — a
      // new candidate must be added here explicitly; the compiler cannot
      // force this equality-style mapping the way it forces the `switch`
      // below. `existingSourceType == decision.sourceType` (three-way, not a
      // boolean) so a captureSession↔halDeviceInput mismatch is never
      // silently read as a match, which a plain "is engine" boolean would do
      // once a third candidate exists.
      let existingSourceType = Self.sourceType(of: existing)

      // Check full config signature, not just source type.
      // Device/VP changes between recordings must trigger rebuild.
      var configMatch = existingSourceType == decision.sourceType
      if configMatch, let engineSource = existing as? AVAudioEngineSource {
        // Compare effective device selection: preferredInputDeviceIDOverride
        // takes priority, fall back to selectedInputDeviceUID when empty.
        let oldEffective =
          engineSource.preferredInputDeviceIDOverride.isEmpty
          ? engineSource.selectedInputDeviceUID
          : engineSource.preferredInputDeviceIDOverride
        let newEffective =
          preferredInputDeviceIDOverride.isEmpty
          ? selectedInputDeviceUID
          : preferredInputDeviceIDOverride
        let deviceMatch = oldEffective == newEffective
        let vpMatch = engineSource.noiseSuppressionEnabled == noiseSuppressionEnabled
        configMatch = deviceMatch && vpMatch
      }
      #if DEBUG
        // A warm AVCaptureSessionSource from a forced-capture-session trial keeps
        // its pinned `targetDeviceUID`. When the override is cleared and we
        // return to `.automatic`, reuse must NOT keep that stale target, or
        // `.automatic` would capture the forced device instead of built-in.
        // Compare the target the same way the engine path compares its device.
        // Release never sets a target (the switch-arm that assigns it is
        // DEBUG-only), so this is a no-op there. (Cloud review P2.)
        if configMatch, let captureSource = existing as? AVCaptureSessionSource {
          let wantsTarget =
            decision.reason == .forcedCaptureSession ? effectiveInputDeviceUID() : ""
          let normalize: (String?) -> String = { ($0?.isEmpty ?? true) ? "" : $0! }
          configMatch = normalize(captureSource.targetDeviceUID) == normalize(wantsTarget)
        }
      // Candidate D (#1377 slice 2b): same stale-target trap as candidate A
      // above — a warm HAL source from a forced trial must not be reused
      // once the override clears (or changes device).
      #endif
      if configMatch, let halSource = existing as? HALDeviceInputSource {
        var wantsTarget = decision.effectiveDeviceUID
        #if DEBUG
          if decision.reason == .forcedHALDeviceInput {
            wantsTarget = effectiveInputDeviceUID()
          }
        #endif
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
    }

    let decision = routeResolver.resolve(
      preferredInputDeviceUID: preferredInputDeviceIDOverride,
      noiseSuppression: noiseSuppressionEnabled
    )
    adoptRouteDecision(decision, prior: priorRouteDecision)

    // Structured telemetry log
    Self.btRouteLog(
      "Route decision: source=\(decision.sourceType), reason=\(decision.reason.rawValue), vp=\(decision.vpAvailable), fallback=\(decision.fallbackAllowed) — \(decision.rationale)"
    )
    Task {
      await AppLogger.shared.log(
        "Capture route: \(decision.reason.rawValue) → \(Self.backendLabel(for: decision.sourceType)), VP=\(decision.vpAvailable)",
        level: .info, category: "Audio"
      )
    }

    let source: any AudioInputSource
    switch decision.sourceType {
    case .captureSession:
      if decision.vpAvailable == false && noiseSuppressionEnabled {
        Self.btRouteLog(
          "Noise suppression unavailable on AVCaptureSession path — VP requires AVAudioEngine to own input"
        )
      }
      let captureSource = AVCaptureSessionSource()
      #if DEBUG
        // Candidate A (#1377): under a force-case, pin the capture session to the
        // user-selected device (e.g. Bluetooth). `.automatic` never emits
        // `.forcedCaptureSession`, so the shipped path leaves the target nil
        // (built-in) — byte-identical to today.
        if decision.reason == .forcedCaptureSession {
          captureSource.targetDeviceUID = effectiveInputDeviceUID()
        }
      #endif
      source = captureSource
    case .audioEngine:
      let engineSource = AVAudioEngineSource()
      engineSource.noiseSuppressionEnabled = noiseSuppressionEnabled
      engineSource.selectedInputDeviceUID = selectedInputDeviceUID
      engineSource.preferredInputDeviceIDOverride = preferredInputDeviceIDOverride
      #if DEBUG
        // Candidate C (#1377): under a force-case, bypass the BT-output force-nil
        // so the engine targets the selected BT device. `.automatic` never emits
        // `.forcedEngine`, so the shipped crash-dodge is unchanged.
        if decision.reason == .forcedEngine {
          engineSource.benchBypassBTOutputForceNil = true
        }
      #endif
      source = engineSource
    case .halDeviceInput:
      let halSource = HALDeviceInputSource()
      halSource.targetDeviceUID = decision.effectiveDeviceUID
      #if DEBUG
        // Candidate D (#1377 slice 2b, reinstated 2026-07-08): under a
        // force-case, pin the AUHAL source to the user-selected device. Only
        // ever reachable via `.forceHALDeviceInput`.
        if decision.reason == .forcedHALDeviceInput {
          halSource.targetDeviceUID = effectiveInputDeviceUID()
        }
      #endif
      source = halSource
    }

    activeSource = source
    return source
  }

  /// Maps a concrete `any AudioInputSource` instance to its `CaptureSourceType`
  /// tag. The non-switch consumer `resolveSource()` uses for warm-reuse
  /// compatibility (#1377 §6 audit point) — a plain `is AVAudioEngineSource`
  /// boolean silently treats every non-engine source as equivalent once a
  /// third candidate exists, so this maps each concrete type explicitly.
  private static func sourceType(of source: any AudioInputSource) -> CaptureSourceType? {
    if source is AVAudioEngineSource { return .audioEngine }
    if source is AVCaptureSessionSource { return .captureSession }
    if source is HALDeviceInputSource { return .halDeviceInput }
    return nil
  }

  /// Human-readable backend label for logging. Single authority so a new
  /// candidate cannot be silently mislabeled by a stale two-way ternary
  /// (#1377 §6 audit point — non-switch consumers compile silently on a new
  /// enum case and must be audited, not trusted to the compiler).
  private static func backendLabel(for sourceType: CaptureSourceType) -> String {
    switch sourceType {
    case .captureSession: return "AVCaptureSession"
    case .audioEngine: return "AVAudioEngine"
    case .halDeviceInput: return "HALDeviceInput"
    }
  }

  #if DEBUG
    /// Effective input-device UID: the explicit override takes priority, else the
    /// selected device — the same order the warm-reuse device comparison and the
    /// engine source's own resolution use. Used to pin a bench candidate's target
    /// device (#1377). DEBUG-only: only the bake-off force-cases read it.
    private func effectiveInputDeviceUID() -> String {
      preferredInputDeviceIDOverride.isEmpty
        ? selectedInputDeviceUID : preferredInputDeviceIDOverride
    }
  #endif

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
}
