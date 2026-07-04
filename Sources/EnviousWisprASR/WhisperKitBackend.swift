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

/// WhisperKit conforms to the load-state machine's opaque model marker so the
/// consolidated `LoadState` can carry the instance without the machine depending
/// on WhisperKit (keeping `WhisperKitLoadState.swift` pure + WhisperKit-free).
extension WhisperKit: LoadedASRModel {}

/// WhisperKit ASR backend — broad language support with hardcoded dictation-optimized quality.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Decoding options and compute hardware allocation are hardcoded for optimal
/// dictation accuracy on Apple Silicon (GPU for mel/encoder/decoder — #879
/// Phase C; the prior Neural Engine path cold-compiled ~109s on a wiped cache).
///
/// The model must be downloaded via WhisperKitSetupService before calling prepare().
public actor WhisperKitBackend: ASRBackend {
  /// Protocol-required readiness, now COMPUTED from the single `loadState`
  /// authority (#1276 Step 1) — true iff the model is loaded AND its warm-up has
  /// resolved. Replaces the stored `isReady` bool that previously had to be
  /// hand-synced at six sites and could disagree with `whisperKit`.
  public var isReady: Bool { loadState.isReady }

  // BRAIN: gotcha id=default-model-turbo-v20240930
  private let modelVariant: String = WhisperKitBackend.defaultModelVariant()

  /// The single load-state authority (#1276 Step 1). Consolidates the nine
  /// former members (`whisperKit`, `isReady`, `loadTask`, `loadTaskSeq`,
  /// `activeLoadTaskID`, `loadGeneration`, `warmupTask`, `warmupTaskGeneration`,
  /// `warmupBudgetExhausted`) into one value; illegal combinations (kit non-nil
  /// while not ready, budget-spent forgotten, orphan warm-up with no generation)
  /// are unrepresentable. Mutated only through `WhisperKitLoadStateMachine.transition`.
  private var loadState: LoadState = .idle

  /// Monotonic generation stamp (former `loadGeneration`). Bumped by `unload()`
  /// BEFORE the teardown transition so a load/warm-up completing after an unload
  /// is recognizably stale. Lives OUTSIDE `loadState` because it must be
  /// capturable at load-task creation time — before the enum transitions — which
  /// is the #1282 fix (capture the generation before the `resolveModelPath`
  /// await, not after).
  private var generation: UInt64 = 0

  /// Monotonic id source (former `loadTaskSeq`) distinguishing concurrent load
  /// tasks so a superseded load's late cleanup can't clobber a newer load.
  private var loadSeq: UInt64 = 0

  /// Duration of the most recent warm-up inference, in milliseconds. `nil`
  /// when no warm-up has completed yet (still loading, threw, or timed out).
  /// Read by telemetry as an optional property on the existing
  /// `coldstart.warmup_completed` event — absent for pre-#1275 rows and for
  /// Parakeet (query by presence, never a new event).
  package private(set) var lastWarmupInferenceMs: Int?

  /// Test-only injection of the two operations that need a real `WhisperKit`
  /// (building the kit from a path; running the silent warm-up inference). `nil`
  /// in production — the real paths run. Lets the actor's load/warm-up/unload
  /// ORCHESTRATION (single-flight, generation staleness, fail-open budget,
  /// two-consumer) be exercised without a real model. `internal` (not `package`)
  /// so it never leaks past the ASR module; tests reach it via `@testable import`.
  struct TestSeams {
    let loadModel: @Sendable (String) async throws -> any LoadedASRModel
    /// The kit is deliberately NOT passed in — a self-isolated non-Sendable kit
    /// can't cross into a `@Sendable` closure, and tests drive the outcome, not
    /// the kit. Production's real warm-up uses the kit directly (see `performWarmup`).
    let runWarmup: @Sendable () async -> WarmupOutcome
    /// Fail-open warm-up deadline. Production is 20s; tests shrink it so the
    /// timeout path is signal-fast, not a real 20s wait.
    var warmupDeadlineSeconds: Double = 20
  }
  private let testSeams: TestSeams?

  /// Fail-open warm-up ceiling (seconds). Bounds an invisible background task,
  /// never a user-facing wait (founder-approved exception to
  /// timeout-numbers-need-distribution-evidence, #1275 Gate 2).
  private var warmupDeadlineSeconds: Double { testSeams?.warmupDeadlineSeconds ?? 20 }

  /// Exposes the configured model variant name (e.g. `openai_whisper-large-v3-v20240930_turbo`).
  /// Read-only; used by telemetry to tag per-transcription events with the model in use.
  package var modelVariantName: String { modelVariant }

  package init() { self.testSeams = nil }

  /// Test-only initializer that injects fake load/warm-up operations.
  init(testSeams: TestSeams) { self.testSeams = testSeams }

  /// Snapshot of the current load phase, for tests to assert orchestration
  /// outcomes without touching private state.
  var loadPhaseForTesting: LoadPhase { loadState.phase }

  /// Test-only: drive the load single-flight with an INJECTED resolver, so tests
  /// avoid the real `WhisperKitSetupService` / network resolver `prepare()` uses.
  /// Pairs with `TestSeams` (which fakes the kit build + warm-up).
  func loadForTesting(resolveModelPath: @escaping @Sendable () async throws -> String)
    async throws
  {
    try await loadIfNeeded(resolveModelPath: resolveModelPath)
  }

  /// Test-only: run the vend gate and report the resulting phase (the fake kit
  /// can't be a real `WhisperKit`, so the returned kit is not observable — the
  /// phase transition is what tests assert on).
  func vendForTesting() async -> LoadPhase {
    _ = await readyKitAfterWarmupDrain()
    return loadState.phase
  }

  /// Single source of truth for the shipped default model variant.
  package static func defaultModelVariant() -> String {
    "openai_whisper-large-v3-v20240930_turbo"
  }

  public func prepare() async throws {
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
    if loadState.isReady { return true }
    guard let cached = WhisperKitSetupService.getLocalModelPath(variant: modelVariant) else {
      return false  // Model not cached or cache incomplete — skip silently.
    }
    try await loadIfNeeded { cached }
    return true
  }

  // MARK: - Load-state orchestration (#1276 Step 1)

  /// Advance the state machine by one event: apply the returned state, run its
  /// SYNCHRONOUS side-effects (logging, telemetry, task cancellation), and return
  /// the ORCHESTRATION effects (`beginLoad`/`joinLoad`/`beginWarmup`/`beginDrain`/
  /// `throwSuperseded`) for the async caller to drive. State is mutated BEFORE any
  /// logging await, so a reentrant read never sees a stale phase
  /// ([[actor-reentrancy-await]]).
  @discardableResult
  private func emit(_ event: LoadEvent) async -> [Effect] {
    let (next, effects) = WhisperKitLoadStateMachine.transition(
      loadState, on: event, generation: generation)
    loadState = next
    for effect in effects { await runSideEffect(effect) }
    return effects
  }

  /// Executes the synchronous effects (cancel / log / telemetry). Orchestration
  /// effects are no-ops here — the async caller drives them.
  private func runSideEffect(_ effect: Effect) async {
    switch effect {
    case .cancelLoadTask(let task): task.cancel()
    case .cancelWarmupTask(let task): task.cancel()
    case .cancelOrphanWarmupOnUnload(let task): task.cancel()
    case .recordWarmupMs(let ms):
      lastWarmupInferenceMs = ms
      await AppLogger.shared.log(
        "WhisperKit warm-up: completed(\(ms)ms)", level: .info, category: "WhisperKitBackend")
    case .logWarmupThrew(let desc):
      await AppLogger.shared.log(
        "WhisperKit warm-up: threw(\(desc))", level: .info, category: "WhisperKitBackend")
    case .logWarmupTimedOut:
      await AppLogger.shared.log(
        "WhisperKit warm-up: timed_out (20s fail-open ceiling)",
        level: .info, category: "WhisperKitBackend")
    case .logBudgetExhaustedVend:
      await AppLogger.shared.log(
        "WhisperKit warm-up: budget already exhausted — vending kit without re-draining",
        level: .info, category: "WhisperKitBackend")
    case .logDrainTimedOutVend:
      await AppLogger.shared.log(
        "WhisperKit warm-up: drain also timed_out after 20s — vending kit anyway",
        level: .info, category: "WhisperKitBackend")
    case .beginLoad, .joinLoad, .beginWarmup, .beginDrain, .throwSuperseded:
      break  // orchestration — driven by the async caller
    }
  }

  /// Single owner of the load single-flight lifecycle for BOTH `prepare()` and
  /// `prepareIfCached()` (#445 + #1275). Consults the state machine's
  /// `prepareRequested` decision: already-ready → return; a load in flight → join
  /// it (never a second CoreML load); idle → start one.
  private func loadIfNeeded(resolveModelPath: @escaping @Sendable () async throws -> String)
    async throws
  {
    let effects = await emit(.prepareRequested)
    for effect in effects {
      switch effect {
      case .joinLoad(let task):
        try await task.value
        return
      case .beginLoad:
        try await startLoad(resolveModelPath: resolveModelPath)
        return
      default:
        break
      }
    }
    // No orchestration effect → already ready; nothing to do.
  }

  /// Creates the load task and records it (idle → loading). Captures the
  /// generation + id BEFORE the `resolveModelPath` await runs (the #1282 fix):
  /// the identity carries the pre-await generation, so an `unload()` during
  /// `resolveModelPath` bumps `generation` and the later `loadSucceeded` guard
  /// recognizes this load as stale. The single-flight handle cleanup lives in
  /// `runLoad`'s terminal transitions (loadFailed → idle / loadSucceeded → warming).
  private func startLoad(resolveModelPath: @escaping @Sendable () async throws -> String)
    async throws
  {
    let capturedGeneration = generation  // #1282: capture BEFORE any await
    loadSeq &+= 1
    let identity = LoadIdentity(generation: capturedGeneration, id: loadSeq)
    let task = Task<Void, Error> {
      try await self.runLoad(resolveModelPath: resolveModelPath, identity: identity)
    }
    await emit(.loadStarted(identity, task: task))  // → .loading
    try await task.value
  }

  /// The load task body: resolve the path, build the kit, then hand off to the
  /// warm-up phase. Every terminal feeds an event into the state machine, which
  /// owns the staleness decision (a completion racing an `unload()` is dropped by
  /// generation comparison — the actor never re-checks staleness itself).
  private func runLoad(
    resolveModelPath: @escaping @Sendable () async throws -> String, identity: LoadIdentity
  ) async throws {
    let modelPath: String
    do {
      modelPath = try await resolveModelPath()
    } catch {
      await emit(.loadFailed(identity))
      throw error
    }
    let kit: any LoadedASRModel
    do {
      kit = try await performLoad(modelPath)
    } catch {
      await emit(.loadFailed(identity))
      throw error
    }
    for effect in await emit(.loadSucceeded(kit: kit, identity)) {
      switch effect {
      case .throwSuperseded:
        throw ASRLoadSupersededError()
      case .beginWarmup(let warmKit, let warmGeneration):
        try await runWarmupPhase(kit: warmKit, generation: warmGeneration)
      default:
        break
      }
    }
  }

  /// Runs the silent warm-up inference (loading → warming → ready). One silent
  /// decode before `isReady` flips, so the first real press never pays the
  /// first-decode penalty (#1275 item A). Fails open under a 20s deadline: on
  /// timeout the model is still vendable, the orphan task rides in
  /// `.ready(staleWarmup:)`, and its budget is marked spent so no caller ever
  /// pays the 20s twice. The 20s ceiling bounds an invisible background task,
  /// never a user-facing wait (founder-approved exception to
  /// timeout-numbers-need-distribution-evidence, #1275 Gate 2).
  private func runWarmupPhase(kit: any LoadedASRModel, generation warmGeneration: UInt64)
    async throws
  {
    // Invariant #7: clear the previous load's value before this run — only a
    // clean completion records a fresh one, so a throw/timeout must not leave a
    // prior load's stale duration attached to telemetry.
    lastWarmupInferenceMs = nil

    let warmupTask = Task<WarmupOutcome, Never> { await self.performWarmup(kit) }
    await emit(.warmupStarted(kit: kit, generation: warmGeneration, warmupTask: warmupTask))
    // If the warm-up was superseded before it could be recorded, `emit` cancelled
    // the just-created task and the state is not `.warming` — bail as superseded.
    guard case .warming = loadState else { throw ASRLoadSupersededError() }

    if let outcome = await withDeadline(
      seconds: warmupDeadlineSeconds, operation: { await warmupTask.value })
    {
      await emit(.warmupResolved(outcome, generation: warmGeneration))
    } else {
      // Codex code-diff review (#1275): the timeout marks this generation's
      // budget spent (via `.warmupTimedOut` → `.ready(staleWarmup: budgetSpent)`)
      // so the vend gate never re-awaits the same stuck task with a fresh 20s.
      await emit(.warmupTimedOut(generation: warmGeneration))
    }

    // Codex code-diff r1: if an `unload()` raced this warm-up await, the state
    // machine already ignored the (stale) resolve/timeout event and moved the
    // backend to `.idle`. Without this guard `runWarmupPhase` would return
    // NORMALLY, so `prepare()`/`prepareIfCached()` would report success while the
    // backend is actually unloaded (`isReady == false`). Mirror the old
    // post-warm-up generation guard: a load whose generation no longer matches
    // the live one throws superseded rather than falsely reporting ready.
    guard warmGeneration == generation else { throw ASRLoadSupersededError() }
  }

  /// Builds the WhisperKit instance from a model path. Test seam overrides it so
  /// the load orchestration is exercisable without a real model.
  private func performLoad(_ modelPath: String) async throws -> any LoadedASRModel {
    if let seams = testSeams { return try await seams.loadModel(modelPath) }
    let config = WhisperKitConfig(
      model: modelVariant,
      modelFolder: modelPath,
      computeOptions: dictationComputeOptions,
      download: false
    )
    // Load-duration timing + the hang signal for this in-process WhisperKit load
    // already exist via `ensureEngineWarm`'s `coldstart.warmup_*` events; what is
    // missing is a FINE-GRAINED progress callback (upstream `WhisperKit(config)`
    // exposes no per-step load progress), so an automatic hang WATCHDOG stays
    // deferred for lack of a defended-timeout distribution — NOT for lack of
    // timing data. Do NOT wrap this in a wall-clock timeout
    // (timeout-numbers-need-distribution-evidence).
    return try await WhisperKit(config)
  }

  /// Runs one silent warm-up decode (1s of digital silence through the SAME
  /// production option builder every real transcribe uses). Test seam overrides
  /// it so the warm-up orchestration is exercisable without a real model.
  private func performWarmup(_ kit: any LoadedASRModel) async -> WarmupOutcome {
    if let seams = testSeams { return await seams.runWarmup() }
    guard let wk = kit as? WhisperKit else {
      return .threw(desc: "warm-up skipped: model is not a WhisperKit instance")
    }
    let silence = [Float](repeating: 0, count: 16_000)  // 1s at 16kHz
    let opts = makeDecodeOptions(from: .default, sampleCount: silence.count)
    let start = CFAbsoluteTimeGetCurrent()
    do {
      _ = try await wk.transcribe(audioArray: silence, decodeOptions: opts)
      return .completed(ms: Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
    } catch {
      return .threw(desc: error.localizedDescription)
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

  /// Single vend gate for the shared `WhisperKit` instance. Every
  /// shared-instance caller (`transcribe`, `observeLID`,
  /// `makeIncrementalSession`) MUST obtain the kit through this helper, never
  /// by reading the state's kit directly, so a request can never race a
  /// straggling orphaned warm-up decode from a prior timeout (no proven
  /// concurrent-decode safety on one `WhisperKit` instance).
  ///
  /// The state machine's `vendRequested` decision (invariants #4/#5/#6):
  /// - clean ready → vend immediately;
  /// - ready with a budget-already-spent orphan → vend without re-draining
  ///   (`.logBudgetExhaustedVend`; the orphan handle is dropped by the transition),
  ///   so a caller never pays the 20s twice;
  /// - ready with an un-drained orphan, or mid-warming → drain the warm-up under
  ///   the SAME 20s fail-open budget, then re-read readiness. If the drain also
  ///   times out we vend anyway (`.logDrainTimedOutVend`), accepting the same
  ///   theoretical concurrent-decode risk the design documents as
  ///   unproven-but-low-probability rather than re-paying an unbounded wait.
  ///
  /// The generation carried on `.beginDrain`/`.drainResolved` means a drain whose
  /// warm-up belonged to a since-superseded load is dropped by the transition —
  /// the actor never re-checks staleness after the await.
  private func readyKitAfterWarmupDrain() async -> WhisperKit? {
    for effect in await emit(.vendRequested) {
      if case .beginDrain(let task, let drainGeneration) = effect {
        let outcome = await withDeadline(
          seconds: warmupDeadlineSeconds, operation: { await task.value })
        await emit(.drainResolved(didTimeOut: outcome == nil, generation: drainGeneration))
      }
    }
    return currentReadyKit()
  }

  /// The vendable `WhisperKit` iff the state is `.ready`, else nil. In production
  /// the ready kit is always a `WhisperKit`; the downcast fails only under a test
  /// seam that injected a fake, which never drives the real transcribe path.
  private func currentReadyKit() -> WhisperKit? {
    guard case .ready(let kit, _) = loadState else { return nil }
    return kit as? WhisperKit
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
    // Supersede any in-flight load/warm-up BEFORE the teardown transition
    // (#1275 Codex r2 P2): bumping `generation` first means a load/warm-up
    // completing after this point sees the new generation and its state-machine
    // guard drops it (never resurrecting a stale `.ready` on a discarded model).
    generation &+= 1
    // The `.unloadRequested` transition returns `.idle` and the cancel effects
    // for whatever tasks the leaving state held (load task, live warm-up, or
    // orphaned warm-up). Cancellation is best-effort — CoreML load/decode is
    // uncancellable cooperatively — but dropping the handles (the enum leaving
    // those cases) is what stops us from later draining or reporting on a task
    // tied to a discarded model, and stops a post-unload `prepare()` from
    // joining a doomed load instead of starting a fresh one.
    await emit(.unloadRequested)
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

  // #1276 Step 2 (PR-2): vend the authoritative streaming session for the "Live
  // transcription" toggle's ON + locked-language path. Mirrors
  // `makeIncrementalSession` (same nil-on-not-loaded contract, same
  // `readyKitAfterWarmupDrain` vend) but constructs the confirmed-segment
  // `WhisperKitStreamingSession`. `sampleCount: 0` forces `chunkingStrategy: .none`
  // in the base options (the session sets `clipTimestamps = [lastConfirmedSec]` and
  // keeps `.none` per cycle; it must NEVER inherit the `>30s -> .vad` branch that
  // would re-chunk the whole growing buffer, F2).
  package func makeStreamingSession(options: TranscriptionOptions)
    async -> (any WhisperKitIncrementalSession)?
  {
    guard let kit = await readyKitAfterWarmupDrain() else { return nil }
    var opts = makeDecodeOptions(from: options, sampleCount: 0)
    // LocalAgreement-2 confirmation is word-level — word timings are required
    // regardless of the caller's timestamp preference (without them the session
    // silently falls back to segment-lag confirmation).
    opts.wordTimestamps = true
    // #1276 PR-2 benchmark winner (120-clip founder-audio replay, 2026-07-04):
    // the UFAL whisper_streaming BUFFER architecture — word-level
    // LocalAgreement-2 over a sentence-trimmed buffer (committed speech stays
    // in the decode window, giving every decode full context). Trailing
    // phantom-phrase hallucination 3/107 clips and dropped endings 18/107 vs
    // 14/107 and 49/107 for the padded-tail stitch this replaces.
    // `conditionOnPriorText` stays OFF: measured on this model
    // (large-v3-turbo CoreML), a `<|startofprev|>` prompt makes the decoder
    // intermittently EOT whole speech-filled windows empty (WhisperKit trace,
    // investigation log 2026-07-04) — the buffer shape alone is the winner.
    return WhisperKitStreamingSession(
      whisperKit: kit, decodingOptions: opts,
      conditionOnPriorText: false, localAgreement: true)
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
