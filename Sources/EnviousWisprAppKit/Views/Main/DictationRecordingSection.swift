import EnviousWisprStorage
import SwiftUI

/// One dictation's saved recording in History's detail (#3147 PR1): Play/Pause with the
/// scrubber and clock (the meeting player's approved controls on the same playback engine),
/// "Keep this recording" and "Delete recording, keep text". Without a recording it shows one
/// line chosen from the reason recorded when it happened. The sentence-timed card, waveform and
/// docked player are PR2.
///
/// The recording's state is read off the main actor when the row is shown and again whenever
/// its recording changes (`DictationRecordingChanges`), never in `body` and never by polling.
struct DictationRecordingSection: View {
  let rowID: UUID
  let recordings: DictationRecordings

  @State private var status: DictationRecordingStatus?
  @State private var player: MeetingPlaybackController?
  @State private var playerURL: URL?
  @State private var actionFailed = false

  private struct LoadKey: Hashable {
    let rowID: UUID
    let revision: Int
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      switch status {
      case .available(_, _, let pinned):
        if let player {
          MeetingPlaybackControls(player: player, identifier: "history.detail.recording.play")
            .id(ObjectIdentifier(player))
        }
        // Side by side only when both full labels fit on one line; otherwise Delete drops below
        // Keep and each label may wrap, so nothing is cut off at the detail pane's narrowest
        // width or in German.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DesignSpacing.xxl) {
            keepToggle(pinned: pinned).fixedSize()
            Spacer(minLength: DesignSpacing.xxl)
            deleteButton.fixedSize()
          }
          VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            keepToggle(pinned: pinned)
            deleteButton
          }
        }
      case .absent(let reason):
        Text(Self.absenceLine(reason))
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      case .unreadable:
        Text(
          "The recording can't be read right now.",
          comment: "History: the recording's file or details could not be read just now."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      case nil:
        EmptyView()
      }
      if actionFailed {
        Text(
          "That didn't work. Try again.",
          comment: "History: a recording action (keep or delete) failed."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
    .task(id: LoadKey(rowID: rowID, revision: recordings.changes.revision(for: rowID))) {
      await refresh()
    }
    .onDisappear { dropPlayer() }
  }

  private func keepToggle(pinned: Bool) -> some View {
    Toggle(isOn: Binding(get: { pinned }, set: { keep in setKeep(keep) })) {
      Text(
        "Keep this recording",
        comment: "History: keeps this dictation's recording from being removed automatically."
      )
      .font(.stBody)
    }
    .toggleStyle(BrandedToggleStyle())
    .help(
      Text(
        "Automatic removal never deletes a kept recording. You can still delete it yourself.",
        comment: "History: explains Keep this recording."))
  }

  private var deleteButton: some View {
    Button(role: .destructive) {
      deleteRecording()
    } label: {
      EnviousButtonLabel(
        LocalizedStringResource(
          "Delete recording, keep text",
          comment: "History: deletes this dictation's audio and keeps its text."),
        size: .medium, systemImage: "trash")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: true)
  }

  /// One line per recorded reason (#3147 §3.4). Legacy or unexplained absence never guesses. An
  /// expiry names the keep period recorded when it happened, never today's setting.
  static func absenceLine(_ absence: RecordedAbsence?) -> LocalizedStringResource {
    switch absence?.reason {
    case .recordingsOff:
      LocalizedStringResource(
        "Recordings were off for this dictation.",
        comment: "History: no recording because recordings were off when this dictation started.")
    case .saveFailed:
      LocalizedStringResource(
        "Recording couldn't be saved.",
        comment: "History: the recording of this dictation failed to save.")
    case .deleted:
      LocalizedStringResource(
        "Recording deleted. The text stays.",
        comment: "History: the user deleted this dictation's recording and kept its text.")
    case .expired:
      if absence?.expiredAfterDays == 1 {
        LocalizedStringResource(
          "Recording expired after 1 day. The text stays.",
          comment: "History: the recording was removed after the one-day keep period chosen in Settings.")
      } else if let days = absence?.expiredAfterDays {
        LocalizedStringResource(
          "Recording expired after \(days) days. The text stays.",
          comment: "History: the recording was removed after the keep period chosen in Settings. %lld is a number of days, more than one.")
      } else {
        LocalizedStringResource(
          "Recording removed after your keep period. The text stays.",
          comment: "History: the recording was removed by the user's recording keep period.")
      }
    case .removedForSpace:
      LocalizedStringResource(
        "Recording removed to free space. The text stays.",
        comment: "History: the recording was removed automatically to free disk space.")
    case nil:
      LocalizedStringResource(
        "Recording unavailable.",
        comment: "History: this dictation has no recording and no recorded reason.")
    }
  }

  /// Reads the recording's state and keeps a player only for the current file. A lookup that a
  /// deletion overtook is dropped, so a stale answer never builds a player for deleted audio.
  private func refresh() async {
    let arbiter = recordings.arbiter
    let id = PlaybackSourceID.dictation(rowID)
    let before = (arbiter?.deletionCount(for: id), arbiter?.dictationEpoch)
    let read = await recordings.status(for: rowID)
    guard !Task.isCancelled else { return }
    guard before == (arbiter?.deletionCount(for: id), arbiter?.dictationEpoch) else { return }
    status = read
    guard case .available(let url, let durationMs, _) = read else {
      dropPlayer()
      return
    }
    guard Self.needsNewPlayer(current: player, currentURL: playerURL, read: url) else { return }
    dropPlayer()
    player = MeetingPlaybackController(
      media: .dictation(url), durationMs: durationMs, output: MeetingPlaybackEngineOutput(),
      sourceID: id, arbiter: arbiter)
    playerURL = url
  }

  /// Whether a fresh, deletion-fenced read of available audio at `url` needs a new player. A
  /// player a deletion stopped stays stopped for good; when that removal failed and the audio is
  /// still there, a new player replaces it, so Play works again.
  static func needsNewPlayer(
    current: MeetingPlaybackController?, currentURL: URL?, read url: URL
  ) -> Bool {
    guard let current else { return true }
    return currentURL != url || current.state == .unavailable
  }

  private func dropPlayer() {
    player?.stop()
    player = nil
    playerURL = nil
  }

  private func setKeep(_ keep: Bool) {
    actionFailed = false
    Task {
      do {
        if keep {
          try await recordings.pin(rowID: rowID)
        } else {
          try await recordings.unpin(rowID: rowID)
        }
      } catch {
        actionFailed = true
      }
    }
  }

  private func deleteRecording() {
    actionFailed = false
    Task {
      do {
        try await recordings.deleteRecording(rowID: rowID, reason: .deleted)
      } catch {
        actionFailed = true
      }
    }
  }
}
