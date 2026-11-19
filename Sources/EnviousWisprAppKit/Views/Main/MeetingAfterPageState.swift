import EnviousWisprCore
import Foundation
import Observation

// The meeting page's own state, grouped by job (#4703). Each holder is kept in one `@State` on
// `HistoryMeetingAfterView`, so every value keeps the page's lifetime: it survives the stacked and
// wide layouts, the header and body split and the record, orphan and removed branches, and resets
// only where the page resets it.

// MARK: - Player

@MainActor @Observable
final class MeetingPagePlayer {
  var player: MeetingPlaybackController?
  var source: MeetingPlaybackSource?
  var retainedRate: Float = 1

  /// Keeps a player only for the meeting's current playable source: the same source keeps it
  /// (and its place), a changed inventory or length replaces it, and no source drops it.
  func reconcile(
    to newSource: MeetingPlaybackSource?, meetingID: UUID, arbiter: () -> PlaybackArbiter?
  ) {
    switch MeetingPlaybackSource.change(from: player == nil ? nil : source, to: newSource) {
    case .keep:
      return
    case .drop:
      drop()
    case .replace:
      let rate = player?.playbackRate ?? retainedRate
      drop()
      if let newSource {
        // #3147: known to the shared now-playing owner, so another recording starting pauses
        // this one and a deletion stops it before its files go.
        let next = MeetingPlaybackController(
          source: newSource, output: MeetingPlaybackEngineOutput(), meetingID: meetingID,
          arbiter: arbiter())
        next.setPlaybackRate(rate)
        player = next
        source = newSource
      }
    }
  }

  func drop() {
    if let player { retainedRate = player.playbackRate }
    player?.stop()
    player = nil
    source = nil
  }
}

// MARK: - Follow playback

@MainActor @Observable
final class MeetingFollowState {
  var follow: MeetingAfterPresentation.Follow = .following
  var activeTurnID: String?
  var highlightedTurnID: String?

  func suspendIfPlaying(_ isPlaying: Bool) {
    // Same as the transcript page: scrolling suspends following only while playing.
    guard isPlaying else { return }
    if follow == .following { follow = .suspended }
  }

  /// View source on a turn: stop following and highlight it (the page scrolls to it).
  func showTurn(_ id: String) {
    if follow == .following { follow = .suspended }
    highlightedTurnID = id
  }

  /// Return to playback: follow again and drop the View source highlight.
  func returnToPlayback() {
    follow = .following
    highlightedTurnID = nil
  }
}

// MARK: - Notes and panes

@MainActor @Observable
final class MeetingNotesPaneState {
  struct NoteRequest: Equatable {
    let id: UUID
    let nonce = UUID()
  }

  var leftPane: MeetingAfterPresentation.LeftPane = .notes
  /// #4611: Your notes' edit mode, owned here so Edit notes sits on the tab row. Nil until the
  /// person chooses: the pane then starts in its default mode.
  var editingNotes: Bool?
  var highlightedNoteID: UUID?
  /// A request to bring a note into view. A fresh request each time, so choosing the same note
  /// again scrolls back to it.
  var noteRequest: NoteRequest?
  var narrowPane: MeetingSessionPane = .notes
  let notesActions = MeetingNotesEditorActions()

  func showNote(_ id: UUID) {
    leftPane = .notes
    narrowPane = .notes
    // A note shown from a marker or View source opens in read mode, where it is highlighted
    // (#4611: the edit state lives here, and a recreated notes pane sees no request change).
    editingNotes = false
    highlightedNoteID = id
    noteRequest = NoteRequest(id: id)
  }
}

// MARK: - Summary editing

@MainActor @Observable
final class MeetingSummaryEditState {
  var summaryPolishNotice = false
  var keepingSummary = false
  var editingSummary = false
}

// MARK: - Commands

@MainActor @Observable
final class MeetingPageCommands {
  struct Notice: Equatable {
    let text: String
    let isError: Bool
    /// A failed deletion offers Try again here, even when the menu no longer offers it (the
    /// deletion mark was already saved).
    var retry: HistoryMeetingAfterView.Confirmation? = nil
  }

  let anchor = HistoryMenuAnchorHolder()
  let transcriptPolish = HistoryPolishPreview()
  var confirming: HistoryMeetingAfterView.Confirmation?
  var pendingTranscription: MeetingEngineChoice?
  var actionInFlight = false
  var saveError: String?
  var notice: Notice?
}
