import EnviousWisprCore
import Foundation

// MARK: - VAD signal / policy split (epic #827, PR-1 §B.6 → PR-2)
//
// PR-1 §B.6: the kernel owns VAD *policy* (auto-stop, the no-speech gate,
// whether ASR runs, max-duration); the capture/VAD seam owns VAD *signal
// production*. The kernel cannot own signal production because XPC-mode VAD
// physically runs in a separate process (D8). `VADSignalSource` is the narrow,
// origin-agnostic protocol the seam vends and the kernel subscribes to — an
// in-process `SilenceDetector` and the XPC service-side detector both map onto
// it.
//
// Placement: `EnviousWisprPipeline` — a kernel-facing input contract, same
// kind as `ASREngineAdapter` (PR-2 plan §3.1, §3b). INERT in PR-2: the kernel
// (PR-3) becomes the subscriber; `FakeVADSignalSource` (test target) is the
// PR-2 conformer.

/// The kind of stop-driving VAD signal (PR-1 §B.6). Both kinds latch a stop
/// through the identical kernel path — there is no App-layer routing (D7).
public enum VADStopKind: Equatable, Sendable {
  /// Silence hangover expired — stop now (when `vadAutoStop` config is on).
  case autoStopTriggered
  /// Recording hit `maxRecordingDuration`.
  case maxDurationReached
}

/// A stop-driving VAD signal carrying the `SessionID` it was issued under
/// (PR-1 §B.6, FSM invariant 7). The seam is told the session at session start
/// (VAD config is frozen per session), so it stamps each signal; the kernel
/// drops a signal whose `sessionID` is not its current session — a late
/// auto-stop from a finished recording cannot terminate the next one.
public struct VADStopSignal: Equatable, Sendable {
  public let kind: VADStopKind
  public let sessionID: SessionID

  public init(kind: VADStopKind, sessionID: SessionID) {
    self.kind = kind
    self.sessionID = sessionID
  }
}

/// Tri-state speech evidence read by the kernel at `stopping` (PR-1 §B.6).
/// The no-speech gate keys on *confirmed* no-speech, not on an empty segment
/// list per se (Codex r2 correction).
public enum VADSpeechEvidence: Equatable, Sendable {
  /// Voiced segments are present.
  case voiced
  /// VAD ran and confirms no speech — the kernel routes to `noSpeech` and
  /// skips the adapter.
  case confirmedNoSpeech
  /// No detector ran — evidence is unavailable. The kernel does NOT gate; it
  /// fails toward visibility (the adapter still runs, so a genuine ASR failure
  /// still surfaces as an error).
  case unavailable
}

/// The narrow protocol the capture/VAD seam vends and the kernel subscribes to
/// (PR-1 §B.6). The kernel does not know whether the conformer is the
/// in-process detector or the XPC service-side one.
@MainActor
protocol VADSignalSource: AnyObject {
  /// Open a fresh per-subscriber stream of stop-driving signals (auto-stop,
  /// max-duration). The kernel latches a stop on each delivered signal.
  ///
  /// PR-5 Rung 5 (#827) Codex code-diff r1 P1: a single shared
  /// `AsyncStream` cannot be safely consumed by two kernel drivers
  /// (Parakeet + WhisperKit) — `AsyncStream` delivers each yielded item to
  /// exactly one iterator, and overlap between two `for await` loops makes
  /// signal delivery non-deterministic. Each call returns a NEW stream
  /// backed by its own continuation; the source broadcasts every yield to
  /// every live subscriber so both drivers receive every signal. The
  /// per-subscriber continuation is removed automatically on iterator
  /// cancellation via `onTermination`.
  func subscribeStopSignals() -> AsyncStream<VADStopSignal>

  /// The speech-evidence verdict at stop. Read once when the kernel enters
  /// `stopping`.
  func speechEvidenceAtStop() -> VADSpeechEvidence

  /// The kernel calls this at session start so every subsequent signal carries
  /// the live `SessionID` (PR-1 §B.6, PR-4.5 #2). The old Parakeet pipeline
  /// stamped per session (`:569-570,1276-1285`); the fresh kernel never wired
  /// the stamp, so the seam dropped every signal as stale. Required on the
  /// protocol so `any VADSignalSource` can be stamped without down-casting.
  func setCurrentSessionID(_ id: SessionID)

  /// The voiced segments observed during the just-stopped session, used by
  /// the kernel's `CapturedAudioConditioner` (PR-4.5 #5, Codex r1). The seam
  /// — not `CaptureResult.vadSegments` — is the authoritative source because
  /// in direct (non-XPC) mode `AudioCaptureManager.stopCapture()` does not
  /// populate `CaptureResult.vadSegments`; segments live in the in-process
  /// `SilenceDetector`. Both modes feed the seam: XPC bundles via
  /// `captureResult.vadSegments`, direct mode bridges from the detector. A
  /// conformer with no segments (no detector ran) returns an empty array —
  /// the conditioner then no-ops `SampleFilter` and falls through to raw
  /// fallback / padding, matching the old pipeline's no-VAD path.
  func speechSegmentsAtStop() -> [SpeechSegment]
}
