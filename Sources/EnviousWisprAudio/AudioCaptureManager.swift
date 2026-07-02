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
  /// Current recording state.
  public private(set) var isCapturing = false

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
    guard let decision = lastRouteDecision else { return "unknown" }
    switch decision.reason {
    case .noBTAutoInput, .noBTUserSelectedDevice:
      return "built_in_mic"
    case .btOutputAutoInput, .btOutputUserSelectedBuiltIn,
      .btOutputUserSelectedBTMic, .btOutputUserSelectedWired:
      return "capture_session_bt"
    case .forcedEngine, .fallbackToEngine:
      return "audio_engine"
    case .forcedCaptureSession:
      return "capture_session"
    case .failedNoFallback:
      return "failed"
    }
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
    let maxSamples = Self.maxRecordingSamples
    source.onSamples = { [weak self] samples, level in
      Task { @MainActor in
        guard let self, self.isCapturing,
          self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
        else { return }
        self.audioLevel = level
        self.capturedSamples.append(contentsOf: samples)
        if self.capturedSamples.count >= maxSamples {
          await AppLogger.shared.log(
            "Max recording duration reached (\(Self.maxRecordingDurationSeconds)s) — auto-stopping",
            level: .info, category: "Audio"
          )
          self.isCapturing = false
          self.audioLevel = 0.0
          // Direct-mode 60-min cap — a normal auto-stop, never captured as a loss.
          self.onEngineInterrupted?(.maxDurationReached)
        }
      }
    }
    source.onBufferCaptured = onBufferCaptured
    // Direct mode: an AVCaptureSession interruption is already captured by
    // `onCaptureSessionInterruption` (→ `.audioCaptureFailed`), so tag it
    // `.captureSessionLost` (suppress). An AVAudioEngine device disconnect has
    // no other owner → `.engineLost` (capture). Resolve the discriminator to a
    // value at bind time so the closure captures only the `Bool` (no strong
    // `source` capture / retain cycle — matches the `sourceID`-only pattern).
    let interruptionCause: EngineInterruptionCause =
      source is AVCaptureSessionSource ? .captureSessionLost : .engineLost
    source.onInterrupted = { [weak self] in
      guard let self,
        self.activeSource.map({ ObjectIdentifier($0) }) == sourceID
      else { return }
      self.isCapturing = false
      self.audioLevel = 0.0
      self.onEngineInterrupted?(interruptionCause)
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
    return CaptureResult(samples: samples)
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

    // If a source is already running (warm engine), check route compatibility
    if let existing = activeSource, existing.isRunning {
      let decision = routeResolver.resolve(
        preferredInputDeviceUID: preferredInputDeviceIDOverride,
        noiseSuppression: noiseSuppressionEnabled
      )
      let existingIsEngine = existing is AVAudioEngineSource
      let wantsEngine = decision.sourceType == .audioEngine

      // Check full config signature, not just source type.
      // Device/VP changes between recordings must trigger rebuild.
      var configMatch = existingIsEngine == wantsEngine
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

      if configMatch {
        // Route and config unchanged, reuse warm source
        lastRouteDecision = decision
        Self.btRouteLog("Reusing warm \(wantsEngine ? "engine" : "capture session") source")
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
    lastRouteDecision = decision

    // Structured telemetry log
    Self.btRouteLog(
      "Route decision: source=\(decision.sourceType), reason=\(decision.reason.rawValue), vp=\(decision.vpAvailable), fallback=\(decision.fallbackAllowed) — \(decision.rationale)"
    )
    Task {
      await AppLogger.shared.log(
        "Capture route: \(decision.reason.rawValue) → \(decision.sourceType == .captureSession ? "AVCaptureSession" : "AVAudioEngine"), VP=\(decision.vpAvailable)",
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
      source = AVCaptureSessionSource()
    case .audioEngine:
      let engineSource = AVAudioEngineSource()
      engineSource.noiseSuppressionEnabled = noiseSuppressionEnabled
      engineSource.selectedInputDeviceUID = selectedInputDeviceUID
      engineSource.preferredInputDeviceIDOverride = preferredInputDeviceIDOverride
      source = engineSource
    }

    activeSource = source
    return source
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
}
