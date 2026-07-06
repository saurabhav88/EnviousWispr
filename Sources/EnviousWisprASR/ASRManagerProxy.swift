@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// XPC-backed implementation of `ASRManagerInterface`.
///
/// Bridges the in-process ASR interface to XPC calls against `EnviousWisprASRService`.
/// Model loading, inference, and memory all live in the service process.
/// Crash recovery mirrors `AudioCaptureProxy` — same `OneShotContinuation`,
/// `nonisolated static` handler factories, per-call error routing.
@MainActor
@Observable
public final class ASRManagerProxy: ASRManagerInterface {

  // MARK: - Observable state

  public private(set) var activeBackendType: ASRBackendType = .parakeet
  public private(set) var isModelLoaded = false
  public private(set) var isStreaming = false

  // Download progress — updated via XPC callback from ASR service.
  public private(set) var downloadProgress: Double = 0
  public private(set) var downloadPhase: String = ""
  public private(set) var downloadDetail: String = ""

  // MARK: - XPC connection

  private var connection: NSXPCConnection?
  private var needsReinit = false

  // MARK: - Crash notification

  /// Fires when the ASR XPC service crashes during an active session (streaming or batch in-flight).
  public var onServiceInterrupted: (() -> Void)?

  /// Issue #445: per-tick callback wired by the dictation kernel to feed
  /// its `LoadProgressWatcher` from the existing 8Hz polling timer.
  public var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  // MARK: - Idle timer (stays in proxy — same as ASRManager)

  private var idleTimer: Timer?
  private var progressPollTimer: Timer?
  /// Single-flight guard: if a load is already in progress, callers await it instead of starting a new one.
  private var inFlightLoadTask: Task<Void, any Error>?

  /// #959 readiness-integrity token. Monotonic; `loadModel()` captures it at the
  /// start of its load and refuses to write `isModelLoaded = true` if it changed
  /// before the load completes (throws `ASRLoadSupersededError`). Bumped by
  /// `invalidateCurrentLoadGeneration(cause:)` from `cancelInFlightLoad()` /
  /// `unloadModel()` / a real `switchBackend(to:)`, so a cancelled, unloaded, or
  /// switched-away load can never resurrect a false `.ready` on a dead/wrong engine.
  private var loadGeneration: UInt64 = 0

  /// #959 single-flight identity. Each `loadModel()` that creates a task tags it
  /// with a fresh `loadTaskSeq` and records it as `activeLoadTaskID`. The task's
  /// cleanup `defer` nils `inFlightLoadTask` ONLY if it is still the active task,
  /// so a superseded load A (whose handle `cancelInFlightLoad()` already nilled,
  /// letting retry B install its own task) cannot clear B's handle on A's exit
  /// (Codex code-diff P1).
  private var loadTaskSeq: UInt64 = 0
  private var activeLoadTaskID: UInt64 = 0

  /// #899 test seam — the connection-preflight step `loadModel()` runs before it
  /// reaches `serviceProxy`. Production default establishes the real XPC
  /// connection exactly as `ensureConnection()` does today, so behavior is
  /// identical by default. A test supplies a no-op preflight, leaving
  /// `connection` nil, so production's real `serviceProxy` nil-connection branch
  /// fires `onProxyError` → `serviceUnreachable`, exercising the real
  /// `defer { self.stopProgressPolling() }` (#586 leak guard). Closure takes the
  /// proxy as a parameter (not a captured `self`) so the default is a plain
  /// expression with no self-capture; bound inside `init` so it can name the
  /// private `ensureConnection()`.
  private let connectionPreflight: @MainActor (ASRManagerProxy) -> Void

  public init(connectionPreflight: (@MainActor (ASRManagerProxy) -> Void)? = nil) {
    self.connectionPreflight = connectionPreflight ?? { $0.ensureConnection() }
  }

  /// #1348 Phase 2: when true, Parakeet loads are delivery-managed — the XPC
  /// call carries `cacheOnly: true` so the service loads the host-admitted
  /// cache with FluidAudio's offline switch armed (it can never download).
  /// Set by `ParakeetEngineAdapter` from the delivery flag before each
  /// warm-up; false = legacy in-service download path, bit-for-bit.
  public var parakeetCacheOnly = false

  /// #1348 Phase 2 (grounded r2 blocker 1 — forced helper recycle): after a
  /// proxy-level error on the load path (nil connection, interface/selector
  /// mismatch, remote-proxy failure), drop the connection so the NEXT call
  /// respawns the helper from the CURRENT bundle binary via
  /// `ensureConnection()`. Builds on the shipped invalidate→terminate→respawn
  /// machinery (`cancelInFlightLoad` doc); `internal` for the recycle test.
  func recycleConnectionAfterProxyError() {
    connection?.invalidate()
    connection = nil
    needsReinit = true
  }

  /// Test accessors for the recycle path (#1348; r3-precise scope: the
  /// reachable `onProxyError` behavior, not the OS callback).
  var needsReinitForTesting: Bool { needsReinit }
  var hasConnectionForTesting: Bool { connection != nil }

  /// Invalidate whatever load is current: bump the generation so an in-flight
  /// `loadModel()` completion (even one whose `isModelLoaded` is still `false`)
  /// is superseded, and log the `ready → notReady` transition tagged with cause.
  /// Called BEFORE any supersession early-return so an in-flight load is caught.
  /// Ordinary `cancel()` (session discard) does NOT call this — its appearance
  /// after a plain terminal is the recurrence signal for #959.
  private func invalidateCurrentLoadGeneration(cause: String) {
    loadGeneration &+= 1
    if isModelLoaded {
      Task {
        await AppLogger.shared.log(
          "[ASRManagerProxy] readiness ready→notReady (cause=\(cause)) backend=\(activeBackendType.rawValue)",
          level: .info, category: "ASR"
        )
      }
    }
  }

  // MARK: - ASRManagerInterface: Model lifecycle

  /// Load the active backend's model. Single-flight: concurrent callers await the same task.
  public func loadModel() async throws {
    // If a load is already in progress, await it instead of starting a new one.
    if let existing = inFlightLoadTask {
      try await existing.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      // #959: capture the load generation at the start of this load. If a
      // cancel/unload/switch bumps it before the load completes, the completion
      // below throws `ASRLoadSupersededError` instead of marking the model loaded.
      let gen = self.loadGeneration
      // Reset progress state before starting.
      self.downloadProgress = 0
      self.downloadPhase = ModelLoadStallPolicy.listingPhase
      self.downloadDetail = ""

      self.connectionPreflight(self)
      self.resendConfigIfNeeded()

      // Codex finding (2026-05-07): clear any stale progress file from a
      // previous load before the host starts polling. The XPC service also
      // clears on its side (`ASRServiceHandler.loadModel`), but a brief
      // window exists between host startProgressPolling() and the service
      // clear during which a leftover mtime could mis-arm the watcher.
      ProgressFile.shared.clear()

      // Start polling the XPC service for progress at 8 Hz.
      self.startProgressPolling()
      // Codex finding (2026-05-07): defer stop so the polling timer never
      // leaks on a thrown continuation. Previously stopProgressPolling() ran
      // only on the success path; an XPC error left the timer alive forever.
      defer { self.stopProgressPolling() }

      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        let guard_ = OneShotContinuationASR(cont)
        self.serviceProxy { proxy in
          let cacheOnly = self.parakeetCacheOnly && self.activeBackendType == .parakeet
          proxy.loadModel(backendType: self.activeBackendType.rawValue, cacheOnly: cacheOnly) {
            nsError in
            if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
          }
        } onProxyError: {
          // #1348: force a helper recycle so the next attempt reconnects to
          // the current bundle binary (grounded r2 blocker 1).
          self.recycleConnectionAfterProxyError()
          guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
        }
      }
      // #959: a cancel/unload/switch that landed during the load bumped the
      // generation — do NOT mark the (now superseded) model loaded; throw so
      // `warmUp()` / `ensureEngineWarm()` report failure instead of false success.
      guard gen == self.loadGeneration else { throw ASRLoadSupersededError() }
      // Success path — clear progress and mark loaded. (stopProgressPolling
      // runs from the defer above on every exit.)
      self.downloadProgress = 1.0
      self.downloadPhase = ""
      self.downloadDetail = ""
      self.isModelLoaded = true
    }
    loadTaskSeq &+= 1
    let myTaskID = loadTaskSeq
    inFlightLoadTask = task
    activeLoadTaskID = myTaskID
    // #959: identity-guarded cleanup — only retire the handle if it is still
    // ours. A supersession (`cancelInFlightLoad`/`switchBackend`) nils the handle
    // and a retry may install its own; this defer must not clobber that retry.
    defer { if activeLoadTaskID == myTaskID { inFlightLoadTask = nil } }
    try await task.value
  }

  // #879: `loadModelSilently` + the `launchPreloadReporter` launch-telemetry
  // callback were removed here too. The launch/onboarding warm-up entry is now
  // the shared `KernelDictationDriver.ensureEngineWarm(reason:)`, which drives
  // `loadModel()` via the adapter and owns `launch.model_preload_completed` for
  // the `.launch` reason. The `inFlightLoadTask` single-flight is unchanged, so
  // a press during a launch warm-up still joins the in-flight load.

  /// Whether the progress-polling timer is currently scheduled. Internal only
  /// for the #586 regression test that exercises the polling lifecycle without
  /// going through the (XPC-coupled) `loadModel` happy path. Tests reach it
  /// via `@testable import EnviousWisprASR`.
  // periphery:ignore - test seam
  internal var isProgressPollingActiveForTesting: Bool { progressPollTimer != nil }

  /// Read-only handle to the live polling timer, for the #586 leak-regression
  /// test that must hold a reference to the PRIOR timer across a re-arm and
  /// assert it was invalidated (a leak is invisible through the `!= nil` flag
  /// above, which only ever sees the newest timer). Read-only window onto the
  /// existing private state — adds no behavior and no new stored property.
  // periphery:ignore - test seam
  internal var progressPollTimerForTesting: Timer? { progressPollTimer }

  /// #1339: the proxy's load progress IS the shared progress file (the XPC
  /// service writes it; the 8Hz poll above reads it) — the sessionless wedge
  /// guard may arm over this manager's loads.
  public var feedsSharedProgressFile: Bool { true }

  internal func startProgressPolling() {
    stopProgressPolling()
    // Read progress from shared file — bypasses XPC entirely.
    // XPC serializes replies, so polling via XPC is blocked behind loadModel's pending reply.
    let progressFile = ProgressFile.shared
    let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
      // Timer schedules on `RunLoop.main`, so the closure body runs on the
      // main thread. `assumeIsolated` bridges that runtime guarantee to the
      // compile-time `@MainActor` isolation of the proxy's mutable state.
      MainActor.assumeIsolated {
        guard let self, !self.isModelLoaded else { return }
        let observedMtime = progressFile.modificationTime()
        var observedPhase = ""
        if let state = progressFile.read() {
          self.downloadProgress = state.fraction
          self.downloadPhase = state.phase
          self.downloadDetail = state.detail
          observedPhase = state.phase
        }
        // Issue #445: feed the pipeline-owned load-progress watcher even on
        // ticks where the file hasn't moved, so it can re-evaluate silence.
        self.loadProgressTickReporter?(observedMtime, observedPhase)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    progressPollTimer = timer
  }

  internal func stopProgressPolling() {
    progressPollTimer?.invalidate()
    progressPollTimer = nil
  }

  public func unloadModel() async {
    // #959: bump BEFORE the loaded-guard so an in-flight load (whose
    // `isModelLoaded` is still false) is superseded too, not just a resident model.
    invalidateCurrentLoadGeneration(cause: "unload")
    // #959 (Codex re-review P2): retire the superseded in-flight load task the
    // same way `switchBackend()` / `cancelInFlightLoad()` do — otherwise a retry
    // that joins via single-flight before the doomed task finishes propagates
    // `ASRLoadSupersededError` instead of starting a fresh load. Must run BEFORE
    // the loaded-guard, because the in-flight case is exactly when `isModelLoaded`
    // is still false and the guard would early-return with the stale handle live.
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    guard isModelLoaded else { return }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      serviceProxy { proxy in
        proxy.unloadModel {
          cont.resume()
        }
      } onProxyError: {
        cont.resume()
      }
    }
    isModelLoaded = false
  }

  /// Set the backend type synchronously at app startup. No unload (nothing loaded yet).
  /// Must be called before any loadModel() or warmup task.
  public func setInitialBackendType(_ type: ASRBackendType) {
    activeBackendType = type
    isModelLoaded = false
    isStreaming = false
  }

  public func switchBackend(to type: ASRBackendType) async {
    // #959: keep the same-backend no-op guard FIRST so a no-op switch (settings
    // re-applying the current backend) never supersedes a valid in-flight load.
    guard type != activeBackendType else { return }
    // A real switch supersedes any in-flight load for the old backend.
    invalidateCurrentLoadGeneration(cause: "switch")
    // #959 (Codex code-diff P2): retire the old backend's in-flight load task so
    // a subsequent `loadModel()` for the NEW backend starts fresh instead of
    // joining the stale task and receiving `ASRLoadSupersededError`.
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    if isModelLoaded { await unloadModel() }
    activeBackendType = type
    isStreaming = false
  }

  // MARK: - ASRManagerInterface: Capability

  public var activeBackendSupportsStreaming: Bool {
    get async {
      await withCheckedContinuation { cont in
        serviceProxy { proxy in
          proxy.checkStreamingSupport(backendType: self.activeBackendType.rawValue) { result in
            cont.resume(returning: result)
          }
        } onProxyError: {
          cont.resume(returning: false)
        }
      }
    }
  }

  // MARK: - ASRManagerInterface: Batch transcription

  public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    let data = audioSamples.withUnsafeBytes { Data($0) }
    let language = options.language ?? ""
    let speechSegmentsData =
      options.speechSegments.isEmpty ? nil : try JSONEncoder().encode(options.speechSegments)

    let (resultData, error): (Data?, NSError?) = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<(Data?, NSError?), any Error>) in
      let guard_ = OneShotContinuationASR(cont)
      serviceProxy { proxy in
        proxy.transcribeSamples(
          data, sampleCount: audioSamples.count,
          language: language, enableTimestamps: options.enableTimestamps,
          speechSegmentsData: speechSegmentsData
        ) { resultData, nsError in
          guard_.resume(returning: (resultData, nsError))
        }
      } onProxyError: {
        guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
      }
    }

    if let error {
      throw error
    }
    guard let resultData,
      let result = try? PropertyListDecoder().decode(ASRResult.self, from: resultData)
    else {
      throw ASRError.transcriptionFailed("Failed to decode ASR result from XPC service")
    }
    return result
  }

  // MARK: - ASRManagerInterface: Streaming

  public func startStreaming(options: TranscriptionOptions) async throws {
    let language = options.language ?? ""
    try await withASRXPCOperationSignal(stage: "start_streaming") { operationID in
      try await self.awaitStartStreamingReply(
        operationID: operationID,
        language: language,
        enableTimestamps: options.enableTimestamps
      )
    }
    isStreaming = true
  }

  private func awaitStartStreamingReply(
    operationID: String,
    language: String,
    enableTimestamps: Bool
  ) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      let guard_ = OneShotContinuationASR(cont)
      serviceProxy { proxy in
        proxy.startStreaming(
          operationID: operationID,
          language: language,
          enableTimestamps: enableTimestamps
        ) { nsError in
          if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
        }
      } onProxyError: {
        guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
      }
    }
  }

  public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    guard isStreaming else { return }
    guard let floatData = buffer.floatChannelData?[0] else { return }
    let count = Int(buffer.frameLength)
    let data = Data(bytes: floatData, count: count * MemoryLayout<Float>.size)
    serviceProxy { proxy in
      proxy.feedAudioBuffer(data, frameCount: count)
    }
  }

  public func finalizeStreaming() async throws -> ASRResult {
    guard isStreaming else { throw ASRError.streamingNotSupported }

    let (resultData, error): (Data?, NSError?) = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<(Data?, NSError?), any Error>) in
      let guard_ = OneShotContinuationASR(cont)
      serviceProxy { proxy in
        proxy.finalizeStreaming { resultData, nsError in
          guard_.resume(returning: (resultData, nsError))
        }
      } onProxyError: {
        guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
      }
    }

    isStreaming = false

    if let error {
      throw error
    }
    guard let resultData,
      let result = try? PropertyListDecoder().decode(ASRResult.self, from: resultData)
    else {
      throw ASRError.transcriptionFailed("Failed to decode ASR result from XPC service")
    }
    return result
  }

  public func cancelStreaming() async {
    guard isStreaming else { return }
    serviceProxy { proxy in proxy.cancelStreaming() }
    isStreaming = false
  }

  // MARK: - ASRManagerInterface: Pipeline lifecycle

  public func noteTranscriptionComplete(policy: ModelUnloadPolicy) {
    if policy == .immediately {
      Task { await unloadModel() }
      return
    }
    scheduleIdleTimer(policy: policy)
  }

  public func cancelIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = nil
  }

  private func scheduleIdleTimer(policy: ModelUnloadPolicy) {
    guard let interval = policy.interval else { return }
    cancelIdleTimer()
    idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        _ = Task<Void, Never> { await self?.unloadModel() }
      }
    }
  }

  // MARK: - Issue #445 model-load wedge recovery

  /// Cancel a wedged in-flight model load and force a service-level reset.
  ///
  /// Called by the dictation kernel's watchdog when `loadModel()` exceeds
  /// the recovery deadline. Three actions:
  ///
  /// 1. Cancel `inFlightLoadTask`. Host-side cooperative cancellation. Helps
  ///    in the rare case the underlying load path observes `Task.isCancelled`
  ///    (FluidAudio's load path does not, but the cancel still drains the
  ///    host-side await).
  /// 2. Invalidate the XPC connection. Fires the existing `invalidationHandler`,
  ///    which terminates the service process. CoreML's synchronous `MLModel.load`
  ///    is killed when its hosting process dies. Next call auto-respawns the
  ///    service via `ensureConnection()`.
  /// 3. Reset host-side load state so the next press triggers a fresh load
  ///    against the freshly-respawned service.
  ///
  /// This is the programmatic equivalent of the user manually quitting and
  /// relaunching the app — same recovery mechanism, no user effort required.
  public func cancelInFlightLoad() {
    // #959: supersede the current load FIRST so its completion can't resurrect
    // readiness after this teardown (always destructive — no no-op guard here).
    invalidateCurrentLoadGeneration(cause: "recoverFromWedge")
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    connection?.invalidate()
    // Codex pass 3: clear `connection` synchronously. `invalidate()`
    // schedules its handler asynchronously; if the user retries before the
    // handler runs, `ensureConnection()` would return early on a non-nil
    // pointer to the dead connection. Nil it now so the next call respawns.
    connection = nil
    isModelLoaded = false
    needsReinit = true
    // Codex pass 2: the 4 Hz progress poller was started by `loadModel()` but
    // its end-of-load cleanup never runs when the load is wedged. Stop it and
    // clear the visible progress fields so the next press starts fresh.
    stopProgressPolling()
    downloadProgress = 0
    downloadPhase = ""
    downloadDetail = ""
  }

  // MARK: - V2 fault-injection (DEBUG only, issue #291)

  #if DEBUG
    /// Invalidates the active XPC connection synchronously. Fires the existing
    /// `invalidationHandler` path, which clears `isModelLoaded`/`isStreaming`,
    /// nils the connection, and emits `onServiceInterrupted` if the service
    /// was active.
    ///
    /// Drives Lane A scenario A3 ("ASR XPC service mid-stream kill") via the
    /// DEBUG localhost endpoint. Equivalent in effect to a real ASR service
    /// crash during streaming or batch transcription — deterministic, synchronous.
    ///
    /// `package` access: callable from `DebugFaultEndpoint` in the app target.
    /// Inert in release builds.
    package func forceConnectionTerminationNow() {
      connection?.invalidate()
    }
  #endif

  // MARK: - XPC Connection

  private func ensureConnection() {
    guard connection == nil else { return }

    let conn = NSXPCConnection(serviceName: XPCServiceName.asrService)
    conn.remoteObjectInterface = NSXPCInterface(with: ASRServiceProtocol.self)
    conn.exportedInterface = NSXPCInterface(with: ASRServiceClientProtocol.self)

    conn.interruptionHandler = Self.makeInterruptionHandler(proxy: self)
    conn.invalidationHandler = Self.makeInvalidationHandler(proxy: self)

    conn.resume()
    connection = conn

    // Verify service is alive
    serviceProxy { proxy in proxy.ping { _ in } }
  }

  private func resendConfigIfNeeded() {
    guard needsReinit else { return }
    // Model state is replayed on next loadModel() call.
    needsReinit = false
  }

  private func serviceProxy(
    _ work: (any ASRServiceProtocol) -> Void,
    onProxyError: (() -> Void)? = nil
  ) {
    guard let conn = connection else {
      onProxyError?()
      return
    }
    let proxy = conn.remoteObjectProxyWithErrorHandler(
      Self.makeXPCErrorHandler(onProxyError: onProxyError))
    guard let service = proxy as? ASRServiceProtocol else {
      onProxyError?()
      return
    }
    work(service)
  }

  private func withASRXPCOperationSignal<T: Sendable>(
    stage: String,
    _ work: @MainActor @escaping (String) async throws -> T
  ) async throws -> T {
    let operationID = UUID().uuidString
    let signal = XPCOperationSignalWatcher(file: .asr, operationID: operationID)
    signal.start()
    nonisolated(unsafe) let unsafeWork = work
    let operationTask = Task { @MainActor in
      try await unsafeWork(operationID)
    }
    let outcome = await raceWithSignalWatcher(watcher: signal.progressWatcher) {
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
      handleASRXPCOperationWedge(stage: stage, operationID: operationID, snapshot: snapshot)
      throw XPCOperationSignalWedgeError(
        service: "ASR",
        stage: stage,
        observedPhase: snapshot.lastObservedPhase
      )
    }
  }

  private func handleASRXPCOperationWedge(
    stage: String,
    operationID: String,
    snapshot: WatcherSnapshot
  ) {
    Task {
      await AppLogger.shared.log(
        "[ASRManagerProxy] signal watchdog fired stage=\(stage) operationID=\(operationID) phase=\(snapshot.lastObservedPhase) silenceMs=\(snapshot.silenceMs)",
        level: .info, category: "XPC"
      )
    }
    // #959: align with the connection-loss handlers — supersede the load + log
    // cause BEFORE clearing loaded state, and clear `isModelLoaded` explicitly
    // (the async invalidationHandler also clears it, but make this path
    // self-consistent so readiness is unambiguous after a wedge).
    if isModelLoaded || isStreaming || inFlightLoadTask != nil {
      invalidateCurrentLoadGeneration(cause: "xpc_wedge")
    }
    connection?.invalidate()
    connection = nil
    isStreaming = false
    isModelLoaded = false
    needsReinit = true
  }

  // MARK: - Nonisolated Handler Factories (Swift 6 isolation safety)

  nonisolated private static func makeXPCErrorHandler(onProxyError: (() -> Void)? = nil)
    -> @Sendable (any Error) -> Void
  {
    nonisolated(unsafe) let proxyError = onProxyError
    return { error in
      Task { @MainActor in
        await AppLogger.shared.log(
          "[ASRManagerProxy] XPC error: \(error.localizedDescription)",
          level: .info, category: "XPC"
        )
        proxyError?()
      }
    }
  }

  nonisolated private static func makeInterruptionHandler(proxy: ASRManagerProxy) -> @Sendable () ->
    Void
  {
    return { [weak proxy] in
      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        let wasStreaming = proxy.isStreaming
        let wasLoaded = proxy.isModelLoaded
        let wasInFlight = proxy.inFlightLoadTask != nil
        // #959: supersede the current/in-flight load (and log the ready→notReady
        // cause) BEFORE clearing `isModelLoaded`, so the cause log fires and a
        // load completing after this teardown cannot resurrect a false `.ready`.
        // Widened to `wasInFlight` so a connection lost mid-load is superseded
        // even though `isModelLoaded` is still false.
        if wasLoaded || wasStreaming || wasInFlight {
          proxy.invalidateCurrentLoadGeneration(cause: "xpc_interruption")
        }
        if proxy.isModelLoaded {
          proxy.isModelLoaded = false
          proxy.isStreaming = false
        }
        proxy.needsReinit = true
        // #959: fire the interruption signal BEFORE the fire-and-forget log so
        // the router's idle-marker set is not delayed behind the `await` (shrinks
        // the kill-vs-press gap). Surface only if ASR was active/resident.
        if wasStreaming || wasLoaded {
          proxy.onServiceInterrupted?()
        }
        await AppLogger.shared.log(
          "[ASRManagerProxy] XPC interruptionHandler fired — wasStreaming=\(wasStreaming), wasLoaded=\(wasLoaded)",
          level: .info, category: "XPC"
        )
      }
    }
  }

  nonisolated private static func makeInvalidationHandler(proxy: ASRManagerProxy) -> @Sendable () ->
    Void
  {
    return { [weak proxy] in
      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        let wasActive = proxy.isStreaming || proxy.isModelLoaded
        let wasInFlight = proxy.inFlightLoadTask != nil
        // #959: same as the interruption handler — supersede current/in-flight
        // load + log cause BEFORE clearing `isModelLoaded`.
        if wasActive || wasInFlight {
          proxy.invalidateCurrentLoadGeneration(cause: "xpc_invalidation")
        }
        proxy.connection = nil
        if proxy.isModelLoaded {
          proxy.isModelLoaded = false
          proxy.isStreaming = false
        }
        proxy.needsReinit = true
        if wasActive {
          proxy.onServiceInterrupted?()
        }
      }
    }
  }
}

// MARK: - Helpers

/// Thread-safe one-shot continuation guard — duplicate of AudioCaptureProxy's version.
/// Duplicated per architecture rule: "duplication is allowed when it protects independence."
private final class OneShotContinuationASR<T: Sendable>: @unchecked Sendable {
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

extension OneShotContinuationASR where T == Void {
  func resume() { resume(returning: ()) }
}

// `package` (#1348 Phase 2): ParakeetEngineAdapter's one-shot stale-helper
// retry matches on this type — narrowest visibility that crosses the module
// (architecture-rules minimize-visibility).
package enum XPCASRTransportError: LocalizedError {
  case serviceUnreachable

  package var errorDescription: String? {
    switch self {
    case .serviceUnreachable: return "XPC ASR service is unreachable."
    }
  }
}
