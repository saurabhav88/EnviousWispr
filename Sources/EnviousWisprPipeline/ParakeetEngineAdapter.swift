@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
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
final class ParakeetEngineAdapter: ASREngineAdapter, @unchecked Sendable {

  // MARK: Injected dependency

  private let asrManager: any ASRManagerInterface
  /// #1348 Phase 2: the delivery stage that runs before any Parakeet load —
  /// nil means the legacy in-service download path (tests, or the flag off).
  private let delivery: ParakeetDeliveryHandle?
  /// #1707 Phase 2: DEBUG fault-injection oracle (§11.1) — `nil` in every
  /// production/test path that doesn't explicitly construct one.
  private let batchDecodeFaultController: BatchDecodeFaultController?

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

  // MARK: ASR-interruption recovery (#1707)

  /// Wall-clock ceiling on `recoverFromASRInterruption()`'s reconnect+reload
  /// attempt. Measured 2026-07-20 against the live dev app
  /// (`validation-discipline.md` RULE: timeout-numbers-need-distribution-
  /// evidence) — corrected once, see history below.
  ///
  /// AUTHORITATIVE number (Codex code-diff r11): 30 trials of a REAL helper
  /// crash — `kill -9` on the actual `EnviousWisprASRService` process,
  /// confirmed respawned under a new PID — not just a connection
  /// invalidation. 27/30 landed in a tight 4159-4215ms band (p50=4182ms,
  /// p99=4215ms); the other 3 (154ms/161ms/3195ms) were each the first
  /// trial after a fresh dev-app launch and almost certainly benefited from
  /// launch-time OS file-cache warmth on the model/delivery-validation
  /// files — not representative of a crash landing mid-session on an
  /// otherwise idle cache. `8.0` is ~1.9x the measured p99, headroom for a
  /// slower disk/CPU/Mac model. Raw trial data (both measurement passes):
  /// `docs/audits/2026-07-20-recovery-v2-phase1-asr-recovery-latency.txt`.
  ///
  /// SUPERSEDED number (Codex code-diff r6-r10): an earlier measurement
  /// used `force_xpc_kill` (`ASRManagerProxy.forceConnectionTerminationNow`)
  /// — this invalidates the XPC connection but the helper PROCESS stays
  /// alive, so the model is never actually unloaded. That gave a real but
  /// wrong-scenario 99-127ms (p99=127ms), which produced a `2.0` deadline.
  /// Codex r11 correctly identified that this doesn't represent a genuine
  /// crash; verifying with a real process kill (above) showed the true
  /// cold-reload cost is over 30x higher — with the `2.0` deadline in
  /// place, a direct rerun of the real-crash trial showed 4 of 5 attempts
  /// hit the deadline and reported `.failed`, discarding the very
  /// dictations this whole mechanism exists to save.
  ///
  /// Construction parameter (not `TimingConstants`) — Parakeet reconnect
  /// duration is backend-specific policy, not a Core primitive.
  private let asrInterruptionRecoveryDeadlineSec: Double

  /// Monotonic generation for `recoverFromASRInterruption()` attempts.
  /// Bumped at the start of every attempt AND by every method that can start
  /// replacement session/load work (`beginSession`, `discardSession` — shared
  /// by `cancel()`/`recoverFromWedge()`/transitively `cancelSessionlessWarmup()`)
  /// — so a stale attempt's post-await checks always see a mismatch and can
  /// never mutate state a newer attempt or an ordinary session lifecycle owns.
  private var recoveryGeneration = 0

  /// #1707 Codex code-diff r1: a SEPARATE, narrower generation scoped entirely
  /// to `warmUp()`'s own reentrancy — bumped at the top of every `warmUp()`
  /// call (not just recovery-triggered ones), so an abandoned call's `defer`
  /// cannot clear a newer call's shared tracking fields after it unwinds late.
  private var warmUpGeneration = 0

  /// #1707 Phase 2: monotonic generation for the attempt/commit split shared
  /// by `finalize()` and `retryDecode()`. Bumped by `beginSession`/
  /// `discardSession` (a new session or a cancel/wedge-recovery must
  /// invalidate any in-flight attempt, mirroring `recoveryGeneration`'s own
  /// bump sites) AND by `bumpRetryGeneration()` specifically (a retry's own
  /// honest "stop waiting" signal). A SEPARATE counter from
  /// `recoveryGeneration`/`warmUpGeneration` — those are scoped entirely to
  /// Phase 1's `recoverFromASRInterruption()`/`warmUp()` reentrancy, a
  /// different mechanism at a different layer; not reused here, not
  /// conflicting either.
  private var retryGeneration = 0

  // MARK: ASREngineAdapter — engine interruption

  /// Optional adapter-local interruption hook. Parakeet leaves
  /// `ASRManagerInterface.onServiceInterrupted` to `ASREventRouter` so the
  /// shared ASR callback has one owner.
  var onEngineInterrupted: (@MainActor () -> Void)?

  /// #1707: real, attempt-scoped recovery — this adapter IS the one whose
  /// out-of-process connection can die mid-recording, so this is where the
  /// actual reconnect/reload work lives.
  ///
  /// 1. Retires the stale `streamingActive` flag: the crash handlers already
  ///    forced `asrManager.isStreaming` false, but this adapter's own flag
  ///    survives the crash untouched (Premise 3) — left uncorrected, a later
  ///    `finalize()` would try `finalizeStreamingWithRescue()` first against
  ///    a manager that no longer thinks it's streaming.
  /// 2. Reuses `warmUp()` unchanged — it already IS the factored model-load
  ///    path (delivery admission, cache-only config, one-shot transport
  ///    recovery, readiness recheck); no separate path is invented. `warmUp()`
  ///    touches none of this session's own bookkeeping (`sessionID`,
  ///    `retainedPCM`, `decodeOptions`, `isTerminal`, `isCancelled`), so
  ///    calling it a second time mid-session is safe.
  /// 3. Bounds the attempt with `withOrderedDeadline`, NOT bare `withDeadline`
  ///    — on timeout, `onTimeout` actively invalidates this attempt's token
  ///    and calls the SYNCHRONOUS `cancelInFlightLoad()` (never an async
  ///    cleanup hook), guaranteeing that cleanup completes before this
  ///    function can return `.failed`/`.cancelled` to the kernel.
  /// 4. The generation token, bumped ONLY by `beginSession`/`discardSession`
  ///    (covering `cancel`/`recoverFromWedge`/`cancelSessionlessWarmup`) — never
  ///    by this function itself — is checked both inside `onTimeout` (skip the
  ///    active cancel if a lifecycle op already superseded this attempt) and
  ///    after the awaited attempt returns (report `.cancelled` instead of
  ///    trusting a result that no longer belongs to the current session).
  func recoverFromASRInterruption() async -> ASRInterruptionRecoveryOutcome {
    streamingActive = false
    recoveryGeneration &+= 1
    let myGeneration = recoveryGeneration
    let mySession = sessionID

    let succeeded = await withOrderedDeadline(
      seconds: asrInterruptionRecoveryDeadlineSec,
      operation: { [weak self] in
        guard let self else { return false }
        do {
          try await self.warmUp()
          return true
        } catch {
          return false
        }
      },
      onTimeout: { [weak self] in
        // Do NOT bump `recoveryGeneration` here — that would corrupt THIS
        // attempt's own outer check below (a real bug caught by
        // `recoverFromASRInterruptionTimesOutAndSupersedes`: it made a
        // genuine timeout report `.cancelled` instead of `.failed`).
        // `withOrderedDeadline`'s own single-winner `claim()` already
        // guarantees the operation's late completion can never resume this
        // continuation after timeout wins; the generation check exists to
        // catch a DIFFERENT caller (`beginSession`/`discardSession`)
        // superseding this attempt, not to protect against itself.
        guard let self, self.recoveryGeneration == myGeneration else { return }
        self.asrManager.cancelInFlightLoad()
      }
    )

    guard sessionID == mySession, recoveryGeneration == myGeneration else { return .cancelled }
    guard succeeded == true else { return .failed }
    return asrManager.isModelLoaded ? .readyForBatchDecode : .failed
  }

  // MARK: Init

  init(
    asrManager: any ASRManagerInterface, delivery: ParakeetDeliveryHandle? = nil,
    asrInterruptionRecoveryDeadlineSec: Double = 8.0,
    // #1707 Phase 2: DEBUG fault-injection oracle (§11.1). Defaulted `nil`
    // so every existing test construction site is unaffected.
    batchDecodeFaultController: BatchDecodeFaultController? = nil
  ) {
    self.asrManager = asrManager
    self.delivery = delivery
    self.asrInterruptionRecoveryDeadlineSec = asrInterruptionRecoveryDeadlineSec
    self.batchDecodeFaultController = batchDecodeFaultController
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

  /// #1707 Phase 2: PLACEHOLDER — see the protocol doc comment.
  var retryDecodeTimeoutSeconds: Double { 8.0 }

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
    // #1707 Codex code-diff r1: `warmUp()` was only ever called once per
    // session before `recoverFromASRInterruption()` started calling it a
    // second time mid-session. A timed-out, abandoned call's `defer` can
    // unwind LATE (Swift task cancellation is cooperative — `cancel()` alone
    // does not stop an in-flight XPC await) and unconditionally clear
    // `loadProgressTickReporter`/`isLoadInFlight`, clobbering a genuinely
    // NEWER `warmUp()` call's own in-flight tracking. This local generation
    // makes the defer a no-op for any call that is no longer the most recent.
    warmUpGeneration &+= 1
    let myWarmUpGeneration = warmUpGeneration
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
      if warmUpGeneration == myWarmUpGeneration {
        asrManager.loadProgressTickReporter = nil
        isLoadInFlight = false
      }
    }

    // #1348 Phase 2: delivery stage BEFORE any load. The host admits a
    // verified cache (fetch/validate/repair as needed); the service then
    // loads cache-only and can never download. Flag off (or no handle) =
    // legacy path, bit-for-bit.
    let deliveryActive: Bool
    if let delivery, delivery.isEnabled() {
      deliveryActive = true
      asrManager.parakeetCacheOnly = true
      switch await delivery.ensureAvailable() {
      case .admitted:
        break
      case .failed(let failure):
        throw ParakeetDeliveryError(failure)
      case .cancelled:
        throw CancellationError()
      }
    } else {
      deliveryActive = false
      asrManager.parakeetCacheOnly = false
      delivery?.noteLegacyPathActive()
    }

    // #1707 Codex code-diff r9/r10: `delivery.ensureAvailable()` above is a
    // long, separately-owned await (cache fetch/validate/repair, epic #1348)
    // whose own internal cancellation responsiveness this call has no
    // visibility into. If a timeout's `operationTask.cancel()` fires while
    // this call is still stuck inside that await, `cancelInFlightLoad()`
    // (`recoverFromASRInterruption`'s `onTimeout`) is a no-op — no ASR load
    // exists yet to cancel — so an abandoned call could still resume here,
    // stale, after the kernel already reported recovery failure. r9's
    // `warmUpGeneration` check alone is insufficient (r10 finding): it only
    // detects a NEWER `warmUp()` call having started, not THIS call having
    // been individually cancelled — if no newer call has started yet,
    // `warmUpGeneration` is unchanged and that guard alone passes even though
    // `onTimeout` already ran. `operationTask.cancel()` propagates into this
    // call's own execution context, so `Task.checkCancellation()` is the
    // correct, direct signal for that; the generation check stays alongside
    // it to also catch the "a newer call already superseded me" case, which
    // cancellation alone would not (a fresh `beginSession()`/`discardSession()`
    // never calls `operationTask.cancel()` on an old attempt — it only bumps
    // the generation).
    try Task.checkCancellation()
    guard warmUpGeneration == myWarmUpGeneration else { throw CancellationError() }

    do {
      try await loadModelWithTransportRecovery()
    } catch let error
      where deliveryActive
      && !(error is ASRLoadSupersededError)
      // #1388 (Codex r3 P1): a user Cancel must NOT fall into the repair
      // retry — repairing an intact cache succeeds and silently restarts the
      // install the user just cancelled (the founder watched exactly this
      // ~2s resurrection live). Same policy as the transport-recovery catch:
      // cancellation propagates untouched.
      && !(error is ASRLoadCancelledError)
      && !(error is CancellationError)
    {
      // One-shot load-miss repair (#1348 grounded r1 revision 7): a
      // cache-only load failure (raced deletion, missed corruption) gets ONE
      // revalidate/repair pass and ONE retry; a second failure is terminal.
      // Owner is THIS warm-up sequence (a local, not stored state) — callers
      // cannot duplicate it because warm-up is single-flighted upstream.
      // Composed AROUND the transport recovery (exhaustive r7 finding 6) so
      // a stale-helper retry that then misses the cache still gets its
      // repair pass. deliveryActive guarantees the handle exists; a nil here
      // would be a logic error, so fail the warm-up rather than crash.
      guard let delivery, case .admitted = await delivery.repair() else { throw error }
      // Same staleness window as the guard above, at `delivery.repair()`'s
      // own long, separately-owned await instead of `ensureAvailable()`'s —
      // same two-signal reasoning (r10): cancellation first, then generation.
      try Task.checkCancellation()
      guard warmUpGeneration == myWarmUpGeneration else { throw CancellationError() }
      try await loadModelWithTransportRecovery()
    }
    // #959: a superseded load throws from `loadModel()`, but recheck readiness
    // anyway so any "returned but not actually loaded" path reports failure to
    // `ensureEngineWarm()` instead of a false "warm-up succeeded".
    guard asrManager.isModelLoaded else { throw ASRLoadSupersededError() }
  }

  /// One load with one-shot stale-helper recovery, ANY mode (code-diff r3):
  /// a proxy-level error (incl. an old helper rejecting the new selector
  /// after an app update) already recycled the connection in the proxy's
  /// errorHandler; the retry connects to the freshly spawned helper. A
  /// second transport failure propagates.
  ///
  /// #1388 retry-vs-cancel policy (this adapter's side of the contract): the
  /// catch matches ONLY transport errors, so `ASRLoadCancelledError` — a user
  /// Cancel or the wedge guard's teardown — propagates without a retry. That
  /// is load-bearing, not incidental: the cancel resume was deliberately
  /// typed as a non-transport error so this one-shot recovery can never
  /// silently restart a load the user just cancelled. Do not widen the catch.
  private func loadModelWithTransportRecovery() async throws {
    do {
      try await asrManager.loadModel()
    } catch let error as XPCASRTransportError where error.isServiceUnreachable {
      // #1525 PR I-B: narrowed from a bare type-check — the 6 new
      // codec/transport cases are not stale-helper-retry-eligible; retrying
      // a reload for, say, `.requestDecodingFailed` would mask a real bug.
      try await asrManager.loadModel()
    }
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
    // #1707: a new session invalidates any recovery attempt still pending
    // from a prior one — its post-await checks compare against this.
    recoveryGeneration &+= 1
    retryGeneration &+= 1  // #1707 Phase 2: also invalidate any pending retry.
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
    let generation = retryGeneration
    let outcome: ASREngineOutcome
    if streamingActive {
      await drainStreamingFeeds()
      outcome = await finalizeStreamingWithRescue(
        batchSamples: batchSamples, session: session, generation: generation)
    } else {
      outcome = await finalizeBatch(
        batchSamples: batchSamples, session: session, generation: generation)
    }
    // A `cancel()` + new `beginSession()` during the ASR await must not let
    // this stale finalize clobber the fresh session's retained PCM / terminal
    // flag (Codex r2 — stale-finalize race). `lastResult`/`lastASRDiagnostics`/
    // `lastFailureError` are already gated on this SAME staleness check inside
    // `commitAttempt`, called from `finalizeStreamingWithRescue`/`finalizeBatch`
    // — not re-written here (single owner, #1707 Phase 2).
    guard sessionID == session, !isCancelled else {
      return isCancelled ? .cancelled : outcome
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
    // #1707: covers `cancel()`, `recoverFromWedge()`, and transitively
    // `cancelSessionlessWarmup()` (which calls `cancel()`) — every heavy
    // lifecycle op that can start replacement work invalidates any pending
    // recovery attempt in one place.
    recoveryGeneration &+= 1
    retryGeneration &+= 1  // #1707 Phase 2: also invalidate any pending retry.
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
    // #1405: this recovery is now for MODEL-LOAD wedges only. The download owns
    // its own stall detection (the fetcher's request idle timeout), and the
    // wedge guard stays parked during the download phase — so a download is
    // never in flight here. The #1371 `delivery.cancel()` that used to live
    // here was the external canceller that fought the fetcher's retry; removed.
  }

  /// #1388 step 3 — the onboarding install Cancel. Cancels BOTH stages the
  /// sessionless warm-up can be awaiting: the delivery fetch (download half)
  /// and the in-flight model load (install half). Distinct from `cancel()`
  /// above, the kernel's session discard, which deliberately does NOT touch
  /// the delivery — a cancelled recording must not kill a first-run download
  /// running in the background.
  func cancelSessionlessWarmup() async {
    await delivery?.cancelActiveFetch()
    await cancel()
  }

  // MARK: ASREngineAdapter — cleanup

  func applyUnloadPolicy(_ policy: ModelUnloadPolicy) {
    asrManager.noteTranscriptionComplete(policy: policy)
  }

  // MARK: ASREngineAdapter — Phase 2 retry

  /// Best-effort, honest "stop waiting" signal for a retry that has timed
  /// out — NOT active cancellation (no genuine in-flight-decode cancel
  /// exists on this backend, §3.2a). Bumping `retryGeneration` is what
  /// actually prevents a late-arriving abandoned result from mutating state
  /// belonging to a session/attempt that has since moved on — checked inside
  /// `commitAttempt`.
  func bumpRetryGeneration() {
    retryGeneration &+= 1
  }

  /// #1707 Phase 2: a second, bounded batch decode attempt over audio a
  /// PRIOR `finalize()` call already failed to decode. Always batch-only —
  /// never re-attempts the streaming-then-rescue sequence, since a retry is
  /// scoped to a single failed decode, not a fresh session.
  func retryDecode(inputSamples: [Float]) async -> ASREngineOutcome {
    // Readiness-gated repair-before-retry (§3.2): `.decodeFailed` conflates a
    // benign decode error (helper alive, connection intact) with the XPC
    // helper actually dying mid-transcribe (which independently clears
    // `isModelLoaded`). Gate on the live readiness snapshot rather than the
    // outcome alone — an honest, non-atomic signal (§3.2's documented limit).
    let session = sessionID
    let generation = retryGeneration
    if readiness != .ready {
      do {
        try await warmUp()
      } catch {
        return .failed(.decodeFailed)
      }
      // The repair awaited — re-check staleness BEFORE spending the decode
      // attempt on audio that may no longer belong to the current session.
      guard sessionID == session, retryGeneration == generation else { return .cancelled }
    }
    // Retry is always batch-only — never re-attempt streaming-then-rescue.
    streamingActive = false
    let attempt = await attemptBatchDecode(samples: inputSamples)
    return commitAttempt(attempt, session: session, generation: generation)
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
  private func finalizeStreamingWithRescue(
    batchSamples: [Float]?, session: SessionID?, generation: Int
  ) async -> ASREngineOutcome {
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
        let attempt = DecodeAttemptResult(
          outcome: .transcript(result), diagnostics: diagnostics, failureError: nil)
        return commitAttempt(attempt, session: session, generation: generation)
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
    let outcome = await finalizeBatchRescue(
      batchSamples: batchSamples, diagnostics: diagnostics, session: session, generation: generation
    )
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
    diagnostics: KernelASRAdapterDiagnostics,
    session: SessionID?, generation: Int
  ) async -> ASREngineOutcome {
    var diagnostics = diagnostics
    diagnostics.batchRescueAttempted = true
    let samples = batchSamples ?? retainedPCM
    await AppLogger.shared.log(
      "Streaming rescue triggered -> batch fallback (\(samples.count) samples)",
      level: .info, category: "Pipeline"
    )
    guard !samples.isEmpty else {
      let attempt = DecodeAttemptResult(
        outcome: .empty(hadSpeechEvidence: true), diagnostics: diagnostics, failureError: nil)
      return commitAttempt(attempt, session: session, generation: generation)
    }
    // Codex r4: this real decode call bypassed the §11.1 fault check entirely
    // — `fail_batch_decode(parakeet)`/`fail_every_batch_decode(parakeet)` must
    // cover EVERY real batch-decode call this adapter issues, not just the
    // one `attemptBatchDecode` makes, or a Live UAT test targeting a
    // streaming session's rescue path would silently never exercise the
    // Phase-2 retry it's trying to test.
    if batchDecodeFaultController?.shouldForceFailBatchDecode(
      backend: .parakeet, sampleCount: samples.count) == true
    {
      let error = ASREngineError.decodeFailed
      let attempt = DecodeAttemptResult(
        outcome: .failed(error), diagnostics: diagnostics, failureError: error)
      return commitAttempt(attempt, session: session, generation: generation)
    }
    do {
      let result = try await asrManager.transcribe(
        audioSamples: samples, options: decodeOptions)
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      diagnostics.batchRescueResultChars = trimmed.count
      await AppLogger.shared.log(
        "Streaming rescue result: batch produced \(trimmed.count) chars",
        level: .info, category: "Pipeline"
      )
      let outcome: ASREngineOutcome =
        trimmed.isEmpty ? .empty(hadSpeechEvidence: true) : .transcript(result)
      let attempt = DecodeAttemptResult(
        outcome: outcome, diagnostics: diagnostics, failureError: nil)
      return commitAttempt(attempt, session: session, generation: generation)
    } catch is CancellationError {
      return .cancelled
    } catch {
      await AppLogger.shared.log(
        "Streaming rescue result: batch failed: \(error.localizedDescription)",
        level: .info, category: "Pipeline"
      )
      let attempt = DecodeAttemptResult(
        outcome: .failed(.decodeFailed), diagnostics: diagnostics, failureError: error)
      return commitAttempt(attempt, session: session, generation: generation)
    }
  }

  /// Batch decode (§3.2a). Uses kernel-conditioned `batchSamples` when
  /// supplied (PR-4.5 #5 — VAD-filtered + raw-fallback + silence-padded);
  /// else falls back to the adapter's raw retained PCM.
  private func finalizeBatch(
    batchSamples: [Float]?, session: SessionID?, generation: Int
  ) async -> ASREngineOutcome {
    let samples = batchSamples ?? retainedPCM
    let attempt = await attemptBatchDecode(samples: samples)
    return commitAttempt(attempt, session: session, generation: generation)
  }

  // MARK: #1707 Phase 2 — attempt/commit split

  /// Pure decode-attempt result — no shared-state writes. Both `finalize()`
  /// (via `finalizeBatch`/`finalizeStreamingWithRescue`/`finalizeBatchRescue`)
  /// and `retryDecode()` produce one of these, then commit it through the
  /// SAME gated step (`commitAttempt`) — the generation guard that actually
  /// prevents a late-arriving abandoned result from mutating state belonging
  /// to a session/attempt that has since moved on (Grounded Review r1
  /// finding #5: a check performed only AFTER this write would be too late).
  private struct DecodeAttemptResult {
    let outcome: ASREngineOutcome
    let diagnostics: KernelASRAdapterDiagnostics
    let failureError: (any Error)?
  }

  /// Pure batch-decode attempt over already-resolved `samples` — reused by
  /// `finalizeBatch` (existing decode, `batchSamples ?? retainedPCM`) and
  /// `retryDecode` (always the retry's own `inputSamples`, no fallback: the
  /// first attempt's `retainedPCM` is already cleared by the time a retry
  /// runs). No shared-state writes; the caller commits via `commitAttempt`.
  private func attemptBatchDecode(samples: [Float]) async -> DecodeAttemptResult {
    var diagnostics = KernelASRAdapterDiagnostics(batchRescueAttempted: false)
    guard !samples.isEmpty else {
      return DecodeAttemptResult(
        outcome: .empty(hadSpeechEvidence: true), diagnostics: diagnostics, failureError: nil)
    }
    // #1707 Phase 2 (§11.1): DEBUG-only forced-failure fault, consulted only
    // AFTER the real retry input snapshot above is already prepared — proving
    // the retry genuinely re-decodes real, already-captured audio. `nil`
    // controller (production, and every test that doesn't opt in) never
    // forces a failure.
    if batchDecodeFaultController?.shouldForceFailBatchDecode(
      backend: .parakeet, sampleCount: samples.count) == true
    {
      let error = ASREngineError.decodeFailed
      return DecodeAttemptResult(
        outcome: .failed(error), diagnostics: diagnostics, failureError: error)
    }
    do {
      let result = try await asrManager.transcribe(
        audioSamples: samples, options: decodeOptions)
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      diagnostics.batchRescueResultChars = trimmed.count
      if trimmed.isEmpty {
        // The adapter saw samples, so it reports `hadSpeechEvidence: true`. Past
        // the kernel's VAD no-speech gate this normally routes to
        // `failed(asrEmpty)` (PR-1 §B.1.2) — today's "Couldn't catch that" path.
        // Exception (#964): when the kernel reached ASR on the faint-speech
        // recovery path (zero VAD segments but raw energy above the dead-air
        // floor) it re-maps this empty result to `.noSpeech`. The kernel owns
        // that decision; the adapter's report is unchanged.
        return DecodeAttemptResult(
          outcome: .empty(hadSpeechEvidence: true), diagnostics: diagnostics, failureError: nil)
      }
      return DecodeAttemptResult(
        outcome: .transcript(result), diagnostics: diagnostics, failureError: nil)
    } catch is CancellationError {
      return DecodeAttemptResult(outcome: .cancelled, diagnostics: diagnostics, failureError: nil)
    } catch {
      return DecodeAttemptResult(
        outcome: .failed(.decodeFailed), diagnostics: diagnostics, failureError: error)
    }
  }

  /// Commit step, shared by every batch-decode-shaped path
  /// (`finalizeBatch`/`finalizeStreamingWithRescue`/`finalizeBatchRescue`/
  /// `retryDecode`): writes `lastASRDiagnostics`/`lastFailureError`/
  /// `lastResult` ONLY while the captured session and generation are still
  /// current — the SOLE owner of these three fields (§3c single-authority).
  /// Session-closing bookkeeping (`isTerminal`/`streamingActive`/
  /// `retainedPCM`) is NOT this function's concern — `finalize()`'s own
  /// wrapper owns that, since a retry does not re-terminate an
  /// already-terminal session.
  private func commitAttempt(
    _ attempt: DecodeAttemptResult, session: SessionID?, generation: Int
  ) -> ASREngineOutcome {
    guard sessionID == session, retryGeneration == generation else { return .cancelled }
    lastASRDiagnostics = attempt.diagnostics
    if let failureError = attempt.failureError {
      lastFailureError = failureError
    }
    if case .transcript(let result) = attempt.outcome {
      lastResult = result
    }
    return attempt.outcome
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

// #1388 step 3: opt in to the warm-up cancel capability (the method itself
// lives with the other lifecycle methods above).
extension ParakeetEngineAdapter: ASREngineWarmupCancelling {}
