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
/// streaming path (`TranscriptionPipeline.swift:483`) never does.
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
}
