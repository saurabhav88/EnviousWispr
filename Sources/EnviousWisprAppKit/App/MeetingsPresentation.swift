import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// What EnviousMeet's views and the menu bar show, from `MeetingCoordinator`'s state (#3972
/// §3.8, R20). Pure: every decision the views make about copy, status and which action is
/// offered lives here, so it is tested without a window. Copy rules: no accuracy claims, and
/// "call sound" is described as what the Mac plays.
enum MeetingsPresentation {
  // MARK: - Recorder

  // MARK: - Export (R38)

  /// A saved meeting: its visible transcript, then the user's notes under their own heading
  /// when there are any.
  static func exportDocument(transcript: String, notes: String) -> String {
    guard !notes.isEmpty else { return transcript }
    let heading = String(
      localized: "Notes", comment: "History, a meeting: the tab with the user's own notes.")
    return transcript + "\n\n" + heading + "\n\n" + notes + "\n"
  }

  // MARK: - Live words (R42, R52)

  /// The live words' label: the microphone is the user, the call track is the call.
  static func liveSpeaker(_ track: MeetingTrackKind) -> String {
    switch track {
    case .microphone:
      return String(localized: "You", comment: "EnviousMeet: the microphone level meter's label.")
    case .callSound:
      return String(
        localized: "Call",
        comment: "History, live words of a recording meeting: words heard in the sound the Mac plays.")
    }
  }

  /// What the live words are and how each track is doing, one sentence each (#3973): words
  /// appear as people speak; a track that is off or stopped says why; skipped live audio is
  /// named. The full transcript, with speakers and echo hidden, comes after the meeting.
  static func liveStatusLines(
    _ live: MeetingLiveWords.Transcript, callSoundRecorded: Bool
  ) -> [String] {
    var lines = [
      String(
        localized: "Live words, as people speak. The full transcript comes after the meeting.",
        comment: "History, a recording meeting: what the live words are.")
    ]
    for track in MeetingTrackKind.allCases {
      guard let state = live.tracks[track], let line = trackLine(track, state.status),
        !lines.contains(line)
      else { continue }
      lines.append(line)
    }
    if live.tracks.values.contains(where: \.droppedAudio) {
      lines.append(
        String(
          localized: "Some live audio was skipped. The full transcript comes after the meeting.",
          comment: "History, a recording meeting: some audio did not reach the live words."))
    }
    if callSoundRecorded {
      lines.append(
        String(
          localized: "Echo is hidden when the meeting ends.",
          comment: "History, a recording meeting: repeated call lines are hidden only in the final transcript."))
    }
    return lines
  }

  /// Why a track shows no live words, or nil when it is starting or running.
  static func trackLine(_ track: MeetingTrackKind, _ status: MeetingLiveWords.Status) -> String? {
    let name = liveSpeaker(track)
    switch status {
    case .starting, .running, .off(.notCaptured):
      return nil
    case .off(.universalNotDownloaded):
      return String(
        localized:
          "Live words need the Universal engine. Download it in Dictation Settings, Live Preview.",
        comment: "History, a recording meeting: no live words on this Mac until the Universal engine is downloaded.")
    case .off(.appleLanguageAndUniversalMissing(let language)):
      return String(
        localized:
          "Live words need Apple's \(language) language or the Universal engine. Download either in Dictation Settings, Live Preview.",
        comment: "History, a recording meeting: no live words until a language or the Universal engine is downloaded. The placeholder is a language name.")
    case .off(.previousStillClosing):
      return String(
        localized: "Live words are off for this meeting while the last one finishes closing.",
        comment: "History, a recording meeting: the previous meeting's live words are still closing.")
    case .off(.couldNotStart), .off(.unavailable):
      return String(
        localized: "Live words are not available for this meeting.",
        comment: "History, a recording meeting: live words could not start.")
    case .off(.modelBeingRemoved), .stopped(.modelRemoved):
      return String(
        localized: "Live words stopped while the Universal engine is being removed.",
        comment: "History, a recording meeting: live words stopped because the Universal engine is being removed in Dictation Settings.")
    case .stopped:
      return String(
        localized: "Live words stopped for \(name). The recording continues.",
        comment: "History, a recording meeting: one track's live words stopped; the placeholder is You or Call.")
    }
  }

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

  /// `waitingOnSummary`: dictation is idle and a meeting summary call runs on this Mac, so a
  /// wait is for the summary (R50).
  static func stage(_ processing: MeetingCoordinator.Processing, waitingOnSummary: Bool = false)
    -> String
  {
    if processing.waitingForDictation, waitingOnSummary {
      return String(
        localized: "Paused while a meeting summary is written",
        comment: "EnviousMeet: the transcript waits until a summary on this Mac is finished.")
    }
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
    // No pass owns it (the first line above): its end could not be saved, and Transcribe
    // again recovers it (#4008).
    case .processing: return .needsAttention
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
    if let app = record.callApp?.displayName {
      // #4012 D8: a detected call without a calendar or AI name says which app it was.
      return String(
        localized: "\(app) call, \(date)",
        comment:
          "EnviousMeet: a detected call's default name: the app's name (Zoom, Microsoft Teams) and the date and time it started.")
    }
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

  /// `canTranscribeAgain` is the coordinator's answer (`MeetingCoordinator.canTranscribeAgain`,
  /// #4008), never re-derived here; the detail view also turns it off while one of its own
  /// actions is running (#4001 H12), so its missing-transcript hint can share the same answer.
  static func actions(_ record: MeetingRecord, isActive: Bool, canTranscribeAgain: Bool)
    -> Actions
  {
    Actions(
      transcribeAgain: canTranscribeAgain,
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

  /// What the menu bar's meeting block is built from (R34): the recorder is managed here and in
  /// History, never in a window of its own (F14).
  struct MenuFacts: Equatable {
    var phase: MeetingCoordinator.Phase
    var processing: MeetingCoordinator.Processing? = nil
    var callSound: MeetingTrackStatus? = nil
    /// The final pass waits for a meeting summary on this Mac, not for dictation (R50).
    var waitingOnSummary = false
  }

  /// One item of the meeting block. `.none` with `isEnabled` false is a status line.
  struct MenuItem: Equatable {
    enum Kind: Equatable { case control, elapsed, callSound, showLive, processing, showInHistory }
    enum Action: Equatable { case start, stop, show(UUID), none }
    let kind: Kind
    let title: String
    let action: Action
    let isEnabled: Bool
  }

  /// The block, in order: Start or Stop first (it stays under Transcribe a File), then what the
  /// recording is doing, then the after-recording pass of a stopped meeting.
  static func menuItems(_ facts: MenuFacts, now: Date) -> [MenuItem] {
    var items = [control(facts.phase)]
    if case .recording(let meetingID, let startedAt) = facts.phase {
      items.append(
        MenuItem(
          kind: .elapsed,
          title: String(
            localized: "Recording for \(elapsed(from: startedAt, to: now))",
            comment: "Menu bar menu: how long the meeting has been recording, e.g. 12:34."),
          action: .none, isEnabled: false))
      if let line = menuCallSoundLine(facts.callSound) {
        items.append(MenuItem(kind: .callSound, title: line, action: .none, isEnabled: false))
      }
      items.append(
        MenuItem(
          kind: .showLive,
          title: String(
            localized: "Show Live Transcript",
            comment: "Menu bar menu: opens History on the meeting that is recording now."),
          action: .show(meetingID), isEnabled: true))
    }
    if let processing = facts.processing {
      items.append(
        MenuItem(
          kind: .processing, title: processingLine(processing, waitingOnSummary: facts.waitingOnSummary),
          action: .none, isEnabled: false))
      items.append(
        MenuItem(
          kind: .showInHistory,
          title: String(
            localized: "Show in History",
            comment: "Menu bar menu: opens History on the meeting whose transcript is being made."),
          action: .show(processing.meetingID), isEnabled: true))
    }
    return items
  }

  /// Start or Stop, decided by the phase. A click decides again from the phase then.
  static func control(_ phase: MeetingCoordinator.Phase) -> MenuItem {
    switch phase {
    case .idle:
      return MenuItem(
        kind: .control,
        title: String(
          localized: "Start Meeting Recording",
          comment: "Menu bar menu: starts recording a meeting with EnviousMeet."),
        action: .start, isEnabled: true)
    case .starting:
      return MenuItem(
        kind: .control,
        title: String(
          localized: "Starting Meeting Recording",
          comment: "Menu bar menu: a meeting recording is starting (not clickable)."),
        action: .none, isEnabled: false)
    case .recording:
      return MenuItem(
        kind: .control,
        title: String(
          localized: "Stop Meeting Recording",
          comment: "Menu bar menu: stops the meeting recording."),
        action: .stop, isEnabled: true)
    case .stopping:
      return MenuItem(
        kind: .control,
        title: String(
          localized: "Saving Meeting Recording",
          comment: "Menu bar menu: the meeting recording is being saved (not clickable)."),
        action: .none, isEnabled: false)
    }
  }

  /// A short call-sound line for the menu; History shows the full sentence with its fix.
  static func menuCallSoundLine(_ status: MeetingTrackStatus?) -> String? {
    switch status {
    case .captured?:
      return String(
        localized: "Recording the call sound",
        comment: "Menu bar menu, while a meeting records: the sound the Mac plays is recorded.")
    case .off?:
      return String(
        localized: "Recording your microphone only",
        comment: "Menu bar menu, while a meeting records: the call sound is switched off.")
    case .unsupported?, .denied?, .failed?:
      return String(
        localized: "Call sound not recorded",
        comment: "Menu bar menu, while a meeting records: the call sound could not be recorded.")
    case nil:
      return nil
    }
  }

  /// The pass's stage, with its percent while the words are written.
  static func processingLine(_ processing: MeetingCoordinator.Processing, waitingOnSummary: Bool)
    -> String
  {
    let stage = stage(processing, waitingOnSummary: waitingOnSummary)
    guard let fraction = progress(processing) else { return stage }
    let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
    return String(
      localized: "\(stage) (\(percent))",
      comment: "Menu bar menu: a stopped meeting's transcript work and how far it is, e.g. Writing the transcript (42%).")
  }
}

/// What a meeting's Save writes (#3972 R38, Codex C10 r2): the visible transcript and the
/// user's notes, the notes read first so unknown notes are never written as no notes, and both
/// read again after that wait so a deletion or a new projection meanwhile wins.
@MainActor
enum MeetingExport {
  enum Outcome: Equatable {
    case document(String)
    case notesUnreadable
    /// The meeting is gone, deleting, or has nothing visible.
    case nothingToDeliver
  }

  static func document(
    meetingID: UUID, rowID: UUID, documents: MeetingDocumentsOwner,
    transcripts: TranscriptCoordinator
  ) async -> Outcome {
    guard await documents.load(meetingID) else {
      // A failed read is reported; a meeting deleted meanwhile simply delivers nothing.
      return documents.loadState(meetingID) == .failed ? .notesUnreadable : .nothingToDeliver
    }
    guard let live = transcripts.currentRow(id: rowID),
      let text = transcripts.textForDelivery(live)
    else { return .nothingToDeliver }
    let notes = documents.notes(meetingID).trimmingCharacters(in: .whitespacesAndNewlines)
    return .document(MeetingsPresentation.exportDocument(transcript: text, notes: notes))
  }
}
