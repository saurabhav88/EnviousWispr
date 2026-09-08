@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// Manages ASR backend selection and delegates transcription calls.
@MainActor
@Observable
public final class ASRManager: ASRManagerInterface {
  public private(set) var activeBackendType: ASRBackendType = .parakeet
  public private(set) var isModelLoaded = false
  public private(set) var isStreaming = false

  // Download progress — updated in-process during loadModel().
  public private(set) var downloadProgress: Double = 0
  public private(set) var downloadPhase: String = ""
  public private(set) var downloadDetail: String = ""
  public var onServiceInterrupted: (() -> Void)?  // No-op for in-process — no XPC crash path
  /// #1707 Phase 3 (§3.2, row 7) / #1741 Chunk 3 — the mutation-side capability
  /// guarding `unloadModel()`'s idle-timer unload, a background actor unrelated
  /// to any active session, so recovery must never race it. Required at
  /// construction (no default) — replaces the old defaulted
  /// `tryBeginEngineMutation`/`endEngineMutation`/`wakeRecoveryIfOwed` closure
  /// triplet. `package`, not `public`: `EnviousWisprASR` is an exported
  /// library product and `EngineMutationScope` is itself only
  /// `package`-visible, so a wider property could not hold it.
  package let engineMutationScope: EngineMutationScope
  /// Issue #445: in-process variant, fed from `loadModel()`'s progress
  /// callback on the same event-driven basis `ASRManagerProxy`'s XPC round
  /// trip already uses — never a fixed cadence (#1908: forwarding a timer
  /// tick here would manufacture progress the kernel counts as real).
  public var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?
  /// #1348 Phase 2: delivery-managed Parakeet loads are cache-only (see
  /// `ASRManagerInterface.parakeetCacheOnly`).
  public var parakeetCacheOnly = false
  /// #2483: see `ASRManagerProxy.parakeetModelDirectory`. The default is OUR
  /// directory, never the vendor's, so an entry point that loads without going
  /// through `ParakeetEngineAdapter` — `ActiveEngineOperation.load` does exactly
  /// that — cannot reach FluidAudio's shared tree by omission.
  public var parakeetModelDirectory: URL?
  /// #1908: this manager's `loadModel()` progress also lands in the shared
  /// file, matching `ASRManagerProxy`'s existing opt-in — the sessionless
  /// warm-up wedge guard depends on it regardless of transport.
  public var feedsSharedProgressFile: Bool { true }
  private var idleTimer: Timer?
  private var lastTranscriptionTime: Date?
  /// Single-flight guard: if a load is already in progress, callers await it instead of starting a new one.
  private var inFlightLoadTask: Task<Void, any Error>?

  /// #959 readiness-integrity token (see `ASRManagerProxy.loadGeneration`).
  private var loadGeneration: UInt64 = 0

  /// #959 single-flight identity (see `ASRManagerProxy.loadTaskSeq`).
  private var loadTaskSeq: UInt64 = 0
  private var activeLoadTaskID: UInt64 = 0

  /// #1908: the pending `loadModel()` caller(s)' escape hatch. `loadModel()`
  /// races the real vendor work against this continuation; `cancelInFlightLoad()`
  /// resumes it directly with `ASRLoadCancelledError` so a caller is released
  /// even when the underlying vendor call does not observe `Task.isCancelled`
  /// (confirmed it does not — FluidAudio's loader ignores cancellation).
  /// Ports `ASRManagerProxy.pendingLoadCompletion`'s exact contract: resumed
  /// on EVERY exit path, never left dangling. `OneShotContinuationASR` also
  /// lives in this module so it survives `ASRManagerProxy`'s eventual deletion.
  private var pendingLoadCompletion: OneShotContinuationASR<Void>?

  /// Bump the load generation so an in-flight load completion is superseded, and
  /// log the `ready → notReady` transition tagged with cause. Called before any
  /// supersession early-return. Ordinary session discard never calls this.
  private func invalidateCurrentLoadGeneration(cause: String) {
    loadGeneration &+= 1
    if isModelLoaded {
      Task {
        await AppLogger.shared.log(
          "[ASRManager] readiness ready→notReady (cause=\(cause)) backend=\(activeBackendType.rawValue)",
          level: .info, category: "ASR"
        )
      }
    }
  }

  // Phase G5: existential-typed for test injection. Production callers pass
  // nothing; the default factory preserves today's wiring exactly. Tests pass
  // a factory returning a fake that reports `isReady=true` without a real
  // model load, unblocking reset-branch coverage in `setInitialBackendType`
  // and `switchBackend`.
  //
  // #1908: a FACTORY, not a stored instance — every `loadModel()` attempt
  // constructs a FRESH backend and only publishes it into `parakeetBackend`
  // on success, mirroring `ASRServiceHandler.swift:58-89`'s existing
  // fresh-backend-per-load behavior across XPC helper respawns. An abandoned
  // or wedged attempt's candidate is therefore never the instance any other
  // caller (`transcribe`, `startStreaming`, `unloadModel`, …) can reach —
  // closing the race a shared single instance would otherwise have. Tests
  // that inject a factory returning the SAME fake every call keep their
  // existing sequential-behavior assertions unchanged (identity comparisons
  // in `loadModel()` below become no-ops for them); a test proving the
  // abandon-then-retry race must inject a factory returning DISTINCT fakes.
  private let parakeetBackendFactory: () -> any ASRBackend
  private var parakeetBackend: any ASRBackend

  /// #1908: FluidAudio's `ModelHub.offlineMode` (`ParakeetBackend.configureOfflineMode`)
  /// is a process-global static, NOT scoped to any one backend instance —
  /// fresh-backend-per-attempt does not isolate it (grounded review round 2).
  /// Serialize admission so a load attempt whose vendor call has not yet
  /// returned holds this value until it does; a conflicting-mode attempt is
  /// refused before it can race the write, a same-mode attempt proceeds
  /// (writing the identical value again is harmless — order cannot change
  /// what a concurrent reader observes when every writer agrees on the value).
  private var offlineModeAdmittedValue: Bool?
  private var offlineModeAdmissionCount = 0

  private func admitOfflineMode(cacheOnly: Bool) throws {
    if let admitted = offlineModeAdmittedValue {
      guard admitted == cacheOnly else {
        throw ParakeetOfflineModeConflictError()
      }
      offlineModeAdmissionCount += 1
      return
    }
    offlineModeAdmittedValue = cacheOnly
    offlineModeAdmissionCount = 1
  }

  private func releaseOfflineModeAdmission() {
    guard offlineModeAdmissionCount > 0 else { return }
    offlineModeAdmissionCount -= 1
    if offlineModeAdmissionCount == 0 {
      offlineModeAdmittedValue = nil
    }
  }

  package init(
    engineMutationScope: EngineMutationScope,
    parakeetBackendFactory: @escaping () -> any ASRBackend = { ParakeetBackend() }
  ) {
    self.engineMutationScope = engineMutationScope
    self.parakeetBackendFactory = parakeetBackendFactory
    self.parakeetBackend = parakeetBackendFactory()
  }

  /// The active backend WHEN THIS MANAGER OWNS IT — nil for WhisperKit.
  ///
  /// #1386 PR-2 made this manager Parakeet-only. It used to construct its own
  /// `WhisperKitBackend`, which was never the instance real dictation used: the
  /// kernel driver builds its own and drives it through `WhisperKitEngineAdapter`
  /// (`WisprBootstrapper.swift:282`). So this was a duplicate model owner reachable
  /// only from crash recovery and Diagnostics — and under the default
  /// `ASRManagerProxy` those two crossed XPC and had the helper build a THIRD one
  /// (`ASRServiceHandler.swift:77`), where no in-process relocation gate can reach
  /// it. A model mapped behind the gate's back is exactly what PR-2 forbids, so
  /// WhisperKit is gone from here entirely and both callers route through the
  /// gated adapter instead. XPC stays Parakeet-only, as the architecture intends.
  ///
  /// `activeBackendType` still tracks BOTH engines: it is this manager's
  /// bookkeeping/reporting answer (`EngineCoordinator`, `BackendMetadata`,
  /// telemetry), not a claim of ownership.
  private var activeBackend: (any ASRBackend)? {
    activeBackendType == .parakeet ? parakeetBackend : nil
  }

  /// Whether the active backend supports streaming ASR. False when the active
  /// engine is not this manager's — the honest answer to "can I stream through
  /// YOU", which is what every caller here is actually asking.
  public var activeBackendSupportsStreaming: Bool {
    get async {
      guard let activeBackend else { return false }
      return await activeBackend.supportsStreaming
    }
  }

  /// Set the backend type synchronously at app startup. No unload (nothing loaded yet).
  /// Must be called before any loadModel() or warmup task.
  public func setInitialBackendType(_ type: ASRBackendType) {
    activeBackendType = type
    isModelLoaded = false
    isStreaming = false
  }

  /// Switch to a different backend. Unloads the previous one if it is ours.
  public func switchBackend(to type: ASRBackendType) async {
    // #959: same-backend no-op guard FIRST so it never supersedes a valid load.
    guard type != activeBackendType else { return }
    invalidateCurrentLoadGeneration(cause: "switch")
    // #959 (Codex code-diff P2): retire the old backend's in-flight load task so
    // a later `loadModel()` for the new backend starts fresh, not joins the stale.
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    // #1908: deliberately NOT resuming `pendingLoadCompletion` here — that
    // early-release is scoped to `cancelInFlightLoad()` only (matching
    // `ASRManagerProxy`, which never touches `pendingLoadCompletion` from its
    // own switch/unload paths either). A switch is an ORDINARY lifecycle
    // transition, not a hung load recovery; a caller still awaiting the
    // superseded load keeps its existing, tested contract — it observes the
    // real work finish and gets `ASRLoadSupersededError()` from the
    // generation check in `performLoad`, unchanged.
    //
    // Switching AWAY from WhisperKit unloads nothing here: the adapter owns that
    // model's lifecycle, and the instance this manager used to unload was never
    // the one holding real weights.
    await activeBackend?.unload()
    activeBackendType = type
    isModelLoaded = false
    isStreaming = false
  }

  /// Load the active backend's model. Single-flight: concurrent callers await the same task.
  public func loadModel() async throws {
    // If a load is already in progress, await it instead of starting a new one.
    if let existing = inFlightLoadTask {
      try await existing.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      try await self.performLoadRacingCancellation()
    }
    loadTaskSeq &+= 1
    let myTaskID = loadTaskSeq
    inFlightLoadTask = task
    activeLoadTaskID = myTaskID
    // #959 (Codex code-diff P1): identity-guarded cleanup — only retire the
    // handle if it is still ours, so a superseded load can't clear a retry's task.
    defer { if activeLoadTaskID == myTaskID { inFlightLoadTask = nil } }
    try await task.value
  }

  /// #1908: races the real vendor load against an early-release signal so
  /// `cancelInFlightLoad()` can unblock every awaiting caller even when the
  /// vendor call itself never observes cancellation (confirmed it does not).
  ///
  /// The continuation is registered SYNCHRONOUSLY, before the real work is
  /// even started — `withCheckedThrowingContinuation`'s closure runs
  /// immediately when the coroutine suspends, so there is no window in
  /// which `cancelInFlightLoad()` could fire before `pendingLoadCompletion`
  /// exists. (An earlier draft raced two task-group children instead, which
  /// left a real window where the fast-throwing child could resume-and-clear
  /// the completion before the continuation-registering child had even run,
  /// leaking an unresumed `CheckedContinuation` — a Swift runtime fatal
  /// error. This shape cannot do that: exactly one path ever calls the
  /// underlying `cont.resume`, guarded by `OneShotContinuationASR`'s
  /// resume-once lock, whichever of "cancel" or "real work finished" gets
  /// there first.)
  private func performLoadRacingCancellation() async throws {
    let gen = loadGeneration
    try await withCheckedThrowingContinuation {
      [weak self] (cont: CheckedContinuation<Void, any Error>) in
      guard let self else {
        cont.resume()
        return
      }
      let completion = OneShotContinuationASR(cont)
      self.pendingLoadCompletion = completion
      // The real work runs in its own unstructured Task so it can keep
      // running orphaned in the background if `cancelInFlightLoad()` beats
      // it to resuming `completion` — matching the accepted risk this
      // plan documents for a vendor call that will not cooperate.
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await self.performLoad(generation: gen)
          completion.resume()
        } catch {
          completion.resume(throwing: error)
        }
        // Only clear if this attempt's completion is still the current one —
        // a cancel that already cleared it (or a newer attempt's own
        // registration) must not be clobbered by a late-finishing orphan.
        if self.pendingLoadCompletion === completion {
          self.pendingLoadCompletion = nil
        }
      }
    }
  }

  private func performLoad(generation gen: UInt64) async throws {
    downloadProgress = 0
    downloadPhase = ModelLoadStallPolicy.listingPhase
    downloadDetail = ""
    // #1908 Codex review: clear any stale shared-progress entry (e.g. a
    // `validatingCachePhase` write left by delivery's legacy-migration check,
    // `ParakeetModelDelivery.ensureModelLocationReady`) before this attempt's
    // own event-driven writes begin. Ported from `ASRManagerProxy.loadModel`,
    // itself tracking a prior Codex finding (2026-05-07) on the same class:
    // a stale phase left in the file mis-arms/mis-parks the SESSIONLESS wedge
    // guard (`SessionlessLoadWedgeGuard`, which reads this file directly, not
    // the kernel-facing tick stream) if the vendor then hangs before its
    // first real progress callback.
    ProgressFile.shared.clear()

    guard activeBackendType == .parakeet else {
      // #1386 PR-2: WhisperKit does not load here. Callers that reach this
      // with WhisperKit active are on the retired route and must go through
      // the gated adapter (`ASRManagerNotOwnedError` says so out loud rather
      // than silently loading nothing or, worse, mapping past the gate).
      throw ASRManagerNotOwnedError(backend: activeBackendType)
    }

    // #1908: a FRESH candidate for this attempt — never published until it
    // succeeds, so an abandoned attempt can never mutate the instance a
    // successor or any other caller is using.
    let candidate = parakeetBackendFactory()
    var published = false
    defer {
      // Any exit that never published `candidate` — superseded, cancelled,
      // or a thrown error — must still release whatever resources its own
      // `prepare()` may have allocated. Dropping the reference alone does
      // NOT run FluidAudio's `cleanup()` (no `deinit` performs it), so this
      // is the ONLY thing that frees a superseded attempt's real resources.
      if !published {
        Task { await candidate.unload() }
      }
    }

    let progress: ProgressCallback = { [weak self] fraction, phase, detail in
      Task { @MainActor [weak self] in
        guard let self, gen == self.loadGeneration, !self.isModelLoaded else { return }
        self.downloadProgress = fraction
        self.downloadPhase = phase
        self.downloadDetail = detail
        // #1908: event-driven only — never a fixed cadence. A timer-driven
        // write here would manufacture a fresh timestamp during a genuine
        // hang and hide the wedge from the sessionless guard, which reads
        // this file's mtime as its stale-progress baseline.
        ProgressFile.shared.write(fraction: fraction, phase: phase, detail: detail)
        self.loadProgressTickReporter?(Date(), phase)
      }
    }

    // #1348 Phase 2: cache-only is Parakeet+FluidAudio-concrete behavior
    // (the offline switch lives in that library), so the delivery mode
    // downcasts to the concrete backend this manager itself constructed —
    // not a kernel-side identity gate (capability rule applies to
    // adapters/kernel; injected test mocks keep the legacy path).
    //
    // #2483 second-pass finding 1/2/5: the downcast is no longer gated on
    // `parakeetCacheOnly`. It used to be, and the `else` then reached
    // `prepare(progressCallback:)`, whose convenience overload resolves
    // FluidAudio's SHARED directory — so switching delivery off sent the
    // in-process path straight back to the tree this whole change exists to
    // stop touching, with downloading enabled. The XPC path never had that
    // hole because the proxy passes the directory on every load. Only a
    // non-`ParakeetBackend` backend (an injected mock, which loads nothing)
    // takes the protocol overload now.
    if let parakeet = candidate as? ParakeetBackend {
      // #2697: refuse rather than resolve one of our own. `nil` means the
      // location seam either has not run or REFUSED, and both must fail
      // loudly here instead of loading from an assumed directory.
      guard let directory = parakeetModelDirectory else {
        throw ParakeetModelDirectoryUnsetError()
      }
      // #1908: process-global offline-mode exclusion — see the property docs
      // above. Refuses a conflicting-mode attempt BEFORE `prepare()` ever
      // reaches FluidAudio's shared static; a same-mode attempt proceeds.
      try admitOfflineMode(cacheOnly: parakeetCacheOnly)
      defer { releaseOfflineModeAdmission() }
      try await parakeet.prepare(
        cacheOnly: parakeetCacheOnly, modelDirectory: directory,
        progressCallback: progress)
    } else {
      try await candidate.prepare(progressCallback: progress)
    }

    downloadProgress = 1.0
    downloadPhase = ""
    downloadDetail = ""
    // #959: read readiness first, THEN guard, so a cancel/unload/switch that
    // landed during the `isReady` await can't be overwritten by a stale write.
    let ready = await candidate.isReady
    guard gen == loadGeneration else { throw ASRLoadSupersededError() }

    // #1908: publish — retire whatever was previously current, then adopt
    // the freshly-loaded instance as the ONLY thing anything else will
    // touch. Retiring calls `.unload()` (not a bare drop) because
    // `ParakeetBackend.unload()` awaits FluidAudio's own `cleanup()`, which
    // ARC deallocation alone does not run.
    let retiring = parakeetBackend
    parakeetBackend = candidate
    published = true
    isModelLoaded = ready
    if !(retiring === (candidate as AnyObject)) {
      Task { await retiring.unload() }
    }
  }

  // #879: the launch/onboarding warm-up entry (formerly `loadModelSilently` +
  // the `launchPreloadReporter` callback) moved to the shared
  // `KernelDictationDriver.ensureEngineWarm(reason:)`, which drives this
  // `loadModel()` via the adapter and owns the `launch.model_preload_completed`
  // telemetry for the `.launch` reason. The single-flight (`inFlightLoadTask`)
  // still makes a press landing during a launch warm-up join the in-flight load.

  /// Transcribe raw audio samples (16kHz mono Float32).
  public func transcribe(audioSamples: [Float], options: TranscriptionOptions = .default)
    async throws -> ASRResult
  {
    guard let activeBackend else { throw ASRManagerNotOwnedError(backend: activeBackendType) }
    return try await activeBackend.transcribe(audioSamples: audioSamples, options: options)
  }

  // MARK: - Streaming ASR

  /// Start streaming ASR on the active backend. Falls back silently if unsupported.
  /// If a streaming session is already active, cancels it first to prevent double-session state.
  public func startStreaming(options: TranscriptionOptions = .default) async throws {
    guard let activeBackend, await activeBackend.supportsStreaming else { return }
    // Cancel any existing session before starting a new one
    if isStreaming {
      await activeBackend.cancelStreaming()
      isStreaming = false
    }
    try await activeBackend.startStreaming(options: options)
    isStreaming = true
  }

  /// Feed an audio buffer to the streaming ASR session.
  public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    guard isStreaming, let activeBackend else { return }
    try await activeBackend.feedAudio(buffer)
  }

  /// Finalize streaming and return the transcript. Throws `ASRError.streamingNotSupported` if no streaming session is active.
  public func finalizeStreaming() async throws -> ASRResult {
    guard isStreaming, let activeBackend else {
      throw ASRError.streamingNotSupported
    }
    // #1908 Codex review: clear BEFORE branching on success/failure, ported
    // from `ASRManagerProxy.finalizeStreaming` (unconditional `isStreaming =
    // false` right after the vendor call returns, before its error is even
    // inspected). Clearing only after a successful `try await` left the flag
    // `true` on a thrown error — the adapter's own batch rescue can still
    // recover the transcript, but `unloadModel()` refuses while `isStreaming`
    // is true, so the model stayed resident forever after a session that hit
    // this leg, with nothing left to clear it (the session is already closed
    // by the time this returns).
    do {
      let result = try await activeBackend.finalizeStreaming()
      isStreaming = false
      return result
    } catch {
      isStreaming = false
      throw error
    }
  }

  /// Cancel an active streaming session, discarding partial results.
  public func cancelStreaming() async {
    guard isStreaming, let activeBackend else { return }
    await activeBackend.cancelStreaming()
    isStreaming = false
  }

  /// #1908 Codex review: invalidate an in-flight `startStreaming()` a caller
  /// gave up waiting on (e.g. `ParakeetEngineAdapter.beginSession()`'s
  /// deadline). Deliberately NOT `cancelStreaming()` — that guards on
  /// `isStreaming`, which is still `false` here (the abandoned attempt never
  /// reached its own `isStreaming = true` line). Forwards unconditionally to
  /// `activeBackend.cancelStreaming()`, whose concrete `ParakeetBackend`
  /// conformer bumps its own streaming generation so the abandoned attempt's
  /// late completion cannot publish `streamingManager` behind a newer
  /// session's back — the same class `cancelInFlightLoad()` closes on the
  /// load side.
  public func cancelInFlightStreamingStart() async {
    await activeBackend?.cancelStreaming()
  }

  /// Unload the active backend, freeing model RAM.
  /// Refuses to unload if a streaming session is active — cancel streaming first.
  public func unloadModel() async {
    // #959: a live streaming session means the model is in use and there is no
    // in-flight load to supersede — refuse FIRST, before bumping the generation,
    // so the readiness `ready→notReady` log never falsely fires on a refusal
    // (Codex code-diff P2 note). The model stays loaded.
    if isStreaming {
      Task {
        await AppLogger.shared.log(
          "unloadModel() refused — streaming session is active. Cancel streaming first.",
          level: .info, category: "ASR"
        )
      }
      return
    }
    // #1707 Phase 3 (§3.2, row 7) / #1741 Chunk 3: hold a mutation claim BEFORE
    // touching anything below — including the load-generation bump and
    // in-flight-load cancel, which would otherwise cancel a load RECOVERY is
    // currently running under its own recovery claim (Codex code-diff round 1
    // P1: the original ordering let an idle-unload fire mid-recovery-load,
    // invalidate its generation, and have recovery treat the resulting throw
    // as an unrecoverable failure — deleting a recoverable spool). A denied
    // claim (recovery holds the engine) skips this attempt entirely, touching
    // NOTHING; the next genuine idle-unload trigger re-attempts — no bespoke
    // retry machinery for a background convenience unload.
    _ = await engineMutationScope.withClaim(site: "asrManagerUnload") {
      // Bump before the loaded-guard so an in-flight load (flag still false) is
      // superseded too, not just a resident model.
      self.invalidateCurrentLoadGeneration(cause: "unload")
      // #959 (Codex re-review P2): retire the superseded in-flight load task the
      // same way `switchBackend()` / `cancelInFlightLoad()` do — otherwise a retry
      // that joins via single-flight before the doomed task finishes propagates
      // `ASRLoadSupersededError` instead of starting a fresh load. Must run BEFORE
      // the loaded-guard, because the in-flight case is exactly when `isModelLoaded`
      // is still false and the guard would early-return with the stale handle live.
      self.inFlightLoadTask?.cancel()
      self.inFlightLoadTask = nil
      // #1908: deliberately NOT resuming `pendingLoadCompletion` here — see
      // the matching note in `switchBackend()`. Scoped to `cancelInFlightLoad()`
      // only, matching `ASRManagerProxy`'s exact contract.
      guard self.isModelLoaded, let activeBackend = self.activeBackend else { return }
      await activeBackend.unload()
      self.isModelLoaded = false
    }
  }

  /// Issue #445: in-process variant of the watchdog recovery. CHEAP and
  /// non-blocking: resumes any pending waiter, supersedes the current load
  /// generation, and cancels the host-side task. The next press triggers a
  /// fresh load. Does NOT itself attempt a backend unload — that is the
  /// separate, deadline-bounded `attemptWedgeRecoveryUnload()` below, called
  /// only by the kernel's HEAVY wedge-recovery path so ordinary cheap
  /// cancellation (a user-cancelled recording) is never blocked by it.
  public func cancelInFlightLoad() {
    // #959: supersede the current load first so a stale completion can't resurrect it.
    invalidateCurrentLoadGeneration(cause: "recoverFromWedge")
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    // #1908: release any caller awaiting `loadModel()` even though the
    // underlying vendor call keeps running orphaned in the background —
    // it does not observe `Task.isCancelled` and cannot be interrupted from
    // outside. `performLoad`'s own `defer` would otherwise be the only
    // resumer, and it may never run if the vendor call itself never returns.
    pendingLoadCompletion?.resume(throwing: ASRLoadCancelledError())
    pendingLoadCompletion = nil
    isModelLoaded = false
  }

  /// #1908 issue #445 in-process HEAVY wedge recovery: a deadline-bounded,
  /// fail-open attempt to unload the currently-published backend, so a load
  /// wedged inside a vendor call that will not cooperate with cancellation
  /// cannot block recovery indefinitely. Ports
  /// `WhisperKitEngineAdapter.recoverFromWedge()`'s exact pattern (2.0s
  /// default, `wedgeRecoveryUnloadDeadlineSec`-equivalent) rather than
  /// inventing a new one. Call `cancelInFlightLoad()` FIRST to release any
  /// waiter; this method targets the PUBLISHED backend only — an in-flight
  /// load's freshly-constructed candidate (§`performLoad`) is never
  /// reachable from outside the load task by design, so its own vendor call
  /// may continue running in the background until it completes or the app
  /// quits, matching WhisperKit's already-accepted risk for the identical
  /// case. `ASRManagerProxy` relies on its own XPC connection invalidation
  /// instead and does not override the protocol's no-op default.
  public func attemptWedgeRecoveryUnload() async {
    let captured = parakeetBackend
    _ = await withDeadline(seconds: 2.0) {
      await captured.unload()
    }
  }

  /// Called by pipeline after a transcript is saved.
  /// Records the timestamp and schedules/resets the idle timer.
  public func noteTranscriptionComplete(policy: ModelUnloadPolicy) {
    lastTranscriptionTime = Date()
    if policy == .immediately {
      Task { await unloadModel() }
      return
    }
    scheduleIdleTimer(policy: policy)
  }

  /// Cancel any pending idle timer (called when recording starts).
  public func cancelIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = nil
  }

  /// Schedule (or reset) the idle timer for timed policies.
  private func scheduleIdleTimer(policy: ModelUnloadPolicy) {
    guard let interval = policy.interval else { return }
    cancelIdleTimer()
    // Timer fires on the main run loop — safe for @MainActor ASRManager.
    idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        _ = Task<Void, Never> { await self?.unloadModel() }
      }
    }
  }

  #if DEBUG
    // MARK: #1908 — #1707 Phase 2 batch-decode fault oracle forwarding.
    // Reconnects the DEBUG fault-injection path `BatchDecodeFaultController`
    // needs once it stops downcasting to the concrete `ASRManagerProxy` type
    // (`WisprBootstrapper.swift`). Mirrors `ASRServiceHandler`'s existing
    // `#if DEBUG` block exactly, minus the XPC reply plumbing.
    public func armBatchDecodeHold(trialID: String) async {
      await (parakeetBackend as? ParakeetBackend)?.armBatchDecodeHold(trialID: trialID)
    }

    public func releaseBatchDecode(trialID: String) async {
      await (parakeetBackend as? ParakeetBackend)?.releaseBatchDecode(trialID: trialID)
    }

    public func clearBatchDecodeFault() async {
      await (parakeetBackend as? ParakeetBackend)?.clearBatchDecodeFault()
    }
  #endif
}
