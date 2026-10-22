import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// What EnviousMeet's views and the menu bar show, from `MeetingCoordinator`'s state (#3972
/// §3.8, R20). Pure: every decision the views make about copy, status and which action is
/// offered lives here, so it is tested without a window. Copy rules: no accuracy claims, and
/// "call sound" is described as what the Mac plays.
enum MeetingsPresentation {
  // MARK: - Recorder

  /// `m:ss`, or `h:mm:ss` from an hour. A clock that went backwards reads 0:00.
  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
    let (h, m, s) = (seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  /// A playback position or length as `m:ss`, or `h:mm:ss` from an hour.
  static func clock(ms: Int) -> String {
    elapsed(
      from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: Double(ms) / 1_000))
  }

  /// A meter's fill, 0 to 1. A level that is not a number reads as silence.
  static func meterFraction(_ level: Float) -> Double {
    guard level.isFinite else { return 0 }
    return Double(min(1, max(0, level)))
  }

  /// The line under the meters about the call sound, or nil before a recording reports it.
  /// A capture that failed is never called a refusal: the recorder cannot tell the two apart.
  static func callSoundLine(_ status: MeetingTrackStatus?) -> String? {
    switch status {
    case .captured?:
      return String(
        localized: "Recording the call sound.",
        comment: "EnviousMeet, while recording: the sound the Mac plays is being recorded.")
    case .off?:
      return String(
        localized: "Only your microphone is recorded.",
        comment: "EnviousMeet, while recording: the call sound is switched off.")
    case .unsupported?:
      return unsupportedLine
    case .denied?, .failed?:
      return failedLine
    case nil:
      return nil
    }
  }

  /// Whether the recorder panel offers the call-sound settings fix next to its status line.
  static func offersCallSoundFix(_ status: MeetingTrackStatus?) -> Bool {
    status == .failed || status == .denied
  }

  static var unsupportedLine: String {
    String(
      localized: "Call sound needs macOS 14.2 or later. Only your microphone is recorded.",
      comment: "EnviousMeet: this Mac cannot record the sound it plays.")
  }

  static var failedLine: String {
    String(
      localized:
        "The call sound could not be recorded. Only your microphone is recorded. EnviousWispr needs to be allowed under Screen & System Audio Recording in System Settings.",
      comment:
        "EnviousMeet: recording the sound the Mac plays did not work. The last sentence names the macOS privacy setting."
    )
  }

  // MARK: - Processing

  static func stage(_ processing: MeetingCoordinator.Processing) -> String {
    if processing.waitingForDictation {
      return String(
        localized: "Paused while you dictate",
        comment: "EnviousMeet: the transcript waits until the user's dictation is finished.")
    }
    switch processing.stage {
    case .transcribing?:
      return String(
        localized: "Writing the transcript",
        comment: "EnviousMeet: the meeting is being turned into words.")
    case .findingSpeakers?:
      return String(
        localized: "Finding the speakers",
        comment: "EnviousMeet: working out who said what.")
    case .composing?:
      return String(
        localized: "Putting it together",
        comment: "EnviousMeet: the last step, joining the words and the speakers.")
    case nil:
      return String(
        localized: "Getting ready",
        comment: "EnviousMeet: the transcript work is about to start.")
    }
  }

  /// The progress bar's fraction, or nil for an indeterminate bar.
  static func progress(_ processing: MeetingCoordinator.Processing) -> Double? {
    guard !processing.waitingForDictation,
      case .transcribing(_, let fraction)? = processing.stage, fraction.isFinite
    else { return nil }
    return min(1, max(0, fraction))
  }

  // MARK: - List

  enum Status: Equatable {
    case recording
    case saving
    case waiting
    case interrupted
    case transcribing
    case ready
    case needsAttention
    /// Nothing was recorded; the user's notes are kept (#3972 R53).
    case notesOnly
  }

  static func status(_ record: MeetingRecord, processingID: UUID?) -> Status {
    if processingID == record.id { return .transcribing }
    switch record.state {
    case .recording: return .recording
    case .stopping: return .saving
    case .interrupted: return .interrupted
    case .queued: return .waiting
    case .processing: return .transcribing
    case .ready: return .ready
    case .failed: return .needsAttention
    case .notesOnly: return .notesOnly
    }
  }

  static func statusLabel(_ status: Status) -> String {
    switch status {
    case .recording:
      return String(localized: "Recording", comment: "EnviousMeet list: status of a meeting.")
    case .saving:
      return String(
        localized: "Saving", comment: "EnviousMeet list: the recording is being closed.")
    case .waiting:
      return String(
        localized: "Waiting",
        comment: "EnviousMeet list: the meeting waits for its turn to be transcribed.")
    case .interrupted:
      return String(
        localized: "Interrupted",
        comment:
          "EnviousMeet list: the recording was cut short (the app quit); what was recorded is kept and transcribed."
      )
    case .transcribing:
      return String(
        localized: "Transcribing", comment: "EnviousMeet list: status of a meeting.")
    case .ready:
      return String(localized: "Ready", comment: "EnviousMeet list: status of a meeting.")
    case .needsAttention:
      return String(
        localized: "Needs attention",
        comment: "EnviousMeet list: the transcript could not be made; the detail says why.")
    case .notesOnly:
      return String(
        localized: "Notes only",
        comment:
          "EnviousMeet list: nothing was recorded for this meeting, but the notes the user typed are kept."
      )
    }
  }

  /// The meeting's name: its title, else the date and time it started.
  static func title(_ record: MeetingRecord) -> String {
    if let title = record.title, !title.isEmpty { return title }
    let date = record.createdAt.formatted(date: .abbreviated, time: .shortened)
    return String(
      localized: "Meeting, \(date)",
      comment: "EnviousMeet: a meeting's default name, from the date and time it started.")
  }

  static func duration(ms: Int) -> String {
    Duration.milliseconds(max(0, ms))
      .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }

  /// "2 speakers", or nil when the transcript has no speaker count yet.
  static func speakers(_ analysis: TranscriptSpeakerAnalysis?) -> String? {
    guard case .labeled(let count)? = analysis, count > 0 else { return nil }
    if count == 1 {
      return String(
        localized: "1 speaker", comment: "EnviousMeet list: the transcript found one person.")
    }
    return String(
      localized: "\(count) speakers",
      comment: "EnviousMeet list: how many people the transcript found (two or more).")
  }

  /// Why a meeting needs attention, from its failure code.
  static func failureLine(_ record: MeetingRecord) -> String? {
    if record.state == .notesOnly {
      return String(
        localized: "The recording failed. Your notes are kept.",
        comment: "EnviousMeet detail: nothing was recorded, but the notes the user typed are saved.")
    }
    guard record.state == .failed else { return nil }
    switch record.failureCode {
    case "no_audio"?, "audio_unreadable"?:
      return String(
        localized: "No audio could be read from this recording.",
        comment: "EnviousMeet detail: why a meeting has no transcript.")
    case "audio_deleted"?:
      return String(
        localized: "The audio was deleted before it was transcribed.",
        comment: "EnviousMeet detail: why a meeting has no transcript.")
    default:
      return String(
        localized: "The transcript could not be made. Transcribe again to try once more.",
        comment: "EnviousMeet detail: why a meeting has no transcript, with what to do.")
    }
  }

  // MARK: - Actions

  /// Which meeting actions the detail offers now. Every action re-reads the meeting by its id
  /// before it runs; this only decides what is drawn enabled.
  struct Actions: Equatable {
    let transcribeAgain: Bool
    let deleteAudio: Bool
    let delete: Bool
  }

  static func actions(_ record: MeetingRecord, isActive: Bool) -> Actions {
    let settled = [.failed, .ready, .interrupted].contains(record.state)
    return Actions(
      transcribeAgain: record.audioKept && settled && !isActive && record.isWritableByThisBuild,
      // A notes-only meeting has no audio to delete, and never says it was deleted (R53).
      deleteAudio: record.audioKept && record.state != .notesOnly && !isActive
        && record.isWritableByThisBuild,
      delete: record.isWritableByThisBuild && !record.deletionRequested)
  }

  /// The kept audio's size, or why it cannot be shown.
  enum AudioSize: Equatable {
    case measuring
    case bytes(Int64)
    case deleted
    case unreadable
  }

  static func audioSizeLine(_ size: AudioSize) -> String {
    switch size {
    case .measuring:
      return String(
        localized: "Measuring the audio", comment: "EnviousMeet detail: the audio size is loading.")
    case .bytes(let bytes):
      let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      return String(
        localized: "Audio: \(formatted)",
        comment: "EnviousMeet detail: how much space the kept recording takes, like 42 MB.")
    case .deleted:
      return String(
        localized: "The audio was deleted. The transcript is kept.",
        comment: "EnviousMeet detail: after Delete audio.")
    case .unreadable:
      return String(
        localized: "The audio size could not be read.",
        comment: "EnviousMeet detail: the recording's folder could not be measured.")
    }
  }

  // MARK: - Notices

  /// Whether a notice offers Allow Microphone (the macOS prompt, or System Settings).
  static func offersMicrophoneFix(_ notice: MeetingCoordinator.Notice) -> Bool {
    notice == .microphoneDenied
  }

  static func notice(_ notice: MeetingCoordinator.Notice) -> String {
    switch notice {
    case .microphoneDenied:
      return String(
        localized:
          "EnviousWispr needs microphone access to record a meeting. Allow it in System Settings, Privacy & Security, Microphone.",
        comment: "EnviousMeet: the microphone permission is missing.")
    case .microphoneUnavailable:
      return String(
        localized: "The microphone could not start. Check your microphone and try again.",
        comment: "EnviousMeet: the microphone did not start.")
    case .finishDictationFirst:
      return String(
        localized: "Finish your dictation first, then start the meeting.",
        comment: "EnviousMeet: a dictation was still running when Start was pressed.")
    case .lowDisk:
      return String(
        localized: "Your Mac is almost out of space. Free up space to record a meeting.",
        comment: "EnviousMeet: not enough disk space to start.")
    case .stoppedLowDisk:
      return String(
        localized: "Recording stopped: your Mac is almost out of space.",
        comment: "EnviousMeet: the recording was ended because the disk is nearly full.")
    case .recordingStoppedFileError:
      return String(
        localized: "Recording stopped because a file could not be saved.",
        comment: "EnviousMeet: the recording was ended by a file error.")
    case .callSoundUnavailable:
      return unsupportedLine
    case .callSoundFailed:
      return failedLine
    case .storageFailed:
      return String(
        localized: "A change to a meeting could not be saved. Its last saved state is kept.",
        comment: "EnviousMeet: writing a meeting's details failed.")
    }
  }

  // MARK: - Menu bar

  /// The menu bar's meeting item, read when the menu is built.
  struct MenuItem: Equatable {
    enum Action: Equatable { case start, stop, none }
    let title: String
    let action: Action
    let isEnabled: Bool
  }

  static func menuItem(_ phase: MeetingCoordinator.Phase, now: Date) -> MenuItem {
    switch phase {
    case .idle:
      return MenuItem(
        title: String(
          localized: "Start Meeting Recording",
          comment: "Menu bar menu: starts recording a meeting with EnviousMeet."),
        action: .start, isEnabled: true)
    case .starting:
      return MenuItem(
        title: String(
          localized: "Starting Meeting Recording",
          comment: "Menu bar menu: a meeting recording is starting (not clickable)."),
        action: .none, isEnabled: false)
    case .recording(_, let startedAt):
      return MenuItem(
        title: String(
          localized: "Stop Meeting Recording (\(elapsed(from: startedAt, to: now)))",
          comment: "Menu bar menu: stops the meeting recording; the value is how long it ran."),
        action: .stop, isEnabled: true)
    case .stopping:
      return MenuItem(
        title: String(
          localized: "Saving Meeting Recording",
          comment: "Menu bar menu: the meeting recording is being saved (not clickable)."),
        action: .none, isEnabled: false)
    }
  }
}
