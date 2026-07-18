@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// XPC-backed implementation of `ASRManagerInterface`.
///
/// Bridges the in-process ASR interface to XPC calls against `EnviousWisprASRService`.
/// Model loading, inference, and memory all live in the service process.
/// Crash recovery uses the same shape the deleted audio-capture proxy used —
/// a `OneShotContinuation`, `nonisolated static` handler factories, per-call
/// error routing.
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

  /// #1388 step 1: the pending `loadModel()` continuation's resume-once guard,
  /// reachable by EVERY completion source — the XPC reply, the per-call proxy
  /// error, the invalidation/interruption handlers, and an explicit
  /// `cancelInFlightLoad()`. Production proved the per-call error handler does
  /// NOT reliably fire for a pending reply on invalidate/death (119 of 126
  /// wedge fires reached no terminal outcome — the await hung and the caller's
  /// guard slot leaked), so the connection handlers resume this directly.
  /// `OneShotContinuationASR` guarantees exactly one resume; the
  /// identity-guarded clear in `loadModel()` prevents a superseded load's exit
  /// from clobbering a retry's freshly registered guard.
  private var pendingLoadCompletion: OneShotContinuationASR<Void>?

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
    // Deliberate recycle OWNS the cleanup synchronously: detach the async
    // handlers before invalidating, or the invalidation handler can fire
    // AFTER the adapter's one-shot retry installed its new load task and
    // bump the generation out from under it — turning a successful retry
    // into ASRLoadSupersededError (code-diff r5 P2). No session is active on
    // this path (the load just failed), so the handlers' interruption
    // duties are moot; their state resets happen right here.
    if let conn = connection {
      conn.invalidationHandler = nil
      conn.interruptionHandler = nil
      conn.invalidate()
    }
    connection = nil
    needsReinit = true
  }

  /// Test accessors for the recycle path (#1348; r3-precise scope: the
  /// reachable `onProxyError` behavior, not the OS callback).
  var needsReinitForTesting: Bool { needsReinit }
  var hasConnectionForTesting: Bool { connection != nil }

  /// #1388 test accessor: whether a pending load completion is registered.
  /// The contract test asserts it is cleared on every `loadModel` exit.
  // periphery:ignore - test seam
  var hasPendingLoadCompletionForTesting: Bool { pendingLoadCompletion != nil }

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
  ///
  /// Parakeet only (#1386 PR-2). A WhisperKit load must never leave this process:
  /// the helper would construct its own backend, out of reach of the in-process
  /// relocation gate, and map a model while its bytes may still be moving.
  public func loadModel() async throws {
    guard activeBackendType == .parakeet else {
      throw ASRManagerNotOwnedError(backend: activeBackendType)
    }
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

      // #1388 step 1: register the continuation guard so the connection
      // handlers and `cancelInFlightLoad()` can complete the load. The clear
      // is identity-guarded: a superseded load's exit must not clobber the
      // guard a retry registered after it (same trap as `activeLoadTaskID`).
      var registeredCompletion: OneShotContinuationASR<Void>?
      defer {
        if let registered = registeredCompletion, self.pendingLoadCompletion === registered {
          self.pendingLoadCompletion = nil
        }
      }
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        let guard_ = OneShotContinuationASR(cont)
        registeredCompletion = guard_
        self.pendingLoadCompletion = guard_
        // #1388 (cloud review P1): era of the connection this call goes out
        // on. A LATE per-call error handler — queued behind the invalidation
        // that already resumed this load — must not recycle the SUCCESSOR's
        // fresh connection after the adapter's retry installed it. Same
        // whole-body era rule as the interruption/invalidation handlers; the
        // duplicate `guard_` resume below stays harmless either way (this
        // era's one-shot, not the successor's).
        let callEraID = self.connection.map(ObjectIdentifier.init)
        self.serviceProxy { proxy in
          let cacheOnly = self.parakeetCacheOnly && self.activeBackendType == .parakeet
          proxy.loadModel(backendType: self.activeBackendType.rawValue, cacheOnly: cacheOnly) {
            nsError in
            // #1525 PR I-B: reconstruct the typed, conforming error from the
            // surviving NSError domain/code before throwing to the adapter.
            if let error = nsError {
              let reconstructed: any Error =
                ParakeetModelLoadSentryError(reconstructingFrom: error).map { $0 as any Error }
                ?? XPCASRTransportError(reconstructingFrom: error).map { $0 as any Error }
                ?? error
              guard_.resume(throwing: reconstructed)
            } else {
              guard_.resume()
            }
          }
        } onProxyError: {
          // #1348: force a helper recycle so the next attempt reconnects to
          // the current bundle binary (grounded r2 blocker 1) — era-gated
          // (#1388): only while OUR connection is still current (or cleared
          // with no successor yet).
          let currentEraID = self.connection.map(ObjectIdentifier.init)
          if currentEraID == nil || currentEraID == callEraID {
            self.recycleConnectionAfterProxyError()
          }
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

  /// Parakeet only (#1386 PR-2) — see `loadModel()`. The helper no longer has a
  /// WhisperKit backend to transcribe with, so refuse here rather than round-trip
  /// into an "Unknown backend" from across the process boundary.
  public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    guard activeBackendType == .parakeet else {
      throw ASRManagerNotOwnedError(backend: activeBackendType)
    }
    let data = audioSamples.withUnsafeBytes { Data($0) }
    let language = options.language ?? ""
    let speechSegmentsData: Data?
    if options.speechSegments.isEmpty {
      speechSegmentsData = nil
    } else {
      do {
        speechSegmentsData = try JSONEncoder().encode(options.speechSegments)
      } catch {
        // #1525 PR I-B: a request-encoding failure never reaches the service
        // at all — pin its own identity rather than bridging via the raw
        // JSONEncoder error's ordinal-derived NSError.
        throw XPCASRTransportError.requestEncodingFailed(error.localizedDescription)
      }
    }

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
      // #1525 PR I-B: reconstruct the typed, conforming error from the
      // surviving NSError domain/code before throwing to the adapter.
      let reconstructed: any Error =
        ParakeetTranscriptionSentryError(reconstructingFrom: error).map { $0 as any Error }
        ?? XPCASRTransportError(reconstructingFrom: error).map { $0 as any Error }
        ?? error
      throw reconstructed
    }
    guard let resultData else {
      throw XPCASRTransportError.responseDecodingFailed("XPC ASR service returned no result data.")
    }
    do {
      return try PropertyListDecoder().decode(ASRResult.self, from: resultData)
    } catch {
      // #1525 PR I-B (§3.3c): a response-CODEC failure, not "the ASR backend
      // failed to transcribe" — belongs on the transport authority, not
      // ASRError.transcriptionFailed's bridged group.
      throw XPCASRTransportError.responseDecodingFailed(error.localizedDescription)
    }
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
          // #1525 PR I-B (Codex cloud review): reconstruct the typed,
          // conforming error before throwing to the adapter, matching
          // loadModel/transcribe/finalizeStreaming's reconstruction.
          if let error = nsError {
            let reconstructed: any Error =
              XPCASRTransportError(reconstructingFrom: error).map { $0 as any Error } ?? error
            guard_.resume(throwing: reconstructed)
          } else {
            guard_.resume()
          }
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
      // #1525 PR I-B: reconstruct the typed, conforming error from the
      // surviving NSError domain/code before throwing to the adapter.
      let reconstructed: any Error =
        ParakeetTranscriptionSentryError(reconstructingFrom: error).map { $0 as any Error }
        ?? XPCASRTransportError(reconstructingFrom: error).map { $0 as any Error }
        ?? error
      throw reconstructed
    }
    guard let resultData else {
      throw XPCASRTransportError.responseDecodingFailed("XPC ASR service returned no result data.")
    }
    do {
      return try PropertyListDecoder().decode(ASRResult.self, from: resultData)
    } catch {
      // #1525 PR I-B (§3.3c): a response-CODEC failure, not "the ASR backend
      // failed to transcribe" — belongs on the transport authority, not
      // ASRError.transcriptionFailed's bridged group.
      throw XPCASRTransportError.responseDecodingFailed(error.localizedDescription)
    }
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
    // #1388 step 1: resume the pending load continuation FIRST, with the
    // dedicated cancellation error, so (a) `loadModel`'s await always reaches
    // a terminal outcome — before this contract the invalidation handler
    // never resumed it and `ensureEngineWarm` hung forever — and (b) the
    // cancel CAUSE wins over the death cause the invalidation handler would
    // stamp (the one-shot guard drops the handler's later duplicate resume).
    // Deliberately NOT a transport error: the adapter's one-shot transport
    // retry would silently restart a load the user just cancelled.
    pendingLoadCompletion?.resume(throwing: ASRLoadCancelledError())
    pendingLoadCompletion = nil
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

    // #1388: handlers carry their own connection for the era guard — a late
    // handler from a RETIRED connection must not resume a successor load's
    // pending completion (same trap class as `recycleConnectionAfterProxyError`'s
    // detach, code-diff r5 P2).
    conn.interruptionHandler = Self.makeInterruptionHandler(proxy: self, connection: conn)
    conn.invalidationHandler = Self.makeInvalidationHandler(proxy: self, connection: conn)

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

  nonisolated private static func makeInterruptionHandler(
    proxy: ASRManagerProxy, connection: NSXPCConnection
  ) -> @Sendable () ->
    Void
  {
    // NSXPCConnection is not Sendable; the era guard only needs IDENTITY, so
    // carry the Sendable ObjectIdentifier instead of the object.
    let eraID = ObjectIdentifier(connection)
    return { [weak proxy] in
      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        let wasStreaming = proxy.isStreaming
        let wasLoaded = proxy.isModelLoaded
        let wasInFlight = proxy.inFlightLoadTask != nil
        // #1388 step 1: a service death mid-load must FAIL the pending load —
        // the per-call error handler is not guaranteed to fire for a pending
        // reply, and before this contract the await simply hung. Typed as the
        // transport error so the adapter's one-shot retry reconnects to the
        // respawned helper (the designed stale-helper recovery). A deliberate
        // cancel already resumed this with the cancellation error first; the
        // one-shot guard drops this duplicate.
        //
        // Era guard: only the CURRENT connection's death may touch proxy
        // state — a retired connection's late handler racing a fast retry
        // must not kill the successor's freshly registered guard, supersede
        // the successor's generation, or clear the successor's flags (Codex
        // r3 P2 on #1388: the guard originally covered only the resume; the
        // trailing mutations read LIVE state and clobbered the successor).
        // Current era = the proxy's live connection is still this handler's
        // connection, or was cleared with no successor established yet.
        let currentEraID = proxy.connection.map(ObjectIdentifier.init)
        guard currentEraID == nil || currentEraID == eraID else { return }
        proxy.pendingLoadCompletion?.resume(throwing: XPCASRTransportError.serviceUnreachable)
        proxy.pendingLoadCompletion = nil
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

  nonisolated private static func makeInvalidationHandler(
    proxy: ASRManagerProxy, connection: NSXPCConnection
  ) -> @Sendable () ->
    Void
  {
    let eraID = ObjectIdentifier(connection)
    return { [weak proxy] in
      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        let wasActive = proxy.isStreaming || proxy.isModelLoaded
        let wasInFlight = proxy.inFlightLoadTask != nil
        // #1388 step 1: same as the interruption handler — an invalidated
        // connection must fail the pending load with the typed transport
        // error (duplicate resumes are dropped by the one-shot guard), under
        // the same era guard. The guard covers the WHOLE body (Codex r3 P2):
        // a retired connection's late handler must not kill a successor load,
        // supersede the successor's generation, nil the successor connection,
        // or flag reinit against it.
        let currentEraID = proxy.connection.map(ObjectIdentifier.init)
        guard currentEraID == nil || currentEraID == eraID else { return }
        proxy.pendingLoadCompletion?.resume(throwing: XPCASRTransportError.serviceUnreachable)
        proxy.pendingLoadCompletion = nil
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

/// Thread-safe one-shot continuation guard — an ASR-local copy of the guard the
/// deleted audio-capture proxy also used.
/// Duplicated per architecture rule: "duplication is allowed when it protects independence."
/// `internal` (was private) since #1388: the resume-once contract test pins
/// first-resume-wins directly (the cancel cause must beat the invalidation
/// handler's later death cause).
final class OneShotContinuationASR<T: Sendable>: @unchecked Sendable {
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
//
// #1525 PR I-B: widened from the single `.serviceUnreachable` case to cover
// every XPC/codec transport failure — a physically different failure class
// from "the ASR backend itself failed to transcribe" (which belongs on
// `ParakeetTranscriptionSentryError`/`ParakeetModelLoadSentryError` instead).
// `CustomNSError` conforms because some of these cases originate service-side
// and must survive the XPC round-trip, unlike `.serviceUnreachable` (purely
// client-local, never crosses XPC).
package enum XPCASRTransportError: LocalizedError, CustomNSError, Sendable, Equatable {
  case serviceUnreachable
  /// `ASRManagerProxy`'s client-side `speechSegments` JSONEncoder failure —
  /// never crosses XPC (fails before the send).
  case requestEncodingFailed(String)
  /// Service's "Data size mismatch" early guard (was a raw `NSError(domain:
  /// "ASRService", code: -2, ...)`).
  case invalidSamplePayload(String)
  /// Service's JSONDecoder failure decoding the incoming request.
  case requestDecodingFailed(String)
  /// Service's "No model loaded" early guard (was a raw `NSError(domain:
  /// "ASRService", code: -3, ...)`). LIVE: ENVIOUSWISPR-3S.
  case modelNotLoaded
  /// Service's PropertyListEncoder failure encoding the outgoing response.
  case responseEncodingFailed(String)
  /// Client's XPC result-decode failure (§3.3c) — never crosses XPC itself;
  /// the decode happens AFTER the XPC round-trip completes.
  case responseDecodingFailed(String)

  package static let errorDomain = "EnviousWisprASR.XPCASRTransportError"

  /// Wire-level NSError/XPC-bridge identity only — does NOT control Sentry
  /// grouping (`sentryFingerprintDescriptor` below is the sole authority for
  /// that). `.serviceUnreachable` keeps its already-pinned `0`;
  /// `.invalidSamplePayload`/`.modelNotLoaded` keep the exact codes their
  /// predecessor raw NSErrors used, for wire-level continuity.
  package var errorCode: Int {
    switch self {
    case .serviceUnreachable: return 0
    case .requestEncodingFailed: return 1
    case .invalidSamplePayload: return -2
    case .requestDecodingFailed: return 2
    case .modelNotLoaded: return -3
    case .responseEncodingFailed: return 3
    case .responseDecodingFailed: return 4
    }
  }

  package var errorDescription: String? {
    switch self {
    case .serviceUnreachable: return "XPC ASR service is unreachable."
    case .requestEncodingFailed(let d): return d
    case .invalidSamplePayload(let d): return d
    case .requestDecodingFailed(let d): return d
    case .modelNotLoaded: return "No model loaded."
    case .responseEncodingFailed(let d): return d
    case .responseDecodingFailed(let d): return d
    }
  }

  /// Codex r2 finding #1: two EXISTING callers (`ParakeetEngineAdapter`'s
  /// stale-helper retry, `RecoverySpoolReplayer`'s recovery classification)
  /// type-check `is XPCASRTransportError` and assume it means "the XPC
  /// service is unreachable" — widening this enum with 6 new codec/transport
  /// cases silently breaks that assumption. Both narrow to this instead.
  package var isServiceUnreachable: Bool {
    if case .serviceUnreachable = self { return true }
    return false
  }

  /// Reconstructs the typed, conforming error from an NSError that survived
  /// the XPC round-trip. Returns `nil` if the domain doesn't match.
  package init?(reconstructingFrom error: NSError) {
    guard error.domain == Self.errorDomain else { return nil }
    let d = error.localizedDescription
    switch error.code {
    case 0: self = .serviceUnreachable
    case 1: self = .requestEncodingFailed(d)
    case -2: self = .invalidSamplePayload(d)
    case 2: self = .requestDecodingFailed(d)
    case -3: self = .modelNotLoaded
    case 3: self = .responseEncodingFailed(d)
    case 4: self = .responseDecodingFailed(d)
    default: return nil
    }
  }
}

/// #1525 PR G/PR I-B. Pins each case's exact wire identity.
/// `.serviceUnreachable`'s string is measured
/// (`docs/audits/2026-07-14-1525-pr-g-preflight.md` §1); `.modelNotLoaded`'s
/// is measured live (§3.5: ENVIOUSWISPR-3S, `"ASRService#-3"` — MUST NOT
/// change). `package` matches this type's own package visibility (mirrors
/// `KeyStoreError`'s PR-F pattern — a bare `var` would default to `internal`
/// and fail to compile against a `package` enclosing type). NEVER change
/// these strings once shipped.
extension XPCASRTransportError: StableSentryErrorIdentity {
  package var sentryFingerprintDescriptor: String {
    switch self {
    case .serviceUnreachable: return "EnviousWisprASR.XPCASRTransportError#0"
    case .requestEncodingFailed: return "EnviousWisprASR.XPCASRTransportError#1"
    // No live history found for "ASRService#-2" — safe to pin defensively.
    case .invalidSamplePayload: return "ASRService#-2"
    case .requestDecodingFailed: return "EnviousWisprASR.XPCASRTransportError#2"
    // LIVE: ENVIOUSWISPR-3S, 1u/1e, production — must not change.
    case .modelNotLoaded: return "ASRService#-3"
    case .responseEncodingFailed: return "EnviousWisprASR.XPCASRTransportError#3"
    // §3.3c: a genuine grouping SPLIT out of ASRError.transcriptionFailed's
    // bridged group — no live measurement run against this specific
    // descriptor yet (§3.5's "remaining work"), so this is a fresh pin.
    case .responseDecodingFailed: return "EnviousWisprASR.XPCASRTransportError#4"
    }
  }

  package var sentrySemanticID: String {
    switch self {
    case .serviceUnreachable: return "xpc.asr_service_unreachable"
    case .requestEncodingFailed: return "xpc.request_encoding_failed"
    case .invalidSamplePayload: return "xpc.invalid_sample_payload"
    case .requestDecodingFailed: return "xpc.request_decoding_failed"
    case .modelNotLoaded: return "xpc.model_not_loaded"
    case .responseEncodingFailed: return "xpc.response_encoding_failed"
    case .responseDecodingFailed: return "xpc.response_decoding_failed"
    }
  }
}
