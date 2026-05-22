@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
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
// (D14, today `TranscriptionPipeline.transcribeWithStreamingRescue`), and the
// full-session PCM the batch rescue needs (§3.2a). It holds legitimate
// engine-session bookkeeping (a streaming-active flag, the retained PCM, an
// in-flight-load flag, a terminal / cancelled flag) — session bookkeeping is
// explicitly NOT FSM state (Codex finding 46, §3.11 adapter-shape check).
//
// PR-4a ships this production-unwired: no App-layer caller constructs it yet.
// PR-4b wires it behind the Parakeet branch and deletes `TranscriptionPipeline`.

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

  /// In-flight streaming-feed tasks. `acceptAudio(_:)` dispatches each
  /// `feedAudio` on its own task and appends the handle here; `finalize()`
  /// awaits every handle before `finalizeStreaming()`, so a non-empty streaming
  /// result is never finalized missing the tail buffers. Awaiting the actual
  /// task is the completion signal — no wall-clock deadline. A `ContinuousClock`
  /// deadline raced the `@MainActor` scheduler: under contention it fired before
  /// queued feed tasks ran, dropping tail audio (Codex PR-4a r4, reproduced as a
  /// `finalizeDrainsStreamingFeeds` flake). Each task `try?`-awaits `feedAudio`,
  /// so it always completes — on success or a thrown XPC error — never hangs.
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

  /// Cap on `retainedPCM` — `maxRecordingDuration` worth of 16 kHz mono samples
  /// (300 s x 16 kHz = 4.8 M `Float` = ~19 MB). On reaching the cap the
  /// accumulation stops growing; recording auto-stops on max-duration anyway.
  private static let retainedPCMCap = Int(
    TimingConstants.maxRecordingDuration * AudioConstants.sampleRate)

  // MARK: Load-progress stream

  private let loadStream: AsyncStream<ASRLoadProgressTick>
  private let loadContinuation: AsyncStream<ASRLoadProgressTick>.Continuation
  private var loadMarker: UInt64 = 0

  // MARK: ASREngineAdapter — engine interruption

  /// Set by the kernel during session setup; the kernel routes it to the
  /// `asrInterrupted` terminal. Bridged from `ASRManagerInterface.onServiceInterrupted`
  /// — the mid-recording ASR-service crash signal (PR-4 §3.2, Codex RR1).
  var onEngineInterrupted: (@MainActor () -> Void)?

  // MARK: Init

  init(asrManager: any ASRManagerInterface) {
    self.asrManager = asrManager
    (loadStream, loadContinuation) = AsyncStream.makeStream(of: ASRLoadProgressTick.self)
    // Bridge the ASR-service-crash signal. `onServiceInterrupted` is a distinct
    // XPC layer from the audio-capture `onXPCServiceError` the kernel binds
    // separately (PR-4 §3.2).
    asrManager.onServiceInterrupted = { [weak self] in
      self?.onEngineInterrupted?()
    }
  }

  // MARK: ASREngineAdapter — identity & capability

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
    asrManager.loadProgressTickReporter = { [weak self] _, _ in
      self?.emitLoadTick()
    }
    defer {
      asrManager.loadProgressTickReporter = nil
      isLoadInFlight = false
    }
    try await asrManager.loadModel()
  }

  /// Parakeet always exposes a load-progress stream (D5) — non-nil, so the
  /// kernel runs signal-based warm-up wedge detection.
  var loadProgress: AsyncStream<ASRLoadProgressTick>? { loadStream }

  private func emitLoadTick() {
    loadMarker += 1
    loadContinuation.yield(ASRLoadProgressTick(marker: loadMarker))
  }

  // MARK: ASREngineAdapter — session lifecycle

  /// Begin a session. Opens a live stream only when the kernel asked for one
  /// (`streaming`) AND the backend supports it; on a streaming-setup failure it
  /// degrades to batch-after-stop — today's `streamingSetupSucceeded` fallback
  /// (`TranscriptionPipeline.swift:458`). `streaming == false` (the user
  /// disabled live transcription) means batch decode after stop only.
  func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws {
    sessionID = id
    decodeOptions = options
    isTerminal = false
    isCancelled = false
    streamingActive = false
    lastResult = nil
    feedTasks.removeAll()
    retainedPCM.removeAll(keepingCapacity: true)

    // Cancel any pending model-unload timer a prior session armed via
    // `applyUnloadPolicy` — otherwise it can fire mid-recording and unload the
    // model under the live session. Mirrors `TranscriptionPipeline.swift:359`,
    // which cancels the idle timer at every session start.
    asrManager.cancelIdleTimer()

    if streaming, await asrManager.activeBackendSupportsStreaming {
      do {
        try await asrManager.startStreaming(options: options)
        streamingActive = true
      } catch {
        // Streaming setup failed — fall back to batch decode after stop. Not a
        // session failure; the batch rescue over `retainedPCM` covers it.
        streamingActive = false
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
    // Mirror the shipped per-buffer hand-off (`TranscriptionPipeline.swift:481`):
    // each buffer is fed on its own `@MainActor` task. The buffer is already
    // MainActor-confined here, so capturing it carries no cross-actor transfer.
    // The task handle is retained in `feedTasks` so `finalize()` can await it.
    let pcmBuffer = buffer.buffer
    let handoffSession = buffer.sessionID
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      // Re-check on the `@MainActor` hop: a `cancel()` or a new `beginSession()`
      // between dispatch and now must not feed this buffer into a fresh
      // streaming session (Codex r2 — stale-feed race). The shipped pipeline
      // re-checks `streamingASRActive` / `state` inside the same hop
      // (`TranscriptionPipeline.swift:486`).
      guard self.sessionID == handoffSession, self.streamingActive, !self.isTerminal
      else { return }
      try? await self.asrManager.feedAudio(pcmBuffer)
    }
    feedTasks.append(task)
  }

  /// Finalize: one normalized outcome. Streaming runs the
  /// streaming-finalize-then-batch rescue (D14); batch-mode runs batch decode
  /// over the retained PCM. After `cancel()`, returns `.cancelled` (PR-1 §B.2.2).
  func finalize() async -> ASREngineOutcome {
    if isCancelled {
      isTerminal = true
      retainedPCM.removeAll()
      return .cancelled
    }
    let session = sessionID
    let outcome: ASREngineOutcome
    if streamingActive {
      await drainStreamingFeeds()
      outcome = await finalizeStreamingWithRescue()
    } else {
      outcome = await finalizeBatch()
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

  /// Parakeet's streaming-finalize returns in milliseconds — no finalize-wedge
  /// signal (§B.1.7 `finalizeProgress == nil` = signal-free `transcribing`).
  var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? { nil }

  /// Idempotent discard. Cancels streaming and any wedged in-flight model load,
  /// clears the retained PCM. `cancelInFlightLoad()` is what unblocks the
  /// kernel's load-wedge recovery (issue #445); the kernel routes its
  /// `detectLoadWedge` recovery through this same `cancel()`.
  func cancel() async {
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
    asrManager.cancelInFlightLoad()
  }

  // MARK: ASREngineAdapter — cleanup

  func applyUnloadPolicy(_ policy: ModelUnloadPolicy) {
    asrManager.noteTranscriptionComplete(policy: policy)
  }

  // MARK: Streaming drain

  /// Await every dispatched `feedAudio` task before `finalizeStreaming()` — so
  /// a non-empty streaming result is never finalized missing tail buffers still
  /// queued behind `acceptAudio` (`TranscriptionPipeline.swift:675` — "losing
  /// ~250-500ms of trailing audio"). Awaiting the task handles is the actual
  /// completion signal; no wall-clock deadline (`no-arbitrary-timeouts.md`) —
  /// the prior `ContinuousClock` deadline raced the scheduler and flaked.
  /// Iterates a value snapshot and does NOT clear `feedTasks` — only
  /// `beginSession()` / `cancel()` clear it, so a session that begins during
  /// this drain's `await` cannot have its fresh feed handles dropped here.
  private func drainStreamingFeeds() async {
    for task in feedTasks { await task.value }
  }

  // MARK: Rescue

  /// Streaming finalize, then batch rescue if streaming returned empty or
  /// failed. Mirrors `TranscriptionPipeline.transcribeWithStreamingRescue`.
  /// The kernel runs the VAD no-speech gate before `finalize()`, so reaching
  /// here means speech evidence was voiced or unavailable — the rescue always
  /// attempts batch when streaming yields nothing.
  private func finalizeStreamingWithRescue() async -> ASREngineOutcome {
    do {
      let result = try await asrManager.finalizeStreaming()
      if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .transcript(result)
      }
      // Streaming returned empty — fall through to the batch rescue.
    } catch is CancellationError {
      return .cancelled
    } catch {
      // Streaming finalize failed — fall through to the batch rescue.
    }
    return await finalizeBatch()
  }

  /// Batch decode over the retained session PCM (§3.2a).
  private func finalizeBatch() async -> ASREngineOutcome {
    guard !retainedPCM.isEmpty else { return .empty(hadSpeechEvidence: true) }
    do {
      let result = try await asrManager.transcribe(
        audioSamples: retainedPCM, options: decodeOptions)
      if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Past the kernel's VAD no-speech gate, an empty decode is a real ASR
        // failure — `hadSpeechEvidence: true` routes the kernel to
        // `failed(asrEmpty)` (PR-1 §B.1.2), matching today's "Couldn't catch
        // that" path.
        return .empty(hadSpeechEvidence: true)
      }
      return .transcript(result)
    } catch is CancellationError {
      return .cancelled
    } catch {
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
}
