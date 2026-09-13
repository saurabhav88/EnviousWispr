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
        ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
          TurnRowView(turn: turn, onRename: onRename, onRenameCancelled: onRenameCancelled)
        }
      }
      .onAppear(perform: onTurnsDisplayed)
    } else {
      fallback()
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
}

private struct TurnRowView: View {
  let turn: TranscriptDocumentPresenter.RenderedTurn
  let onRename: (String, String) async -> RenameFailure?
  let onRenameCancelled: () -> Void
  @State private var isRenaming = false
  @State private var draftName = ""
  @State private var renameFailure: RenameFailure?
  /// Captured when the popover opens, never read live off `turn` at commit time: `ForEach`
  /// keys rows by POSITION (`\.offset`), so the same row identity can be reused for a
  /// different turn while a popover is still open (found by chunk review). Committing must
  /// target the speaker the user actually opened the popover on.
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
      }
      content
    }
  }

  /// A real `Button`, never a bare tap gesture (per `accessibility-semantic-controls`) — it
  /// inherits AX role, keyboard activation, and focus order. `"unknown"` never gets one:
  /// `turn.speakerName == nil` is the same signal for BOTH "unnamed real speaker" and
  /// "unknown classification," so the tap target is gated on `speakerId`, not on the name.
  @ViewBuilder private var speakerLabel: some View {
    let displayName = turn.speakerName ?? "Unknown speaker"
    if turn.speakerId == TurnAssembler.unknownSpeakerID {
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
      MarkedUpTurnText(result: diff)
        .textSelection(.enabled)
        // The marks are visual; a screen reader gets the wizard's own spoken form instead,
        // the same helper its whole-document marked-up view uses (found by whole-diff review).
        .accessibilityLabel(TranscribeFileView.markedUpAccessibilityText(diff.segments))
    }
  }
}

/// One turn's worth of marked-up text — struck-through removals, highlighted changes/adds.
/// Mirrors the wizard's existing whole-document marked-up rendering, applied per turn.
private struct MarkedUpTurnText: View {
  let result: WordDiff.Result

  var body: some View {
    result.segments.enumerated().reduce(Text("")) { text, element in
      let (_, segment) = element
      var piece = Text(segment.text + segment.trailing)
      switch segment.kind {
      case .same: break
      case .removed: piece = piece.strikethrough()
      case .changed, .added: piece = piece.foregroundColor(.orange)
      }
      return text + piece
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
private struct RenamePopoverView: View {
  @Binding var name: String
  let failure: RenameFailure?
  let onCommit: (String) -> Void
  let onCancel: () -> Void
  @State private var didCancelExplicitly = false
  @State private var hasCommitted = false
  private static let maxLength = 60

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("Speaker name", text: $name)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
        .onSubmit { commit() }
        .onExitCommand {
          didCancelExplicitly = true
          onCancel()
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

  private func commit() {
    hasCommitted = true
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      onCancel()
      return
    }
    onCommit(trimmed)
  }
}
