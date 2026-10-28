import EnviousWisprCore
import SwiftUI

/// Renders a `TranscriptDocumentPresenter.RenderedTurn` list, or falls through to a caller's
/// own plain-text view when there is nothing turn-shaped to show (#2811, phase 4 of #2807).
///
/// Shared by the file-import wizard's Done step and History's detail view — the two places
/// that replace their own independent renderers with this one (epic §3b). Each caller keeps
/// its OWN plain-text fallback (`fallback`), since the wizard's and History's existing
/// unlabeled behavior are NOT identical (#2811 addendum §3 Design) — this view only owns the
/// turn-labeled case.
struct TurnDocumentView<Fallback: View>: View {
  let turns: [TranscriptDocumentPresenter.RenderedTurn]?
  /// Called with a speaker id and its new name when the user commits a rename. Returns `nil`
  /// on success, or a `RenameFailure` to show inline without dismissing the popover (plan §7:
  /// "Rename write fails ... Popover shows an inline error, does not silently claim success").
  /// The caller re-fetches current analysis/turns and writes through
  /// `mergeSpeakerFields(explicitRename:)` — this view never persists anything itself.
  let onRename: (String, String) async -> RenameFailure?
  /// Called when a rename popover closes WITHOUT a commit: Escape, or a blank name reverting
  /// (plan §3d). An outside click commits and never reaches this. Shape-only telemetry is the
  /// only consumer (#2811 §3e `cancelled`); the view keeps nothing.
  var onRenameCancelled: () -> Void = {}
  /// Called each time the turn branch below APPEARS, i.e. `turns` became non-nil for this
  /// view identity. The caller decides whether that is new for the document (#2811 §3e
  /// `file_import_turns_displayed`, deduplicated per document in each coordinator).
  var onTurnsDisplayed: () -> Void = {}
  /// #3972: when set, a turn with a start time offers "play from here", which calls this with
  /// that time. Only EnviousMeet's detail sets it.
  var onPlayFrom: ((Int) -> Void)? = nil
  /// #4013 r3 F3: the names the rename popover offers for each speaker. `.none` offers nothing,
  /// as before.
  var renameSuggestions: SpeakerRenameSuggestions = .none
  @ViewBuilder let fallback: () -> Fallback

  /// No `ScrollView` of its own (found by chunk review): both callers already embed this
  /// view inside a container that scrolls the WHOLE page — the wizard's Done step and
  /// History's detail view alike. A nested `ScrollView` with no height of its own has nothing
  /// to size against and collapses instead of growing with the text, exactly the "renders
  /// exactly today's plain text" contract this view exists to preserve.
  ///
  /// `LazyVStack`, not `VStack` (found by cloud review, round 5): a multi-hour recording has
  /// thousands of turns, each row carrying its own rename state and popover, and the eager
  /// stack built and laid out every one of them at once inside the callers' scroll views.
  /// Rows now materialise as they scroll into view; a rename popover only ever belongs to a
  /// visible row, so the per-row state a lazy stack discards off-screen is never in use.
  var body: some View {
    if let turns {
      LazyVStack(alignment: .leading, spacing: 16) {
        // #4001 H11: surviving unique-ID turns keep their keys when other turns
        // are hidden or shown. Reused IDs can retain state across replacements.
        ForEach(TurnRowKey.keyed(turns), id: \.key) { _, turn in
          TurnRowView(
            turn: turn, onRename: onRename, onRenameCancelled: onRenameCancelled,
            onPlayFrom: onPlayFrom, renameSuggestions: renameSuggestions)
        }
      }
      .onAppear(perform: onTurnsDisplayed)
    } else {
      fallback()
    }
  }
}

/// A turn row's identity in `TurnDocumentView` (#4001 H11): the turn's id and its occurrence
/// among turns with the same id in one document.
struct TurnRowKey: Hashable {
  let turnID: String
  let occurrence: Int

  /// Each turn's id and its zero-based occurrence among matching ids.
  /// Valid producer output has unique IDs; duplicate data still receives
  /// distinct keys. Occurrences do not establish semantic identity across edits.
  /// Keeping the count separate makes ["x", "x", "x#1"] collision-free.
  /// Plain value code with no main-actor isolation.
  static func keyed(_ turns: [TranscriptDocumentPresenter.RenderedTurn])
    -> [(key: TurnRowKey, turn: TranscriptDocumentPresenter.RenderedTurn)]
  {
    var seen: [String: Int] = [:]
    return turns.map { turn in
      let occurrence = seen[turn.turnID, default: 0]
      seen[turn.turnID] = occurrence + 1
      return (TurnRowKey(turnID: turn.turnID, occurrence: occurrence), turn)
    }
  }
}

/// A failed rename write. `currentName` is the re-read, currently-saved name (plan §9: "Revert
/// popover's TextField to the LAST KNOWN GOOD name ... re-read, not the value the user typed"),
/// `nil` if the speaker still has no name — the caller performs the actual re-read; this type
/// only carries the result back into the popover.
struct RenameFailure: Equatable, Sendable {
  let message: String
  let currentName: String?
  /// Two consecutive failures with the same message and name must still read as DIFFERENT
  /// values, or `RenamePopoverView`'s `.onChange(of: failure)` never fires for the second
  /// and its `hasCommitted` guard stays stuck, so an outside click no longer commits (found
  /// by second-pass review).
  let attemptID = UUID()

  /// #3142: the two outcomes both rename paths (History and Transcribe a File) report,
  /// authored once.
  static var couldNotSaveName: String {
    String(
      localized: "Couldn't save the name.",
      comment: "Speaker rename popover: saving the new name failed.")
  }
  static var recordingRemoved: String {
    String(
      localized: "This recording was removed from History.",
      comment:
        "Speaker rename popover: the recording no longer exists in History, so the name was not saved."
    )
  }
}

private struct TurnRowView: View {
  let turn: TranscriptDocumentPresenter.RenderedTurn
  let onRename: (String, String) async -> RenameFailure?
  let onRenameCancelled: () -> Void
  let onPlayFrom: ((Int) -> Void)?
  let renameSuggestions: SpeakerRenameSuggestions
  @State private var isRenaming = false
  @State private var draftName = ""
  @State private var renameFailure: RenameFailure?
  /// Captured when the popover opens, never read live off `turn` at commit
  /// time: a retry can reuse a persisted turn ID with changed content or
  /// speaker assignment. Commit targets the speaker the user opened.
  @State private var renamingSpeakerId: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        speakerLabel
        if let timeLabel = turn.timeLabel {
          Text(timeLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let onPlayFrom, let startMs = turn.startMs {
          Button {
            onPlayFrom(startMs)
          } label: {
            Image(systemName: "play.circle")
          }
          .buttonStyle(.borderless)
          .help(
            Text(
              "Play from here",
              comment: "EnviousMeet transcript: plays the recording from this turn's start.")
          )
          .accessibilityLabel(
            Text(
              "Play from here",
              comment: "EnviousMeet transcript: plays the recording from this turn's start."))
        }
      }
      content
      // The same disclosure the document gives a passage the polisher could not clean, per
      // turn (#2851 §3 D): the presenter decides, this only shows it, on both screens.
      if turn.isUncleaned {
        Text("Not fully polished")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }
    }
  }

  /// A real `Button`, never a bare tap gesture (per `accessibility-semantic-controls`) — it
  /// inherits AX role, keyboard activation, and focus order. `"unknown"` never gets one:
  /// `turn.speakerName == nil` is the same signal for BOTH "unnamed real speaker" and
  /// "unknown classification," so the tap target is gated on `speakerId`, not on the name.
  @ViewBuilder private var speakerLabel: some View {
    let displayName =
      turn.speakerName
      ?? String(
        localized: "Unknown speaker",
        comment: "Transcript turn header when the speaker has no name.")
    if turn.speakerId == TurnAssembler.unknownSpeakerID
      || turn.speakerId == TurnAssembler.bothSpeakersID
    {
      Text(displayName)
        .font(.subheadline.bold())
        .foregroundStyle(.secondary)
    } else {
      Button {
        renamingSpeakerId = turn.speakerId
        draftName = turn.speakerName ?? ""
        renameFailure = nil
        isRenaming = true
      } label: {
        Text(displayName)
          .font(.subheadline.bold())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Rename speaker")
      .accessibilityValue(displayName)
      .popover(isPresented: $isRenaming) {
        RenamePopoverView(
          name: $draftName,
          failure: renameFailure,
          suggestions: renameSuggestions.names(for: renamingSpeakerId ?? turn.speakerId),
          onCommit: { name in commitRename(name) },
          onCancel: {
            renameFailure = nil
            isRenaming = false
            onRenameCancelled()
          })
      }
    }
  }

  /// On failure, reopens (or keeps open) the popover showing the error and the reverted name;
  /// on success it closes. `isRenaming = true` is required even when it is already true: an
  /// outside-click commit has ALREADY dismissed the popover (SwiftUI cleared the binding before
  /// `.onDisappear` fired), so without this the failure and restored name would land on an
  /// already-gone view (found by chunk review r3).
  private func commitRename(_ name: String) {
    guard let id = renamingSpeakerId else {
      isRenaming = false
      return
    }
    Task {
      if let failure = await onRename(id, name) {
        // The field reverts to the re-read current name (plan §9), never the rejected input;
        // seeded HERE on the row's own binding so it holds whether the popover instance
        // survived (Enter) or is about to be recreated (outside click).
        draftName = failure.currentName ?? ""
        renameFailure = failure
        isRenaming = true
      } else {
        renameFailure = nil
        isRenaming = false
      }
    }
  }

  /// Selectable in both modes, as every passage this view replaces already was on both
  /// screens (found by whole-diff review): a user copies one sentence of one turn as freely
  /// as before, not only the whole document through Copy.
  @ViewBuilder private var content: some View {
    switch turn.content {
    case .plain(let text):
      Text(text)
        .textSelection(.enabled)
    case .markedUp(let diff):
      MarkedUpPassageText(segments: diff.segments)
    }
  }
}

/// One passage of marked-up text — red struck-through removals, green-tinted
/// changes/adds. The colours come from `MarkUpPalette`, the same table the wizard's
/// whole-document `markedUpText` reads (#2817 finding 5: this view painted orange and no red).
///
/// One `Text` per passage rather than one per document, so a 20,000-word transcript is forty-odd
/// small layouts instead of one that re-lays out on every scroll (finding 5, the lag half).
///
/// The one home for how a marked-up passage is selectable and spoken, shared by History's turn
/// rows and Transcribe a File's passages. Text selection stays enabled on the visible text, and the
/// marks (colour and strikethrough say nothing aloud) are spoken as words ("Removed: um.") through
/// `accessibilityRepresentation`.
///
/// #3573: with the dev app launched through LaunchServices, an outside accessibility client reading
/// History's two-speaker Marked up view crashed unchanged main (selection plus a custom
/// `.accessibilityLabel` on the same text) in 3 of 3 launches. Label alone, selection alone and
/// selection plus this representation each had no crash in 2 of 2 launches; putting the label
/// before the selection still crashed 2 of 2. This view had no crash in 5 of 5 launches and exposed
/// "Hello Removed: um. world today.". A direct executable launch did not reproduce the crash on
/// unchanged main. Not live-verified: Transcribe a File, and VoiceOver focus, selection
/// announcements and copy behaviour.
struct MarkedUpPassageText: View {
  let segments: [WordDiff.Segment]

  var body: some View {
    Text(TranscribeFileExport.markedUpText(segments))
      .textSelection(.enabled)
      .accessibilityRepresentation {
        Text(TranscribeFileExport.markedUpAccessibilityText(segments))
      }
  }
}

/// Blank reverts; duplicate names allowed; 60-character cap; Enter commits, Escape cancels,
/// dismissing by clicking outside ALSO commits (#2811 addendum §3d). SwiftUI has no direct
/// "dismissed by outside click" event — only `.onExitCommand` for Escape specifically — so
/// this distinguishes the two via a flag Escape sets before dismissal, and treats ANY OTHER
/// disappearance (`.onDisappear`, which fires for outside-click dismissal too) as a commit
/// attempt. Escape's own flag makes it read as a cancel instead, even though both paths
/// dismiss through the same SwiftUI mechanism.
///
/// The field is a BINDING to the row's draft, never a `@State` seeded in `init` (found by
/// Live UAT, 2026-09-13: the popover opened EMPTY for "Speaker 1"). macOS builds a
/// popover's content before it is first shown, and a `State(initialValue:)` set in `init`
/// counts only for that first construction, so the field kept the empty draft it was built
/// with. The row sets the draft on open and on a failed commit (plan §9's revert), and the
/// two dismissal guards are reset on every appearance for the same reason: this instance
/// can be reused across presentations, and a `hasCommitted` left over from the last one
/// would turn the next outside click into a silent no-op.
///
/// `failure` renders inline when the caller's last commit attempt failed (plan §7).
///
/// #4013 r3 F3: `suggestions` (this meeting's participants and the user's kept names) are
/// buttons above the field. Choosing one commits it through the same `onCommit`, once, spelled
/// exactly as saved (the 60-character cap is for typing, so a long participant name is not cut).
/// Keyboard focus stays in the field, as before (#4013 UAT: focusable suggestion buttons took
/// focus from it when the popover opened): Down and Up highlight a suggestion, Return chooses
/// the highlighted one, Up from the first clears the highlight. Each suggestion is a real
/// button, so VoiceOver and Full Keyboard Access reach and activate it directly.
private struct RenamePopoverView: View {
  @Binding var name: String
  let failure: RenameFailure?
  let suggestions: [String]
  let onCommit: (String) -> Void
  let onCancel: () -> Void
  @State private var didCancelExplicitly = false
  @State private var hasCommitted = false
  /// The suggestion Return chooses, by name, never by position: the list can change while the
  /// popover is open, and the highlight must not move to another name in the same place.
  @State private var highlighted: String?
  private static let maxLength = 60

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !suggestions.isEmpty { suggestionList }
      TextField("Speaker name", text: $name)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
        .onSubmit {
          if let highlighted, suggestions.contains(highlighted) {
            choose(highlighted)
          } else {
            commit()
          }
        }
        .onExitCommand {
          didCancelExplicitly = true
          onCancel()
        }
        .onKeyPress(.downArrow) {
          guard !suggestions.isEmpty else { return .ignored }
          let index = highlighted.flatMap(suggestions.firstIndex(of:)).map { $0 + 1 } ?? 0
          highlighted = suggestions[min(index, suggestions.count - 1)]
          return .handled
        }
        .onKeyPress(.upArrow) {
          guard let current = highlighted.flatMap(suggestions.firstIndex(of:)) else {
            return .ignored
          }
          highlighted = current > 0 ? suggestions[current - 1] : nil
          return .handled
        }
        .onChange(of: name) { _, newValue in
          if newValue.count > Self.maxLength { name = String(newValue.prefix(Self.maxLength)) }
        }
      if let failure {
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(8)
    .onAppear {
      hasCommitted = false
      didCancelExplicitly = false
      highlighted = nil
    }
    .onChange(of: suggestions) { _, newValue in
      // The highlighted name left the list: nothing is highlighted, never a neighbour.
      if let highlighted, !newValue.contains(highlighted) { self.highlighted = nil }
    }
    .onChange(of: failure) { _, newValue in
      guard newValue != nil else { return }
      hasCommitted = false
      didCancelExplicitly = false
    }
    .onDisappear {
      guard !didCancelExplicitly, !hasCommitted else { return }
      commit()
    }
  }

  private var suggestionList: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Suggestions", comment: "Speaker rename popover: heading above names to choose from.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          // Names are unique in the list (`SpeakerRenameSuggestions.names(for:)`).
          ForEach(suggestions, id: \.self) { suggestion in
            Button {
              choose(suggestion)
            } label: {
              // A participant's name is content, never a translation key.
              Text(verbatim: suggestion)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(highlighted == suggestion ? Color.accentColor.opacity(0.2) : .clear))
            .accessibilityAddTraits(highlighted == suggestion ? .isSelected : [])
          }
        }
      }
      .frame(width: 200)
      .frame(maxHeight: 160)
      .fixedSize(horizontal: false, vertical: suggestions.count <= 5)
    }
  }

  /// A chosen suggestion is the name. `hasCommitted` is the one gate for every commit (choosing,
  /// Return in the field, the outside click): while one write is pending no other is sent, and
  /// a failure (`onChange(of: failure)`) opens it again for a retry.
  private func choose(_ suggestion: String) {
    guard !hasCommitted else { return }
    hasCommitted = true
    onCommit(suggestion)
  }

  private func commit() {
    guard !hasCommitted else { return }
    hasCommitted = true
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      onCancel()
      return
    }
    onCommit(trimmed)
  }
}
