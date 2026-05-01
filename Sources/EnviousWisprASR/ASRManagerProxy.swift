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

  // MARK: - Idle timer (stays in proxy — same as ASRManager)

  private var idleTimer: Timer?
  private var progressPollTimer: Timer?
  /// Single-flight guard: if a load is already in progress, callers await it instead of starting a new one.
  private var inFlightLoadTask: Task<Void, any Error>?

  public init() {}

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
      // Reset progress state before starting
      self.downloadProgress = 0
      self.downloadPhase = "Preparing download..."
      self.downloadDetail = ""

      self.ensureConnection()
      self.resendConfigIfNeeded()

      // Start polling the XPC service for progress at 4 Hz.
      self.startProgressPolling()

      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        let guard_ = OneShotContinuationASR(cont)
        self.serviceProxy { proxy in
          proxy.loadModel(backendType: self.activeBackendType.rawValue) { nsError in
            if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
          }
        } onProxyError: {
          guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
        }
      }
      // Stop polling and clear progress on completion
      self.stopProgressPolling()
      self.downloadProgress = 1.0
      self.downloadPhase = ""
      self.downloadDetail = ""
      self.isModelLoaded = true
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
          level: .info, category: "ASRManagerProxy"
        )
      }
    }
  }

  private func startProgressPolling() {
    stopProgressPolling()
    // Read progress from shared file — bypasses XPC entirely.
    // XPC serializes replies, so polling via XPC is blocked behind loadModel's pending reply.
    let progressFile = ProgressFile.shared
    let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
      guard let self, !self.isModelLoaded else { return }
      if let state = progressFile.read() {
        self.downloadProgress = state.fraction
        self.downloadPhase = state.phase
        self.downloadDetail = state.detail
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    progressPollTimer = timer
  }

  private func stopProgressPolling() {
    progressPollTimer?.invalidate()
    progressPollTimer = nil
  }

  public func unloadModel() async {
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
    guard type != activeBackendType else { return }
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

    let (resultData, error): (Data?, NSError?) = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<(Data?, NSError?), any Error>) in
      let guard_ = OneShotContinuationASR(cont)
      serviceProxy { proxy in
        proxy.transcribeSamples(
          data, sampleCount: audioSamples.count,
          language: language, enableTimestamps: options.enableTimestamps
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
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      let guard_ = OneShotContinuationASR(cont)
      serviceProxy { proxy in
        proxy.startStreaming(language: language, enableTimestamps: options.enableTimestamps) {
          nsError in
          if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
        }
      } onProxyError: {
        guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
      }
    }
    isStreaming = true
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
        if proxy.isModelLoaded {
          proxy.isModelLoaded = false
          proxy.isStreaming = false
        }
        proxy.needsReinit = true
        await AppLogger.shared.log(
          "[ASRManagerProxy] XPC interruptionHandler fired — wasStreaming=\(wasStreaming), wasLoaded=\(wasLoaded)",
          level: .info, category: "XPC"
        )
        // Surface crash to pipeline if ASR was active (streaming or batch in-flight)
        if wasStreaming || wasLoaded {
          proxy.onServiceInterrupted?()
        }
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

enum XPCASRTransportError: LocalizedError {
  case serviceUnreachable

  var errorDescription: String? {
    switch self {
    case .serviceUnreachable: return "XPC ASR service is unreachable."
    }
  }
}
