import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

// FIXME(#827): founder/upstream action needed. WhisperKit/CoreML must expose
// model-load, LID-window, and decoder-step progress signals before this backend
// can add real signal-based watchdog recovery without wall-clock timeouts.

/// Hardcoded compute options optimized for Apple Silicon dictation.
/// Audio encoder + text decoder + mel spectrogram → GPU (#879 Phase C).
///
/// Moved encoder/decoder off the Neural Engine: the ANE path runs a from-scratch
/// Espresso→ANE AOT compile on a cold/OS-update-wiped cache that measured ~109s,
/// blocking the first press behind a long "preparing" window. The GPU path
/// compiles ~13s cold (measured 2026-06-01) with no first-inference penalty
/// (ASR 0.70s vs 0.75s) and verbatim jfk output, so the launch warm-up wins the
/// race against the user's first press. `.cpuAndGPU` requests CPU/GPU placement
/// and avoids requesting the Neural Engine; CoreML maps that choice per
/// `MLComputeUnits` semantics on each device (WhisperKit forces CPU-only on the
/// Simulator). The transcript-quality parity vs the prior ANE path is verified
/// by live UAT before merge (#879 Phase C gate).
private let dictationComputeOptions = ModelComputeOptions(
  melCompute: .cpuAndGPU,
  audioEncoderCompute: .cpuAndGPU,
  textDecoderCompute: .cpuAndGPU
)

/// WhisperKit ASR backend — broad language support with hardcoded dictation-optimized quality.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Decoding options and compute hardware allocation are hardcoded for optimal
/// dictation accuracy on Apple Silicon (GPU for mel/encoder/decoder — #879
/// Phase C; the prior Neural Engine path cold-compiled ~109s on a wiped cache).
///
/// The model must be downloaded via WhisperKitSetupService before calling prepare().
public actor WhisperKitBackend: ASRBackend {
  public private(set) var isReady = false

  // BRAIN: gotcha id=default-model-turbo-v20240930
  private let modelVariant: String = WhisperKitBackend.defaultModelVariant()
  private var whisperKit: WhisperKit?

  /// Issue #445: single-flight guard for `prepare()`/`prepareIfCached()`.
  /// Prevents duplicate `MLModel.load` work when the pipeline watchdog
  /// cancels its host await and a subsequent press calls `prepare()` again
  /// before the first one's background load returns. CoreML model loading is
  /// uncancellable cooperatively, so we cannot stop the in-flight load — but
  /// we can stop it from doubling. #1275: both `prepare()` and
  /// `prepareIfCached()` now join this SAME task via `loadIfNeeded(resolveModelPath:)` —
  /// previously `prepareIfCached()` called `loadFromPath` directly, bypassing
  /// the guard.
  private var loadTask: Task<Void, Error>?

  /// #1275 (Codex r2 P2): monotonic generation stamp, mirroring
  /// `ASRManagerProxy.loadGeneration` (`ASRManagerProxy.swift:53`). Bumped by
  /// `unload()` so a `loadFromPath` in-flight at unload time can never write
  /// `isReady = true` after the fact on a since-cleared `whisperKit`.
  private var loadGeneration: UInt64 = 0

  /// #1275 item A: outcome of the silent warm-up inference run at load time.
  private enum WarmupOutcome: Sendable {
    case completed(ms: Int)
    case threw(desc: String)
  }

  /// Handle to the in-flight (or, after a fail-open timeout, orphaned)
  /// warm-up task. Drained — never blindly awaited — by
  /// `readyKitAfterWarmupDrain()`, the single gate every shared-instance
  /// caller (`transcribe`/`observeLID`/`makeIncrementalSession`) must pass
  /// through before touching `whisperKit`.
  private var warmupTask: Task<WarmupOutcome, Never>?

  /// The `loadGeneration` value `warmupTask` belongs to. `nil` when no task
  /// is tracked. Consolidates what was a separate `warmupToken` counter
  /// (adversarial-review finding, #1275) into the SAME generation stamp
  /// `unload()` already bumps: a `warmupTask` left behind by a load that has
  /// since been superseded (by `unload()`, not just by a newer warm-up
  /// within the same load) is now recognizable as stale by comparing this
  /// against the CURRENT `loadGeneration` — not just against a later
  /// warm-up's own token. This closes a race the separate-counter version
  /// missed: `readyKitAfterWarmupDrain()` would otherwise await a fail-open
  /// timeout on an ORPHANED warm-up from a load that `unload()` already
  /// discarded, while a completely independent newer load is still in its
  /// (multi-second) CoreML load phase — turning what should be an immediate
  /// "not ready yet" into a 20-second stall on irrelevant background work.
  private var warmupTaskGeneration: UInt64?

  /// Duration of the most recent warm-up inference, in milliseconds. `nil`
  /// when no warm-up has completed yet (still loading, threw, or timed out).
  /// Read by telemetry as an optional property on the existing
  /// `coldstart.warmup_completed` event — absent for pre-#1275 rows and for
  /// Parakeet (query by presence, never a new event).
  package private(set) var lastWarmupInferenceMs: Int?

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

    let variant = modelVariant
    try await loadIfNeeded {
      // Use cached model path from WhisperKitSetupService (no network call).
      // Falls back to WhisperKit.download() if path not found (handles edge cases
      // like user-initiated record when cache was cleared).
      if let cached = WhisperKitSetupService.getLocalModelPath(variant: variant) {
        return cached
      }
      // TODO(#827): watchdog needs WhisperKit download progress wired into
      // this fallback path if product keeps allowing first-record downloads.
      let folder = try await WhisperKit.download(variant: variant, progressCallback: nil)
      return folder.path
    }
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
    try await loadIfNeeded { cached }
    return true
  }

  /// Issue #445 + #1275: single owner of the `loadTask` single-flight
  /// lifecycle for BOTH `prepare()` and `prepareIfCached()`. Previously
  /// `prepareIfCached()` called `loadFromPath` directly, bypassing this
  /// guard — a latent double-load race (documented at
  /// `WhisperKitEngineAdapter.swift` near the `prepareIfCached` call site).
  /// If a prior load is still in flight (e.g. its host await was cancelled
  /// by the pipeline watchdog but the underlying CoreML load is still
  /// grinding), join the existing task instead of spawning a parallel load.
  private func loadIfNeeded(resolveModelPath: @escaping @Sendable () async throws -> String)
    async throws
  {
    if let existing = loadTask {
      try await existing.value
      return
    }

    let task = Task<Void, Error> {
      let modelPath = try await resolveModelPath()
      try await loadFromPath(modelPath)
    }
    loadTask = task
    do {
      try await task.value
      loadTask = nil
    } catch {
      loadTask = nil
      throw error
    }
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
    // #1275 (Codex r2 P2): capture the generation before any await. `unload()`
    // bumps it, so a load/warm-up whose completion races an unload can never
    // resurrect `isReady = true` on a since-cleared `whisperKit` — the same
    // established pattern `ASRManagerProxy.loadGeneration` uses for the
    // identical class of race (`ASRManagerProxy.swift:53`), reused here
    // rather than inventing a new mechanism.
    let gen = loadGeneration

    let config = WhisperKitConfig(
      model: modelVariant,
      modelFolder: modelPath,
      computeOptions: dictationComputeOptions,
      download: false
    )
    // Load-duration timing + the hang signal for this in-process WhisperKit load
    // already exist: `ensureEngineWarm` emits `coldstart.warmup_started` /
    // `_completed {duration_ms}` / `_failed` (and `launch.model_preload_completed`)
    // for the launch / engine-swap paths where the model actually cold-loads, so
    // a hang shows up as `warmup_started` with no terminal. What is still missing
    // is a FINE-GRAINED progress callback: upstream `WhisperKit(config)` exposes
    // no per-step load progress, so an automatic hang WATCHDOG stays deferred for
    // lack of a defended-timeout distribution — NOT for lack of timing data. Do
    // not wrap this in a wall-clock timeout (timeout-numbers-need-distribution-evidence).
    let kit = try await WhisperKit(config)
    guard gen == loadGeneration else { throw ASRLoadSupersededError() }
    self.whisperKit = kit

    // #1275 item A: one silent warm-up inference before flipping isReady, so
    // the first real press never pays the (path-dependent) first-decode
    // penalty measured 2026-07-02. Fails open — a throw or timeout still
    // flips isReady, since the model IS loaded and usable; only the
    // first-press latency win is lost.
    await runWarmup(kit: kit, generation: gen)
    guard gen == loadGeneration else { throw ASRLoadSupersededError() }
    isReady = true
  }

  /// Runs the silent warm-up inference (1s of digital silence, decoded
  /// through the SAME production option builder every real transcribe call
  /// uses) and records its terminal status. Wrapped in a 20s fail-open
  /// deadline (founder-approved exception to timeout-numbers-into-evidence,
  /// #1275 Gate 2 — this bounds an invisible background task, never a
  /// user-facing wait; a too-large value costs nothing in the healthy case,
  /// a too-small value merely reverts to today's behavior). On timeout the
  /// task handle is left in `warmupTask` for `readyKitAfterWarmupDrain()` to
  /// drain later — never re-awaited here, since `withDeadline` abandons it.
  /// `generation` is the `loadGeneration` this warm-up belongs to (captured
  /// by the caller, `loadFromPath`, before any await).
  private func runWarmup(kit: WhisperKit, generation: UInt64) async {
    // Codex r1 P3: clear the PREVIOUS load's value before this run — only
    // `.completed` below sets a fresh one, so a throw/timeout on THIS load
    // must not leave a prior load's stale duration attached to telemetry.
    lastWarmupInferenceMs = nil

    let silence = [Float](repeating: 0, count: 16_000)  // 1s at 16kHz
    let opts = makeDecodeOptions(from: .default, sampleCount: silence.count)

    let task = Task<WarmupOutcome, Never> {
      let start = CFAbsoluteTimeGetCurrent()
      do {
        _ = try await kit.transcribe(audioArray: silence, decodeOptions: opts)
        return .completed(ms: Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
      } catch {
        return .threw(desc: error.localizedDescription)
      }
    }
    warmupTask = task
    warmupTaskGeneration = generation

    guard let outcome = await withDeadline(seconds: 20, operation: { await task.value }) else {
      await AppLogger.shared.log(
        "WhisperKit warm-up: timed_out (20s fail-open ceiling)",
        level: .info, category: "WhisperKitBackend"
      )
      return
    }

    // Per actor-reentrancy-await: only clear the handle — and only record the
    // outcome — if this generation is still the one `warmupTask` is tracking
    // (no interleaved unload/reload replaced it during this await). Without
    // this check, an abandoned load's late completion could overwrite a
    // NEWER load's `lastWarmupInferenceMs` with stale data (the same class
    // of race Codex r2 P2 found for `isReady`, closed here too).
    guard warmupTaskGeneration == generation else { return }
    warmupTask = nil
    warmupTaskGeneration = nil

    switch outcome {
    case .completed(let ms):
      lastWarmupInferenceMs = ms
      await AppLogger.shared.log(
        "WhisperKit warm-up: completed(\(ms)ms)",
        level: .info, category: "WhisperKitBackend"
      )
    case .threw(let desc):
      await AppLogger.shared.log(
        "WhisperKit warm-up: threw(\(desc))",
        level: .info, category: "WhisperKitBackend"
      )
    }
  }

  /// Single vend gate for the shared `WhisperKit` instance. Every
  /// shared-instance caller (`transcribe`, `observeLID`,
  /// `makeIncrementalSession`) MUST obtain the kit through this helper, never
  /// by reading `whisperKit` directly, so a request can never race a
  /// straggling orphaned warm-up decode from a prior timeout (no proven
  /// concurrent-decode safety on one `WhisperKit` instance).
  ///
  /// Codex r1 P1: draining the orphan with NO deadline defeated the whole
  /// point of the 20s fail-open ceiling — a genuinely wedged warm-up would
  /// then block every subsequent press indefinitely instead of just its own
  /// decode. The drain reuses the SAME 20s fail-open budget; if it ALSO
  /// expires, the handle is cleared anyway and the kit is vended regardless
  /// (accepting the same theoretical concurrent-decode risk the design
  /// already documents as unproven-but-low-probability, rather than
  /// re-paying an unbounded wait on every future press).
  ///
  /// Adversarial-review finding (#1275): only drain a `warmupTask` that
  /// belongs to the CURRENT `loadGeneration`. A `warmupTask` left behind by
  /// a load `unload()` has since superseded is irrelevant to a request that
  /// arrives while a completely independent newer load is still in its
  /// (multi-second) CoreML load phase — draining it anyway meant such a
  /// request could pay up to 20 extra seconds waiting on background work for
  /// a model that no longer exists, instead of immediately falling through
  /// to `guard isReady` and returning nil.
  private func readyKitAfterWarmupDrain() async -> WhisperKit? {
    if let pending = warmupTask, warmupTaskGeneration == loadGeneration {
      let generation = loadGeneration
      let outcome = await withDeadline(seconds: 20, operation: { await pending.value })
      if warmupTaskGeneration == generation {
        warmupTask = nil
        warmupTaskGeneration = nil
        if outcome == nil {
          await AppLogger.shared.log(
            "WhisperKit warm-up: drain also timed_out after 20s — vending kit anyway",
            level: .info, category: "WhisperKitBackend"
          )
        }
      }
    }
    guard isReady else { return nil }
    return whisperKit
  }

  public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    guard let kit = await readyKitAfterWarmupDrain() else { throw ASRError.notReady }

    let paddedSamples = Self.padAudioWithSilence(audioSamples)
    let decodeOptions = makeDecodeOptions(from: options, sampleCount: paddedSamples.count)
    let startTime = CFAbsoluteTimeGetCurrent()
    let results: [TranscriptionResult]
    do {
      // TODO(#827): watchdog needs a decoder-step or token/segment progress
      // callback owned by WhisperKit; cancellation depends on this await
      // returning.
      results = try await kit.transcribe(audioArray: paddedSamples, decodeOptions: decodeOptions)
    } catch {
      throw ASRError.transcriptionFailed(error.localizedDescription)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    return mapResults(results, processingTime: elapsed)
  }

  public func unload() async {
    // #1275 (Codex r2 P2): supersede any in-flight loadFromPath BEFORE
    // clearing state, so its post-await guards see the bumped generation.
    loadGeneration &+= 1
    // Adversarial-review finding (#1275): also clear `loadTask` — mirrors
    // `ASRManagerProxy.unloadModel()`'s `inFlightLoadTask?.cancel(); nil`
    // (`ASRManagerProxy.swift:226,233-234`). Without this, a `prepare()`
    // called right after `unload()` would join the now-doomed task via
    // `loadIfNeeded`'s single-flight join instead of starting a fresh load —
    // the doomed task's generation check (`loadFromPath`) throws
    // `ASRLoadSupersededError`, which would then wrongly fail a legitimate
    // new load request instead of ever starting one. Cancellation is
    // best-effort (CoreML loading is uncancellable cooperatively); nil-ing
    // the handle is what actually matters.
    loadTask?.cancel()
    loadTask = nil
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
    guard let kit = await readyKitAfterWarmupDrain() else { return nil }
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
    guard let kit = await readyKitAfterWarmupDrain() else { return .unavailable }

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
        // TODO(#827): watchdog needs a within-window LID progress callback
        // owned by WhisperKit; cancellation is only checked between windows.
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

    // VAD-driven clip seek: feed only voiced ranges to the decoder.
    // Each pair is (startSec, endSec) in WhisperKit's expected sample-rate space.
    if !options.speechSegments.isEmpty {
      let sampleRate = Float(WhisperKit.sampleRate)
      var clipTimestamps: [Float] = []
      clipTimestamps.reserveCapacity(options.speechSegments.count * 2)
      var didClamp = false
      for segment in options.speechSegments {
        // Safety clamp (#827): a segment whose bounds exceed the audio length
        // makes WhisperKit's clip seek select an out-of-range window and throw
        // "Audio samples are nil". The primary fix (single capture-coordinate
        // source) keeps segments in range, so this clamp must never fire in
        // normal operation — if it does, a coordinate regression has returned
        // and the log below is the signal. Clamp bounds into [0, sampleCount]
        // but preserve the segment (including in-range zero-width pairs, which
        // are a long-standing contract — WhisperKit tolerates [t, t]).
        let start = max(0, min(segment.startSample, sampleCount))
        let end = max(start, min(segment.endSample, sampleCount))
        if segment.startSample != start || segment.endSample != end { didClamp = true }
        clipTimestamps.append(Float(start) / sampleRate)
        clipTimestamps.append(Float(end) / sampleRate)
      }
      if didClamp {
        let requestedMax = options.speechSegments.map(\.endSample).max() ?? 0
        Task {
          await AppLogger.shared.log(
            "WARNING clipTimestamps clamped: requested max endSample=\(requestedMax) "
              + "audioSamples=\(sampleCount) — coordinate regression (#827)",
            level: .info, category: "WhisperKitBackend")
        }
      }
      opts.clipTimestamps = clipTimestamps
    }

    // Use VAD chunking for long recordings to prevent hallucinated repetitions.
    let thirtySeconds = Int(WhisperKit.sampleRate) * 30
    // BRAIN: gotcha id=vad-chunking-30s
    opts.chunkingStrategy = sampleCount > thirtySeconds ? .vad : ChunkingStrategy.none

    // Keep current behavior for this PR: WhisperKit's default 1.0 subtracts time
    // from the end of every seek clip, which can clip legitimate trailing speech
    // when clipTimestamps come from raw VAD segment ends.
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
