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
  private var idleTimer: Timer?
  private var lastTranscriptionTime: Date?
  /// Single-flight guard: if a load is already in progress, callers await it instead of starting a new one.
  private var inFlightLoadTask: Task<Void, any Error>?

  private var parakeetBackend = ParakeetBackend()
  private var whisperKitBackend = WhisperKitBackend()

  public init() {}

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
    guard type != activeBackendType else { return }
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
      self.isModelLoaded = await self.activeBackend.isReady
    }
    inFlightLoadTask = task
    defer { inFlightLoadTask = nil }
    try await task.value
  }

  /// Silent warmup: load the model in the background without mutating UI-visible download state.
  /// Used at app launch. If a user-initiated load is already in progress, awaits it.
  public func loadModelSilently() async {
    guard !isModelLoaded else { return }
    // If a load is already in progress, just await it silently.
    if let existing = inFlightLoadTask {
      try? await existing.value
      return
    }
    do {
      try await loadModel()
    } catch {
      // Silent warmup failure is non-fatal. Record button triggers lazy-load as fallback.
      Task {
        await AppLogger.shared.log(
          "Silent model warmup failed: \(error.localizedDescription)",
          level: .info, category: "ASRManager"
        )
      }
    }
  }

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

  /// Finalize streaming and return the transcript. Falls back to batch if streaming was not active.
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
    guard isModelLoaded else { return }
    if isStreaming {
      Task {
        await AppLogger.shared.log(
          "unloadModel() refused — streaming session is active. Cancel streaming first.",
          level: .info, category: "ASR"
        )
      }
      return
    }
    await activeBackend.unload()
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
