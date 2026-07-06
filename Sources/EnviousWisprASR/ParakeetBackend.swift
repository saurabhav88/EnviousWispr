@preconcurrency import AVFoundation
import EnviousWisprCore
@preconcurrency import FluidAudio

// Disambiguate from FluidAudio.ASRResult — we always mean our own type.
public typealias ASRResult = EnviousWisprCore.ASRResult

/// Parakeet v3 ASR backend using FluidAudio/CoreML.
///
/// This is the primary (default) backend. Parakeet v3 provides:
/// - ~110x real-time factor on Apple Silicon
/// - Built-in punctuation and capitalization
/// - 25 European language support
public actor ParakeetBackend: ASRBackend {
  public private(set) var isReady = false

  private var fluidAsrManager: AsrManager?
  private var fluidModels: AsrModels?

  // Streaming ASR state
  private var streamingManager: SlidingWindowAsrManager?
  private var streamingStartTime: CFAbsoluteTime = 0

  public var supportsStreaming: Bool { true }

  /// Total download size shown in the progress detail (#1339). The pinned
  /// Parakeet v3 set (4 model dirs + vocab + loose json/txt) measures
  /// 483,256,769 bytes — byte-verified in `workers/parakeet-mirror/
  /// expected-manifest.json` (in-repo since #1348 PR-2a; the bundled
  /// `parakeet-delivery-manifest.json` derives from it).
  static let totalDownloadMB = 483

  public init() {}

  public func prepare() async throws {
    try await prepare(cacheOnly: false, progressCallback: nil)
  }

  public func prepare(progressCallback: ProgressCallback?) async throws {
    try await prepare(cacheOnly: false, progressCallback: progressCallback)
  }

  /// #1348 Phase 2: whether this process may let FluidAudio touch the
  /// network. Cache-only is the delivery-managed invariant — the host admits
  /// verified bytes into FluidAudio's default cache and the service ONLY
  /// loads them; a cache miss must throw typed (`OfflineError.modelMissing`
  /// for model dirs, `AsrModelsError` for the vocab), never silently re-enter
  /// the borrowed downloader. Deterministic last-writer per prepare (the XPC
  /// handler serializes loads and unloads the previous backend first), so
  /// flipping the delivery flag works without a service restart.
  /// `internal` for the legacy-after-cache-only unit test.
  static func configureOfflineMode(cacheOnly: Bool) {
    DownloadUtils.enforceOffline = cacheOnly
  }

  /// Prepare with optional progress reporting.
  /// The callback is called from FluidAudio's download thread — caller must marshal to MainActor.
  ///
  /// FluidAudio's progress system:
  /// - `downloadRepo()` downloads ALL model files in one pass with byte-weighted progress.
  /// - `fractionCompleted` range: [0.0, 0.5] = download, [0.5, 1.0] = CoreML compilation.
  /// - `downloadRepo()` only fires on the first `loadModels()` call — subsequent calls find
  ///   files cached and skip. We map directly from FluidAudio's fraction.
  ///
  /// Stall detection is host-side (#1339): the kernel's session detector and
  /// the sessionless warm-up guard watch the shared progress file this
  /// callback feeds.
  ///
  /// `cacheOnly` (#1348 Phase 2): load the host-admitted cache with
  /// FluidAudio's own offline switch armed — zero network in this process.
  /// The legacy path (`cacheOnly: false`) stays byte-identical for the
  /// staged-rollout window (D5 §5), minus the deleted inert checksum no-op.
  public func prepare(cacheOnly: Bool, progressCallback: ProgressCallback?) async throws {
    let handler: DownloadUtils.ProgressHandler? = progressCallback.map {
      callback -> DownloadUtils.ProgressHandler in
      { progress in
        let phase: String
        let detail: String

        switch progress.phase {
        case .listing:
          // Single authority for this token: the host-side stall guard keys
          // its listing-stall gate on it (ModelLoadStallPolicy, #1339).
          phase = ModelLoadStallPolicy.listingPhase
          detail = ""
        case .downloading:
          phase = "Downloading model files..."
          // #1339: honest byte counter. The real payload is ~483MB of
          // already-compiled Core ML artifacts (445MB encoder weights); the
          // old "23 MB" label was the decoder file alone. Fraction [0, 0.5]
          // is FluidAudio's byte-weighted download half.
          let downloadPct = min(progress.fractionCompleted * 2.0, 1.0)
          let downloadedMB = Int(downloadPct * Double(Self.totalDownloadMB))
          detail =
            "\(downloadedMB) MB of \(Self.totalDownloadMB) MB (\(Int(downloadPct * 100))%)"
        case .compiling(let modelName):
          phase = "Installing model..."
          detail = modelName
        }
        callback(progress.fractionCompleted, phase, detail)
      }
    }

    Self.configureOfflineMode(cacheOnly: cacheOnly)
    let loadedModels: AsrModels
    if cacheOnly {
      // Delivery-managed: the default cache was admitted by the host's hash
      // gate before this call; enforceOffline (armed above) turns any gap
      // into a typed throw the host maps to its repair path.
      loadedModels = try await AsrModels.loadFromCache(version: .v3, progressHandler: handler)
    } else {
      loadedModels = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
    }
    self.fluidModels = loadedModels

    let manager = AsrManager(config: .default)
    // v0.15.4 API: initialize(models:) became loadModels(_:).
    try await manager.loadModels(loadedModels)
    self.fluidAsrManager = manager

    isReady = true
  }

  public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    guard isReady, let manager = fluidAsrManager else { throw ASRError.notReady }

    let startTime = CFAbsoluteTimeGetCurrent()
    // v0.15.4 API: the caller owns decoder state (fresh per one-shot batch decode;
    // upstream's ChunkProcessor also makes fresh state per chunk internally) and the
    // `source:` parameter is gone. Language hint intentionally NOT passed in PR-2
    // (parity with the d5fcca4 behavior); G7 language propagation ships in PR-4.
    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let fluidResult = try await manager.transcribe(audioSamples, decoderState: &decoderState)
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    return ASRResult(
      text: fluidResult.text,
      language: "en",
      duration: fluidResult.duration,
      processingTime: elapsed,
      backendType: .parakeet,
      tokenTimingSummary: Self.tokenTimingSummary(from: fluidResult.tokenTimings)
    )
  }

  /// Numbers-only summary of FluidAudio token timings for tail-clip diagnostics (#1232).
  /// We keep only the count and the end time (ms) of the last token — never token text.
  /// Used to compute how far the decoded text reached vs the captured audio.
  private static func tokenTimingSummary(from timings: [TokenTiming]?) -> ASRTokenTimingSummary? {
    guard let timings else { return nil }
    let lastEndMs = timings.map(\.endTime).max().map { Int(($0 * 1000).rounded()) }
    return ASRTokenTimingSummary(tokenCount: timings.count, lastTokenEndMs: lastEndMs)
  }

  // MARK: - Streaming ASR

  public func startStreaming(options _: TranscriptionOptions) async throws {
    guard isReady, let models = fluidModels else { throw ASRError.notReady }

    // Cancel any existing streaming session before starting a new one.
    // Prevents double-session state where the old manager is leaked.
    if let existing = streamingManager {
      await existing.cancel()
      streamingManager = nil
    }

    let config = SlidingWindowAsrConfig.streaming
    let manager = SlidingWindowAsrManager(config: config)
    // v0.15.4 API: start(models:source:) split into loadModels(_:) + startStreaming(source:).
    try await manager.loadModels(models)
    try await manager.startStreaming(source: .microphone)
    self.streamingManager = manager
    self.streamingStartTime = CFAbsoluteTimeGetCurrent()
  }

  public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    guard let manager = streamingManager else { throw ASRError.streamingNotSupported }
    await manager.streamAudio(buffer)
  }

  public func finalizeStreaming() async throws -> ASRResult {
    guard let manager = streamingManager else { throw ASRError.streamingNotSupported }
    defer { streamingManager = nil }

    let finalizeStart = CFAbsoluteTimeGetCurrent()
    let text = try await manager.finish()
    let finalizeEnd = CFAbsoluteTimeGetCurrent()

    let totalElapsed = finalizeEnd - streamingStartTime
    let finalizeElapsed = finalizeEnd - finalizeStart

    return ASRResult(
      text: text,
      language: "en",
      duration: totalElapsed,
      processingTime: finalizeElapsed,
      backendType: .parakeet
    )
  }

  public func cancelStreaming() async {
    if let manager = streamingManager {
      await manager.cancel()
      streamingManager = nil
    }
  }

  public func unload() async {
    if let streaming = streamingManager {
      await streaming.cancel()
      streamingManager = nil
    }
    await fluidAsrManager?.cleanup()
    fluidAsrManager = nil
    fluidModels = nil
    isReady = false
  }
}
