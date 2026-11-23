import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// Your notes, from the app-owned draft (`MeetingNotesAccessing`): each block with its meeting
/// time (choosing it moves playback there without playing), task ticks, quotes with their
/// speaker, and whether the notes are saved on this Mac (with Try again after a failed save).
struct MeetingAfterNotesPane: View {
  let meetingID: UUID
  let notes: any MeetingNotesAccessing
  let snapshot: MeetingNotesSnapshot
  let highlightedNoteID: UUID?
  /// A new marker or View source request, even for the same note: it leaves edit mode.
  let requestNonce: UUID?
  /// Plays the recording from a note's time (a click on the time, in read or edit mode).
  let onPlayFrom: (Int) -> Void
  /// False once the recording is gone or unreadable: note times are then plain text.
  let playbackAvailable: Bool
  /// #3147 PR4A: the playback position, so a block typed after Stop starts there (plan §3.6).
  let playbackMs: @MainActor () -> Int?
  let startsEditing: Bool
  /// #4611: owned by the page, whose tab row draws Edit notes and Done editing.
  @Binding var editing: Bool?
  let recording: Bool
  let markMoment: () -> Void
  let toggleActionItem: () -> Void
  let editorActions: MeetingNotesEditorActions
  // Read mode keeps note times as seek buttons and the marker highlight; Edit notes swaps in
  // the block editor, as Edit summary does for the summary.

  var body: some View {
    Group {
      if editing ?? startsEditing {
        editor
      } else {
        reader
      }
    }
    // A marker or View source that points at a note shows it in read mode, where it is
    // highlighted and its time seeks.
    .onChange(of: requestNonce) { _, nonce in
      if nonce != nil { editing = false }
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      if recording {
        ViewThatFits(in: .horizontal) {
          HStack { liveNoteControls }
          VStack(alignment: .leading) { liveNoteControls }
        }
      }
      MeetingNotesBlockEditor(
        meetingID: meetingID, notes: notes, currentMs: playbackMs, playFrom: playbackAvailable ? onPlayFrom : nil,
        actions: editorActions)
    }
  }

  @ViewBuilder
  private var liveNoteControls: some View {
    Button(action: markMoment) {
      EnviousButtonLabel("Mark moment", size: .medium, systemImage: "flag")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: snapshot.canEdit)
    .disabled(!snapshot.canEdit)
    .keyboardShortcut("m", modifiers: [.command, .shift])
    Button(action: toggleActionItem) {
      EnviousButtonLabel("Action item", size: .medium, systemImage: "checklist")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: snapshot.canEdit)
    .disabled(!snapshot.canEdit)
  }

  private var reader: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      saveLine
      let blocks = snapshot.document.blocks.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if blocks.isEmpty, snapshot.saveState != .loading {
        // #4611 D16: Write notes starts writing, as Write summary does for the summary.
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          Text(
            "No notes for this meeting.",
            comment: "History meeting: the notes pane of a meeting without notes."
          )
          .font(.stCardText)
          .foregroundStyle(.stTextSecondary)
          if snapshot.canEdit {
            Button {
              editing = true
            } label: {
              EnviousButtonLabel(
                LocalizedStringResource(
                  "Write notes", comment: "History meeting: starts writing notes for this meeting."),
                size: .medium)
            }
            .settingsButton(.outlined, size: .medium, isEnabled: true)
          }
        }
      }
      ForEach(blocks) { block in
        blockRow(block)
          .padding(DesignSpacing.xs)
          .background(
            block.id == highlightedNoteID ? Color.stAccent.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: DesignRadius.md)
          )
          .id(block.id)
      }
    }
  }

  @ViewBuilder private var saveLine: some View {
    switch snapshot.saveState {
    case .loading:
      HStack(spacing: DesignSpacing.sm) {
        ProgressView().controlSize(.small)
        Text("Loading your notes", comment: "History meeting: the notes are being read.")
      }
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    case .saving:
      Text("Saving…", comment: "History meeting: the notes are being saved.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    case .saved:
      Text("Saved on this Mac", comment: "History meeting: the notes are saved.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    case .failed:
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
        Text(
          "Your notes couldn't be saved. They stay here until a save works.",
          comment: "History meeting: saving the notes failed; the draft is kept."
        )
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
        Button {
          Task { _ = await notes.flush(meetingID) }
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Try again", comment: "History meeting: saves the notes again."), size: .medium)
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
      }
      .font(.stHelper)
    }
  }

  private func blockRow(_ block: MeetingNoteBlock) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
      if let ms = block.startedAtMs, !block.text.isEmpty {
        if playbackAvailable {
          Button {
            onPlayFrom(ms)
          } label: {
            Text(verbatim: MeetingsPresentation.clock(ms: ms))
              .font(.stHelper.monospacedDigit())
              .foregroundStyle(.stAccent)
          }
          .buttonStyle(.plain)
          .help(
            Text(
              "Play the recording from this note",
              comment: "History meeting: a note's time; plays the recording from there."))
          .accessibilityLabel(
            Text(
              "Play from \(MeetingsPresentation.clock(ms: ms))",
              comment:
                "History meeting: VoiceOver label of a note's time. %@ is the time, like 1:05."))
        } else {
          Text(verbatim: MeetingsPresentation.clock(ms: ms))
            .font(.stHelper.monospacedDigit())
            .foregroundStyle(.stTextSecondary)
        }
      }
      if block.kind == .task {
        Button {
          _ = notes.apply(
            .setDone(blockID: block.id, done: !block.done), to: meetingID,
            expectedRevision: snapshot.revision, atMs: nil)
        } label: {
          Image(systemName: block.done ? "checkmark.square.fill" : "square")
            .font(.stCardText)
            .foregroundStyle(block.done ? Color.stAccent : Color.stTextSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!snapshot.canEdit)
        .accessibilityLabel(
          Text(
            block.done
              ? LocalizedStringResource(
                "Action item done",
                comment: "History meeting: VoiceOver label of a ticked action item's checkbox.")
              : LocalizedStringResource(
                "Action item not done",
                comment: "History meeting: VoiceOver label of an unticked action item's checkbox.")
          ))
      }
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(verbatim: block.text)
          .font(.stCardText)
          .italic(block.kind == .quote)
          .strikethrough(block.kind == .task && block.done)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if block.kind == .quote, let speaker = block.sourceSpeaker {
          HStack(spacing: DesignSpacing.xs) {
            Text(verbatim: speaker)
            if playbackAvailable, let sourceMs = block.sourceMs, sourceMs != block.startedAtMs {
              Button {
                onPlayFrom(sourceMs)
              } label: {
                EnviousButtonLabel(
                  verbatim: MeetingsPresentation.clock(ms: sourceMs), size: .medium)
              }
              .settingsButton(.quiet, size: .medium, isEnabled: true)
              .accessibilityLabel(
                Text(
                  "Play from \(MeetingsPresentation.clock(ms: sourceMs))",
                  comment:
                    "History meeting: VoiceOver label of a quote's source time. %@ is the time, like 1:05."
                ))
            }
          }
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      }
    }
  }
}
