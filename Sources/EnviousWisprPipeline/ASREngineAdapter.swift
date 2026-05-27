@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

// MARK: - Engine-adapter contract (epic #827, PR-1 §B.2 → PR-2)
//
// `ASREngineAdapter` is the uniform, kernel-facing orchestration contract that
// both ASR engines plug into. PR-1's kernel-contract spec
// (`docs/feature-requests/issue-PR1-2026-05-21-behavior-inventory-kernel-contract.md`
// §B.2) defines the surface; PR-2 makes it compilable Swift. It is INERT in
// PR-2: no production type conforms to or calls it yet. `FakeEngine` (test
// target) is the PR-2 conformer and the proof the surface is implementable;
// the `RecordingSessionKernel` (PR-3) becomes the caller; the real Parakeet
// and WhisperKit adapters (PR-4 / PR-5) become the production conformers.
//
// Placement: `EnviousWisprPipeline`, not `EnviousWisprASR` — this is a
// kernel-facing orchestration contract, not the engine-internal `ASRBackend`
// actor protocol (PR-1 §B.2).

/// A `UUID`-backed recording-session identity, minted by the kernel at every
/// `idle → preparing` / `terminal → preparing` transition (PR-1 §B.1.5).
///
/// Distinct from the capture layer's `AudioCaptureInterface.currentCaptureSessionID`
/// (`UInt64`), which is an unrelated per-source capture counter. A `SessionID`
/// is never reused.
public struct SessionID: Hashable, Sendable {
  public let raw: UUID

  public init(_ raw: UUID = UUID()) {
    self.raw = raw
  }
}

/// Self-declared engine identity (epic #827, PR-5 Rung 1). Replaces the
/// kernel- and factory-side hard-coded `.parakeet` literals: each
/// `ASREngineAdapter` conformer declares its identity, and the kernel /
/// factory read identity from `adapter.engineIdentity` rather than
/// branching on engine type (epic §3.4).
public struct ASREngineIdentity: Sendable {
  public let backendType: ASRBackendType
  public var rawValue: String { backendType.rawValue }
  public var displayName: String { backendType.displayName }

  public init(backendType: ASRBackendType) {
    self.backendType = backendType
  }
}

/// Static capability flags an engine adapter advertises so the kernel can
/// branch on `capabilities` rather than on engine identity (PR-1 §B.2.1,
/// D15). An optional capability the adapter does not support MUST degrade
/// cleanly.
public struct ASREngineCapabilities: Sendable {
  /// The engine decodes incrementally and accepts `acceptAudio(_:)` during
  /// recording (Parakeet). `false` for batch-after-stop engines (WhisperKit).
  public let supportsStreaming: Bool

  /// The engine can detect the spoken language (WhisperKit). `false` for
  /// Parakeet.
  ///
  /// TODO(PR-5 telemetry): the WhisperKit adapter must surface its
  /// engine-internal telemetry at this seam: `language.detected`,
  /// `language.lid_abstained`, `language.transcription_latency`,
  /// LID perf signpost logs (`lid_perf_signpost`), and incremental-finalize
  /// AppLogger lines. The lifecycle sink only owns kernel-level events.
  public let supportsLanguageDetection: Bool

  public init(supportsStreaming: Bool, supportsLanguageDetection: Bool) {
    self.supportsStreaming = supportsStreaming
    self.supportsLanguageDetection = supportsLanguageDetection
  }
}

/// Adapter warm-up / model-load readiness (PR-1 §B.2.1). Warm-but-idle is the
/// kernel's `idle` state with `readiness == .ready` — there is no separate
/// `ready` FSM state (PR-1 §B.1, D1).
public enum ASREngineReadiness: Sendable {
  case notReady
  case warming
  case ready
}

/// A closed, normalized engine-failure enum. The kernel never branches on
/// engine-specific error types (PR-1 §B.2.1, epic §3.4) — each adapter maps
/// its internal errors into one of these cases.
public enum ASREngineError: Error, Sendable {
  /// Model warm-up / load failed.
  case loadFailed
  /// The decoder failed to produce a result.
  case decodeFailed
  /// The engine process crashed during `finalize()` — surfaced as a value,
  /// never as a thrown error the kernel must catch, never as a hang
  /// (PR-1 §B.2.2).
  case engineCrashed
  /// The engine wedged — no progress signal advanced (PR-1 §B.1.7).
  case wedged
}

/// The normalized outcome of one `finalize()` call (PR-1 §B.2.1). The kernel
/// consumes exactly one of these per session and never sees an engine-specific
/// result type.
public enum ASREngineOutcome: Sendable {
  /// A non-empty raw transcript.
  case transcript(ASRResult)
  /// The decoder produced nothing. `hadSpeechEvidence` routes the kernel to
  /// `failed(asrEmpty)` vs `noSpeech` (PR-1 §B.1.2).
  case empty(hadSpeechEvidence: Bool)
  /// `finalize()` was called after `cancel()` — never partial text
  /// (PR-1 §B.2.2).
  case cancelled
  /// A typed, normalized engine failure.
  case failed(ASREngineError)
}

/// A wedge-detection progress tick emitted during model warm-up (PR-1 §B.1.7,
/// §B.2.1). The kernel watches *cadence* — absence of ticks, not absence of
/// completion-within-a-deadline — so there is no wall-clock timeout.
public struct ASRLoadProgressTick: Sendable {
  /// Monotonic progress marker. The kernel treats a stalled marker as a wedge.
  public let marker: UInt64

  public init(marker: UInt64) {
    self.marker = marker
  }
}

/// A wedge-detection progress tick emitted during `finalize()` (PR-1 §B.1.7,
/// §B.2.1). Same cadence-watching semantics as `ASRLoadProgressTick`.
public struct ASRFinalizeProgressTick: Sendable {
  /// Monotonic progress marker.
  public let marker: UInt64

  public init(marker: UInt64) {
    self.marker = marker
  }
}

/// A carrier wrapping one captured audio buffer for the kernel → adapter
/// handoff (PR-1 §B.3). The kernel calls `acceptAudio(_:)` for every captured
/// buffer; a streaming adapter forwards it, a batch adapter buffers or no-ops.
///
/// 2026-05-22 erratum (PR-4, plan §3.4). PR-1 §B.3 and the PR-3 plan deferred
/// the production PCM-representation decision to PR-4 — the first PR with a
/// real audio thread feeding the kernel. PR-4 resolves it: the carrier holds
/// the `AVAudioPCMBuffer` directly (PR-1 §B.3 option b), not an owned `[Float]`
/// copy. The production Parakeet adapter feeds streaming ASR through
/// `ASRManagerInterface.feedAudio(_:)`, which takes an `AVAudioPCMBuffer`; an
/// owned-`[Float]` carrier would force a buffer reconstruction the shipped
/// streaming path (old Parakeet pipeline) never does.
///
/// `@unchecked Sendable`: `AVAudioPCMBuffer` is not `Sendable`, but the buffer
/// is created on the audio thread, wrapped here exactly once, and handed to
/// `@MainActor` exactly once — never touched from two threads. This is the
/// shipped `nonisolated(unsafe)` cross-actor-buffer transfer discipline
/// (`swift-patterns.md`).
public struct AudioBufferHandoff: @unchecked Sendable {
  /// 16 kHz mono Float32 capture buffer.
  public let buffer: AVAudioPCMBuffer
  /// Frame count in `buffer` (`buffer.frameLength`).
  public let frameCount: Int
  /// Monotonic sequence number stamped on the audio thread. A streaming
  /// adapter that needs strict order reorders by `sequence`; a batch adapter
  /// ignores it (PR-1 §B.3).
  public let sequence: UInt64
  /// The session this buffer belongs to. A buffer whose `sessionID` is not the
  /// kernel's current session is dropped (PR-1 §B.3, FSM invariant 7).
  public let sessionID: SessionID

  public init(
    buffer: AVAudioPCMBuffer, frameCount: Int, sequence: UInt64, sessionID: SessionID
  ) {
    self.buffer = buffer
    self.frameCount = frameCount
    self.sequence = sequence
    self.sessionID = sessionID
  }
}

/// The uniform, kernel-facing engine-adapter contract (PR-1 §B.2.1).
///
/// An adapter owns its own ASR and rescue. Invariant (epic §4): an adapter
/// never touches capture, finalization, paste, UI, or kernel state. The
/// MUST / MUST NOT clauses in PR-1 §B.2.2 define the behavior every conformer
/// (`FakeEngine`, and the PR-4 / PR-5 real adapters) must implement.
@MainActor
public protocol ASREngineAdapter: AnyObject {
  // MARK: Identity & capability

  /// Self-declared engine identity. The kernel and factory read identity from
  /// here rather than branching on engine type (epic §3.4: kernel never
  /// branches on engine identity).
  var engineIdentity: ASREngineIdentity { get }

  /// Static capability flags (PR-1 §B.2.1).
  var capabilities: ASREngineCapabilities { get }

  /// Current warm-up / load readiness.
  var readiness: ASREngineReadiness { get }

  // MARK: Warm-up

  /// Idempotent, sessionless warm-up — drives `readiness` toward `.ready`.
  /// Takes no `SessionID`: it can be driven by a sessionless pre-warm or by a
  /// session's `warmingUp` state. A late completion never drives an FSM
  /// transition by itself — it only updates `readiness` (PR-1 §B.2.2, CN-7).
  func warmUp() async throws

  /// OPTIONAL load-wedge signal (PR-1 §B.1.7). `nil` when the engine exposes
  /// no load-progress stream — the kernel then does signal-free `warmingUp`
  /// (no wedge detection, no timeout); it never falls back to a wall-clock
  /// deadline (PR-1 §B.2.2).
  var loadProgress: AsyncStream<ASRLoadProgressTick>? { get }

  /// Latest model-load phase string surfaced by the underlying loader, or
  /// `"warmup"` when the loader doesn't expose phases. Used by the kernel's
  /// model-load-wedge Sentry payload — Div 5 of seam audit (TP:407 read
  /// `snap.lastObservedPhase` from `ModelLoadWatchdog.snapshot`). Default
  /// returns `"warmup"`; adapters that observe phase strings (e.g.
  /// `ParakeetEngineAdapter` via the XPC `loadProgressTickReporter`) override.
  var lastObservedPhase: String { get }

  // MARK: Session lifecycle

  /// Begin a recording session under `id`. `streaming` carries the kernel's
  /// per-session orchestration decision — `config.useStreamingASR` ANDed with
  /// this adapter's static `capabilities.supportsStreaming` (PR-4 plan §3.4).
  /// The kernel owns the policy; the adapter obeys. `false` means batch-decode
  /// after stop: the adapter MUST NOT open a live stream. An adapter MAY still
  /// fall back to batch from `true` if its own runtime backend check fails.
  func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws

  /// Accept one captured buffer. The kernel ALWAYS calls this; the adapter
  /// decides forward-vs-buffer. A call after a terminal session (post-`cancel()`
  /// or post-`finalize()`) MUST be a no-op (PR-1 §B.2.2).
  func acceptAudio(_ buffer: AudioBufferHandoff)

  /// Finalize and produce exactly one outcome. Engine-specific rescue lives
  /// here. After `cancel()`, MUST return `.cancelled` (PR-1 §B.2.2).
  ///
  /// `batchSamples`, when non-nil, is the kernel-conditioned ASR-ready audio
  /// the adapter MUST use for any batch decode in this finalize call (PR-4.5
  /// #5 — VAD-segment filtering, raw fallback, short-utterance padding are
  /// kernel-side, not adapter-side). When nil, the adapter uses its own
  /// raw retained audio unchanged (today's pre-PR-4.5 behavior, preserved for
  /// tests + the `FakeEngine` simulator path). The streaming path is
  /// unaffected — per-buffer feeds were already raw and the kernel's
  /// `acceptAudio` contract has not changed.
  func finalize(batchSamples: [Float]?) async -> ASREngineOutcome

  /// OPTIONAL `finalize()`-wedge signal (PR-1 §B.1.7). Same `nil` semantics as
  /// `loadProgress`.
  var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? { get }

  /// Idempotent discard. Calling it 2+ times has the same effect as once
  /// (PR-1 §B.2.2).
  func cancel() async

  // MARK: Engine interruption

  /// Fires when the engine's own backend dies mid-recording — distinct from a
  /// crash surfaced through `finalize()` as `.failed(.engineCrashed)`
  /// (PR-1 §B.2.2 covered only the `finalize()`-time crash; a mid-recording
  /// crash was a gap, PR-4 plan §3.2). The kernel sets this during session
  /// setup and routes it to the `asrInterrupted` terminal. An adapter whose
  /// engine has no mid-recording crash signal leaves it nil.
  var onEngineInterrupted: (@MainActor () -> Void)? { get set }

  // MARK: Cleanup

  /// Apply the model-unload policy (PR-1 §B.2.1, D16).
  func applyUnloadPolicy(_ policy: ModelUnloadPolicy)

  // MARK: Finalization metadata (PR-5 Rung 2A)

  /// The last successful `finalize()` result, or `nil` between sessions.
  /// The kernel's finalization wiring reads `result.{language, duration,
  /// processingTime}` to build `Transcript`; without this on the protocol,
  /// the wiring would have to know the concrete adapter type.
  ///
  /// MUST be `nil` between sessions: cleared at `beginSession()` and
  /// `cancel()`, assigned only by a successful `finalize()` returning
  /// `.transcript(...)`. Read-only on the protocol; each conformer owns the
  /// storage.
  var lastResult: ASRResult? { get }

  // MARK: Optional engine hooks (PR-5 Rung 2A, passive surface)
  //
  // Each has a no-op default in the protocol extension below. Adapters whose
  // engine has a meaningful implementation override; adapters without leave
  // the default. The kernel does NOT call any of these in Rung 2A: that
  // wiring lands in Rung 2B. They are declared now so the contract surface
  // is closed before Rung 3 writes the second adapter.

  /// Best-effort load from on-disk model cache only: no network, no full
  /// in-memory model resolve. Default no-op. Adapters whose engine has a
  /// meaningful cache-only preload path override.
  func warmUpFromCache() async throws

  /// Cancel any pending model-unload timer the engine had armed. Called by
  /// the kernel (in Rung 2B+) when the user signals intent to record soon,
  /// before `beginSession()`. Default no-op. Idempotent.
  func cancelPendingUnload()

  /// Receive the voiced-speech segments computed by the kernel's VAD at the
  /// stop boundary. The adapter MAY use them to derive engine-specific
  /// decode parameters (the second engine derives `clipTimestamps`). Default
  /// no-op. The kernel calls this (in Rung 2B+) once per session, after VAD
  /// finalize, before `finalize(batchSamples:)`.
  func observeSpeechSegments(_ segments: [SpeechSegment])
}

extension ASREngineAdapter {
  /// Default phase: adapters without a loader-phase surface return the
  /// generic warmup label. Concrete adapters override when they observe
  /// real phase strings.
  public var lastObservedPhase: String { "warmup" }

  // PR-5 Rung 2A: no-op defaults for the three optional hooks. Adapters
  // with meaningful semantics override; the others inherit these.
  public func warmUpFromCache() async throws {}
  public func cancelPendingUnload() {}
  public func observeSpeechSegments(_ segments: [SpeechSegment]) {}
}
