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
// network), `beginSession` (cancel pending model unload, start incremental
// worker in `.locked` mode only), `acceptAudio` (retained-PCM accumulator,
// bounded to ~19 MB), `observeSpeechSegments` (store voiced ranges from the
// kernel's VAD), `finalize` (LID → transcribe with `clipTimestamps` derived
// from observed segments → incremental-worker-then-batch-fallback decode),
// `cancel` (cancels held tasks + worker), `applyUnloadPolicy` (delay-then-
// unload timer mirroring `scheduleModelUnloadIfNeeded`), `cancelPendingUnload`
// (Rung 2B kernel hook).
//
// Scope (epic §4): an adapter owns its own ASR and rescue and NOTHING else —
// no capture, no finalization, no paste, no UI, no FSM, no kernel state. The
// adapter holds legitimate engine-session bookkeeping (a session ID, decode
// options, an `isTerminal`/`isCancelled` pair, the retained PCM (live worker
// only), the authoritative batch-capture buffer, the observed speech segments,
// the LID result, held async-task handles).
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
// single-capture-coordinate parity. `retainedPCM` now feeds ONLY the live
// incremental worker (best-effort, tolerates the lossiness). The Parakeet
// adapter MUST use `batchSamples`; this adapter MUST NOT.

/// The kernel-facing `ASREngineAdapter` conformer for WhisperKit. Drives the
/// underlying WhisperKit actor through a local `package` protocol seam
/// (`WhisperKitBackendDriving` below) so tests can inject a stub without
/// loading a real model.
@MainActor
final class WhisperKitEngineAdapter: ASREngineAdapter {

  // MARK: Injected dependencies

  private let backend: any WhisperKitBackendDriving
  private let languageDetector: LanguageDetector

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

  /// Synchronously-readable cached readiness. WhisperKit's `isReady` lives on
  /// an actor (`public private(set) var isReady`); the `ASREngineAdapter`
  /// protocol's `readiness` getter is synchronous, so the adapter caches the
  /// most-recent observed state and refreshes it on every transition. All
  /// mutations happen on `@MainActor`, so the cache update is observable to
  /// any subsequent `@MainActor` reader without an intervening `await`.
  private var cachedReadiness: ASREngineReadiness = .notReady

  // MARK: Engine state

  /// Issue #445: held `prepare()` task so `cancel()` can cancel its host
  /// await even though CoreML's `MLModel.load` is uncancellable cooperatively.
  /// The backend's single-flight guard handles the orphan that keeps grinding.
  private var prepareTask: Task<Void, Error>?

  /// The incremental decoding worker — present only in `.locked` language
  /// mode. `WhisperKitPipeline.swift:519-530`: in `.auto` mode the worker
  /// would snapshot the legacy language and decode with the wrong language;
  /// post-LID batch decode is the only correct path. The worker reads
  /// `retainedPCM` via its provider closure.
  private var incrementalWorker: (any WhisperKitIncrementalSession)?

  /// Pending model-unload timer armed by `applyUnloadPolicy(_:)`.
  /// `cancelPendingUnload()` (the Rung 2B kernel hook called pre-`beginSession`)
  /// and `beginSession` (defense-in-depth) both cancel it.
  private var modelUnloadTask: Task<Void, Never>?

  // MARK: Audio + speech segments

  /// Live per-buffer accumulation from every `acceptAudio(_:)`, fed via
  /// `onBufferCaptured` during capture. Used ONLY by the incremental worker's
  /// live `audioSamplesProvider` (locked-language mode). It is NOT the
  /// batch-decode buffer: this stream is async/lossy and diverges in length
  /// from the kernel's authoritative `captureResult.samples`, so using it for
  /// the post-stop batch decode caused the "Audio samples are nil" alternating
  /// failure (PR-5 Rung 5 UAT #827). Batch decode uses `batchCaptureSamples`
  /// instead. The worker stays best-effort by design and tolerates the
  /// lossiness; the batch path does not. Cleared on `cancel()` / `finalize()`.
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

  /// Cap on `retainedPCM` — `maxRecordingDuration` worth of 16 kHz mono samples
  /// (300 s * 16 kHz = 4.8 M Float = ~19 MB). Mirrors Parakeet's cap so the
  /// two engines size memory the same way. On reaching the cap the
  /// accumulation stops growing; recording auto-stops on max-duration anyway.
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

  // MARK: Init

  init(
    backend: any WhisperKitBackendDriving,
    languageDetector: LanguageDetector = LanguageDetector(),
    audioCaptureSessionIDSource: @escaping @MainActor () -> UInt64 = { 0 }
  ) {
    self.backend = backend
    self.languageDetector = languageDetector
    self.audioCaptureSessionIDSource = audioCaptureSessionIDSource
  }

  // MARK: ASREngineAdapter — identity & capability

  /// Self-declared identity. The kernel reads from here at every site that
  /// previously hard-coded an engine literal (PR-5 Rung 1).
  var engineIdentity: ASREngineIdentity {
    ASREngineIdentity(backendType: .whisperKit)
  }

  /// WhisperKit decodes batch-only (no streaming) and runs engine-internal
  /// LID. Static — the kernel branches on `capabilities`, never on engine
  /// identity (epic §3.4).
  var capabilities: ASREngineCapabilities {
    ASREngineCapabilities(supportsStreaming: false, supportsLanguageDetection: true)
  }

  var readiness: ASREngineReadiness { cachedReadiness }

  // MARK: ASREngineAdapter — warm-up

  /// Idempotent, sessionless warm-up. Held `prepareTask` so `cancel()` can
  /// cancel the host await; the backend's single-flight guard owns the
  /// in-flight CoreML load semantics (`#445`). CoreML's `MLModel.load` exposes
  /// no progress signal, so the kernel runs signal-free warm-up — no wedge
  /// detection, no wall-clock timeout (per the protocol's MUST NOT clause).
  func warmUp() async throws {
    if await backend.isReady {
      cachedReadiness = .ready
      return
    }
    cachedReadiness = .warming
    let captured = backend
    let task = Task<Void, Error> { try await captured.prepare() }
    prepareTask = task
    do {
      try await task.value
      prepareTask = nil
      cachedReadiness = .ready
    } catch {
      prepareTask = nil
      cachedReadiness = .notReady
      throw error
    }
  }

  /// Cache-only warm-up — intentionally a near no-op for WhisperKit.
  ///
  /// Earlier drafts dispatched `prepareIfCached()` here on a detached `Task`
  /// to silently load a cached model during the kernel's `preWarm` hop. But
  /// `WhisperKitBackend.prepareIfCached()` does NOT participate in
  /// `prepare()`'s `loadTask` single-flight guard at
  /// `WhisperKitBackend.swift:61-97` — so a detached `prepareIfCached` racing
  /// the kernel's spawned `warmUp()` (which calls `prepare()`) can launch
  /// two concurrent CoreML loads, doubling cold-start work and memory
  /// pressure (Codex code-diff r5).
  ///
  /// In the kernel-driven flow, the kernel's spawned `warmUp()` path
  /// already calls `prepare()`, which internally checks
  /// `WhisperKitSetupService.getLocalModelPath` and loads from cache when
  /// the model is cached. So no `warmUpFromCache` work is needed here —
  /// the cached-load optimization is preserved by `prepare()`'s own cache
  /// branch, and the single-flight guard prevents duplicate loads.
  ///
  /// Side effect: keep `cachedReadiness` refreshed against the backend's
  /// current state so a recently-unloaded model is reported as `.notReady`.
  func warmUpFromCache() async throws {
    cachedReadiness = await backend.isReady ? .ready : .notReady
  }

  /// WhisperKit / CoreML exposes no model-load progress signal. The kernel
  /// runs signal-free `warmingUp` with no wedge detection, per the protocol's
  /// MUST NOT clause.
  var loadProgress: AsyncStream<ASRLoadProgressTick>? { nil }

  // `lastObservedPhase` falls back to the protocol-extension default
  // (`"warmup"`) — WhisperKit's loader exposes no phase strings.

  // MARK: ASREngineAdapter — session lifecycle

  /// Begin a session. WhisperKit doesn't stream — `streaming` is ignored for
  /// the live-stream decision. In `.locked` language mode (`options.language`
  /// non-nil) the incremental worker is started so finalize can use its
  /// best-effort result before falling back to batch. In `.auto` mode
  /// (language nil) the worker is intentionally skipped — see
  /// `WhisperKitPipeline.swift:519-530` for the rationale (the worker
  /// snapshots language at start; in `.auto` it would decode with the wrong
  /// language).
  func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws {
    sessionID = id
    decodeOptions = options
    isTerminal = false
    isCancelled = false
    lastResult = nil
    lastASRDiagnostics = nil
    lastFailureError = nil
    lastLanguageDetection = nil
    retainedPCM.removeAll(keepingCapacity: true)
    observedSpeechSegments.removeAll()
    // Clear the authoritative batch buffer so a session that reaches finalize
    // without `observeSpeechSegments` can never decode a prior session's audio
    // (#827).
    batchCaptureSamples.removeAll(keepingCapacity: true)
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

    // Cancel + drop any orphan worker from a prior session — if the previous
    // session was superseded before finalize/cancel cleared the handle, the
    // worker would still be installed and the auto-mode branch below would
    // erroneously route through it (Codex code-diff r3 defect 2). Fire the
    // cancel detached so beginSession stays nominally fast; the worker
    // itself is safe to discard immediately since no caller holds it.
    if let orphan = incrementalWorker {
      incrementalWorker = nil
      Task { await orphan.cancel() }
    }

    // Refresh cached readiness — backend may have been unloaded by a prior
    // session's policy timer that fired while idle.
    cachedReadiness = await backend.isReady ? .ready : .notReady

    // `.locked` mode → start the worker. In `.auto` mode language is unknown
    // until LID runs at finalize, so the worker is skipped.
    if options.language != nil {
      if let session = await backend.makeIncrementalSession(options: options) {
        // Stale-beginSession guard: a `cancel()` + new `beginSession(B)`
        // during the `makeIncrementalSession` await must NOT let this
        // stale install land on the fresh session — otherwise `finalize`
        // for B would see a non-nil `incrementalWorker` from A and route
        // through it (Codex code-diff r6).
        guard sessionID == id, !isCancelled else {
          await session.cancel()
          return
        }
        incrementalWorker = session
        await session.start(audioSamplesProvider: { @MainActor [weak self] in
          let samples = self?.retainedPCM ?? []
          return (samples: samples, count: samples.count)
        })
        // Stale-beginSession guard AFTER `session.start`: if a `cancel()` +
        // new `beginSession(B)` landed during the start await, the worker
        // was installed under the wrong session. Uninstall + cancel it
        // (Codex r7 matrix S6).
        guard sessionID == id, !isCancelled else {
          if (incrementalWorker as AnyObject?) === (session as AnyObject) {
            incrementalWorker = nil
          }
          await session.cancel()
          return
        }
        Task {
          await AppLogger.shared.log(
            "WhisperKit recording started (batch mode, incremental worker: on)",
            level: .info, category: "WhisperKitEngineAdapter"
          )
        }
      } else {
        Task {
          await AppLogger.shared.log(
            "WhisperKit recording started (batch mode, incremental worker: off, model not loaded)",
            level: .info, category: "WhisperKitEngineAdapter"
          )
        }
      }
    } else {
      Task {
        await AppLogger.shared.log(
          "WhisperKit recording started (batch mode, incremental worker: off, auto language mode)",
          level: .info, category: "WhisperKitEngineAdapter"
        )
      }
    }
  }

  /// Accept one captured buffer. Always appends to `retainedPCM` (bounded by
  /// `retainedPCMCap`). A call after a terminal session is a no-op
  /// (PR-1 §B.2.2). WhisperKit has no live stream — buffers are batched
  /// until `finalize`.
  func acceptAudio(_ buffer: AudioBufferHandoff) {
    // Drop late buffers from a prior session — PR-1 §B.3 / FSM invariant 7:
    // a buffer whose `sessionID` is not the kernel's current session is
    // dropped. Without this gate, a delayed handoff after `beginSession(B)`
    // would land in session B's `retainedPCM` and misalign the
    // segment-derived `clipTimestamps` for batch decode (Codex code-diff r3
    // defect 3).
    guard !isTerminal, !isCancelled, buffer.sessionID == sessionID else { return }
    appendRetainedPCM(from: buffer.buffer)
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
  /// segments → incremental-worker-result-or-batch-fallback. After `cancel()`,
  /// returns `.cancelled`. **MUST NOT use `batchSamples`** (it is the kernel's
  /// VAD-filtered `conditioned.samples`, a different coordinate) — see the
  /// coordinate-space note above and the protocol comment at
  /// `ASREngineAdapter.swift:240-247`. Batch-decodes `batchCaptureSamples` (the
  /// authoritative raw `captureResult.samples` handed in by
  /// `observeSpeechSegments`) so segment-derived `clipTimestamps` stay
  /// coordinate-aligned (#827). `retainedPCM` feeds only the live incremental
  /// worker, never this batch decode.
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
    // `incrementalWorker`/`decodeOptions` for the rest of finalize. The
    // downstream guards catch session B's state AFTER the next awaits, but
    // an early bail here prevents reading session B's worker between
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

    // Decode — worker-result first, batch fallback. Diagnostics surface
    // through `lastASRDiagnostics` on every terminal outcome.
    var diagnostics = KernelASRAdapterDiagnostics()
    diagnostics.rawSampleCount = rawSamples.count
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

    let asrText: String
    let asrLanguage: String?
    let asrStart = CFAbsoluteTimeGetCurrent()

    if let worker = incrementalWorker {
      // Snapshot the worker handle for THIS session — if session B starts
      // while this await is suspended, `incrementalWorker` may already point
      // at B's worker. Clear only the captured handle on the post-await
      // session-match path (Codex code-diff r2 defect 2).
      let capturedWorker = worker
      let workerResult = await capturedWorker.finalize(
        finalSamples: rawSamples, speechSegments: speechSegments)
      if sessionID == session, !isCancelled {
        // Only A's worker handle can be cleared. If session B is now
        // current, its worker stays installed.
        if (incrementalWorker as AnyObject?) === (capturedWorker as AnyObject) {
          incrementalWorker = nil
        }
      } else {
        return isCancelled ? .cancelled : .empty(hadSpeechEvidence: true)
      }
      diagnostics.incrementalAccepted = workerResult.accepted
      diagnostics.incrementalResultChars =
        workerResult.text?.trimmingCharacters(in: .whitespacesAndNewlines).count
      diagnostics.incrementalDecodeCount = workerResult.decodeCount
      diagnostics.incrementalSamplesCovered = workerResult.samplesCovered
      diagnostics.incrementalStrategy = workerResult.strategy
      diagnostics.incrementalMode = workerResult.mode
      diagnostics.incrementalTailDecodeMs = workerResult.tailDecodeMs

      if workerResult.accepted, let text = workerResult.text,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        asrText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        asrLanguage = decodeOptions.language
        Task {
          [
            text = asrText, strategy = workerResult.strategy, mode = workerResult.mode,
            decodes = workerResult.decodeCount, tailMs = workerResult.tailDecodeMs,
            covered = workerResult.samplesCovered, totalSamples = rawSamples.count
          ] in
          let coveragePct =
            totalSamples > 0
            ? String(format: "%.1f", Double(covered) / Double(totalSamples) * 100)
            : "0"
          await AppLogger.shared.log(
            "WhisperKit finalize: strategy=\(strategy), mode=\(mode), "
              + "decodes=\(decodes), tailDecodeMs=\(tailMs), "
              + "coverage=\(covered)/\(totalSamples) (\(coveragePct)%) chars=\(text.count)",
            level: .info, category: "WhisperKitEngineAdapter"
          )
        }
      } else {
        // Batch fallback over the raw capture buffer. PR-5 Rung 5 Pass 2 #7:
        // log the fallback reason so debug-build readers can grep app.log
        // for the worker→batch handoff (parity with the OLD
        // `WhisperKitPipeline.swift:898-914` fallback log).
        Task {
          [
            decodes = workerResult.decodeCount,
            samplesCovered = workerResult.samplesCovered,
            totalSamples = rawSamples.count,
            strategy = workerResult.strategy,
            mode = workerResult.mode,
            chars = (workerResult.text ?? "").count
          ] in
          let coveragePct =
            totalSamples > 0
            ? String(format: "%.1f", Double(samplesCovered) / Double(totalSamples) * 100)
            : "0"
          await AppLogger.shared.log(
            "WhisperKit incremental worker rejected — falling back to batch "
              + "(strategy=\(strategy), mode=\(mode), decodes=\(decodes), "
              + "coverage=\(samplesCovered)/\(totalSamples) (\(coveragePct)%), chars=\(chars))",
            level: .info, category: "WhisperKitEngineAdapter"
          )
        }
        let batchFallbackStart = CFAbsoluteTimeGetCurrent()
        logLIDPerfSignpost(
          "t_asr_start",
          sessionID: sessionIDForLog,
          voicedDuration: voicedDurationSec,
          lidWindowCount: lidWindowCount,
          clipKind: clipKind
        )
        diagnostics.batchRescueAttempted = true
        let batchOutcome = await runBatchDecode(samples: asrSamples)
        logLIDPerfSignpost(
          "t_asr_end",
          sessionID: sessionIDForLog,
          voicedDuration: voicedDurationSec,
          lidWindowCount: lidWindowCount,
          clipKind: clipKind
        )
        // Stale guard immediately after the decode await — a stale
        // failure/cancel from session A MUST NOT clobber session B's
        // state (Codex code-diff r2 defect 3).
        guard sessionID == session, !isCancelled else {
          return isCancelled ? .cancelled : .empty(hadSpeechEvidence: true)
        }
        switch batchOutcome {
        case .success(let result):
          let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
          diagnostics.batchRescueResultChars = trimmed.count
          asrText = trimmed
          asrLanguage = result.language
          // PR-5 Rung 5 Pass 2 #7: log batch timing so worker→batch
          // fallback duration is debuggable (OLD `WhisperKitPipeline.swift:945-950`).
          let batchMs = Int((CFAbsoluteTimeGetCurrent() - batchFallbackStart) * 1000)
          Task { [chars = trimmed.count] in
            await AppLogger.shared.log(
              "WhisperKit batch fallback complete: chars=\(chars) (\(batchMs)ms)",
              level: .info, category: "WhisperKitEngineAdapter"
            )
          }
        case .cancelled:
          isTerminal = true
          clearSessionBuffers()
          return .cancelled
        case .failed(let error):
          // PR-5 Rung 5 Pass 2 #4: app.log line for the decode-failure
          // path — without it the user sees "ASR Failed" and the local
          // debug log has zero signature to grep (the UAT-caught gap).
          // Sentry still receives the error via `lastFailureError` →
          // `KernelLifecycleTelemetrySink`.
          Task { [desc = error.localizedDescription] in
            await AppLogger.shared.log(
              "WhisperKit batch-fallback decode failed: \(desc)",
              level: .info, category: "WhisperKitEngineAdapter"
            )
          }
          lastFailureError = error
          lastASRDiagnostics = diagnostics
          isTerminal = true
          clearSessionBuffers()
          return .failed(.decodeFailed)
        }
      }
    } else {
      // `.auto` mode (or worker setup failed): batch only.
      logLIDPerfSignpost(
        "t_asr_start",
        sessionID: sessionIDForLog,
        voicedDuration: voicedDurationSec,
        lidWindowCount: lidWindowCount,
        clipKind: clipKind
      )
      diagnostics.batchRescueAttempted = false
      let batchOutcome = await runBatchDecode(samples: asrSamples)
      logLIDPerfSignpost(
        "t_asr_end",
        sessionID: sessionIDForLog,
        voicedDuration: voicedDurationSec,
        lidWindowCount: lidWindowCount,
        clipKind: clipKind
      )
      // Stale guard immediately after the decode await — a stale
      // failure/cancel from session A MUST NOT clobber session B's
      // state (Codex code-diff r2 defect 3).
      guard sessionID == session, !isCancelled else {
        return isCancelled ? .cancelled : .empty(hadSpeechEvidence: true)
      }
      switch batchOutcome {
      case .success(let result):
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.batchRescueResultChars = trimmed.count
        asrText = trimmed
        asrLanguage = result.language
      case .cancelled:
        isTerminal = true
        clearSessionBuffers()
        return .cancelled
      case .failed(let error):
        // PR-5 Rung 5 Pass 2 #4: app.log line for the auto-mode batch
        // decode-failure path — same parity rationale as the
        // worker→batch fallback failure branch above.
        Task { [desc = error.localizedDescription] in
          await AppLogger.shared.log(
            "WhisperKit batch decode failed: \(desc)",
            level: .info, category: "WhisperKitEngineAdapter"
          )
        }
        lastFailureError = error
        lastASRDiagnostics = diagnostics
        isTerminal = true
        clearSessionBuffers()
        return .failed(.decodeFailed)
      }
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
  }

  /// Idempotent discard. Cancels held tasks (prepare, model-unload timer) and
  /// the incremental worker; clears retained audio + segments + capture buffer
  /// + LID result.
  func cancel() async {
    isCancelled = true
    isTerminal = true
    lastResult = nil
    lastLanguageDetection = nil
    clearSessionBuffers()
    prepareTask?.cancel()
    prepareTask = nil
    modelUnloadTask?.cancel()
    modelUnloadTask = nil
    if let worker = incrementalWorker {
      incrementalWorker = nil
      await worker.cancel()
    }
    cachedReadiness = await backend.isReady ? .ready : .notReady
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

  // MARK: Batch decode helper

  private enum BatchDecodeOutcome {
    case success(ASRResult)
    case cancelled
    case failed(any Error)
  }

  private func runBatchDecode(samples: [Float]) async -> BatchDecodeOutcome {
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

extension WhisperKitEngineAdapter: ASREngineCacheModelLoadable {
  /// Silent model pre-load matching the OLD `WhisperKitPipeline.prepareBackendSilently()`
  /// at `:349-377` byte-for-byte: checks `backend.isReady`, calls
  /// `backend.prepareIfCached()` (cache-only, no download), logs the three OLD
  /// messages to AppLogger under the surviving `"WhisperKitPipeline"` category,
  /// swallows errors. Called from `KernelDictationDriver.prepareBackendSilently()`
  /// via the `as? any ASREngineCacheModelLoadable` cast on the adapter.
  package func prepareModelIfCached() async {
    let isBackendReady = await backend.isReady
    guard !isBackendReady else { return }
    do {
      let loaded = try await backend.prepareIfCached()
      if loaded {
        Task {
          await AppLogger.shared.log(
            "WhisperKit model pre-loaded successfully (background)",
            level: .info, category: "WhisperKitPipeline"
          )
        }
      } else {
        Task {
          await AppLogger.shared.log(
            "WhisperKit model not cached, skipping silent pre-load",
            level: .info, category: "WhisperKitPipeline"
          )
        }
      }
    } catch {
      Task {
        await AppLogger.shared.log(
          "WhisperKit model pre-load failed: \(error.localizedDescription)",
          level: .info, category: "WhisperKitPipeline"
        )
      }
    }
  }
}

// MARK: - Test-only inspectors (`@testable import` reaches `internal`)

extension WhisperKitEngineAdapter {
  /// Test-only read of the retained PCM. The production read site is the
  /// incremental worker's provider closure, which captures `self` weakly and
  /// reads `retainedPCM` on `@MainActor`.
  internal var retainedPCMForUnitTests: [Float] { retainedPCM }
  /// Test-only read of the kernel-supplied speech segments.
  internal var observedSpeechSegmentsForUnitTests: [SpeechSegment] { observedSpeechSegments }
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
  func prepare() async throws
  func prepareIfCached() async throws -> Bool
  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult
  func observeLID(samples: [Float], maxWindows: Int) async -> LIDObservationBatch
  func makeIncrementalSession(options: TranscriptionOptions) async
    -> (any WhisperKitIncrementalSession)?
  func unload() async
}

// Retroactive conformance — `WhisperKitBackend` already has every requirement
// at the right access level (`isReady` public, `modelVariantName` package,
// `prepare()` public, `prepareIfCached()` package, `transcribe(...)` public,
// `observeLID(...)` package, `makeIncrementalSession(...)` package, `unload()`
// public). No method additions needed in `EnviousWisprASR`.
extension WhisperKitBackend: WhisperKitBackendDriving {}
