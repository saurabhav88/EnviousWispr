@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// XPC-backed implementation of `AudioCaptureInterface`.
///
/// Bridges the in-process `AudioCaptureInterface` contract to XPC calls against the
/// embedded `EnviousWisprAudioService`. Real audio capture runs in the service process;
/// the proxy handles connection lifecycle, buffer reconstruction, and state management.
///
/// **Connection lifecycle (Step 1.5 design rules):**
/// - `interruptionHandler`: if capturing → user-visible failure (reset state, fire onEngineInterrupted).
///   If idle → transient (set needsReinit only). Always keep the same connection.
/// - `invalidationHandler`: terminal — nil connection, recreate on next use.
@MainActor
@Observable
public final class AudioCaptureProxy: AudioCaptureInterface {

  // MARK: - Observable state

  public private(set) var isCapturing = false
  public private(set) var audioLevel: Float = 0.0

  /// Step 3: returns [] — samples accumulate in the service process.
  /// Step 5 will add getSamplesSnapshot XPC method for incremental access.
  public private(set) var capturedSamples: [Float] = []

  // MARK: - Callbacks

  public var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  public var onEngineInterrupted: (() -> Void)?
  public var onVADAutoStop: (() -> Void)?

  // MARK: - Round-4 telemetry callbacks (issue #285)

  public var onCaptureStalled: ((CaptureStallContext) -> Void)?
  public var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
  public var onXPCServiceError: ((XPCErrorContext) -> Void)?
  public var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?
  public var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?

  /// Monotonic capture-session counter — returns `activeCaptureGeneration` so
  /// the id stays stable across the `stopCapture` bump (which flips
  /// `captureGeneration` early to reject stale XPC callbacks). The pipeline's
  /// dedup flag relies on this stability; using `captureGeneration` would
  /// produce two distinct sessions for a single stall-then-empty incident.
  public var currentCaptureSessionID: UInt64 { activeCaptureGeneration }

  /// Authoritative capture-active predicate.
  public var isActivelyCapturing: Bool { isCapturing }

  /// Concrete capture backend tag for Sentry attribution. Always "xpc_proxy"
  /// — actual sample capture happens service-side and is not visible here.
  public let captureSourceType: String = "xpc_proxy"

  // MARK: - Configuration (stored locally, forwarded to service)

  public var noiseSuppressionEnabled = false
  public var selectedInputDeviceUID: String = ""
  public var preferredInputDeviceIDOverride: String = ""

  /// Cached warm engine policy -- forwarded to service, replayed after crash.
  public var warmEnginePolicy: WarmEnginePolicy = .seconds30 {
    didSet {
      guard oldValue != warmEnginePolicy else { return }
      serviceProxy { [self] proxy in
        proxy.setWarmEnginePolicy(warmEnginePolicy.rawValue)
      }
    }
  }

  // MARK: - XPC connection state

  private var connection: NSXPCConnection?
  private var needsReinit = false

  /// AsyncStream continuation for buffer delivery from service → pipeline.
  private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  /// Generation counter to reject stale callbacks from previous capture sessions.
  /// Incremented on beginCapturePhase, stopCapture, and interruption.
  /// Checked in audioBufferCaptured (inside @MainActor Task) before yielding.
  private var captureGeneration: UInt64 = 0

  /// The generation that was active when the current capture session began.
  /// Set in beginCapturePhase, compared in audioBufferCaptured.
  private var activeCaptureGeneration: UInt64 = 0

  /// #455: uptime-ns at the moment `beginCapturePhase` flipped `isCapturing`
  /// to true. Read in the XPC interrupt/invalidate handlers to surface
  /// `recording_duration_ms` in the captureError breadcrumb. Reset to 0 on
  /// every clean stop / interrupt / invalidate so a stale value cannot bleed
  /// into the next session.
  private var captureStartUptimeNs: UInt64 = 0

  // MARK: - Capture-liveness watchdog (issue #285)

  /// Private serial queue that fires the stall `DispatchWorkItem`.
  private static let stallQueue = DispatchQueue(
    label: "com.enviouswispr.audio.capture-stall.proxy"
  )
  /// Pending stall watchdog. Cancelled on stop / interrupt / invalidate /
  /// on every new session's arm. Fires on MainActor via Task hop.
  private var stallWorkItem: DispatchWorkItem?
  /// Flips true on the MainActor inside `audioBufferCaptured` when any buffer
  /// for the active session reaches us. Reset to false when arming.
  private var hasReceivedBufferThisSession: Bool = false

  /// 16kHz mono Float32 format used for buffer reconstruction.
  /// Matches AudioCaptureManager.targetSampleRate / targetChannels.
  nonisolated(unsafe) private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
  )!

  /// Derived at startEnginePhase time from the same BT detection logic as CaptureRouteResolver.
  public private(set) var currentAudioRoute: String = "unknown"

  #if DEBUG
    /// V2 fault-injection seam (issue #291). When > 0, the next N captured
    /// buffers are silently dropped before reaching the continuation or
    /// `onBufferCaptured`. Decrements per drop until 0, then normal delivery
    /// resumes. Drives Lane A scenario A5 ("forced audio buffer stall") via
    /// the DEBUG localhost endpoint; can also be set directly from Lane C
    /// tests via `@testable import EnviousWisprAudio`.
    ///
    /// `package` access: callable from `DebugFaultEndpoint` in the app target
    /// (same SPM package). Inert in release builds — this property does not
    /// exist outside DEBUG.
    ///
    /// See `Tests/RuntimeUAT/SCENARIOS.md` for negative-control documentation.
    package var forceStallRemainingBuffers: Int = 0
  #endif

  public init() {}

  // MARK: - Core lifecycle

  public func startEnginePhase() async throws {
    // Derive route label app-side (same BT check as CaptureRouteResolver).
    if let outID = AudioDeviceEnumerator.defaultOutputDeviceID(),
      AudioDeviceEnumerator.isBluetoothDevice(outID)
    {
      currentAudioRoute = "capture_session_bt"
    } else {
      currentAudioRoute = "built_in_mic"
    }

    ensureConnection()
    resendConfigIfNeeded()
    try await withAudioXPCOperationSignal(stage: "start_engine") { operationID in
      try await self.awaitStartEnginePhaseReply(operationID: operationID)
    }
  }

  private func awaitStartEnginePhaseReply(operationID: String) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      let guard_ = OneShotContinuation(cont)
      serviceProxy { proxy in
        proxy.startEnginePhase(
          operationID: operationID,
          preferredDeviceUID: self.preferredInputDeviceIDOverride,
          selectedDeviceUID: self.selectedInputDeviceUID
        ) { nsError in
          if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
        }
      } onProxyError: {
        guard_.resume(throwing: XPCTransportError.serviceUnreachable)
      }
    }
  }

  public func beginCapturePhase(recoveryPayload: Data?) async throws
    -> AsyncStream<AVAudioPCMBuffer>
  {
    ensureConnection()

    // Finish any stale continuation from a previous session.
    bufferContinuation?.finish()
    bufferContinuation = nil

    captureGeneration &+= 1
    activeCaptureGeneration = captureGeneration

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
      self.bufferContinuation = continuation
    }

    try await withAudioXPCOperationSignal(stage: "begin_capture") { operationID in
      try await self.awaitBeginCaptureReply(
        operationID: operationID, recoveryPayload: recoveryPayload)
    }

    isCapturing = true
    captureStartUptimeNs = DispatchTime.now().uptimeNanoseconds  // #455
    hasReceivedBufferThisSession = false
    armCaptureStallWatchdog()
    return stream
  }

  private func awaitBeginCaptureReply(operationID: String, recoveryPayload: Data?) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      let guard_ = OneShotContinuation(cont)
      serviceProxy { proxy in
        proxy.beginCapture(operationID: operationID, recoveryPayload: recoveryPayload) { nsError in
          if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
        }
      } onProxyError: {
        guard_.resume(throwing: XPCTransportError.serviceUnreachable)
      }
    }
  }

  /// Arm the one-shot stall watchdog for the current `activeCaptureGeneration`.
  private func armCaptureStallWatchdog() {
    stallWorkItem?.cancel()
    let armedSession = activeCaptureGeneration
    let armedAtNs = DispatchTime.now().uptimeNanoseconds
    let item = Self.makeStallWorkItem(
      armedSession: armedSession, armedAtNs: armedAtNs, proxy: self)
    stallWorkItem = item
    Self.stallQueue.asyncAfter(
      deadline: .now() + .milliseconds(TimingConstants.audioCaptureStallWindowMs),
      execute: item
    )
  }

  /// Build the watchdog closure in a nonisolated context so it does NOT inherit
  /// the enclosing `@MainActor` isolation. Swift 6 otherwise inserts executor
  /// checks that fire `dispatch_assert_queue_fail` when the work item runs on
  /// the stall queue. Same escape-hatch pattern as `makeInterruptionHandler`.
  nonisolated private static func makeStallWorkItem(
    armedSession: UInt64,
    armedAtNs: UInt64,
    proxy: AudioCaptureProxy
  ) -> DispatchWorkItem {
    return DispatchWorkItem { [weak proxy] in
      Task { @MainActor [weak proxy] in
        proxy?.captureStallWatchdogFired(
          armedSession: armedSession, armedAtNs: armedAtNs)
      }
    }
  }

  private func captureStallWatchdogFired(armedSession: UInt64, armedAtNs: UInt64) {
    guard activeCaptureGeneration == armedSession else { return }
    guard isCapturing else { return }
    guard !hasReceivedBufferThisSession else { return }

    let ctx = CaptureStallContext(
      sessionID: armedSession,
      armedAtUptimeNs: armedAtNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: currentAudioRoute,
      sourceType: "xpc_proxy",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: preferredInputDeviceIDOverride.isEmpty
        ? nil : preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID()
    )
    onCaptureStalled?(ctx)
  }

  // periphery:ignore - protocol conformance (AudioCaptureInterface)
  public func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard !isCapturing else { return AsyncStream { $0.finish() } }
    try await startEnginePhase()
    return try await beginCapturePhase()
  }

  public func stopCapture() async -> CaptureResult {
    // Cancel any pending stall watchdog before the session id rolls.
    stallWorkItem?.cancel()
    stallWorkItem = nil
    // Snapshot the session id BEFORE the generation bump so reply-path
    // failures report the session the caller was actually stopping.
    let endingSession = activeCaptureGeneration
    // Bump generation so stale callbacks from this session don't leak into the next.
    captureGeneration &+= 1

    var result = CaptureResult(samples: [])
    do {
      // Cleanup must outlive forward-path task cancellation. `finishTerminal`
      // cancels that task while stop may already be in flight; returning early
      // would mark capture resources released before the service actually stops.
      result = try await withAudioXPCOperationSignal(
        stage: "stop_capture",
        parentCancellationBehavior: .waitForResolution
      ) { operationID in
        try await self.awaitStopCaptureReply(
          operationID: operationID,
          endingSession: endingSession
        )
      }
    } catch {
      if error is XPCOperationSignalWedgeError {
        reportXPCReplyFailure(stage: "stop_capture_signal_watchdog", sessionID: endingSession)
      }
      // XPC error — service crashed during stopCapture. Samples are lost.
      // The interruptionHandler fires independently and handles pipeline notification.
      // Do NOT call onEngineInterrupted here to avoid double-firing.
      Task {
        await AppLogger.shared.log(
          "[AudioCaptureProxy] stopCapture failed — service unreachable, samples lost: \(error)",
          level: .info, category: "XPC"
        )
      }
    }

    isCapturing = false
    captureStartUptimeNs = 0  // #455
    audioLevel = 0
    bufferContinuation?.finish()
    bufferContinuation = nil
    return result
  }

  private func awaitStopCaptureReply(
    operationID: String,
    endingSession: UInt64
  ) async throws -> CaptureResult {
    try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<CaptureResult, any Error>) in
      let guard_ = OneShotContinuation(cont)
      serviceProxy { proxy in
        proxy.stopCapture(operationID: operationID) { sampleData, vadData in
          let samples = Self.dataToFloats(sampleData)
          let segments = Self.decodeVADSegments(vadData)
          guard_.resume(returning: CaptureResult(samples: samples, vadSegments: segments))
        }
      } onProxyError: { [weak self] in
        self?.reportXPCReplyFailure(stage: "stop_capture", sessionID: endingSession)
        guard_.resume(returning: CaptureResult(samples: []))
      }
    }
  }

  public func rebuildEngine() {
    serviceProxy { proxy in proxy.rebuildEngine() }
  }

  public func buildEngine(noiseSuppression: Bool) {
    noiseSuppressionEnabled = noiseSuppression
    ensureConnection()
    resendConfigIfNeeded()
    serviceProxy { proxy in proxy.buildEngine(noiseSuppression: noiseSuppression) }
  }

  public func preWarm() async throws {
    let proxyStart = ContinuousClock.now

    // Derive route label so Sentry telemetry is populated even when
    // startEnginePhase() is skipped on the next recording (warm engine reuse).
    if let outID = AudioDeviceEnumerator.defaultOutputDeviceID(),
      AudioDeviceEnumerator.isBluetoothDevice(outID)
    {
      currentAudioRoute = "capture_session_bt"
    } else {
      currentAudioRoute = "built_in_mic"
    }

    ensureConnection()
    resendConfigIfNeeded()
    let connMs = Self.ms(ContinuousClock.now - proxyStart)
    // Phase 1: start engine
    let enginePhaseStart = ContinuousClock.now
    do {
      try await withAudioXPCOperationSignal(stage: "start_engine_prewarm") { operationID in
        try await self.awaitStartEnginePhaseReply(operationID: operationID)
      }
    } catch {
      Task {
        await AppLogger.shared.log(
          "[AudioCaptureProxy] preWarm failed: \(error)",
          level: .info, category: "XPC"
        )
      }
      // Issue #289: propagate so the pipeline / the former root state can abort the
      // recording cleanly instead of flipping isPreWarmed=true against a
      // dead capture path.
      throw error
    }
    let enginePhaseMs = Self.ms(ContinuousClock.now - enginePhaseStart)
    // Phase 2: wait for format stabilization
    let stabStart = ContinuousClock.now
    _ = await waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    let stabMs = Self.ms(ContinuousClock.now - stabStart)
    let totalMs = Self.ms(ContinuousClock.now - proxyStart)
    Task {
      await AppLogger.shared.log(
        "COLD-START [XPC proxy] preWarm: total=\(totalMs)ms | conn=\(connMs)ms enginePhase=\(enginePhaseMs)ms formatStab=\(stabMs)ms",
        level: .info, category: "XPC"
      )
    }
  }

  /// Convert Duration to milliseconds for logging.
  private static func ms(_ d: Duration) -> Int {
    let (seconds, attoseconds) = d.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }

  public func abortPreWarm() {
    serviceProxy { proxy in proxy.abortPreWarm() }
  }

  public func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
    -> Bool
  {
    await withCheckedContinuation { cont in
      serviceProxy { proxy in
        proxy.waitForFormatStabilization(maxWait: maxWait, pollInterval: pollInterval) { result in
          cont.resume(returning: result)
        }
      } onProxyError: {
        cont.resume(returning: false)
      }
    }
  }

  private func withAudioXPCOperationSignal<T: Sendable>(
    stage: String,
    parentCancellationBehavior: WatcherParentCancellationBehavior = .returnCancellation,
    _ work: @MainActor @escaping (String) async throws -> T
  ) async throws -> T {
    let operationID = UUID().uuidString
    let signal = XPCOperationSignalWatcher(file: .audio, operationID: operationID)
    signal.start()
    nonisolated(unsafe) let unsafeWork = work
    let operationTask = Task { @MainActor in
      try await unsafeWork(operationID)
    }
    let outcome = await raceWithSignalWatcher(
      watcher: signal.progressWatcher,
      parentCancellationBehavior: parentCancellationBehavior
    ) {
      try await operationTask.value
    }
    let snapshot = signal.snapshot
    signal.stop()

    switch outcome {
    case .completed(let value):
      return value
    case .threw(let error):
      throw error
    case .wedged:
      operationTask.cancel()
      handleAudioXPCOperationWedge(stage: stage, operationID: operationID, snapshot: snapshot)
      throw XPCOperationSignalWedgeError(
        service: "Audio",
        stage: stage,
        observedPhase: snapshot.lastObservedPhase
      )
    }
  }

  private func handleAudioXPCOperationWedge(
    stage: String,
    operationID: String,
    snapshot: WatcherSnapshot
  ) {
    Task {
      await AppLogger.shared.log(
        "[AudioCaptureProxy] signal watchdog fired stage=\(stage) operationID=\(operationID) phase=\(snapshot.lastObservedPhase) silenceMs=\(snapshot.silenceMs)",
        level: .info, category: "XPC"
      )
    }
    connection?.invalidate()
    connection = nil
    needsReinit = true
  }

  // MARK: - Config re-send after crash

  /// Replays configuration to the service after a crash/relaunch.
  /// Clears needsReinit after the XPC call is dispatched. Note: buildEngine is fire-and-forget
  /// (no reply handler), so we cannot detect if the service actually processed the config.
  /// If the service crashes during replay, the next interruptionHandler will re-set needsReinit.
  /// This is acceptable because buildEngine is idempotent — replay on next attempt is safe.
  private func resendConfigIfNeeded() {
    guard needsReinit else { return }
    serviceProxy { [self] proxy in
      proxy.buildEngine(noiseSuppression: noiseSuppressionEnabled)
      // Replay VAD config so service rebuilds its SilenceDetector after crash.
      if let vad = vadConfig {
        proxy.configureVAD(
          autoStop: vad.autoStop, silenceTimeout: vad.silenceTimeout,
          sensitivity: vad.sensitivity, energyGate: vad.energyGate)
      }
      // Replay warm engine policy so service uses correct idle timeout.
      proxy.setWarmEnginePolicy(warmEnginePolicy.rawValue)
      needsReinit = false
    }
  }

  // MARK: - XPC connection management

  private func ensureConnection() {
    guard connection == nil else { return }

    let conn = NSXPCConnection(serviceName: XPCServiceName.audioService)
    conn.remoteObjectInterface = NSXPCInterface(with: AudioServiceProtocol.self)
    conn.exportedInterface = NSXPCInterface(with: AudioServiceClientProtocol.self)
    conn.exportedObject = self

    // DESIGN RULE: Interruption while isCapturing == true is a user-visible capture failure.
    // Interruption while idle is transient — just set needsReinit.
    //
    // IMPORTANT(Step 3+): Step 1.5 proved kill -9 fires interruptionHandler for embedded
    // XPC services. During active capture, this IS the crash signal. The connection stays
    // valid — the next XPC call auto-relaunches the service via launchd.
    // CRITICAL: interruptionHandler and invalidationHandler run on XPC dispatch queues,
    // NOT MainActor. Closures defined inside @MainActor methods inherit that isolation in
    // Swift 6, causing dispatch_assert_queue_fail when XPC calls them. Extract to
    // nonisolated static to break the isolation inheritance.
    conn.interruptionHandler = Self.makeInterruptionHandler(proxy: self)
    conn.invalidationHandler = Self.makeInvalidationHandler(proxy: self)

    conn.resume()
    connection = conn

    // Verify service is alive — this ping triggers launchd to spawn the service.
    serviceProxy { proxy in proxy.ping { _ in } }
  }

  /// Gets the remote proxy with error handling.
  /// `onProxyError` is called if the proxy can't be obtained (connection nil or cast fails)
  /// AND if the XPC framework delivers a per-call error (service crashed mid-call).
  /// This is critical: when the service dies after a call is dispatched but before it replies,
  /// the XPC error handler fires but the reply handler does NOT. Without routing the error
  /// to `onProxyError`, any pending continuation hangs forever.
  private func serviceProxy(
    _ work: (any AudioServiceProtocol) -> Void,
    onProxyError: (() -> Void)? = nil
  ) {
    guard let conn = connection else {
      onProxyError?()
      return
    }
    let proxy = conn.remoteObjectProxyWithErrorHandler(
      Self.makeXPCErrorHandler(onProxyError: onProxyError))
    guard let service = proxy as? AudioServiceProtocol else {
      onProxyError?()
      return
    }
    work(service)
  }

  /// Build the XPC error handler in a nonisolated context.
  /// Critical: closures defined inside @MainActor methods inherit that isolation.
  /// When XPC calls the error handler on its dispatch queue, Swift 6 asserts
  /// dispatch_assert_queue(main) and traps with EXC_BREAKPOINT. By constructing
  /// the handler in a nonisolated static method, the closure is free of @MainActor.
  /// Build the XPC per-call error handler in a nonisolated context.
  /// This handler fires when the service crashes after a call is dispatched but before it replies.
  /// It MUST call onProxyError to resume any pending continuation — otherwise the caller hangs forever.
  /// The error handler is the primary recovery signal; interruption/invalidation are secondary cleanup.
  nonisolated private static func makeXPCErrorHandler(onProxyError: (() -> Void)? = nil)
    -> @Sendable (any Error) -> Void
  {
    // Capture onProxyError as nonisolated(unsafe) — it may reference @MainActor closures
    // but we dispatch it via Task { @MainActor } so the actual call is safe.
    nonisolated(unsafe) let proxyError = onProxyError
    return { error in
      Task { @MainActor in
        await AppLogger.shared.log(
          "[AudioCaptureProxy] XPC error: \(error.localizedDescription)",
          level: .info, category: "XPC"
        )
        proxyError?()
      }
    }
  }

  /// Build the XPC interruptionHandler in a nonisolated context.
  /// Same isolation-escape pattern as makeXPCErrorHandler.
  nonisolated private static func makeInterruptionHandler(proxy: AudioCaptureProxy) -> @Sendable ()
    -> Void
  {
    return { [weak proxy] in

      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        let wasCapturing = proxy.isCapturing
        await AppLogger.shared.log(
          "[AudioCaptureProxy] XPC interruptionHandler fired — wasCapturing=\(wasCapturing)",
          level: .info, category: "XPC"
        )
        if wasCapturing {
          // Cancel pending stall watchdog before the session ends.
          proxy.stallWorkItem?.cancel()
          proxy.stallWorkItem = nil
          let endingSession = proxy.activeCaptureGeneration
          // #455: compute duration BEFORE flipping isCapturing / resetting
          // captureStartUptimeNs so the breadcrumb has a real number.
          let firedAt = DispatchTime.now().uptimeNanoseconds
          let durationNs: UInt64? =
            proxy.captureStartUptimeNs > 0 && firedAt >= proxy.captureStartUptimeNs
            ? (firedAt - proxy.captureStartUptimeNs) : nil
          proxy.isCapturing = false
          proxy.captureStartUptimeNs = 0  // #455
          proxy.audioLevel = 0
          proxy.captureGeneration &+= 1
          proxy.bufferContinuation?.finish()
          proxy.bufferContinuation = nil
          proxy.onEngineInterrupted?()
          // Fire telemetry callback — idle interruptions stay silent (§3.4 row 2).
          proxy.onXPCServiceError?(
            XPCErrorContext(
              kind: .interruptCapturing,
              sessionID: endingSession,
              recordingDurationNs: durationNs
            )
          )
        }
        proxy.needsReinit = true
      }
    }
  }

  /// Build the XPC invalidationHandler in a nonisolated context.
  nonisolated private static func makeInvalidationHandler(proxy: AudioCaptureProxy) -> @Sendable ()
    -> Void
  {
    return { [weak proxy] in

      Task { @MainActor [weak proxy] in
        guard let proxy else { return }

        proxy.connection = nil
        let wasCapturing = proxy.isCapturing
        let endingSession = proxy.activeCaptureGeneration
        // #455: compute duration BEFORE flipping isCapturing / resetting
        // captureStartUptimeNs so the breadcrumb has a real number. Idle
        // invalidations have no active session and so no duration to report.
        let firedAt = DispatchTime.now().uptimeNanoseconds
        let durationNs: UInt64? =
          wasCapturing && proxy.captureStartUptimeNs > 0
            && firedAt >= proxy.captureStartUptimeNs
          ? (firedAt - proxy.captureStartUptimeNs) : nil
        if wasCapturing {
          proxy.stallWorkItem?.cancel()
          proxy.stallWorkItem = nil
          proxy.isCapturing = false
          proxy.captureStartUptimeNs = 0  // #455
          proxy.audioLevel = 0
          proxy.captureGeneration &+= 1
          proxy.bufferContinuation?.finish()
          proxy.bufferContinuation = nil
          proxy.onEngineInterrupted?()
        }
        proxy.needsReinit = true
        // Invalidation is always a telemetry signal — connection is gone.
        proxy.onXPCServiceError?(
          XPCErrorContext(
            kind: wasCapturing ? .invalidateCapturing : .invalidateIdle,
            sessionID: wasCapturing ? endingSession : nil,
            recordingDurationNs: durationNs
          )
        )
      }
    }
  }

  // MARK: - V2 fault-injection (DEBUG only, issue #291)

  #if DEBUG
    /// Invalidates the active XPC connection synchronously. Fires the existing
    /// `invalidationHandler` path, which sets `connection = nil`, flips
    /// `isCapturing = false`, finishes the buffer continuation, and emits the
    /// `onXPCServiceError(.invalidateCapturing)` telemetry callback.
    ///
    /// Drives Lane A scenario A4 ("audio XPC service kill") via the DEBUG
    /// localhost endpoint. Equivalent in effect to a real audio service crash
    /// mid-stream — but deterministic and synchronous.
    ///
    /// `package` access: callable from `DebugFaultEndpoint` in the app target.
    /// Inert in release builds.
    package func forceConnectionTerminationNow() {
      connection?.invalidate()
    }
  #endif

  // MARK: - VAD Interface (Step 5)

  /// Stored VAD config — forwarded to service, replayed after crash via resendConfigIfNeeded().
  private var vadConfig:
    (autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)?

  public func configureVAD(
    autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool
  ) {
    vadConfig = (autoStop, silenceTimeout, sensitivity, energyGate)
    serviceProxy { proxy in
      proxy.configureVAD(
        autoStop: autoStop, silenceTimeout: silenceTimeout, sensitivity: sensitivity,
        energyGate: energyGate)
    }
  }

  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  public func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    // Use OneShotContinuation to guarantee exactly one resume — XPC error handler and
    // reply handler can race, and double-resume is undefined behavior.
    let sessionID = activeCaptureGeneration
    do {
      return try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<(samples: [Float], totalCount: Int), any Error>) in
        let guard_ = OneShotContinuation(cont)
        serviceProxy { proxy in
          proxy.getSamplesSnapshot(fromIndex: fromIndex) { data, totalCount in
            let floats = Self.dataToFloats(data)
            guard_.resume(returning: (samples: floats, totalCount: totalCount))
          }
        } onProxyError: { [weak self] in
          self?.reportXPCReplyFailure(stage: "get_samples", sessionID: sessionID)
          guard_.resume(returning: (samples: [], totalCount: 0))
        }
      }
    } catch {
      return (samples: [], totalCount: 0)
    }
  }

  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  public func getVADSegments() async -> [SpeechSegment] {
    // Use OneShotContinuation to guarantee exactly one resume.
    let sessionID = activeCaptureGeneration
    do {
      return try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<[SpeechSegment], any Error>) in
        let guard_ = OneShotContinuation(cont)
        serviceProxy { proxy in
          proxy.getVADSegments { data in
            guard_.resume(returning: Self.decodeVADSegments(data))
          }
        } onProxyError: { [weak self] in
          self?.reportXPCReplyFailure(stage: "get_speech_segments", sessionID: sessionID)
          guard_.resume(returning: [])
        }
      }
    } catch {
      return []
    }
  }

  /// Invoke `onXPCReplyFailed` before a reply-path swallowed empty default
  /// surfaces to callers, so the pipeline can emit the correct root cause
  /// instead of mis-classifying as `no_audio_captured`.
  private func reportXPCReplyFailure(stage: String, sessionID: UInt64) {
    onXPCReplyFailed?(
      XPCReplyFailureContext(
        replyStage: stage,
        errorDomain: "com.enviouswispr.xpc",
        errorCode: -1,
        errorDescription: "XPC reply failed — service unreachable",
        sessionID: sessionID
      )
    )
  }

  // MARK: - Data conversion

  /// Convert raw Data to [Float]. Transport format: Float32 PCM, non-interleaved mono, 16kHz.
  /// Data is raw bytes — no header, no metadata.
  /// nonisolated: called from XPC reply callbacks which run on XPC dispatch queues, not MainActor.
  nonisolated private static func dataToFloats(_ data: Data) -> [Float] {
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  /// Decode packed [Int32 start, Int32 end] pairs into SpeechSegment array.
  nonisolated private static func decodeVADSegments(_ data: Data) -> [SpeechSegment] {
    let pairSize = MemoryLayout<Int32>.size * 2
    guard !data.isEmpty, data.count.isMultiple(of: pairSize) else { return [] }
    return data.withUnsafeBytes { raw in
      let int32s = raw.bindMemory(to: Int32.self)
      var segments: [SpeechSegment] = []
      segments.reserveCapacity(int32s.count / 2)
      for i in stride(from: 0, to: int32s.count, by: 2) {
        segments.append(
          SpeechSegment(
            startSample: Int(int32s[i]),
            endSample: Int(int32s[i + 1])
          ))
      }
      return segments
    }
  }
}

// MARK: - AudioServiceClientProtocol (service → host callbacks)

/// These callbacks arrive on an XPC dispatch queue (not RT, not main).
/// Each hops to @MainActor via Task before updating observable state.
extension AudioCaptureProxy: AudioServiceClientProtocol {

  /// Received audio buffer from service — reconstruct AVAudioPCMBuffer and deliver.
  nonisolated public func audioBufferCaptured(_ data: Data, frameCount: Int, audioLevel: Float) {
    // Validation guards before memcpy.
    guard frameCount > 0, frameCount <= 65536 else { return }
    guard data.count == frameCount * MemoryLayout<Float>.size else { return }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: Self.targetFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else { return }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    data.withUnsafeBytes { raw in
      guard let src = raw.baseAddress, let dst = buffer.floatChannelData?[0] else { return }
      memcpy(dst, src, data.count)
    }

    nonisolated(unsafe) let safeBuffer = buffer
    // Snapshot frameCount for generation check inside the MainActor Task.
    // captureGeneration is read inside the Task (MainActor-isolated), not here.

    Task { @MainActor [weak self] in
      guard let self else { return }
      // Reject stale callbacks from previous capture sessions.
      guard self.isCapturing,
        self.captureGeneration == self.activeCaptureGeneration
      else { return }
      #if DEBUG
        // V2 fault-injection (issue #291): drop buffer if forced-stall is active.
        // Intentionally does NOT flip `hasReceivedBufferThisSession` so the
        // existing stall watchdog still fires after `audioCaptureStallWindowMs`.
        if self.forceStallRemainingBuffers > 0 {
          self.forceStallRemainingBuffers -= 1
          return
        }
      #endif
      self.hasReceivedBufferThisSession = true
      self.audioLevel = audioLevel
      self.bufferContinuation?.yield(safeBuffer)
      self.onBufferCaptured?(safeBuffer)
    }
  }

  /// Service's audio engine was interrupted (device disconnect, emergency teardown).
  /// Matches interruptionHandler contract: only fires onEngineInterrupted during active capture.
  /// Idle interruptions are transient — just set needsReinit.
  nonisolated public func engineInterrupted() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.isCapturing {
        self.stallWorkItem?.cancel()
        self.stallWorkItem = nil
        self.isCapturing = false
        self.captureStartUptimeNs = 0  // #455
        self.audioLevel = 0
        self.captureGeneration &+= 1
        self.bufferContinuation?.finish()
        self.bufferContinuation = nil
        self.onEngineInterrupted?()
      }
      self.needsReinit = true
    }
  }

  /// Service-side VAD detected sustained silence after speech — auto-stop should trigger.
  /// Stale-fire protection: generation check + pipeline state guard (in the former root state handler).
  nonisolated public func vadAutoStopTriggered() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.isCapturing,
        self.captureGeneration == self.activeCaptureGeneration
      else { return }
      self.onVADAutoStop?()
    }
  }
}

// MARK: - Helpers

/// Thread-safe one-shot continuation guard. Ensures exactly one resume,
/// preventing crashes from double-resume when XPC reply and error handler race.
private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
  private var continuation: CheckedContinuation<T, any Error>?
  private let lock = NSLock()

  init(_ continuation: CheckedContinuation<T, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: T) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(throwing: error)
  }
}

/// Convenience overload for Void continuations.
extension OneShotContinuation where T == Void {
  func resume() {
    resume(returning: ())
  }
}

/// XPC transport errors surfaced by the proxy.
enum XPCTransportError: LocalizedError {
  case serviceUnreachable

  var errorDescription: String? {
    switch self {
    case .serviceUnreachable: return "XPC audio service is unreachable."
    }
  }
}
