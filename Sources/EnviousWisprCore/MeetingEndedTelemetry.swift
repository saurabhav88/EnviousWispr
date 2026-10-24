import Foundation

/// Where a meeting was started from (telemetry `entry_point`): History's Recordings header or
/// the menu bar (#3972 R34). Rows sent by earlier development builds may say `page` (the
/// EnviousMeet page started meetings before it became settings only); that value is history,
/// never a Start this build makes.
public enum MeetingEntryPoint: String, Sendable, Equatable {
  case history
  case menu
  /// Started for a call EnviousMeet noticed (#4012): the user's Yes, or Start by itself.
  case detected
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
  /// What was decided about a summary at this terminal (#3972 R48, R54).
  public let summaryPlan: SummaryPlan
  /// Whether the meeting had notes at this terminal; false when it has no folder (R54).
  public let hasNotes: Bool

  /// The summary decision taken when the meeting ends (R48, R54).
  public enum SummaryPlan: String, Sendable, CaseIterable {
    /// A summary will be written.
    case scheduled
    /// "Write a summary when a meeting ends" is off.
    case off
    /// No AI Polish provider is selected.
    case noProvider = "no_provider"
    /// The selected provider or model cannot write summaries.
    case unsupported
    /// The meeting did not become ready (failed, start failed, deleted, notes only).
    case notApplicable = "not_applicable"
  }

  public init(
    outcome: Outcome, entryPoint: MeetingEntryPoint?, durationSeconds: Double,
    microphoneTrack: MeetingTrackStatus, callSoundTrack: MeetingTrackStatus,
    engine: MeetingEngineChoice = .parakeet, speakerCount: Int, processingSeconds: Double,
    audioSeconds: Double, yieldCount: Int, gapCount: Int, echoHiddenCount: Int, diskStopped: Bool?,
    summaryPlan: SummaryPlan, hasNotes: Bool
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
    self.summaryPlan = summaryPlan
    self.hasNotes = hasNotes
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
      yieldCount: 0, gapCount: 0, echoHiddenCount: 0, diskStopped: false,
      summaryPlan: .notApplicable, hasNotes: false)
  }
}

/// The one `meeting.summary_finished` row (#3972 R48, R54, R57): exactly one per summary
/// attempt, when it ends. Shape only: the outcome and where the model ran, never text, names,
/// models or ids. Built by `MeetingSummaryOwner`, sent by
/// `TelemetryService.trackMeetingSummaryFinished`.
public struct MeetingSummaryFinishedTelemetry: Equatable, Sendable {
  public enum Outcome: String, Sendable, CaseIterable {
    /// The summary was saved.
    case written
    /// The provider or model cannot write summaries (including a window too small, an Ollama
    /// app too old, or a meeting too long for the model).
    case unsupported
    /// No AI Polish provider is selected.
    case noProvider = "no_provider"
    /// The provider failed, timed out, cut its answer or answered with nothing.
    case failed
    /// The meeting was deleted, the app quit, or the attempt was replaced.
    case cancelled
    /// The answer was not saved because the meeting changed meanwhile, or the summary is the
    /// user's own text.
    case stale
  }

  public enum ProviderKind: String, Sendable, CaseIterable {
    case local
    case hosted
    /// Exactly when `outcome` is `noProvider` (R57).
    case none
  }

  public let outcome: Outcome
  public let providerKind: ProviderKind

  public init(outcome: Outcome, providerKind: ProviderKind) {
    self.outcome = outcome
    self.providerKind = providerKind
  }
}
