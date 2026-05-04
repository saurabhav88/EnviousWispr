import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

/// Hardcoded compute options optimized for Apple Silicon dictation.
/// Audio encoder + text decoder → Neural Engine, mel spectrogram → GPU.
private let dictationComputeOptions = ModelComputeOptions(
  melCompute: .cpuAndGPU,
  audioEncoderCompute: .cpuAndNeuralEngine,
  textDecoderCompute: .cpuAndNeuralEngine
)

/// WhisperKit ASR backend — broad language support with hardcoded dictation-optimized quality.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Decoding options and compute hardware allocation are hardcoded for optimal
/// dictation accuracy on Apple Silicon (Neural Engine for encoder/decoder).
///
/// The model must be downloaded via WhisperKitSetupService before calling prepare().
public actor WhisperKitBackend: ASRBackend {
  public private(set) var isReady = false

  // BRAIN: gotcha id=default-model-turbo-v20240930
  private let modelVariant: String = WhisperKitBackend.defaultModelVariant()
  private var whisperKit: WhisperKit?

  /// Exposes the configured model variant name (e.g. `openai_whisper-large-v3-v20240930_turbo`).
  /// Read-only; used by telemetry to tag per-transcription events with the model in use.
  package var modelVariantName: String { modelVariant }

  package init() {}

  /// Single source of truth for the shipped default model variant.
  package static func defaultModelVariant() -> String {
    "openai_whisper-large-v3-v20240930_turbo"
  }

  public func prepare() async throws {
    guard !isReady else { return }  // Idempotent — skip if already loaded

    // Use cached model path from WhisperKitSetupService (no network call).
    // Falls back to WhisperKit.download() if path not found (handles edge cases
    // like user-initiated record when cache was cleared).
    let modelPath: String
    if let cached = WhisperKitSetupService.getLocalModelPath(variant: modelVariant) {
      modelPath = cached
    } else {
      let folder = try await WhisperKit.download(variant: modelVariant, progressCallback: nil)
      modelPath = folder.path
    }

    try await loadFromPath(modelPath)
  }

  /// Load model from local cache only. Returns false if model is not cached
  /// OR if the cached directory is incomplete (missing one of the required
  /// `.mlmodelc` artifacts). Partial-download detection is enforced upstream in
  /// `WhisperKitSetupService.getLocalModelPath`, so a non-nil path here implies
  /// the artifacts are all present. Used by silent/background warmup paths
  /// that must never trigger a network download.
  package func prepareIfCached() async throws -> Bool {
    guard !isReady else { return true }
    guard let cached = WhisperKitSetupService.getLocalModelPath(variant: modelVariant) else {
      return false  // Model not cached or cache incomplete — skip silently.
    }
    try await loadFromPath(cached)
    return true
  }

  /// WhisperKit 0.12+ model folder artifacts required for a successful load.
  /// Aligned with `WhisperKit.loadModels()` at
  /// `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift:372-381`
  /// — it hard-fails when any of these three are missing. `TextDecoderContextPrefill`
  /// is intentionally excluded: upstream loads it conditionally and tolerates its
  /// absence, so requiring it here would over-reject otherwise-valid caches.
  /// Scope: `.mlmodelc` layout only; our shipped variant is produced by
  /// `WhisperKit.download` which emits this format. `.mlpackage` caches (not used
  /// by our product) are not modeled here.
  internal static let requiredArtifacts: [String] = [
    "AudioEncoder.mlmodelc",
    "MelSpectrogram.mlmodelc",
    "TextDecoder.mlmodelc",
  ]

  /// Canonical inner-file marker that a CoreML compiled-model bundle is complete.
  /// Hugging Face downloads each `.mlmodelc` subfile individually, so an interrupted
  /// pull can leave the outer directory present but its contents partial. Checking
  /// `coremldata.bin` (always the first write Apple's compiler emits at the root of
  /// the bundle) rules out the common "outer dir created, inner files missing" state
  /// without coupling to CoreML's full internal layout.
  internal static let artifactCompletionMarker = "coremldata.bin"

  /// Returns true iff every required `.mlmodelc` artifact exists and contains the
  /// completion marker. Used as a proactive partial-download guard so silent
  /// pre-load (and `detectState`) can distinguish "incomplete cache" from "ready."
  internal static func hasRequiredArtifacts(at modelFolder: String) -> Bool {
    let fm = FileManager.default
    for name in requiredArtifacts {
      let artifactPath = (modelFolder as NSString).appendingPathComponent(name)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: artifactPath, isDirectory: &isDir), isDir.boolValue else {
        return false
      }
      let markerPath = (artifactPath as NSString).appendingPathComponent(artifactCompletionMarker)
      if !fm.fileExists(atPath: markerPath) { return false }
    }
    return true
  }

  private func loadFromPath(_ modelPath: String) async throws {
    let config = WhisperKitConfig(
      model: modelVariant,
      modelFolder: modelPath,
      computeOptions: dictationComputeOptions,
      download: false
    )
    let kit = try await WhisperKit(config)
    self.whisperKit = kit
    isReady = true
  }

  public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    guard isReady, let kit = whisperKit else { throw ASRError.notReady }

    let paddedSamples = Self.padAudioWithSilence(audioSamples)
    let decodeOptions = makeDecodeOptions(from: options, sampleCount: paddedSamples.count)
    let startTime = CFAbsoluteTimeGetCurrent()
    let results: [TranscriptionResult]
    do {
      results = try await kit.transcribe(audioArray: paddedSamples, decodeOptions: decodeOptions)
    } catch {
      throw ASRError.transcriptionFailed(error.localizedDescription)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    return mapResults(results, processingTime: elapsed)
  }

  public func unload() async {
    whisperKit = nil
    isReady = false
  }

  // MARK: - Private

  // R2 (#360): vend an opaque incremental session so Pipeline does not need
  // the WhisperKit handle. Returns nil when the model is not loaded; caller
  // must treat as "incremental unavailable" and fall back to batch transcribe
  // (which itself will throw `ASRError.notReady` if the model is also nil —
  // both paths gate on the same `whisperKit` reference). See
  // `docs/feature-requests/issue-360-2026-04-30-r2-approach-c-plus-lid-split.md`
  // §9 for the honest fallback semantics.
  package func makeIncrementalSession(options: TranscriptionOptions)
    async -> (any WhisperKitIncrementalSession)?
  {
    guard let kit = whisperKit else { return nil }
    let opts = makeDecodeOptions(from: options, sampleCount: 0)
    return WhisperKitIncrementalWorker(whisperKit: kit, decodingOptions: opts)
  }

  // R2 (#360): vend Sendable LID observations so the non-Sendable WhisperKit
  // handle never crosses an actor boundary. The window-loop logic is
  // migrated verbatim from `LanguageDetector.runMultiWindowLID` (the previous
  // owner). The classifier in `LanguageDetector` consumes the resulting
  // `LIDObservationBatch` and runs the same five-layer decision logic.
  //
  // Window construction (start/end indices, fixed windows, full-window cap,
  // dedup, prefix-4) MUST match the original to preserve characterization
  // (per `Tests/EnviousWisprASRTests/R2/R2CharacterizationTests.swift`).
  package func observeLID(
    samples: [Float],
    maxWindows: Int
  ) async -> LIDObservationBatch {
    guard let kit = whisperKit else { return .unavailable }

    let sampleRate = LanguageDetectorThresholds.sampleRate
    let totalSamples = samples.count
    var windows: [[Float]] = []
    var seenRanges: Set<[Int]> = []

    func appendIfNew(_ startIdx: Int, _ endIdx: Int) {
      guard endIdx > startIdx else { return }
      guard seenRanges.insert([startIdx, endIdx]).inserted else { return }
      windows.append(Array(samples[startIdx..<endIdx]))
    }

    for w in LanguageDetectorThresholds.windows {
      let startIdx = min(totalSamples, Int(w.start * Double(sampleRate)))
      let endIdx = min(totalSamples, Int(w.end * Double(sampleRate)))
      appendIfNew(startIdx, endIdx)
    }
    let fullEnd = min(
      totalSamples, Int(LanguageDetectorThresholds.fullWindowMaxSec * Double(sampleRate)))
    appendIfNew(0, fullEnd)
    guard !windows.isEmpty else {
      return .noWindows
    }

    let capped = Array(windows.prefix(maxWindows))

    // WhisperKit's `detectLangauge` returns a single-entry `langProbs` map
    // `{detectedLanguage: logProb}` — argmax + its log-softmax. Per-window
    // collection here; aggregation (vote-count + mean prob) lives in the
    // classifier.
    var observations: [RawLIDObservation] = []
    var lastError: String?
    for (i, window) in capped.enumerated() {
      if Task.isCancelled { return .cancelled }
      let result: (language: String, langProbs: [String: Float])
      do {
        // WhisperKit API is `detectLangauge(audioArray:)` (original typo
        // preserved upstream — do not "fix" it).
        result = try await kit.detectLangauge(audioArray: window)
      } catch is CancellationError {
        return .cancelled
      } catch {
        lastError = error.localizedDescription
        await AppLogger.shared.log(
          "LID window \(i) failed: \(error.localizedDescription)",
          level: .info, category: "WhisperKitBackend"
        )
        continue
      }
      let lang = result.language
      let lp = Double(result.langProbs[lang] ?? 0)
      observations.append(RawLIDObservation(argmaxLang: lang, logProb: lp))
    }

    if observations.isEmpty {
      return .error(reason: lastError ?? "all_windows_failed")
    }
    return .observations(observations)
  }

  // Called by WhisperKitPipeline in EnviousWisprPipeline. `package` access is
  // sufficient: both targets live in the same SPM package, so no `public`
  // exposure is needed.
  package func makeDecodeOptions(from options: TranscriptionOptions, sampleCount: Int)
    -> DecodingOptions
  {
    var opts = DecodingOptions()

    // Shared options (from TranscriptionOptions)
    opts.language = options.language
    // When the caller cannot specify a language, ask WhisperKit to detect it.
    // WhisperKit's library default is `detectLanguage = !usePrefillPrompt`; with
    // prefill on (we keep it on for performance on the known-language path) the
    // default resolves to false, and nil-language silently English-prefills via
    // `Constants.defaultLanguageCode` (TextDecoder.swift:183). Opt into detect
    // explicitly only when language is nil. This mirrors WhisperKit's own
    // auto-detect gate (TranscribeTask.swift:341 checks `language == nil`).
    // BRAIN: gotcha id=detect-language-when-nil
    opts.detectLanguage = (options.language == nil)
    opts.wordTimestamps = options.enableTimestamps

    // Hardcoded dictation-optimized defaults
    opts.temperature = 0.0
    opts.temperatureFallbackCount = 3
    opts.temperatureIncrementOnFallback = 0.2
    opts.compressionRatioThreshold = 2.4
    opts.logProbThreshold = -1.0
    opts.noSpeechThreshold = 0.6
    opts.skipSpecialTokens = true
    opts.suppressBlank = true
    opts.usePrefillPrompt = true

    // Use VAD chunking for long recordings to prevent hallucinated repetitions
    let thirtySeconds = 16000 * 30  // 480_000 samples
    // BRAIN: gotcha id=vad-chunking-30s
    opts.chunkingStrategy = sampleCount > thirtySeconds ? .vad : ChunkingStrategy.none

    // Disable windowClipTime (default 1.0s) which skips the last 1s of audio.
    // We pad audio with silence instead, which provides the look-ahead context
    // the decoder needs without sacrificing real content.
    // BRAIN: gotcha id=window-clip-time-zero
    opts.windowClipTime = 0

    return opts
  }

  /// Pads audio with trailing silence so the Whisper decoder has look-ahead context
  /// at the end of speech. Without this, abruptly-ending audio loses the last 1-3 words.
  // BRAIN: gotcha id=silence-padding
  private static let silencePaddingSamples = Int(0.5 * 16000)  // 500ms at 16kHz

  static func padAudioWithSilence(_ samples: [Float]) -> [Float] {
    var padded = samples
    padded.append(contentsOf: [Float](repeating: 0, count: silencePaddingSamples))
    return padded
  }

  private func mapResults(_ results: [TranscriptionResult], processingTime: TimeInterval)
    -> ASRResult
  {
    let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    let language = results.first?.language

    let duration: TimeInterval =
      if let lastSeg = results.last?.segments.last {
        TimeInterval(lastSeg.end)
      } else {
        0
      }

    return ASRResult(
      text: text,
      language: language,
      duration: duration,
      processingTime: processingTime,
      backendType: .whisperKit
    )
  }
}
