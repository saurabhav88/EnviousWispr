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
  /// Issue #445: in-process variant. Tests do not drive a progress-file stream,
  /// so this stays unset at runtime; the protocol requires it.
  public var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?
  private var idleTimer: Timer?
  private var lastTranscriptionTime: Date?
  /// Single-flight guard: if a load is already in progress, callers await it instead of starting a new one.
  private var inFlightLoadTask: Task<Void, any Error>?

  /// #959 readiness-integrity token (see `ASRManagerProxy.loadGeneration`).
  private var loadGeneration: UInt64 = 0

  /// #959 single-flight identity (see `ASRManagerProxy.loadTaskSeq`).
  private var loadTaskSeq: UInt64 = 0
  private var activeLoadTaskID: UInt64 = 0

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
  // nothing; the defaults preserve today's wiring exactly. Tests pass fakes
  // that report `isReady=true` without a real model load, unblocking
  // reset-branch coverage in `setInitialBackendType` and `switchBackend`.
  private var parakeetBackend: any ASRBackend
  private var whisperKitBackend: any ASRBackend

  public init(
    parakeetBackend: (any ASRBackend)? = nil,
    whisperKitBackend: (any ASRBackend)? = nil
  ) {
    self.parakeetBackend = parakeetBackend ?? ParakeetBackend()
    self.whisperKitBackend = whisperKitBackend ?? WhisperKitBackend()
  }

  /// The currently active backend.
  public var activeBackend: any ASRBackend {
    switch activeBackendType {
    case .parakeet: return parakeetBackend
    case .whisperKit: return whisperKitBackend
    }
  }

  /// Whether the active backend supports streaming ASR.
  public var activeBackendSupportsStreaming: Bool {
    get async {
      await activeBackend.supportsStreaming
    }
  }

  /// Set the backend type synchronously at app startup. No unload (nothing loaded yet).
  /// Must be called before any loadModel() or warmup task.
  public func setInitialBackendType(_ type: ASRBackendType) {
    activeBackendType = type
    isModelLoaded = false
    isStreaming = false
  }

  /// Switch to a different backend. Unloads the previous one.
  public func switchBackend(to type: ASRBackendType) async {
    // #959: same-backend no-op guard FIRST so it never supersedes a valid load.
    guard type != activeBackendType else { return }
    invalidateCurrentLoadGeneration(cause: "switch")
    // #959 (Codex code-diff P2): retire the old backend's in-flight load task so
    // a later `loadModel()` for the new backend starts fresh, not joins the stale.
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    await activeBackend.unload()
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
      // #959: capture the load generation; refuse to mark loaded if superseded.
      let gen = self.loadGeneration
      self.downloadProgress = 0
      self.downloadPhase = "Preparing download..."
      self.downloadDetail = ""

      // For Parakeet, use the progress-reporting variant so in-process path also reports progress.
      if self.activeBackendType == .parakeet {
        try await self.parakeetBackend.prepare { [weak self] fraction, phase, detail in
          Task { @MainActor [weak self] in
            guard let self, !self.isModelLoaded else { return }
            self.downloadProgress = fraction
            self.downloadPhase = phase
            self.downloadDetail = detail
          }
        }
      } else {
        try await self.activeBackend.prepare()
      }
      self.downloadProgress = 1.0
      self.downloadPhase = ""
      self.downloadDetail = ""
      // #959: read readiness first, THEN guard, so a cancel/unload/switch that
      // landed during the `isReady` await can't be overwritten by a stale write.
      let ready = await self.activeBackend.isReady
      guard gen == self.loadGeneration else { throw ASRLoadSupersededError() }
      self.isModelLoaded = ready
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
    try await activeBackend.transcribe(audioSamples: audioSamples, options: options)
  }

  // MARK: - Streaming ASR

  /// Start streaming ASR on the active backend. Falls back silently if unsupported.
  /// If a streaming session is already active, cancels it first to prevent double-session state.
  public func startStreaming(options: TranscriptionOptions = .default) async throws {
    guard await activeBackend.supportsStreaming else { return }
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
    guard isStreaming else { return }
    try await activeBackend.feedAudio(buffer)
  }

  /// Finalize streaming and return the transcript. Throws `ASRError.streamingNotSupported` if no streaming session is active.
  public func finalizeStreaming() async throws -> ASRResult {
    guard isStreaming else {
      throw ASRError.streamingNotSupported
    }
    let result = try await activeBackend.finalizeStreaming()
    isStreaming = false
    return result
  }

  /// Cancel an active streaming session, discarding partial results.
  public func cancelStreaming() async {
    guard isStreaming else { return }
    await activeBackend.cancelStreaming()
    isStreaming = false
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
    // Bump before the loaded-guard so an in-flight load (flag still false) is
    // superseded too, not just a resident model.
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
    await activeBackend.unload()
    isModelLoaded = false
  }

  /// Issue #445: in-process variant of the watchdog recovery. No XPC connection
  /// to invalidate; just cancels the host-side task and resets state. The
  /// next press triggers a fresh load. Mostly used in tests; production runs
  /// against `ASRManagerProxy` which has the full connection-invalidate path.
  public func cancelInFlightLoad() {
    // #959: supersede the current load first so a stale completion can't resurrect it.
    invalidateCurrentLoadGeneration(cause: "recoverFromWedge")
    inFlightLoadTask?.cancel()
    inFlightLoadTask = nil
    isModelLoaded = false
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
}
