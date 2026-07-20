@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation

// MARK: - WhisperKitEngineAdapter (epic #827, PR-5 Rung 3)
//
// The production `ASREngineAdapter` conformer for the WhisperKit engine. It
// wraps a `WhisperKitBackend` actor (the model-owning seam introduced by R2,
// #360) plus a `LanguageDetector` actor (engine-internal LID, capability
// `supportsLanguageDetection: true`) and lifts the WhisperKit-engine-internal
// orchestration from `WhisperKitPipeline.swift`: model load + cancellation
// (#445 held `prepareTask`), `warmUpFromCache` (cache-only preload, no
// network), `beginSession` (cancel pending model unload), `acceptAudio`
// (retained-PCM accumulator, bounded), `observeSpeechSegments` (store voiced
// ranges from the kernel's VAD), `finalize` (LID → transcribe with
// `clipTimestamps` derived from observed segments → single clean batch
// decode), `cancel` (cancels held tasks), `applyUnloadPolicy` (delay-then-
// unload timer mirroring `scheduleModelUnloadIfNeeded`), `cancelPendingUnload`
// (Rung 2B kernel hook).
//
// #1307 (Step 2, PR-1): the incremental decode worker + tail-stitch is no
// longer started or consulted on any path; the worker's structural
// mid-phrase-duplication and wrong-ending bugs are gone. #1315 (Step 3)
// deleted the worker type and its vend outright; a freeze test blocks their
// return.
//
// #1308 (Step 2, PR-2): the "Live transcription" toggle. On + a picked (locked)
// language starts the authoritative `WhisperKitStreamingSession` (confirmed-
// segment holdback, single-coordinate `streamingPCM`, Parakeet feed-task drain
// ported wholesale) whose flush IS the transcript — meshing-free by construction
// (one growing stream compared against itself, no second independent decode).
// Every other path (toggle off, or on + auto language) finalizes through the
// PR-1 clean batch decode. Routing lives in `beginSession(streaming:)`.
//
// Scope (epic §4): an adapter owns its own ASR and rescue and NOTHING else —
// no capture, no finalization, no paste, no UI, no FSM, no kernel state. The
// adapter holds legitimate engine-session bookkeeping (a session ID, decode
// options, an `isTerminal`/`isCancelled` pair, the retained PCM buffer, the
// authoritative batch-capture buffer, the observed speech segments, the LID
// result, held async-task handles).
//
// Coordinate-space (epic §0.5 LESSON `observeSpeechSegments-coordinate-space`;
// hardened by PR-5 Rung 5 UAT #827): the kernel's `observeSpeechSegments` hands
// the adapter BOTH the voiced speech segments AND the authoritative raw capture
// audio (`captureResult.samples`) they index into. The adapter batch-decodes
// THAT buffer (`batchCaptureSamples`, padded) with segment-derived
// `clipTimestamps` (the #452/#560 hallucination-suppression mechanism) — a
// single coordinate source, so segments can never overrun the decode buffer.
// The `finalize(batchSamples:)` parameter is intentionally ignored: it carries
// the kernel's VAD-FILTERED `conditioned.samples` (silence stripped in place),
// a different coordinate than the raw-sample segments. The earlier shape
// decoded the adapter's own `onBufferCaptured`-fed `retainedPCM` and shifted
// segments by `retainedPCM.count - capturedSamplesCount`; that shadow buffer is
// async/lossy and diverges in length from `captureResult.samples`, so the shift
// (always 0 in practice — retainedPCM is SHORTER, not longer) left segment ends
// overrunning the buffer and WhisperKit threw "Audio samples are nil" on
// alternating recordings. Restored OLD `WhisperKitPipeline.swift:614-615`
// single-capture-coordinate parity. After #1307 removed the incremental
// worker, `retainedPCM` has no production reader; it is still accumulated so
// the #827 coordinate-regression tests keep exercising the capture-vs-shadow
// distinction, and it is removed with the worker in Step 3. The Parakeet
// adapter MUST use `batchSamples`; this adapter MUST NOT.

/// The kernel-facing `ASREngineAdapter` conformer for WhisperKit. Drives the
/// underlying WhisperKit actor through a local `package` protocol seam
/// (`WhisperKitBackendDriving` below) so tests can inject a stub without
/// loading a real model.
@MainActor
final class WhisperKitEngineAdapter: ASREngineAdapter, @unchecked Sendable {

  // MARK: Injected dependencies

  private let backend: any WhisperKitBackendDriving
  private let languageDetector: LanguageDetector
  /// #1707 Phase 2: DEBUG fault-injection oracle (§11.1) — `nil` in every
  /// production/test path that doesn't explicitly construct one.
  private let batchDecodeFaultController: BatchDecodeFaultController?

  // MARK: Engine-session bookkeeping (NOT FSM state — §3.11 adapter-shape check)

  /// The session `beginSession(_:)` opened, or `nil` between sessions.
  private var sessionID: SessionID?
  /// Decode options bound at `beginSession(_:)`. Mutated inside `finalize` to
  /// pin the LID-decided language and to thread VAD `speechSegments` through
  /// to `clipTimestamps`.
  private var decodeOptions: TranscriptionOptions = .default
  /// `true` once `finalize()` or `cancel()` has completed — `acceptAudio(_:)`
  /// after this is a no-op (PR-1 §B.2.2).
  private var isTerminal = false
  /// `true` once `cancel()` ran — `finalize()` then returns `.cancelled`.
  private var isCancelled = false

  /// #1707 Phase 2: monotonic generation for `retryDecode()`'s commit gate.
  /// Bumped by `beginSession`/`cancel()` (a new session or discard must
  /// invalidate any in-flight retry attempt) and by `bumpRetryGeneration()`
  /// itself (a retry's own honest "stop waiting" signal). Mirrors
  /// `ParakeetEngineAdapter`'s identically-named field.
  private var retryGeneration = 0

  /// Synchronously-readable cached readiness. WhisperKit's `isReady` lives on
  /// an actor (`public private(set) var isReady`); the `ASREngineAdapter`
  /// protocol's `readiness` getter is synchronous, so the adapter caches the
  /// most-recent observed state and refreshes it on every transition. All
  /// mutations happen on `@MainActor`, so the cache update is observable to
  /// any subsequent `@MainActor` reader without an intervening `await`.
  private var cachedReadiness: ASREngineReadiness = .notReady

  /// #1275: synchronously-readable cache of the backend's most recent
  /// warm-up inference duration, refreshed alongside `cachedReadiness`
  /// wherever `warmUp()` observes the backend reaching `.ready`.
  private var cachedWarmupInferenceMs: Int?

  // MARK: Engine state

  /// Issue #445: held `prepare()` task so `cancel()` can cancel its host
  /// await even though CoreML's `MLModel.load` is uncancellable cooperatively.
  /// The backend's single-flight guard handles the orphan that keeps grinding.
  private var prepareTask: Task<Void, Error>?

  /// Pending model-unload timer armed by `applyUnloadPolicy(_:)`.
  /// `cancelPendingUnload()` (the Rung 2B kernel hook called pre-`beginSession`)
  /// and `beginSession` (defense-in-depth) both cancel it.
  private var modelUnloadTask: Task<Void, Never>?

  // MARK: Audio + speech segments

  /// Live per-buffer accumulation from every `acceptAudio(_:)`, fed via
  /// `onBufferCaptured` during capture. Historically the incremental worker's
  /// live `audioSamplesProvider` read it; after #1307 removed the worker it has
  /// NO production reader. It is still accumulated (and asserted by the #827
  /// coordinate-regression tests) so the capture-vs-shadow distinction stays
  /// under test, and is removed with the worker in Step 3. It is NOT the
  /// batch-decode buffer: this stream is async/lossy and diverges in length
  /// from the kernel's authoritative `captureResult.samples`, so using it for
  /// the post-stop batch decode caused the "Audio samples are nil" alternating
  /// failure (PR-5 Rung 5 UAT #827). Batch decode uses `batchCaptureSamples`
  /// instead. Cleared on `cancel()` / `finalize()`.
  private var retainedPCM: [Float] = []

  /// The authoritative raw capture audio for batch decode — the kernel's
  /// `captureResult.samples`, handed in by `observeSpeechSegments` at the stop
  /// boundary. This is the SAME buffer `observedSpeechSegments` index into, so
  /// `clipTimestamps` derived from the segments stay in-range. Restores OLD
  /// `WhisperKitPipeline.swift:614-615` single-coordinate parity (#827).
  private var batchCaptureSamples: [Float] = []

  /// Speech segments handed in by the kernel's `observeSpeechSegments` hook
  /// (Rung 2B). Coordinates are raw-capture-sample positions indexing into
  /// `batchCaptureSamples` (NO pre-roll shift — same coordinate). Used to
  /// derive `clipTimestamps` for WhisperKit's VAD-driven clip-seek (the
  /// #452/#560 hallucination-suppression mechanism) and to filter LID audio to
  /// voiced-only ranges. Cleared on `cancel()` / `beginSession()` and after
  /// `finalize()` commits.
  private var observedSpeechSegments: [SpeechSegment] = []

  // MARK: Streaming session (#1276 Step 2, PR-2)

  /// The authoritative live-transcription session, present only when the "Live
  /// transcription" toggle is ON and the language is picked (locked). Its
  /// `finalize` output IS the transcript (not a best-effort rescue). `nil` on the
  /// toggle-OFF and auto-language paths, which finalize through the clean batch
  /// decode (PR-1). Reuses the `WhisperKitIncrementalSession` seam (#360).
  private var streamingSession: (any WhisperKitIncrementalSession)?

  /// `true` between a successful streaming-session start and finalize/cancel.
  private var streamingActive = false

  /// #1309 effective-path telemetry, per session. `sessionStreamingRequested`
  /// mirrors the kernel's capability-gate decision as handed to `beginSession`;
  /// the degrade reason narrows as the session progresses:
  /// none / disabled / auto_language / model_not_ready / flush_empty /
  /// flush_throw. Surfaced through `KernelASRAdapterDiagnostics`.
  private var sessionStreamingRequested = false
  private var sessionStreamingDegradeReason = "none"
  /// #1309: the WHOLE degraded streaming-flush result, preserved so the batch
  /// fallback's diagnostics still carry every streaming counter (decode count,
  /// coverage, tail-decode time, stop-mid-decode) — the telemetry matters most
  /// exactly for degraded sessions (Codex r2: field-by-field preservation kept
  /// losing the next field; preserve the source record once).
  private var sessionDegradedFlushResult: IncrementalResult?

  /// The adapter-owned LOSSLESS audio the streaming session reads — the single
  /// coordinate the whole streaming path lives in (§3.2). Fed by `acceptAudio`
  /// via retained `streamingFeedTasks` (Parakeet's drain pattern ported
  /// wholesale) and pulled by the session's provider closure (loop + flush). It
  /// is DISTINCT from the lossy `retainedPCM` and from `batchCaptureSamples`
  /// (the batch path's authoritative buffer): the streaming flush never reads
  /// `finalSamples`/`batchCaptureSamples`, so the pre-roll coordinate mismatch is
  /// structurally irrelevant. Bounded by the same recording cap. Cleared on
  /// `beginSession` / `cancel` / `finalize`.
  private var streamingPCM: [Float] = []

  /// In-flight streaming-feed tasks — each `acceptAudio` appends the buffer's
  /// samples to `streamingPCM` on its own retained `Task`, and `finalize` awaits
  /// every handle (`drainStreamingFeeds`) before the session flush, so a non-empty
  /// streaming result is never finalized missing tail buffers. Awaiting the actual
  /// task handle IS the completion signal — no wall-clock deadline (mirrors
  /// `ParakeetEngineAdapter.feedTasks`; RULE: port-proven-patterns-wholesale).
  /// Cleared at `beginSession` / `cancel`; a value snapshot is drained at
  /// `finalize`.
  private var streamingFeedTasks: [Task<Void, Never>] = []

  /// Cap on `retainedPCM` — `maxRecordingDuration` worth of 16 kHz mono samples
  /// (3600 s * 16 kHz = 57.6 M Float = ~230 MB; #1060 raised the cap 300→3600).
  /// Mirrors Parakeet's cap so the two engines size memory the same way. On
  /// reaching the cap the accumulation stops growing; recording auto-stops on
  /// max-duration anyway.
  private static let retainedPCMCap = Int(
    TimingConstants.maxRecordingDuration * AudioConstants.sampleRate)

  // MARK: Last-result + telemetry (Rung 2A passive surface)

  /// The `ASRResult` of the last successful `finalize()`, or `nil` between
  /// sessions. Cleared on `beginSession()` and `cancel()`; assigned only by a
  /// successful `finalize()` returning `.transcript(...)`.
  private(set) var lastResult: ASRResult?

  /// Rich incremental + batch-rescue diagnostics surfaced through the
  /// `ASREngineTelemetryProviding` protocol. Kernel's lifecycle sink reads
  /// this for the asr-empty-with-speech-evidence payload (today's
  /// `WhisperKitPipeline.swift:1005-1019`). NOT cleared on `finalize()` — only
  /// on `beginSession()` and `cancel()` — so the sink can read it after the
  /// outcome lands.
  private(set) var lastASRDiagnostics: KernelASRAdapterDiagnostics?

  /// The last decode error, surfaced through `ASREngineTelemetryProviding`.
  private(set) var lastFailureError: (any Error)?

  /// The last LID result. NOT surfaced on the `ASREngineAdapter` protocol
  /// (Rung 2A "contract surface stays closed"); Rung 5's App cutover wires
  /// this into `LLMPolishStep.languageDetection`. Cleared on `beginSession()`
  /// and `cancel()`; set inside `finalize` after `languageDetector.detect(...)`
  /// returns and the stale-session guard passes.
  private(set) var lastLanguageDetection: LanguageDetectionResult?

  /// Source for the audio-capture session id. Read once per `finalize`
  /// call into a function-local snapshot (`sessionIDForLog`) — not stored
  /// on `self`, so a concurrent `beginSession(B)` cannot retroactively
  /// change session A's in-flight signposts. PR-5 Rung 4.5 (#827) reuses
  /// the existing `audioCapture: any AudioCaptureInterface` plumbed
  /// through `KernelDictationDriverFactory.WhisperKitInputs:62-69`.
  private let audioCaptureSessionIDSource: @MainActor () -> UInt64

  // MARK: ASREngineAdapter — engine interruption

  /// Optional adapter-local interruption hook. WhisperKit has no
  /// mid-recording crash signal today (the legacy pipeline's
  /// `handleASRServiceInterruption` is XPC-driven from the App layer), so
  /// this remains settable but unused inside the adapter.
  var onEngineInterrupted: (@MainActor () -> Void)?

  /// #1707: WhisperKit is never the SOURCE of an ASR-interruption signal (no
  /// out-of-process connection to lose), but the shared `ASREventRouter` can
  /// still forward a stale Parakeet-origin signal to this adapter's kernel if
  /// WhisperKit happens to be the actively recording driver. Since this
  /// adapter's own engine was never touched, confirming readiness is a real
  /// (not stubbed) but normally near-instant check: `await backend.isReady`
  /// is the SAME actor-isolated authority `warmUp()` itself consults — never
  /// the synchronous `cachedReadiness` mirror alone, which can be stale after
  /// an unload. Refreshes the cache from the awaited value either way.
  func recoverFromASRInterruption() async -> ASRInterruptionRecoveryOutcome {
    let ready = await backend.isReady
    cachedReadiness = ready ? .ready : .notReady
    return ready ? .readyForBatchDecode : .failed
  }

  // MARK: Init

  init(
    backend: any WhisperKitBackendDriving,
    languageDetector: LanguageDetector = LanguageDetector(),
    audioCaptureSessionIDSource: @escaping @MainActor () -> UInt64 = { 0 },
    wedgeRecoveryUnloadDeadlineSec: Double = 2.0,
    // #1707 Phase 2: DEBUG fault-injection oracle (§11.1). Defaulted `nil`
    // so every existing test construction site is unaffected.
    batchDecodeFaultController: BatchDecodeFaultController? = nil
  ) {
    self.backend = backend
    self.languageDetector = languageDetector
    self.audioCaptureSessionIDSource = audioCaptureSessionIDSource
    self.wedgeRecoveryUnloadDeadlineSec = wedgeRecoveryUnloadDeadlineSec
    self.batchDecodeFaultController = batchDecodeFaultController
  }

  // MARK: ASREngineAdapter — identity & capability

  /// Self-declared identity. The kernel reads from here at every site that
  /// previously hard-coded an engine literal (PR-5 Rung 1).
  var engineIdentity: ASREngineIdentity {
    ASREngineIdentity(backendType: .whisperKit)
  }

  /// #1707 Phase 2: measured 2026-07-20 against the live dev app — 7 real
  /// batch decodes spanning 3.8-59.2s of audio, real-time factor (decode
  /// seconds / audio seconds) observed 0.047-0.312, HIGHEST at the shortest
  /// clips (fixed per-call overhead dominates) and settling near 0.09-0.10
  /// by 20-59s. `5.0` fixed floor covers per-call overhead with headroom
  /// over the worst short-clip observation; `0.30` per second is
  /// comfortably above every observed RTF at any length, including the
  /// short-clip outliers, not just the settled long-clip rate. At the 3600s
  /// (60-minute) recording cap this budgets 1085s, generous given the
  /// measured trend — WhisperKit is deliberately the slower, more-capable
  /// "toughest audio" option, so its floor is the widest of the two.
  /// Raw samples: `docs/audits/2026-07-20-recovery-v2-phase2-retry-decode-latency.md`.
  func retryDecodeTimeoutSeconds(forSampleCount sampleCount: Int) -> Double {
    let audioDurationSec = Double(sampleCount) / AudioConstants.sampleRate
    return 5.0 + audioDurationSec * 0.30
  }

  /// WhisperKit runs engine-internal LID and, since #1276 Step 2 (PR-2),
  /// advertises streaming: the kernel's existing `useStreamingASR &&
  /// supportsStreaming` gate then routes the "Live transcription" toggle through
  /// `beginSession(streaming: true)`. The adapter still degrades to the clean
  /// batch decode when it cannot safely stream (auto language, model not ready);
  /// the capability only says "you may ask me to stream." Static — the kernel
  /// branches on `capabilities`, never on engine identity (epic §3.4).
  var capabilities: ASREngineCapabilities {
    // decodesConditionedBatchSamples: false — WhisperKit ignores `batchSamples`
    // and decodes the raw capture via clipTimestamps (#950 tail-trim diagnostic
    // is meaningless for it; the VAD trim does not drop its ASR input).
    ASREngineCapabilities(
      supportsStreaming: true, supportsLanguageDetection: true,
      decodesConditionedBatchSamples: false)
  }

  var readiness: ASREngineReadiness { cachedReadiness }

  /// #1275: read-only pass-through of the cached warm-up duration.
  var lastWarmupInferenceMs: Int? { cachedWarmupInferenceMs }

  // MARK: ASREngineAdapter — warm-up

  /// Idempotent, sessionless warm-up. Held `prepareTask` so `cancel()` can
  /// cancel the host await; the backend's single-flight guard owns the
  /// in-flight CoreML load semantics (`#445`). CoreML's `MLModel.load` exposes
  /// no progress signal, so the kernel runs signal-free warm-up — no wedge
  /// detection, no wall-clock timeout (per the protocol's MUST NOT clause).
  func warmUp() async throws {
    if await backend.isReady {
      cachedReadiness = .ready
      cachedWarmupInferenceMs = await backend.lastWarmupInferenceMs
      return
    }
    cachedReadiness = .warming
    let captured = backend
    let task = Task<Void, Error> { try await captured.prepare() }
    prepareTask = task
    do {
      try await task.value
      prepareTask = nil
      // #959: recheck the backend's actual readiness after `prepare()` returns
      // (a `recoverFromWedge()` that cancelled `prepareTask` rethrows above; this
      // guards any "returned but not ready" path) so `ensureEngineWarm()` never
      // reports a false success on an unready engine.
      let ready = await captured.isReady
      cachedReadiness = ready ? .ready : .notReady
      cachedWarmupInferenceMs = ready ? await captured.lastWarmupInferenceMs : nil
      guard ready else { throw ASRLoadSupersededError() }
    } catch {
      prepareTask = nil
      cachedReadiness = .notReady
      throw error
    }
  }

  /// Cache-only warm-up — intentionally a near no-op for WhisperKit.
  ///
  /// Earlier drafts dispatched a detached cache-only load here during the
  /// kernel's `preWarm` hop, which risked two concurrent CoreML loads racing the
  /// kernel's own spawned `warmUp()`. #1386 PR-2 deleted that door outright:
  /// `prepare()` is now the ONLY way this backend maps a model, so there is one
  /// load path and one single-flight owner.
  /// This adapter dispatches nothing here, and that remains unnecessary because:
  ///
  /// In the kernel-driven flow, the kernel's spawned `warmUp()` path
  /// already calls `prepare()`, which resolves the admitted owned model folder
  /// and loads from it when one exists. (#1386 PR-2 replaced the old
  /// `WhisperKitSetupService.getLocalModelPath` ~/Documents probe named here:
  /// availability is controller admission now, and `prepare()` never fetches.)
  /// So no `warmUpFromCache` work is needed here — the cached-load
  /// optimization is preserved by `prepare()`'s own resolve branch, and the
  /// single-flight guard prevents duplicate loads.
  ///
  /// Side effect: keep `cachedReadiness`/`cachedWarmupInferenceMs` refreshed
  /// against the backend's current state so a recently-unloaded model is
  /// reported as `.notReady`.
  func warmUpFromCache() async throws {
    let ready = await backend.isReady
    cachedReadiness = ready ? .ready : .notReady
    cachedWarmupInferenceMs = ready ? await backend.lastWarmupInferenceMs : nil
  }

  /// WhisperKit / CoreML exposes no model-load progress signal. The kernel
  /// runs signal-free `warmingUp` with no wedge detection, per the protocol's
  /// MUST NOT clause.
  var loadProgress: AsyncStream<ASRLoadProgressTick>? { nil }

  // `lastObservedPhase` falls back to the protocol-extension default
  // (`"warmup"`) — WhisperKit's loader exposes no phase strings.

  // MARK: ASREngineAdapter — session lifecycle

  /// Begin a session. #1276 Step 2 (PR-2) routing on `(streaming, language)`:
  /// - `streaming && locked` (language non-nil): start the authoritative
  ///   `WhisperKitStreamingSession` — live confirmed-segment decoding whose flush
  ///   IS the transcript.
  /// - `streaming && auto` (language nil): DEGRADE to the clean batch decode (no
  ///   session). Streaming commits to one language at the first cycle and
  ///   WhisperKit's sub-second in-decoder LID is unreliable (the garble trap);
  ///   auto stays batch until Ship 2 adds confidence-gated early-LID.
  /// - `!streaming` (toggle off): the clean batch decode (PR-1).
  /// Both non-streaming paths finalize through the single `runBatchFallback()`
  /// helper, so neither meshing bug can occur on any path.
  func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws {
    sessionID = id
    decodeOptions = options
    isTerminal = false
    isCancelled = false
    retryGeneration &+= 1  // #1707 Phase 2: invalidate any pending retry.
    lastResult = nil
    lastASRDiagnostics = nil
    lastFailureError = nil
    // #1309 effective-path telemetry: reset per session. The degrade reason
    // is refined as the session progresses (auto_language / model_not_ready
    // at begin; flush_empty / flush_throw at finalize).
    sessionStreamingRequested = streaming
    sessionStreamingDegradeReason = streaming ? "none" : "disabled"
    sessionDegradedFlushResult = nil
    lastLanguageDetection = nil
    retainedPCM.removeAll(keepingCapacity: true)
    observedSpeechSegments.removeAll()
    // Clear the authoritative batch buffer so a session that reaches finalize
    // without `observeSpeechSegments` can never decode a prior session's audio
    // (#827).
    batchCaptureSamples.removeAll(keepingCapacity: true)
    // Reset streaming state for the fresh session (Parakeet-parity: clear feed
    // handles + the lossless buffer at every session start).
    streamingActive = false
    streamingPCM.removeAll(keepingCapacity: true)
    streamingFeedTasks.removeAll()
    // PR-5 Rung 4.5 (#827): the audio-capture session id is read at
    // finalize entry into a function-local snapshot, not here — kernel
    // calls `beginSession` BEFORE `beginCapturePhase` mints the id, and
    // a shared-property capture would race interleaved sessions. See
    // `finalize`.

    // Cancel any pending model-unload timer a prior session armed. Rung 2B's
    // kernel `cancelPendingUnload` hook already fires synchronously before
    // `beginSession`; this is defense-in-depth, matching Parakeet's
    // `ParakeetEngineAdapter.swift:192` pattern.
    modelUnloadTask?.cancel()
    modelUnloadTask = nil

    // Cancel + drop any orphan streaming session from a prior session that was
    // superseded before finalize/cancel cleared the handle (mirrors PR-1's old
    // orphan-worker cancel). AWAITED, not detached (Codex r2 P1): the orphan's
    // in-flight decode is not cooperatively cancellable, and vending a new
    // streaming session before it fully exits would put two concurrent
    // transcribes on the same WhisperKit instance. `cancel()` returns only
    // after the orphan's loop has exited, bounded by that single decode.
    if let orphan = streamingSession {
      streamingSession = nil
      await orphan.cancel()
    }

    // Refresh cached readiness — backend may have been unloaded by a prior
    // session's policy timer that fired while idle.
    cachedReadiness = await backend.isReady ? .ready : .notReady

    // Streaming ON + locked language → start the authoritative streaming session.
    if streaming, options.language != nil {
      await startStreamingSession(id, options: options)
    } else {
      if streaming { sessionStreamingDegradeReason = "auto_language" }
      let reason = streaming ? "auto language, batch (Ship 2)" : "toggle off"
      let languageForLog = options.language ?? "auto"
      Task {
        await AppLogger.shared.log(
          "WhisperKit recording started (batch mode, language: \(languageForLog), \(reason))",
          level: .info, category: "WhisperKitEngineAdapter"
        )
      }
    }
  }

  /// Start the streaming session under the stale-beginSession guards (a
  /// `cancel()` + new `beginSession(B)` during the `makeStreamingSession` / `start`
  /// await must not let a stale session install on the fresh session). On a
  /// model-not-ready vend (`nil`) the adapter stays in batch mode — `finalize`
  /// then runs the clean batch fallback (fail-open, heart stays alive).
  private func startStreamingSession(_ id: SessionID, options: TranscriptionOptions) async {
    guard let session = await backend.makeStreamingSession(options: options) else {
      // Stale guard (cloud r2): a cancel + beginSession(B) during the vend
      // await must not overwrite B's per-session telemetry state.
      if sessionID == id, !isCancelled {
        sessionStreamingDegradeReason = "model_not_ready"
      }
      Task {
        await AppLogger.shared.log(
          "WhisperKit recording started (batch mode, streaming requested but model not loaded)",
          level: .info, category: "WhisperKitEngineAdapter"
        )
      }
      return
    }
    guard sessionID == id, !isCancelled else {
      await session.cancel()
      return
    }
    streamingSession = session
    streamingActive = true
    await session.start(audioSamplesProvider: { @MainActor [weak self] in
      let samples = self?.streamingPCM ?? []
      return (samples: samples, count: samples.count)
    })
    // Stale-beginSession guard AFTER `start`: if a cancel + new beginSession(B)
    // landed during the start await, this session installed under the wrong
    // session — uninstall + cancel it.
    guard sessionID == id, !isCancelled else {
      if (streamingSession as AnyObject?) === (session as AnyObject) {
        streamingSession = nil
        streamingActive = false
      }
      await session.cancel()
      return
    }
    Task {
      await AppLogger.shared.log(
        "WhisperKit recording started (streaming, language: \(options.language ?? "?"))",
        level: .info, category: "WhisperKitEngineAdapter"
      )
    }
  }

  /// Accept one captured buffer. Always appends to `retainedPCM` (kept for the
  /// #827 coordinate tests until Step 3). For a streaming session, ALSO appends
  /// the samples to the lossless `streamingPCM` on a retained `Task` in
  /// `streamingFeedTasks`, which `finalize` drains before the flush (Parakeet's
  /// feed-task-handle pattern). A call after a terminal session is a no-op.
  func acceptAudio(_ buffer: AudioBufferHandoff) {
    // Drop late buffers from a prior session — PR-1 §B.3 / FSM invariant 7:
    // a buffer whose `sessionID` is not the kernel's current session is
    // dropped. Without this gate, a delayed handoff after `beginSession(B)`
    // would land in session B's buffers and misalign coordinates (Codex
    // code-diff r3 defect 3).
    guard !isTerminal, !isCancelled, buffer.sessionID == sessionID else { return }
    appendRetainedPCM(from: buffer.buffer)
    guard streamingActive else { return }
    // Mirror Parakeet's per-buffer hand-off: dispatch the streamingPCM append on
    // its own retained `@MainActor` task and keep the handle so `finalize` awaits
    // it. The buffer is MainActor-confined here; capturing it carries no
    // cross-actor transfer.
    let pcmBuffer = buffer.buffer
    let handoffSession = buffer.sessionID
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      // Re-check on the MainActor hop: a cancel or new beginSession between
      // dispatch and now must not feed this buffer into a fresh session's
      // streamingPCM (stale-feed race).
      guard self.sessionID == handoffSession, self.streamingActive, !self.isTerminal
      else { return }
      self.appendStreamingPCM(from: pcmBuffer)
    }
    streamingFeedTasks.append(task)
  }

  /// Store the kernel's authoritative raw capture audio (`captureResult.samples`)
  /// and the VAD-derived speech segments that index into it. Segments and audio
  /// share one coordinate space, so NO offset shift is applied — `finalize`
  /// batch-decodes `batchCaptureSamples` (padded) with `clipTimestamps` derived
  /// directly from `observedSpeechSegments`. This restores OLD
  /// `WhisperKitPipeline.swift:614-615` parity (single capture-coordinate
  /// source) and fixes the alternating "Audio samples are nil" failure that the
  /// prior `retainedPCM`-shadow-buffer + pre-roll-shift approach caused, since
  /// the shadow buffer diverged in length from `captureResult.samples`
  /// (PR-5 Rung 5 UAT #827).
  func observeSpeechSegments(
    _ segments: [SpeechSegment], rawCaptureSamples: [Float]
  ) {
    // Drop calls without a live session OR after the session went
    // terminal/cancelled (Codex r7 matrix S0/S3/S4/S6). A late observe
    // from a prior session must NOT repopulate the fresh adapter state.
    guard sessionID != nil, !isTerminal, !isCancelled else { return }
    batchCaptureSamples = rawCaptureSamples
    observedSpeechSegments = segments
  }

  /// Finalize: LID → transcribe with `clipTimestamps` derived from observed
  /// segments → one clean batch decode (#1307: no incremental worker). After
  /// `cancel()`, returns `.cancelled`. **MUST NOT use `batchSamples`** (it is
  /// the kernel's VAD-filtered `conditioned.samples`, a different coordinate) —
  /// see the coordinate-space note above and the protocol comment at
  /// `ASREngineAdapter.swift:240-247`. Batch-decodes `batchCaptureSamples` (the
  /// authoritative raw `captureResult.samples` handed in by
  /// `observeSpeechSegments`) so segment-derived `clipTimestamps` stay
  /// coordinate-aligned (#827), via the single `runBatchFallback()` helper.
  func finalize(batchSamples: [Float]?) async -> ASREngineOutcome {
    _ = batchSamples  // intentionally ignored — see coordinate-space note
    lastFailureError = nil
    // PR-5 Rung 4.5 (#827): capture `currentCaptureSessionID` at finalize
    // entry, NOT at `beginSession`. Codex code-diff review caught this:
    // kernel calls `adapter.beginSession()` BEFORE `audioCapture.beginCapturePhase()`,
    // but `currentCaptureSessionID` only increments inside the capture-phase
    // call. By finalize entry, the capture phase has completed (kernel's
    // `runForwardPath` flow guarantees this), so the source returns the
    // active session's id.
    //
    // `sessionIDForLog` is a function-local immutable snapshot — every
    // signpost emitted in this finalize call passes it explicitly. A
    // concurrent `beginSession(B)` that resets the shared adapter property
    // mid-finalize cannot misattribute this session's post-await signposts
    // (Codex code-diff r2 caught the shared-mutable-property race).
    let sessionIDForLog = audioCaptureSessionIDSource()
    if isCancelled {
      isTerminal = true
      clearSessionBuffers()
      return .cancelled
    }
    // Entry guard: no active session OR already-terminal session must not
    // re-enter the decode path (Codex r7 matrix S0/S4). The protocol's
    // "one outcome per session" shape at `ASREngineAdapter.swift:237-266`
    // means a second `finalize()` after a successful one is undefined; the
    // adapter declines rather than re-running LID/transcribe and clobbering
    // the prior outcome.
    guard let session = sessionID, !isTerminal else {
      return .empty(hadSpeechEvidence: false)
    }

    // #1276 Step 2 (PR-2): if a streaming session ran, its flush IS the
    // transcript (authoritative). Drain the feed tasks so `streamingPCM` is
    // complete, flush, and use the result. On an empty/failed flush the helper
    // returns nil and finalize falls through to the clean batch decode over the
    // authoritative capture buffer (fail-open — raw text always lands, G4).
    if let streamingOutcome = await finalizeStreamingSession(
      session: session, sessionIDForLog: sessionIDForLog)
    {
      return streamingOutcome
    }

    // No-speech gating is kernel-owned in the new model
    // (`RecordingSessionKernel.swift:974-1059` returns early for
    // `VADSignalSource.speechEvidenceAtStop() == .confirmedNoSpeech` BEFORE
    // calling `adapter.finalize`). The kernel calls `observeSpeechSegments`
    // with an empty array in both the `.confirmedSpeech` + (vad found no
    // ranges) AND the `.unavailable` cases, so the adapter cannot
    // disambiguate them from `observedSpeechSegments == []` alone. Trust the
    // kernel: if we reached finalize, ASR runs. Empty segments simply mean
    // "no `clipTimestamps` to thread into decode" (Codex code-diff r2
    // defect 1). The legacy pipeline's own no-speech gate at
    // `WhisperKitPipeline.swift:694-718` was a pipeline-level defense; in
    // the kernel-driven model the kernel owns that gate.
    let minimumSamples = AudioConstants.minimumTranscriptionSamples
    // Batch decode over the kernel's authoritative `captureResult.samples`
    // (handed in via `observeSpeechSegments`), NOT the lossy `retainedPCM`
    // shadow buffer — the segments index into THIS buffer, so `clipTimestamps`
    // stay in range (PR-5 Rung 5 UAT #827 fix; OLD parity at
    // `WhisperKitPipeline.swift:614-615`).
    let rawSamples = batchCaptureSamples

    // Sample shaping for LID + ASR. ASR runs over raw capture audio (padded);
    // LID runs over voiced-only audio (with raw fallback if voiced is too short).
    let speechSegments = observedSpeechSegments
    let asrSamples = WhisperKitPipelineSpeechRouting.paddedASRSamples(
      rawSamples: rawSamples,
      minimumSamples: minimumSamples
    )
    let lidFiltered = SampleFilter.filter(from: rawSamples, segments: speechSegments)
    let lidSamples = WhisperKitPipelineSpeechRouting.paddedLIDSamples(
      filteredSamples: lidFiltered,
      rawSamples: rawSamples,
      minimumSamples: minimumSamples
    )
    decodeOptions = WhisperKitPipelineSpeechRouting.transcriptionOptions(
      from: decodeOptions,
      speechSegments: speechSegments
    )
    let voicedDurationSec =
      Double(
        speechSegments.reduce(0) { $0 + ($1.endSample - $1.startSample) }
      ) / AudioConstants.sampleRate
    let lidWindowCount = WhisperKitPipelineSpeechRouting.lidWindowCount(
      forVoicedDuration: voicedDurationSec
    )
    let clipKind = lidWindowCount == 1 ? "short" : "normal"

    // LID perf signpost: state flip (kernel-owned in the new model; the
    // adapter logs the LID-bound signposts only).
    logLIDPerfSignpost(
      "t_state_flip",
      sessionID: sessionIDForLog,
      voicedDuration: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind
    )

    // LID. `LanguageMode` is reconstructed from `decodeOptions.language`:
    // non-nil → `.locked(code)`; nil → `.auto` — mirrors how the App layer
    // threads `DictationSessionConfig.languageMode` through
    // `TranscriptionOptions.language` (`KernelFinalizationWiring.swift:124-127`).
    let mode: LanguageMode =
      (decodeOptions.language).map { LanguageMode.locked($0) } ?? .auto
    let backendForObserver = backend
    let observerSamples = lidSamples
    let lidWindowCountForObserver = lidWindowCount
    let lidResult = await languageDetector.detect(
      samples: lidSamples,
      voicedDuration: voicedDurationSec,
      observerFn: {
        await backendForObserver.observeLID(
          samples: observerSamples, maxWindows: lidWindowCountForObserver)
      },
      mode: mode
    )
    logLIDPerfSignpost(
      "t_lid_settled",
      sessionID: sessionIDForLog,
      voicedDuration: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind
    )

    // Stale-cancel guard before mutating LID-derived state. Just return on
    // session mismatch — `beginSession(B)` already reset adapter state for
    // session B; this stale finalize for session A must NOT clobber B's
    // PCM/segments/terminal flag (Codex code-diff defect 3).
    guard sessionID == session, !isCancelled else {
      return isCancelled ? .cancelled : .empty(hadSpeechEvidence: false)
    }
    lastLanguageDetection = lidResult
    if let lang = lidResult.lang, !lidResult.abstained {
      decodeOptions.language = lang
    } else {
      decodeOptions.language = nil  // let WhisperKit's internal LID run
    }
    Task {
      await AppLogger.shared.log(
        "LID result: lang=\(lidResult.lang ?? "nil") tier=\(lidResult.tier) "
          + "conf=\(String(format: "%.2f", lidResult.confidence)) "
          + "margin=\(String(format: "%.2f", lidResult.margin)) "
          + "voiced=\(String(format: "%.2f", lidResult.voicedDuration))s "
          + "abstained=\(lidResult.abstained)",
        level: .info, category: "WhisperKitEngineAdapter"
      )
    }

    // PR-5 Rung 4.5 (#827): Sentry breadcrumb "Language detected", byte-identical
    // to OLD `WhisperKitPipeline.swift:814-823`. Payload is derived metadata only
    // (no transcript text, no raw audio) per `sentry-operations.md`
    // RULE: telemetry-privacy-boundary. Locked-mode never reaches LID
    // (`LanguageDetector.swift:152-171`), so this fires on auto-mode paths only.
    SentryBreadcrumb.add(
      stage: "asr", message: "Language detected",
      data: [
        "lang": lidResult.lang ?? "nil",
        "tier": lidResult.tier.rawValue,
        "confidence": String(format: "%.3f", lidResult.confidence),
        "margin": String(format: "%.3f", lidResult.margin),
        "voiced_s": String(format: "%.2f", lidResult.voicedDuration),
        "abstained": lidResult.abstained,
      ])

    // LID PostHog telemetry — adapter-owned per `supportsLanguageDetection`
    // TODO at `ASREngineAdapter.swift:60-65`.
    let sessionPreferredSnapshot = await languageDetector.peekMemory().sessionPreferred

    // Stale guard after the `peekMemory()` await: a `beginSession(B)` during
    // this hop must not let the stale A finalize keep reading mutable
    // `decodeOptions` for the rest of finalize. The downstream guard inside
    // `runBatchFallback` catches session B's state AFTER the decode await, but
    // an early bail here prevents reading session B's decode options between
    // LID telemetry and the decode (Codex code-diff r3 defect 1).
    guard sessionID == session, !isCancelled else {
      return isCancelled ? .cancelled : .empty(hadSpeechEvidence: true)
    }

    TelemetryService.shared.trackLanguageDetected(
      lang: lidResult.lang,
      confidence: lidResult.confidence,
      margin: lidResult.margin,
      voicedDuration: lidResult.voicedDuration,
      abstained: lidResult.abstained,
      sessionPreferredLang: sessionPreferredSnapshot,
      usedSticky: lidResult.usedSessionPrior,
      lidWindowCount: lidWindowCount
    )
    if lidResult.abstained {
      let reason: String
      if lidResult.voicedDuration < LanguageDetectorThresholds.shortClipMinSec {
        reason = "too_short"
      } else if lidResult.confidence < LanguageDetectorThresholds.normalProb {
        reason = "low_confidence"
      } else if lidResult.margin < LanguageDetectorThresholds.normalMargin {
        reason = "narrow_margin"
      } else {
        reason = "low_confidence"
      }
      TelemetryService.shared.trackLIDAbstained(
        voicedDuration: lidResult.voicedDuration,
        top1Prob: lidResult.confidence,
        top1Lang: lidResult.lang,
        reason: reason
      )
    }

    // Decode — one clean batch over the authoritative capture buffer (#1307:
    // the incremental worker + tail-stitch is gone; `.locked` and `.auto` both
    // finalize here). Diagnostics surface through `lastASRDiagnostics` on every
    // terminal outcome.
    var diagnostics = KernelASRAdapterDiagnostics()
    diagnostics.rawSampleCount = rawSamples.count
    // #1309 effective-path telemetry: this is the batch finalize, so streaming
    // did not deliver the transcript. `fallback_batch` when a streaming
    // session ran and degraded at flush; `clean_batch` when streaming never
    // ran (toggle off / auto language / model not ready). The .failed exit
    // below overrides `finalPath` to "failed".
    diagnostics.streamingEffective = false
    diagnostics.streamingDegradeReason = sessionStreamingDegradeReason
    diagnostics.streamingFinalPath =
      ["flush_empty", "flush_throw"].contains(sessionStreamingDegradeReason)
      ? "fallback_batch" : "clean_batch"
    if let flush = sessionDegradedFlushResult {
      // A streaming session ran before this fallback: carry its counters.
      // `samplesCovered` is 0 by construction on a forced fallback — omit it
      // rather than report zero coverage as fact (cloud r2).
      diagnostics.incrementalDecodeCount = flush.decodeCount
      diagnostics.incrementalSamplesCovered = flush.samplesCovered > 0 ? flush.samplesCovered : nil
      diagnostics.incrementalTailDecodeMs = flush.tailDecodeMs
      diagnostics.stopWhileDecodeInFlight = flush.stopWhileDecodeInFlight
      diagnostics.streamingMaxUnconfirmedWindowSec =
        Double(WhisperKitStreamingSession.defaultMaxUnconfirmedWindowSec)
    }
    // PR-5 Rung 4.5 (#827): LID perf-signpost transport for kernel-side
    // `t_release` and wiring-side `t_clipboard_write` emits. Populated here
    // so every terminal write of `lastASRDiagnostics` carries them. Uses the
    // finalize-local `sessionIDForLog` snapshot so a concurrent
    // `beginSession(B)` cannot retroactively change session A's diagnostics
    // payload (Codex code-diff r2 race).
    diagnostics.lidCaptureSessionID = sessionIDForLog
    diagnostics.lidVoicedDurationSec = voicedDurationSec
    diagnostics.lidWindowCount = lidWindowCount
    diagnostics.lidClipKind = clipKind
    // #1307: batch is the primary (only) decode now, not a worker rescue.
    diagnostics.batchRescueAttempted = false

    let asrText: String
    let asrLanguage: String?
    let asrStart = CFAbsoluteTimeGetCurrent()

    switch await runBatchFallback(
      asrSamples: asrSamples,
      session: session,
      sessionIDForLog: sessionIDForLog,
      voicedDurationSec: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind,
      diagnostics: &diagnostics
    ) {
    case .success(let text, let language):
      asrText = text
      asrLanguage = language
    case .stale(let outcome):
      // Session changed under the decode await — return without mutating
      // adapter state (a stale session-A finalize must not clobber B).
      return outcome
    case .cancelled:
      isTerminal = true
      clearSessionBuffers()
      return .cancelled
    case .failed(let error):
      lastFailureError = error
      diagnostics.streamingFinalPath = "failed"  // #1309
      lastASRDiagnostics = diagnostics
      isTerminal = true
      clearSessionBuffers()
      return .failed(.decodeFailed)
    }

    let asrEnd = CFAbsoluteTimeGetCurrent()
    let asrLatencySec = asrEnd - asrStart
    let audioDurationSec = Double(rawSamples.count) / AudioConstants.sampleRate

    // Telemetry fetch BEFORE the stale guard so that every mutation after
    // the guard is synchronous on `@MainActor`. An await between the guard
    // and the state writes would let `beginSession` clobber session B's
    // state if a stale finalize landed in the gap. The model name lookup
    // is the only remaining backend hop; pre-fetch it here.
    let modelName = await backend.modelVariantName

    // Stale-finalize guard: a `cancel()` + new `beginSession()` during the
    // ASR await must not let this stale finalize clobber the fresh session's
    // state — including `lastASRDiagnostics` (mirrors
    // `ParakeetEngineAdapter.swift:271-273`). Just return on mismatch
    // (Codex code-diff defect 3).
    guard sessionID == session, !isCancelled else {
      return isCancelled
        ? .cancelled
        : .empty(hadSpeechEvidence: true)
    }

    // All remaining mutations are synchronous on `@MainActor` — no await
    // between here and `return`, so the guard above protects every write.
    lastASRDiagnostics = diagnostics
    isTerminal = true
    clearSessionBuffers()

    if asrText.isEmpty {
      // Past the kernel's VAD gate, an empty decode is a real ASR failure;
      // route the kernel to `failed(asrEmpty)` (PR-1 §B.1.2).
      return .empty(hadSpeechEvidence: true)
    }

    let result = ASRResult(
      text: asrText,
      language: asrLanguage,
      duration: audioDurationSec,
      processingTime: asrLatencySec,
      backendType: .whisperKit
    )
    lastResult = result

    // Per-transcription latency telemetry — adapter-owned per the
    // `supportsLanguageDetection` TODO on `ASREngineAdapter.swift:60-65`.
    // Fired post-state-commit; telemetry is a limb and must never block the
    // heart path. `audioDurationSec > 0` is true here (we cleared the
    // no-speech gate above and decode produced text).
    if audioDurationSec > 0 {
      let msPerAudioSec = (asrLatencySec * 1000.0) / audioDurationSec
      TelemetryService.shared.trackTranscriptionLatency(
        lang: asrLanguage,
        model: modelName,
        durationSeconds: asrLatencySec,
        msPerAudioSecond: msPerAudioSec
      )
    }

    return .transcript(result)
  }

  /// WhisperKit's `transcribe(...)` is completion-only — no decoder-step
  /// progress signal. Same `nil` semantics as `loadProgress`.
  var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? { nil }

  /// Reset every per-session audio buffer at a terminal/cancel boundary. One
  /// place so a future buffer field added to the session lifecycle can't be
  /// silently missed at a cleanup site (#827 — the bug that caused this fix
  /// was exactly a buffer not tracked alongside its peers). `beginSession`
  /// does its own capacity-retaining reset; this is the free-memory variant
  /// for terminal/cancel.
  private func clearSessionBuffers() {
    retainedPCM.removeAll()
    observedSpeechSegments.removeAll()
    batchCaptureSamples.removeAll()
    streamingPCM.removeAll()
  }

  /// Idempotent discard. Cancels held tasks (prepare, model-unload timer) and the
  /// streaming session; drops streaming feed handles; clears retained audio +
  /// segments + capture buffer + streaming buffer + LID result.
  func cancel() async {
    isCancelled = true
    isTerminal = true
    retryGeneration &+= 1  // #1707 Phase 2: invalidate any pending retry.
    lastResult = nil
    lastLanguageDetection = nil
    // Drop feed-task handles — a `finalize()` after `cancel()` short-circuits to
    // `.cancelled` and never drains; the tasks themselves see `isTerminal` / the
    // session mismatch and skip (mirrors `ParakeetEngineAdapter.discardSession`).
    streamingFeedTasks.removeAll()
    clearSessionBuffers()
    prepareTask?.cancel()
    prepareTask = nil
    modelUnloadTask?.cancel()
    modelUnloadTask = nil
    if let live = streamingSession {
      streamingSession = nil
      streamingActive = false
      await live.cancel()
    }
    cachedReadiness = await backend.isReady ? .ready : .notReady
  }

  /// #959 fail-open ceiling for the wedge-recovery unload. NOT a measured perf
  /// threshold — it is the documented `withDeadline` fail-open budget: a healthy
  /// in-process `unload()` is effectively instant; this bounds the rare case
  /// where a wedged CoreML decode blocks `unload()` so recovery can never hang
  /// the kernel. The abandoned unload finishes in the background. Injectable so
  /// tests can drive a fast deadline; production uses the 2.0s default.
  private let wedgeRecoveryUnloadDeadlineSec: Double

  /// #959 HEAVY wedge recovery. The cheap discard (`cancel()`) PLUS a forced
  /// in-process backend unload so the next press reloads fresh. WhisperKit
  /// decodes IN-PROCESS, so a genuinely wedged CoreML decode could block
  /// `unload()` on the same locked resource — the unload is therefore
  /// deadline-bounded (fail-open: a blocked unload is abandoned rather than
  /// hanging recovery; a pathological in-process freeze may still need a user
  /// force-quit, unlike Parakeet's XPC service which the OS reaps). Called ONLY
  /// by the kernel's wedge detectors. Dormant in practice: WhisperKit is
  /// signal-free for load-wedge detection and exposes no `finalizeProgress`, so
  /// no kernel wedge detector currently fires for it (whisperkit-research.md).
  func recoverFromWedge() async {
    await cancel()
    let captured = backend
    _ = await withDeadline(seconds: wedgeRecoveryUnloadDeadlineSec) {
      await captured.unload()
    }
    cachedReadiness = .notReady
  }

  /// #1386 PR-2c. The EXPLICIT user-Remove unload: cancels session/load work
  /// and any pending policy unload, then AWAITS a full backend unload.
  /// Deliberately NOT `recoverFromWedge()`: that path is deadline-bounded and
  /// fail-open — an abandoned unload is acceptable for wedge recovery, but a
  /// Remove must have the model genuinely released (inference stopped, memory
  /// and disk reclaimable) before deletion proceeds.
  ///
  /// It does NOT drain a wedged CoreML task beyond `unload()`'s own semantics
  /// (ACCEPTED, plan §5c.2/§6.3 — reviewers re-derive this): deleting under a
  /// surviving mapping is safe (unlink keeps the inode until the last holder
  /// exits; no SIGBUS), so the worst case is disk space lingering until the
  /// wedged task dies. Blocking Remove on an unbounded CoreML drain would
  /// trade that bounded delay for an unbounded UI hang.
  package func unloadForRemoval() async {
    await cancel()
    modelUnloadTask?.cancel()
    modelUnloadTask = nil
    await backend.unload()
    cachedReadiness = .notReady
  }

  // MARK: ASREngineAdapter — cleanup

  /// Apply the model-unload policy. Mirrors
  /// `WhisperKitPipeline.scheduleModelUnloadIfNeeded:1457-1476`.
  /// Refuses to arm during an active session and session-keys the unload
  /// task so a delayed unload from session A cannot fire under session B
  /// (Codex r7 matrix S0-S3, S5, S6). The legacy pipeline armed unload
  /// only at the post-finalize terminal transition, so an
  /// active-session arming was implicitly disallowed; the kernel-driven
  /// model needs an explicit guard.
  func applyUnloadPolicy(_ policy: ModelUnloadPolicy) {
    modelUnloadTask?.cancel()
    modelUnloadTask = nil
    // Only arm when no active session exists (idle/post-terminal).
    guard sessionID == nil || isTerminal else { return }
    let armedSession = sessionID
    switch policy {
    case .never:
      return
    case .immediately:
      modelUnloadTask = Task { [backend, weak self] in
        guard !Task.isCancelled else { return }
        // Re-check session keying right before the unload call — a
        // `beginSession(B)` between arm and execute must NOT see A's
        // unload land on B.
        let shouldUnload = await MainActor.run { [weak self] () -> Bool in
          self?.sessionID == armedSession && (self?.isTerminal == true || self?.sessionID == nil)
        }
        guard shouldUnload else { return }
        // Final cancellation re-check: between the `shouldUnload` MainActor
        // hop and this point, a `beginSession(B)` may have cancelled this
        // task. Without the recheck, the cancelled task can still fire
        // `backend.unload()` under session B (Codex code-diff r8).
        guard !Task.isCancelled else { return }
        await backend.unload()
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
          self?.cachedReadiness = .notReady
        }
      }
    case .twoMinutes, .fiveMinutes, .tenMinutes, .fifteenMinutes, .sixtyMinutes:
      guard let interval = policy.interval else { return }
      modelUnloadTask = Task { [backend, weak self] in
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        let shouldUnload = await MainActor.run { [weak self] () -> Bool in
          self?.sessionID == armedSession && (self?.isTerminal == true || self?.sessionID == nil)
        }
        guard shouldUnload else { return }
        // Final cancellation re-check: between the `shouldUnload` MainActor
        // hop and this point, a `beginSession(B)` may have cancelled this
        // task. Without the recheck, the cancelled task can still fire
        // `backend.unload()` under session B (Codex code-diff r8).
        guard !Task.isCancelled else { return }
        await backend.unload()
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
          self?.cachedReadiness = .notReady
        }
      }
    }
  }

  // MARK: ASREngineAdapter optional engine hooks (PR-5 Rung 2A)

  /// Cancel any pending model-unload timer the adapter armed. The kernel
  /// fires this synchronously immediately before `beginSession(...)` in the
  /// Rung 2B `cancelPendingUnload-at-beginSession-not-preWarm` lesson —
  /// catches a fired timer that would otherwise leak the loaded model on
  /// abandoned PTT. Idempotent.
  func cancelPendingUnload() {
    modelUnloadTask?.cancel()
    modelUnloadTask = nil
  }

  // MARK: ASREngineAdapter — Phase 2 retry

  /// Best-effort, honest "stop waiting" signal for a retry that has timed
  /// out — NOT active cancellation (no genuine in-flight-decode cancel
  /// exists on this backend, §3.2a: a single in-flight CoreML prediction
  /// call is not itself interruptible). Bumping `retryGeneration` is what
  /// actually prevents a late-arriving abandoned result from mutating state
  /// belonging to a session/attempt that has since moved on.
  func bumpRetryGeneration() {
    retryGeneration &+= 1
  }

  /// #1707 Phase 2: a second, bounded batch decode attempt over the raw
  /// capture audio a PRIOR `finalize()` call already failed to decode.
  /// `finalize(batchSamples:)` ignores its own parameter and decodes
  /// `batchCaptureSamples` (raw capture) instead — so `inputSamples` here is
  /// the kernel's `captureResult.samples`, NOT the conditioned `asrSamples`
  /// (§3.2's per-adapter kernel-side selection).
  ///
  /// `clearSessionBuffers()` already cleared `batchCaptureSamples` and
  /// `observedSpeechSegments` on the first `finalize()`'s exit, so this
  /// CANNOT re-derive `paddedLIDSamples`/`transcriptionOptions(from:
  /// speechSegments:)` the way the first attempt did — that derivation needs
  /// segments that are gone. Instead: re-derive ONLY `paddedASRSamples` (a
  /// pure function of the raw bytes alone, no segments needed) straight from
  /// the `inputSamples` parameter — never touches `batchCaptureSamples`
  /// (Codex r3: an earlier revision repopulated it needlessly, retaining the
  /// full recording in memory for no reason since nothing reads it again
  /// here); reuse the post-LID `decodeOptions` the first attempt already
  /// finalized and left in place UNCHANGED (`clearSessionBuffers()` does not
  /// touch it) — never re-run language detection. LID was not the failure
  /// point (the decode was), and re-running it would introduce fresh
  /// nondeterminism and violate "same audio-coordinate and timestamp rules
  /// as the original attempt."
  func retryDecode(inputSamples: [Float]) async -> ASREngineOutcome {
    let session = sessionID
    let generation = retryGeneration
    // Codex r3: `retryDecode` never reads `batchCaptureSamples` again after
    // this point — it decodes solely from the local `inputSamples`/
    // `asrSamples` — so writing it here served no purpose and, worse,
    // retained the entire recording (potentially hundreds of MB) until some
    // later session's `beginSession()`/`cancel()` happened to clear it. No
    // assignment means nothing to release.
    let asrSamples = WhisperKitPipelineSpeechRouting.paddedASRSamples(
      rawSamples: inputSamples,
      minimumSamples: AudioConstants.minimumTranscriptionSamples
    )
    let batchOutcome = await runBatchDecode(samples: asrSamples)
    // Codex r10: fetch the model name (the only remaining backend hop)
    // BEFORE the staleness guard below, mirroring the normal finalize
    // path's identical ordering (`:889`) — an await between the guard and
    // the state mutation could let a cancel/interruption supersede this
    // retry in the gap, so the code would still commit and emit success
    // telemetry for an attempt the guard was meant to have already fenced.
    var modelNameForTelemetry: String?
    if case .success = batchOutcome {
      modelNameForTelemetry = await backend.modelVariantName
    }
    // Commit gate (§3.2a): write shared state ONLY while the captured
    // session and generation are still current — a late-arriving abandoned
    // retry must not mutate state belonging to a session/attempt that has
    // since moved on. Mirrors `ParakeetEngineAdapter.commitAttempt`.
    guard sessionID == session, retryGeneration == generation else { return .cancelled }
    switch batchOutcome {
    case .success(let result):
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return .empty(hadSpeechEvidence: true)
      }
      lastResult = result
      // #1707 Codex r9/r10: mirror the normal finalize path's per-
      // transcription latency telemetry (`:930` above) — without this,
      // every Phase-2 retry-rescued dictation silently drops out of the
      // model/language latency metric. Duration is derived from the
      // retry's own INPUT sample count, matching the normal path's
      // `rawSamples.count` (`:882`) — NOT `result.duration`:
      // `WhisperKitBackend.mapResults` sets that to the LAST DECODED
      // SEGMENT's end time, which can be shorter than the real capture
      // (trailing silence) or even zero when text exists without segment
      // timestamps, silently dropping exactly the retry telemetry this
      // fix exists to restore.
      let audioDurationSec = Double(inputSamples.count) / AudioConstants.sampleRate
      if audioDurationSec > 0, let modelName = modelNameForTelemetry {
        let msPerAudioSec = (result.processingTime * 1000.0) / audioDurationSec
        TelemetryService.shared.trackTranscriptionLatency(
          lang: result.language,
          model: modelName,
          durationSeconds: result.processingTime,
          msPerAudioSecond: msPerAudioSec
        )
      }
      return .transcript(result)
    case .cancelled:
      return .cancelled
    case .failed(let error):
      lastFailureError = error
      return .failed(.decodeFailed)
    }
  }

  // MARK: PCM retention

  /// Extract the buffer's Float32 samples and append to `retainedPCM`,
  /// bounded by `retainedPCMCap`. Mirrors `ParakeetEngineAdapter`'s shape.
  private func appendRetainedPCM(from buffer: AVAudioPCMBuffer) {
    guard retainedPCM.count < Self.retainedPCMCap else { return }
    let count = Int(buffer.frameLength)
    guard count > 0, let channel = buffer.floatChannelData?[0] else { return }
    let remaining = Self.retainedPCMCap - retainedPCM.count
    let take = min(count, remaining)
    retainedPCM.append(contentsOf: UnsafeBufferPointer(start: channel, count: take))
  }

  /// Append the buffer's Float32 samples to the lossless `streamingPCM` the
  /// streaming session reads, bounded by the same recording cap. Runs on
  /// `@MainActor` from a retained `streamingFeedTasks` task (#1276 PR-2).
  private func appendStreamingPCM(from buffer: AVAudioPCMBuffer) {
    guard streamingPCM.count < Self.retainedPCMCap else { return }
    let count = Int(buffer.frameLength)
    guard count > 0, let channel = buffer.floatChannelData?[0] else { return }
    let remaining = Self.retainedPCMCap - streamingPCM.count
    let take = min(count, remaining)
    streamingPCM.append(contentsOf: UnsafeBufferPointer(start: channel, count: take))
  }

  // MARK: Streaming flush (#1276 Step 2, PR-2)

  /// Await every dispatched streaming-feed task so `streamingPCM` holds the whole
  /// recording before the session flush — a non-empty streaming result is never
  /// finalized missing tail buffers still queued behind `acceptAudio`. Awaiting
  /// the task handles IS the completion signal; no wall-clock deadline (ported
  /// wholesale from `ParakeetEngineAdapter.drainStreamingFeeds`,
  /// RULE: port-proven-patterns-wholesale). Iterates a value snapshot and does
  /// NOT clear `streamingFeedTasks` — only `beginSession`/`cancel` clear it — so a
  /// session beginning during this drain's await cannot have its fresh feed
  /// handles dropped here.
  private func drainStreamingFeeds() async {
    let snapshot = streamingFeedTasks
    for task in snapshot { await task.value }
  }

  /// Flush the streaming session and turn its authoritative result into the
  /// finalize outcome. Returns:
  /// - a `.transcript` outcome on a non-empty flush (its text IS the transcript),
  /// - a terminal `.cancelled`/`.empty` on a stale-session race (no state mutation
  ///   that could clobber a fresh session),
  /// - `nil` when no streaming session ran OR the flush produced nothing usable —
  ///   `finalize` then falls through to the clean batch decode (fail-open, G4).
  private func finalizeStreamingSession(
    session: SessionID, sessionIDForLog: UInt64
  ) async -> ASREngineOutcome? {
    guard streamingActive, let live = streamingSession else { return nil }
    // #1309: snapshot stop-moment telemetry BEFORE the feed drain — a decode
    // can finish during the drain and undercount stop_while_decode_in_flight.
    await live.noteStopRequested()
    await drainStreamingFeeds()
    let flushStart = CFAbsoluteTimeGetCurrent()
    // The session ignores both params (single-coordinate design §3.2): it flushes
    // over its own `streamingPCM`, pulled via the retained provider.
    let result = await live.finalize(finalSamples: [], speechSegments: [])
    // Stale guard after the flush await — a cancel + new beginSession during the
    // flush must not let this stale finalize clobber the fresh session.
    guard sessionID == session, !isCancelled else {
      return isCancelled ? .cancelled : .empty(hadSpeechEvidence: true)
    }
    // Clear only THIS session's handle (a fresh session's stays installed).
    if (streamingSession as AnyObject?) === (live as AnyObject) {
      streamingSession = nil
      streamingActive = false
    }
    let trimmed = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.accepted, !trimmed.isEmpty else {
      // Streaming produced nothing usable — fall through to the batch fallback.
      // #1309: record WHY streaming degraded and preserve the whole flush
      // result — the batch fallback's diagnostics re-stamp every streaming
      // counter from it (Codex r1/r2).
      sessionStreamingDegradeReason =
        result.strategy == "streaming_flush_failed" ? "flush_throw" : "flush_empty"
      sessionDegradedFlushResult = result
      Task { [strategy = result.strategy] in
        await AppLogger.shared.log(
          "WhisperKit streaming flush empty (strategy=\(strategy)) — falling back to batch",
          level: .info, category: "WhisperKitEngineAdapter"
        )
      }
      return nil
    }
    let flushMs = Int((CFAbsoluteTimeGetCurrent() - flushStart) * 1000)
    let audioDurationSec = Double(result.samplesCovered) / AudioConstants.sampleRate
    // Preserve the locked-language detection state the batch finalize would have
    // set via `LanguageDetector.detect(.locked)` (Codex r4 P2). Streaming only
    // runs for a picked language, so it never calls LID — but downstream polish
    // (`DefaultPromptPlanner`) treats `whisperKit && languageDetection == nil` as
    // low confidence and DROPS per-language custom vocabulary. Mirror the locked
    // short-circuit result (`LanguageDetector.swift:160-170`) exactly. Synchronous
    // (no await after the stale guard) so no concurrent `beginSession(B)` can tear
    // this write.
    if let lockedCode = decodeOptions.language {
      lastLanguageDetection = LanguageDetectionResult(
        lang: lockedCode, confidence: 1.0, margin: 1.0, tier: .locked,
        voicedDuration: audioDurationSec, abstained: false, usedSessionPrior: false)
    }
    var diagnostics = KernelASRAdapterDiagnostics()
    diagnostics.rawSampleCount = result.samplesCovered
    diagnostics.lidCaptureSessionID = sessionIDForLog
    // #1309 effective-path telemetry: streaming ran and its flush IS the
    // transcript.
    diagnostics.streamingEffective = true
    diagnostics.streamingDegradeReason = "none"
    diagnostics.streamingFinalPath = "streaming_flush"
    diagnostics.incrementalDecodeCount = result.decodeCount
    diagnostics.incrementalSamplesCovered = result.samplesCovered
    diagnostics.incrementalTailDecodeMs = result.tailDecodeMs
    diagnostics.stopWhileDecodeInFlight = result.stopWhileDecodeInFlight
    diagnostics.streamingMaxUnconfirmedWindowSec =
      Double(WhisperKitStreamingSession.defaultMaxUnconfirmedWindowSec)
    lastASRDiagnostics = diagnostics
    isTerminal = true
    clearSessionBuffers()
    let asrResult = ASRResult(
      text: trimmed,
      language: decodeOptions.language,
      duration: audioDurationSec,
      processingTime: Double(flushMs) / 1000.0,
      backendType: .whisperKit
    )
    lastResult = asrResult
    Task { [chars = trimmed.count, decodes = result.decodeCount, tailMs = result.tailDecodeMs] in
      await AppLogger.shared.log(
        "WhisperKit streaming flush complete: chars=\(chars), decodes=\(decodes), "
          + "tailDecodeMs=\(tailMs) (\(flushMs)ms total)",
        level: .info, category: "WhisperKitEngineAdapter"
      )
    }
    return .transcript(asrResult)
  }

  // MARK: Batch decode helper

  private enum BatchDecodeOutcome {
    case success(ASRResult)
    case cancelled
    case failed(any Error)
  }

  private func runBatchDecode(samples: [Float]) async -> BatchDecodeOutcome {
    // #1707 Phase 2 (§11.1): DEBUG-only forced-failure fault, consulted only
    // AFTER the real retry input and decode-options snapshot are already
    // prepared by the caller — proving the retry genuinely re-decodes real,
    // already-captured audio, not a synthetic stand-in. `nil` controller
    // (production, and every test that doesn't opt in) never forces a failure.
    if batchDecodeFaultController?.shouldForceFailBatchDecode(
      backend: .whisperKit, sampleCount: samples.count) == true
    {
      return .failed(ASREngineError.decodeFailed)
    }
    do {
      let result = try await backend.transcribe(
        audioSamples: samples, options: decodeOptions)
      return .success(result)
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .failed(error)
    }
  }

  /// The `finalize`-facing result of the single batch-decode path.
  private enum BatchFallbackResult {
    case success(text: String, language: String?)
    /// Session changed under the decode await — `finalize` returns this
    /// verbatim WITHOUT mutating adapter state (a stale session-A finalize must
    /// not clobber session B).
    case stale(ASREngineOutcome)
    case cancelled
    case failed(any Error)
  }

  /// The one batch-decode authority for `finalize` (#1307: every path routes
  /// here now the worker is gone). Owns the `t_asr_start`/`t_asr_end` perf
  /// signposts, the post-decode stale guard, and the completion/failure log
  /// lines so batch entry lives in ONE place. Mutates
  /// `diagnostics.batchRescueResultChars` on success; all adapter-state writes
  /// (terminal flag, buffers, `lastFailureError`) stay in `finalize`.
  private func runBatchFallback(
    asrSamples: [Float],
    session: SessionID,
    sessionIDForLog: UInt64,
    voicedDurationSec: Double,
    lidWindowCount: Int,
    clipKind: String,
    diagnostics: inout KernelASRAdapterDiagnostics
  ) async -> BatchFallbackResult {
    let batchStart = CFAbsoluteTimeGetCurrent()
    logLIDPerfSignpost(
      "t_asr_start",
      sessionID: sessionIDForLog,
      voicedDuration: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind
    )
    let batchOutcome = await runBatchDecode(samples: asrSamples)
    logLIDPerfSignpost(
      "t_asr_end",
      sessionID: sessionIDForLog,
      voicedDuration: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind
    )
    // Stale guard immediately after the decode await — a stale failure/cancel
    // from session A MUST NOT clobber session B's state (Codex code-diff r2
    // defect 3).
    guard sessionID == session, !isCancelled else {
      return .stale(isCancelled ? .cancelled : .empty(hadSpeechEvidence: true))
    }
    switch batchOutcome {
    case .success(let result):
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      diagnostics.batchRescueResultChars = trimmed.count
      let batchMs = Int((CFAbsoluteTimeGetCurrent() - batchStart) * 1000)
      Task { [chars = trimmed.count] in
        await AppLogger.shared.log(
          "WhisperKit batch decode complete: chars=\(chars) (\(batchMs)ms)",
          level: .info, category: "WhisperKitEngineAdapter"
        )
      }
      return .success(text: trimmed, language: result.language)
    case .cancelled:
      return .cancelled
    case .failed(let error):
      // PR-5 Rung 5 Pass 2 #4: app.log line for the decode-failure path — the
      // user sees "ASR Failed" and the debug log needs a signature to grep.
      // Sentry still receives the error via `lastFailureError` →
      // `KernelLifecycleTelemetrySink`.
      Task { [desc = error.localizedDescription] in
        await AppLogger.shared.log(
          "WhisperKit batch decode failed: \(desc)",
          level: .info, category: "WhisperKitEngineAdapter"
        )
      }
      return .failed(error)
    }
  }

  // MARK: LID perf signposts
  //
  // PR-5 Rung 4.5 (#827): all six signpost names carry `session_id` for trace
  // joinability across interleaved sessions. The kernel emits `t_release`
  // from its unified accepted-stop transition; the wiring emits
  // `t_clipboard_write` from `KernelFinalizationWiring.deliver` reading the
  // session id from `lastASRDiagnostics.lidCaptureSessionID`. The four
  // adapter-emitted names are `t_state_flip`, `t_lid_start`, `t_lid_settled`,
  // `t_decode_start` (see call sites above).

  private func logLIDPerfSignpost(
    _ name: String,
    sessionID: UInt64,
    voicedDuration: TimeInterval? = nil,
    lidWindowCount: Int? = nil,
    clipKind: String? = nil
  ) {
    // `sessionID` passed in explicitly (not read from `self`) so a stale
    // finalize that resumes after a fresh `beginSession` reset the adapter's
    // `capturedCaptureSessionID` still emits with its session's id. Codex
    // code-diff review r2 caught the prior shared-property read race.
    var fields = [
      "lid_perf_signpost",
      "name=\(name)",
      "timestamp_s=\(String(format: "%.6f", CFAbsoluteTimeGetCurrent()))",
      "session_id=\(sessionID)",
    ]
    if let voicedDuration {
      fields.append("voiced_duration_s=\(String(format: "%.3f", voicedDuration))")
    }
    if let lidWindowCount {
      fields.append("lid_window_count=\(lidWindowCount)")
    }
    if let clipKind {
      fields.append("clip_kind=\(clipKind)")
    }
    let message = fields.joined(separator: " ")
    Task {
      await AppLogger.shared.log(message, level: .info, category: "WhisperKitEngineAdapter")
    }
  }
}

// MARK: - ASREngineTelemetryProviding conformance

extension WhisperKitEngineAdapter: ASREngineTelemetryProviding {}

// MARK: - PR-5 Rung 5 (#827) — optional capability conformances

extension WhisperKitEngineAdapter: ASREngineLanguageIdentifying {}

// #879: the `ASREngineCacheModelLoadable` conformance (`prepareModelIfCached`)
// was removed with `KernelDictationDriver.prepareBackendSilently()`. WhisperKit's
// launch warm-up now routes through the shared `ensureEngineWarm(reason: .launch)`
// (gated by `SetupCoordinator` on `setupState == .ready`), which drives
// `warmUp()` → `backend.prepare()` (cache-first, with the existing download
// fallback). The kernel's `preWarm` cache-refresh still uses `warmUpFromCache()`.

// MARK: - Test-only inspectors (`@testable import` reaches `internal`)

extension WhisperKitEngineAdapter {
  /// Test-only read of the retained PCM. The production read site is the
  /// incremental worker's provider closure, which captures `self` weakly and
  /// reads `retainedPCM` on `@MainActor`.
  // periphery:ignore - test seam
  internal var retainedPCMForUnitTests: [Float] { retainedPCM }
  /// Test-only read of the kernel-supplied speech segments.
  // periphery:ignore - test seam
  internal var observedSpeechSegmentsForUnitTests: [SpeechSegment] { observedSpeechSegments }
  /// Test-only handle to the armed model-unload task. Tests `await
  /// adapter.modelUnloadTaskForUnitTests?.value` to wait for an armed
  /// `.immediately` unload deterministically instead of yield-polling — the
  /// task always completes (it returns whether or not it fires `unload()`),
  /// so the await is bounded. Avoids the release-config flake where the
  /// scheduled unload had not run within a fixed `Task.yield()` budget.
  // periphery:ignore - test seam
  internal var modelUnloadTaskForUnitTests: Task<Void, Never>? { modelUnloadTask }
}

// MARK: - WhisperKitBackendDriving — local seam for testability (OQ-4 option a)

/// Actor-bound protocol that captures every WhisperKit-backend surface this
/// adapter needs to drive. Declared `package` and local to this file so the
/// protocol surface for the adapter stays in Pipeline; tests inject a stub
/// conforming to this protocol without loading a real WhisperKit model. The
/// concrete `WhisperKitBackend` (in `EnviousWisprASR`) is retro-conformed
/// below.
///
/// The `: Actor` constraint mirrors `package protocol ASRBackend: Actor` at
/// `Sources/EnviousWisprASR/ASRProtocol.swift:14` — `WhisperKitBackend.isReady`
/// is actor-isolated (`public private(set) var isReady`), so the synchronous
/// protocol requirement only satisfies through an actor-bound protocol.
package protocol WhisperKitBackendDriving: Actor {
  var isReady: Bool { get }
  var modelVariantName: String { get }
  /// #1275 item A: duration of the most recent silent warm-up inference, in
  /// milliseconds. `nil` until the first load's warm-up reaches a terminal
  /// state (completed/threw/timed-out — only `.completed` sets it).
  var lastWarmupInferenceMs: Int? { get }
  func prepare() async throws
  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult
  func observeLID(samples: [Float], maxWindows: Int) async -> LIDObservationBatch
  // #1276 Step 2 (PR-2): vend the authoritative streaming session
  // (locked-language Live-transcription path). Nil when the model is not
  // loaded (the adapter stays in batch mode, fail-open).
  func makeStreamingSession(options: TranscriptionOptions) async
    -> (any WhisperKitIncrementalSession)?
  func unload() async
}

// Retroactive conformance — `WhisperKitBackend` already has every requirement
// at the right access level (`isReady` public, `modelVariantName` package,
// `prepare()` public, `transcribe(...)` public,
// `observeLID(...)` package, `makeStreamingSession(...)` package, `unload()`
// public). No method additions needed in `EnviousWisprASR`.
extension WhisperKitBackend: WhisperKitBackendDriving {}
