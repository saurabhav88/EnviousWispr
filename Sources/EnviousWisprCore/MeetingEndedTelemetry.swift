import Foundation

/// Where a meeting was started from (telemetry `entry_point`).
public enum MeetingEntryPoint: String, Sendable, Equatable {
  case page
  case menu
}

/// The one `meeting.ended` row (#3972 R11, plan C4): one row per meeting attempt, at its
/// terminal. Shape only: never words, names, titles, paths or ids. Built by `MeetingCoordinator`,
/// sent by `TelemetryService.trackMeetingEnded`.
///
/// An attempt is one Start, or one Retry. A recording interrupted by a quit or crash is still
/// the same attempt after the relaunch; facts frozen in memory at its start (`entryPoint`,
/// `diskStopped`) are then unknown and travel as nil, never guessed.
public struct MeetingEndedTelemetry: Equatable, Sendable {
  public enum Outcome: String, Sendable, CaseIterable {
    case ready
    case readyWithGaps = "ready_with_gaps"
    case failed
    case startFailed = "start_failed"
    case interruptedReady = "interrupted_ready"
    case deletedBeforeReady = "deleted_before_ready"
  }

  public let outcome: Outcome
  /// Nil when not known (an attempt recovered after a relaunch).
  public let entryPoint: MeetingEntryPoint?
  public let durationSeconds: Double
  public let microphoneTrack: MeetingTrackStatus
  public let callSoundTrack: MeetingTrackStatus
  public let engine: MeetingEngineChoice
  public let speakerCount: Int
  public let processingSeconds: Double
  public let audioSeconds: Double
  public let yieldCount: Int
  /// Failed pieces plus damaged-audio markers in the transcript.
  public let gapCount: Int
  public let echoHiddenCount: Int
  /// The recording was ended by the low-disk floor. Nil when not known.
  public let diskStopped: Bool?

  public init(
    outcome: Outcome, entryPoint: MeetingEntryPoint?, durationSeconds: Double,
    microphoneTrack: MeetingTrackStatus, callSoundTrack: MeetingTrackStatus,
    engine: MeetingEngineChoice = .parakeet, speakerCount: Int, processingSeconds: Double,
    audioSeconds: Double, yieldCount: Int, gapCount: Int, echoHiddenCount: Int, diskStopped: Bool?
  ) {
    self.outcome = outcome
    self.entryPoint = entryPoint
    self.durationSeconds = durationSeconds
    self.microphoneTrack = microphoneTrack
    self.callSoundTrack = callSoundTrack
    self.engine = engine
    self.speakerCount = speakerCount
    self.processingSeconds = processingSeconds
    self.audioSeconds = audioSeconds
    self.yieldCount = yieldCount
    self.gapCount = gapCount
    self.echoHiddenCount = echoHiddenCount
    self.diskStopped = diskStopped
  }

  /// Processing seconds per audio second; 0 when there was no audio or either value is not a
  /// finite number (a start failure, an empty meeting), so the property is always finite.
  public var realTimeFactor: Double {
    guard audioSeconds > 0, audioSeconds.isFinite, processingSeconds.isFinite else { return 0 }
    let value = processingSeconds / audioSeconds
    return value.isFinite ? value : 0
  }

  /// A Start refused before any meeting existed, or a start that recorded nothing.
  public static func startFailed(
    entryPoint: MeetingEntryPoint, microphone: MeetingTrackStatus, callSound: MeetingTrackStatus
  ) -> MeetingEndedTelemetry {
    MeetingEndedTelemetry(
      outcome: .startFailed, entryPoint: entryPoint, durationSeconds: 0, microphoneTrack: microphone,
      callSoundTrack: callSound, speakerCount: 0, processingSeconds: 0, audioSeconds: 0,
      yieldCount: 0, gapCount: 0, echoHiddenCount: 0, diskStopped: false)
  }
}
