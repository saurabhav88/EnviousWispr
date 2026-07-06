@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation

// MARK: - ParakeetEngineAdapter (epic #827, PR-4 §3.2)
//
// The production `ASREngineAdapter` conformer for the Parakeet engine. It wraps
// `any ASRManagerInterface` — Parakeet's model lives in the XPC ASR service
// (PR-1 §B.2 names `ASRManagerInterface`, not a raw `ASRBackend`).
//
// Scope (epic §4): an adapter owns its own ASR and rescue and NOTHING else — no
// capture, no finalization, no paste, no UI, no FSM, no kernel state. This
// adapter owns Parakeet transcription, the streaming-finalize-then-batch rescue
// (D14, today the old Parakeet pipeline's `transcribeWithStreamingRescue`), and the
// full-session PCM the batch rescue needs (§3.2a). It holds legitimate
// engine-session bookkeeping (a streaming-active flag, the retained PCM, an
// in-flight-load flag, a terminal / cancelled flag) — session bookkeeping is
// explicitly NOT FSM state (Codex finding 46, §3.11 adapter-shape check).
//
// PR-4a ships this production-unwired: no App-layer caller constructs it yet.
// PR-4b wires it behind the Parakeet branch and deletes the old Parakeet pipeline.

/// Wraps Parakeet's `ASRManagerInterface` as a kernel-facing `ASREngineAdapter`.
@MainActor
final class ParakeetEngineAdapter: ASREngineAdapter {

  // MARK: Injected dependency

  private let asrManager: any ASRManagerInterface

  // MARK: Engine-session bookkeeping (NOT FSM state — §3.11)

  /// The session `beginSession(_:)` opened, or `nil` between sessions.
  private var sessionID: SessionID?
  /// Decode options bound at `beginSession(_:)`, reused by the batch rescue.
  private var decodeOptions: TranscriptionOptions = .default
  /// `true` between a successful `startStreaming(...)` and `finalize()` /
  /// `cancel()`. `false` means this session decodes batch-after-stop.
  private var streamingActive = false
  /// `true` once `finalize()` or `cancel()` has completed — `acceptAudio(_:)`
  /// after this is a no-op (PR-1 §B.2.2).
  private var isTerminal = false
  /// `true` once `cancel()` ran — `finalize()` then returns `.cancelled`.
  private var isCancelled = false
  /// `true` while `warmUp()` has a `loadModel()` in flight — feeds `readiness`.
  private var isLoadInFlight = false
  private var streamingBuffersDispatched = 0
  private var streamingBuffersFed = 0

  /// In-flight streaming-feed tasks. `acceptAudio(_:)` dispatches each
  /// `feedAudio` on its own task and appends the handle here; `finalize()`
  /// awaits every handle before `finalizeStreaming()`, so a non-empty streaming
  /// result is never finalized missing the tail buffers. Awaiting the actual
  /// task is the completion signal — no wall-clock deadline. A `ContinuousClock`
  /// deadline raced the `@MainActor` scheduler: under contention it fired before
  /// queued feed tasks ran, dropping tail audio (Codex PR-4a r4, reproduced as a
  /// `finalizeDrainsStreamingFeeds` flake). Each task awaits `feedAudio` inside a
  /// `do/catch` (the task type is `Task<Void, Never>`), so it always completes —
  /// on success or a swallowed thrown error — never hangs.
  private var feedTasks: [Task<Void, Never>] = []

  // MARK: Batch-rescue PCM retention (§3.2a)

  /// The whole session's 16 kHz mono Float32 samples, accumulated from every
  /// `acceptAudio(_:)`. The streaming-finalize-then-batch rescue needs the
  /// complete audio; streaming feeds buffers piecemeal and `ASRManagerInterface`
  /// does not retain them. Cleared on `cancel()` and on `finalize()` return —
  /// no accumulation outlives its session.
  private var retainedPCM: [Float] = []

  /// The `ASRResult` of the last successful `finalize()`, or `nil`. The kernel
  /// threads only `result.text` to its `runFinalizing` closures, so the
  /// finalization wiring reads the result's metadata (`language`, `duration`,
  /// `processingTime`) from here to build the `Transcript` (PR-4 §3.3).
  /// Cleared on `beginSession()` and `cancel()`.
  private(set) var lastResult: ASRResult?
  private(set) var lastASRDiagnostics: KernelASRAdapterDiagnostics?
  private(set) var lastFailureError: (any Error)?

  /// Cap on `retainedPCM` — `maxRecordingDuration` worth of 16 kHz mono samples
  /// (3600 s x 16 kHz = 57.6 M `Float` = ~230 MB; #1060 raised the cap 300→3600).
  /// On reaching the cap the accumulation stops growing; recording auto-stops on
  /// max-duration anyway.
  private static let retainedPCMCap = Int(
    TimingConstants.maxRecordingDuration * AudioConstants.sampleRate)

  // MARK: Load-progress stream

  private let loadStream: AsyncStream<ASRLoadProgressTick>
  private let loadContinuation: AsyncStream<ASRLoadProgressTick>.Continuation
  private var loadMarker: UInt64 = 0

  // MARK: ASREngineAdapter — engine interruption

  /// Optional adapter-local interruption hook. Parakeet leaves
  /// `ASRManagerInterface.onServiceInterrupted` to `ASREventRouter` so the
  /// shared ASR callback has one owner.
  var onEngineInterrupted: (@MainActor () -> Void)?

  // MARK: Init

  init(asrManager: any ASRManagerInterface) {
    self.asrManager = asrManager
    (loadStream, loadContinuation) = AsyncStream.makeStream(of: ASRLoadProgressTick.self)
    // ASR service interruption is single-owner at the App router. Installing
    // here races `ASREventRouter`'s handler and loses by last-writer-wins.
  }

  // MARK: ASREngineAdapter — identity & capability

  /// Self-declared identity. The kernel reads from here at every site that
  /// previously hard-coded `.parakeet` (PR-5 Rung 1).
  var engineIdentity: ASREngineIdentity {
    ASREngineIdentity(backendType: .parakeet)
  }

  /// Parakeet decodes incrementally and detects no language (D2, D15). Static —
  /// the kernel branches on `capabilities`, never on engine identity.
  var capabilities: ASREngineCapabilities {
    ASREngineCapabilities(supportsStreaming: true, supportsLanguageDetection: false)
  }

  var readiness: ASREngineReadiness {
    if asrManager.isModelLoaded { return .ready }
    return isLoadInFlight ? .warming : .notReady
  }

  // MARK: ASREngineAdapter — warm-up

  /// Idempotent, sessionless warm-up. Wires `loadProgressTickReporter` for the
  /// duration of the `loadModel()` call so the kernel's signal-based load-wedge
  /// detection (D5) sees progress ticks; clears it after the load resolves.
  func warmUp() async throws {
    if asrManager.isModelLoaded { return }
    isLoadInFlight = true
    asrManager.loadProgressTickReporter = { [weak self] _, phase in
      // Capture the phase string for the kernel's model-load-wedge payload
      // (Div 5 of seam audit / TP:407). The old Parakeet pipeline read
      // `ModelLoadWatchdog.snapshot.lastObservedPhase`; in the kernel path
      // the watchdog lives in the adapter, so the adapter stashes it.
      self?.lastObservedPhase = phase
      self?.emitLoadTick()
    }
    defer {
      asrManager.loadProgressTickReporter = nil
      isLoadInFlight = false
    }
    try await asrManager.loadModel()
    // #959: a superseded load throws from `loadModel()`, but recheck readiness
    // anyway so any "returned but not actually loaded" path reports failure to
    // `ensureEngineWarm()` instead of a false "warm-up succeeded".
    guard asrManager.isModelLoaded else { throw ASRLoadSupersededError() }
  }

  /// Latest phase string observed by the in-flight `loadProgressTickReporter`,
  /// or the default `"warmup"` before any tick lands. Reset at the start of
  /// each warm-up via the protocol's default until the reporter overwrites
  /// it on the first tick. Read by `RecordingSessionKernel.freezeModelLoadWedgeTelemetry`
  /// when surfacing the model-load wedge to Sentry.
  private(set) var lastObservedPhase: String = "warmup"

  /// Parakeet always exposes a load-progress stream (D5) — non-nil, so the
  /// kernel runs signal-based warm-up wedge detection.
  var loadProgress: AsyncStream<ASRLoadProgressTick>? { loadStream }

  /// #1339: eligible only when the manager's load progress lands in the
  /// shared progress file the wedge guard polls (XPC proxy yes; in-process
  /// ASRManager no — its progress never touches the file, so the guard would
  /// read permanent silence and cancel a healthy long download).
  var warmupStallGuardEligible: Bool { asrManager.feedsSharedProgressFile }

  private func emitLoadTick() {
    loadMarker += 1
    loadContinuation.yield(ASRLoadProgressTick(marker: loadMarker))
  }

  // MARK: ASREngineAdapter — session lifecycle

  /// Begin a session. Opens a live stream only when the kernel asked for one
  /// (`streaming`) AND the backend supports it; on a streaming-setup failure it
  /// degrades to batch-after-stop — today's `streamingSetupSucceeded` fallback
  /// (old Parakeet pipeline). `streaming == false` (the user
  /// disabled live transcription) means batch decode after stop only.
  func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws {
    sessionID = id
    decodeOptions = options
    isTerminal = false
    isCancelled = false
    streamingActive = false
    lastResult = nil
    lastASRDiagnostics = nil
    lastFailureError = nil
    streamingBuffersDispatched = 0
    streamingBuffersFed = 0
    feedTasks.removeAll()
    retainedPCM.removeAll(keepingCapacity: true)

    // Cancel any pending model-unload timer a prior session armed via
    // `applyUnloadPolicy` — otherwise it can fire mid-recording and unload the
    // model under the live session. Mirrors the old Parakeet pipeline,
    // which cancels the idle timer at every session start.
    asrManager.cancelIdleTimer()

    if streaming, await asrManager.activeBackendSupportsStreaming {
      do {
        try await asrManager.startStreaming(options: options)
        streamingActive = true
        SentryBreadcrumb.add(
          stage: "asr", message: "Streaming ASR started",
          data: ["backend": ASRBackendType.parakeet.rawValue])
        await AppLogger.shared.log(
          "Streaming ASR started during recording",
          level: .info, category: "Pipeline"
        )
      } catch {
        // Streaming setup failed — fall back to batch decode after stop. Not a
        // session failure; the batch rescue over `retainedPCM` covers it.
        streamingActive = false
        SentryBreadcrumb.add(
          stage: "asr", message: "Streaming start failed, will use batch", level: .warning)
        await AppLogger.shared.log(
          "Streaming ASR failed to start, will use batch: \(error.localizedDescription)",
          level: .info, category: "Pipeline"
        )
      }
    }
  }

  /// Accept one captured buffer. Feeds streaming ASR (when streaming) and
  /// always appends to `retainedPCM` for the batch rescue (§3.2a). A call after
  /// a terminal session is a no-op (PR-1 §B.2.2).
  func acceptAudio(_ buffer: AudioBufferHandoff) {
    guard !isTerminal else { return }
    appendRetainedPCM(from: buffer.buffer)
    guard streamingActive else { return }
    // Mirror the shipped per-buffer hand-off (old Parakeet pipeline):
    // each buffer is fed on its own `@MainActor` task. The buffer is already
    // MainActor-confined here, so capturing it carries no cross-actor transfer.
    // The task handle is retained in `feedTasks` so `finalize()` can await it.
    let pcmBuffer = buffer.buffer
    let handoffSession = buffer.sessionID
    streamingBuffersDispatched += 1
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      // Re-check on the `@MainActor` hop: a `cancel()` or a new `beginSession()`
      // between dispatch and now must not feed this buffer into a fresh
      // streaming session (Codex r2 — stale-feed race). The shipped pipeline
      // re-checks `streamingASRActive` / `state` inside the same hop
      // (old Parakeet pipeline).
      guard self.sessionID == handoffSession, self.streamingActive, !self.isTerminal
      else { return }
      do {
        try await self.asrManager.feedAudio(pcmBuffer)
        self.streamingBuffersFed += 1
      } catch {
        // The host-side `feedAudio` call threw (transient ASR/XPC error). Do NOT
        // count this buffer as fed — `streamingBuffersFed` (surfaced as
        // `asr.streaming_buffers_fed` in ASREmptyResultDiagnostics) counts buffers
        // whose feed call returned successfully, so `fed < dispatched` stays
        // visible in empty-result triage as the signal that some feed calls did
        // not complete (#867). The delta itself is the failure count, so the
        // catch stays silent (a per-buffer breadcrumb would be noisy at ~39Hz).
        // The task is still `Task<Void, Never>` and completes, so `finalize()`'s
        // drain barrier is unaffected.
      }
    }
    feedTasks.append(task)
  }

  /// Finalize: one normalized outcome. Streaming runs the
  /// streaming-finalize-then-batch rescue (D14); batch-mode runs batch decode
  /// over the kernel-conditioned audio when supplied, else raw retained PCM
  /// (PR-4.5 #5). After `cancel()`, returns `.cancelled` (PR-1 §B.2.2).
  func finalize(batchSamples: [Float]?) async -> ASREngineOutcome {
    lastFailureError = nil
    if isCancelled {
      isTerminal = true
      retainedPCM.removeAll()
      return .cancelled
    }
    let session = sessionID
    let outcome: ASREngineOutcome
    if streamingActive {
      await drainStreamingFeeds()
      outcome = await finalizeStreamingWithRescue(batchSamples: batchSamples)
    } else {
      outcome = await finalizeBatch(batchSamples: batchSamples)
    }
    // A `cancel()` + new `beginSession()` during the ASR await must not let
    // this stale finalize clobber the fresh session's `lastResult` / retained
    // PCM / terminal flag (Codex r2 — stale-finalize race). The kernel's own
    // `finalize(_:)` wrapper drops the stale return value separately.
    guard sessionID == session, !isCancelled else {
      return isCancelled ? .cancelled : outcome
    }
    if case .transcript(let result) = outcome {
      lastResult = result
    }
    isTerminal = true
    streamingActive = false
    retainedPCM.removeAll()
    return outcome
  }

  /// Parakeet/ASRManager expose completion-only `finalizeStreaming()` and
  /// `transcribe(...)` calls. There is no decoder-step, partial-result, queue,
  /// or file-mtime signal to feed the kernel's signal-based wedge detector.
  // TODO(#NNN): finalize-wedge watchdog needs Parakeet progress signal.
  var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? { nil }

  /// The cheap, model-preserving teardown shared by `cancel()` and
  /// `recoverFromWedge()`: cancel streaming, clear per-session state. Touches
  /// neither the model load nor the XPC connection.
  private func discardSession() async {
    isCancelled = true
    isTerminal = true
    lastResult = nil
    retainedPCM.removeAll()
    // Drop feed-task handles — the tasks see `isTerminal` and skip; `finalize()`
    // after `cancel()` short-circuits to `.cancelled` and never drains.
    feedTasks.removeAll()
    if streamingActive {
      streamingActive = false
      await asrManager.cancelStreaming()
    }
  }

  /// #959 CHEAP, model-preserving discard — what every ordinary terminal
  /// (`noSpeech`/`discarded`/`cancelled`) routes through. A healthy RESIDENT
  /// model stays loaded and `readiness` stays `.ready` (the warm-engine bug fix).
  /// BUT a load that is still IN FLIGHT (a cold warm-up the user cancelled) is
  /// released via `cancelInFlightLoad()` so the kernel's `warmUp()` await
  /// unblocks promptly instead of hanging the overlay until the load finishes
  /// (Codex code-diff P1). The `isLoadInFlight` gate is the distinction: a warm
  /// resident model has no load in flight, so this never tears down a healthy
  /// engine — that IS the seam split.
  func cancel() async {
    await discardSession()
    if isLoadInFlight {
      asrManager.cancelInFlightLoad()
    }
  }

  /// #959 HEAVY wedge recovery. The cheap discard PLUS an UNCONDITIONAL
  /// `cancelInFlightLoad()` — the issue #445 service-kill that invalidates the
  /// XPC connection (terminating the service-side wedged load OR a stuck batch
  /// decode, which has no in-flight load task) and forces a fresh reload. Called
  /// ONLY by the kernel's load-wedge / finalize-wedge detectors.
  /// `cancelInFlightLoad()` is synchronous and non-blocking, so no deadline is
  /// needed for the Parakeet path.
  func recoverFromWedge() async {
    await discardSession()
    asrManager.cancelInFlightLoad()
  }

  // MARK: ASREngineAdapter — cleanup

  func applyUnloadPolicy(_ policy: ModelUnloadPolicy) {
    asrManager.noteTranscriptionComplete(policy: policy)
  }

  // MARK: ASREngineAdapter optional engine hooks (PR-5 Rung 2A)

  /// Cancel any pending model-unload idle timer the prior session armed. The
  /// existing `cancelIdleTimer()` call inside `beginSession()` above
  /// (`:192`) covers today's flow where no kernel caller exists yet; this
  /// override lifts that semantic to the protocol surface so Rung 2B can
  /// wire the kernel to call the hook pre-`beginSession()`. Idempotent:
  /// safe to call when no timer is armed.
  func cancelPendingUnload() {
    asrManager.cancelIdleTimer()
  }

  // MARK: Streaming drain

  /// Await every dispatched `feedAudio` task before `finalizeStreaming()` — so
  /// a non-empty streaming result is never finalized missing tail buffers still
  /// queued behind `acceptAudio` (the old Parakeet pipeline — "losing
  /// ~250-500ms of trailing audio"). Awaiting the task handles is the actual
  /// completion signal; no wall-clock deadline (`no-arbitrary-timeouts.md`) —
  /// the prior `ContinuousClock` deadline raced the scheduler and flaked.
  /// REVIEWED_OK(#827): production uses `ASRManagerProxy.feedAudio`, which is
  /// XPC fire-and-forget and returns after dispatch. The task drain waits for
  /// host-side dispatch completion, not for remote ASR processing.
  /// Iterates a value snapshot and does NOT clear `feedTasks` — only
  /// `beginSession()` / `cancel()` clear it, so a session that begins during
  /// this drain's `await` cannot have its fresh feed handles dropped here.
  ///
  /// Seam audit Div 7 (2026-05-26) — WONTFIX. The old Parakeet pipeline's
  /// 500ms bounded drain (TP:680-700) was an arbitrary deadline that the
  /// kernel deliberately replaced with this signal-based wait per
  /// `~/.claude/rules/no-arbitrary-timeouts.md`. Re-introducing the timeout
  /// would regress that rule. Hang risk for a feed task that genuinely
  /// stalls is mitigated by #863's signal-based watchdogs on the audio /
  /// ASR XPC await sites, which the feed-task body invokes. The
  /// "clean/timeout/lost" log line shape from OLD TP is replaced by the
  /// `started`/`completed` pair above; PostHog + Sentry retain the
  /// streaming-finalize timing.
  private func drainStreamingFeeds() async {
    let feedCount = feedTasks.count
    let sampleCount = retainedPCM.count
    await AppLogger.shared.log(
      "Streaming drain started (feeds=\(feedCount), samples=\(sampleCount))",
      level: .info, category: "PipelineTiming"
    )
    for task in feedTasks { await task.value }
    await AppLogger.shared.log(
      "Streaming drain completed (feeds=\(feedCount), samples=\(retainedPCM.count))",
      level: .info, category: "PipelineTiming"
    )
  }

  // MARK: Rescue

  /// Streaming finalize, then batch rescue if streaming returned empty or
  /// failed. Mirrors the old Parakeet pipeline's `transcribeWithStreamingRescue`.
  /// The kernel runs the VAD no-speech gate before `finalize()`. Reaching here
  /// means speech evidence was voiced, unavailable, OR (since #964) zero VAD
  /// segments but raw energy above the dead-air floor — the faint-speech
  /// recovery path. In that last case an empty decode is fan/room noise, not a
  /// failure: the adapter still reports `.empty(hadSpeechEvidence: true)` (it
  /// saw samples), and the KERNEL re-maps it to `.noSpeech` because it knows the
  /// segments were empty. The rescue always attempts batch when streaming
  /// yields nothing.
  private func finalizeStreamingWithRescue(batchSamples: [Float]?) async -> ASREngineOutcome {
    var diagnostics = KernelASRAdapterDiagnostics(
      streamingBuffersDispatched: streamingBuffersDispatched,
      streamingBuffersFed: streamingBuffersFed
    )
    do {
      await AppLogger.shared.log(
        "Streaming finalize started",
        level: .info, category: "Pipeline"
      )
      let result = try await asrManager.finalizeStreaming()
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      diagnostics.streamingResultChars = trimmed.count
      diagnostics.streamingFinalizeFailed = false
      await AppLogger.shared.log(
        "Streaming finalize result: \(trimmed.count) chars",
        level: .info, category: "Pipeline"
      )
      if !trimmed.isEmpty {
        lastASRDiagnostics = diagnostics
        return .transcript(result)
      }
      // Streaming returned empty — fall through to the batch rescue.
    } catch is CancellationError {
      return .cancelled
    } catch {
      // Streaming finalize failed — fall through to the batch rescue.
      diagnostics.streamingFinalizeFailed = true
      diagnostics.streamingFinalizeErrorType = String(reflecting: type(of: error))
      await AppLogger.shared.log(
        "Streaming finalize failed: \(error.localizedDescription), rescue triggered -> batch fallback",
        level: .info, category: "Pipeline"
      )
    }
    // Codex r1: store the rescue outcome locally so the emit can read whether the
    // batch rescue recovered a transcript before returning it.
    let outcome = await finalizeBatchRescue(batchSamples: batchSamples, diagnostics: diagnostics)
    // #1177 (Telemetry Bible Phase 8): observe the quiet streaming-finalize failure.
    // The heart was fine (batch rescue gave text, or raw fell through), but until now
    // we never knew streaming broke. Fire ONLY on the genuine-failure branch — a
    // CancellationError returned `.cancelled` and an empty-but-successful streaming
    // result returned earlier without setting the flag. `@MainActor` adapter → direct
    // emit, no hop. Metadata only (the error's type name, never any transcript).
    if diagnostics.streamingFinalizeFailed == true {
      let recovered: Bool = {
        if case .transcript = outcome { return true } else { return false }
      }()
      TelemetryService.shared.limbFailureObserved(
        limb: "asr_streaming", operation: "finalize",
        result: recovered ? "rescued" : "failed",
        errorCategory: diagnostics.streamingFinalizeErrorType ?? "unknown",
        durationMs: nil)
    }
    return outcome
  }

  private func finalizeBatchRescue(
    batchSamples: [Float]?,
    diagnostics: KernelASRAdapterDiagnostics
  ) async -> ASREngineOutcome {
    var diagnostics = diagnostics
    diagnostics.batchRescueAttempted = true
    let samples = batchSamples ?? retainedPCM
    await AppLogger.shared.log(
      "Streaming rescue triggered -> batch fallback (\(samples.count) samples)",
      level: .info, category: "Pipeline"
    )
    guard !samples.isEmpty else {
      lastASRDiagnostics = diagnostics
      return .empty(hadSpeechEvidence: true)
    }
    do {
      let result = try await asrManager.transcribe(
        audioSamples: samples, options: decodeOptions)
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      diagnostics.batchRescueResultChars = trimmed.count
      lastASRDiagnostics = diagnostics
      await AppLogger.shared.log(
        "Streaming rescue result: batch produced \(trimmed.count) chars",
        level: .info, category: "Pipeline"
      )
      if trimmed.isEmpty {
        return .empty(hadSpeechEvidence: true)
      }
      return .transcript(result)
    } catch is CancellationError {
      return .cancelled
    } catch {
      lastFailureError = error
      lastASRDiagnostics = diagnostics
      await AppLogger.shared.log(
        "Streaming rescue result: batch failed: \(error.localizedDescription)",
        level: .info, category: "Pipeline"
      )
      return .failed(.decodeFailed)
    }
  }

  /// Batch decode (§3.2a). Uses kernel-conditioned `batchSamples` when
  /// supplied (PR-4.5 #5 — VAD-filtered + raw-fallback + silence-padded);
  /// else falls back to the adapter's raw retained PCM.
  private func finalizeBatch(batchSamples: [Float]?) async -> ASREngineOutcome {
    let samples = batchSamples ?? retainedPCM
    var diagnostics = KernelASRAdapterDiagnostics(batchRescueAttempted: false)
    guard !samples.isEmpty else {
      lastASRDiagnostics = diagnostics
      return .empty(hadSpeechEvidence: true)
    }
    do {
      let result = try await asrManager.transcribe(
        audioSamples: samples, options: decodeOptions)
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      diagnostics.batchRescueResultChars = trimmed.count
      lastASRDiagnostics = diagnostics
      if trimmed.isEmpty {
        // The adapter saw samples, so it reports `hadSpeechEvidence: true`. Past
        // the kernel's VAD no-speech gate this normally routes to
        // `failed(asrEmpty)` (PR-1 §B.1.2) — today's "Couldn't catch that" path.
        // Exception (#964): when the kernel reached ASR on the faint-speech
        // recovery path (zero VAD segments but raw energy above the dead-air
        // floor) it re-maps this empty result to `.noSpeech`. The kernel owns
        // that decision; the adapter's report is unchanged.
        return .empty(hadSpeechEvidence: true)
      }
      return .transcript(result)
    } catch is CancellationError {
      return .cancelled
    } catch {
      lastFailureError = error
      lastASRDiagnostics = diagnostics
      return .failed(.decodeFailed)
    }
  }

  // MARK: PCM retention

  /// Extract the buffer's Float32 samples and append to `retainedPCM`, bounded
  /// by `retainedPCMCap`. Runs on `@MainActor` (the audio thread did only the
  /// wrap + hop — `architecture-rules.md` audio-thread discipline).
  private func appendRetainedPCM(from buffer: AVAudioPCMBuffer) {
    guard retainedPCM.count < Self.retainedPCMCap else { return }
    let count = Int(buffer.frameLength)
    guard count > 0, let channel = buffer.floatChannelData?[0] else { return }
    let remaining = Self.retainedPCMCap - retainedPCM.count
    let take = min(count, remaining)
    retainedPCM.append(contentsOf: UnsafeBufferPointer(start: channel, count: take))
  }

  /// Test-only handle to the in-flight per-buffer feed tasks. A test captures
  /// this snapshot BEFORE `cancel()`/`beginSession()` (which clear the array)
  /// and `await`s the captured handles afterward to assert deterministically
  /// that a queued feed saw the terminated session and skipped — instead of
  /// yield-polling `feedAudioCount`. Each task always returns (it guards on the
  /// session check and returns), so the await is bounded.
  // periphery:ignore - test seam
  internal var feedTasksForUnitTests: [Task<Void, Never>] { feedTasks }
}

extension ParakeetEngineAdapter: ASREngineTelemetryProviding {}
