import Foundation

/// #2787 — the stages a take walks between "stop pressed" and "text in hand".
///
/// A live decode that never returns leaves the app parked in "transcribing"
/// with nothing to say about WHICH step stopped. The kernel records each of
/// these as it enters it; the checkpoint store persists the latest one per
/// take so a launch after a quit, a crash or a force-quit can report where the
/// previous take was when the process died. Bounded set, string-backed: the
/// Sentry fingerprint groups on the stage name, so a new member is a new group.
public enum TranscriptionStage: String, Codable, Sendable, CaseIterable, Equatable {
  /// The audio engine returned from `stopCapture`.
  case captureStopped = "capture_stopped"
  /// The VAD conditioning pass over the whole buffer finished.
  case vadConditioned = "vad_conditioned"
  /// The tail-preserve decision was made; the batch buffer is final.
  case tailChecked = "tail_checked"
  /// The adapter's `finalize` (the vendor decode) was called.
  case decodeStarted = "decode_started"
  /// The vendor scheduled another chunk of a long decode (observation only;
  /// `chunksScheduled` on the checkpoint carries the count).
  case decodeChunkScheduled = "decode_chunk_scheduled"
  /// The vendor decode returned, with or without text.
  case decodeReturned = "decode_returned"
}

/// #2787 — metadata about one take's last observed transcription stage.
/// Never text, never audio, never a path: the privacy boundary is unchanged.
public struct TranscriptionCheckpoint: Codable, Sendable, Equatable {
  public let takeID: String
  public let backend: String
  public let stage: TranscriptionStage
  public let stageEnteredAt: Date
  public let chunksScheduled: Int
  public let appVersion: String

  public init(
    takeID: String, backend: String, stage: TranscriptionStage, stageEnteredAt: Date,
    chunksScheduled: Int, appVersion: String
  ) {
    self.takeID = takeID
    self.backend = backend
    self.stage = stage
    self.stageEnteredAt = stageEnteredAt
    self.chunksScheduled = chunksScheduled
    self.appVersion = appVersion
  }
}

/// #2787 — what the kernel tells the checkpoint store. One closure-shaped sink,
/// defaulted to a no-op in every test construction site, wired to the real
/// store by the composition root.
public enum TranscriptionCheckpointEvent: Sendable, Equatable {
  /// The take entered `stage`. `chunksScheduled` is the running count of vendor
  /// chunks scheduled so far (0 until the decode reports any).
  case mark(takeID: String, backend: String, stage: TranscriptionStage, chunksScheduled: Int)
  /// The take reached a terminal while the app was alive: nothing to report later.
  case clear
}
