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
  @ViewBuilder let fallback: () -> Fallback

  var body: some View {
    if let turns {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
            TurnRowView(turn: turn, onRename: onRename)
          }
        }
        .padding()
      }
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
}

private struct TurnRowView: View {
  let turn: TranscriptDocumentPresenter.RenderedTurn
  let onRename: (String, String) async -> RenameFailure?
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
          initialName: draftName,
          failure: renameFailure,
          onCommit: { name in commitRename(name) },
          onCancel: {
            renameFailure = nil
            isRenaming = false
          })
      }
    }
  }

  /// On failure, the popover stays open (`isRenaming` was never cleared) showing the error and
  /// the reverted name; on success it closes.
  private func commitRename(_ name: String) {
    guard let id = renamingSpeakerId else {
      isRenaming = false
      return
    }
    Task {
      if let failure = await onRename(id, name) {
        renameFailure = failure
      } else {
        renameFailure = nil
        isRenaming = false
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch turn.content {
    case .plain(let text):
      Text(text)
    case .markedUp(let diff):
      MarkedUpTurnText(result: diff)
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
/// `failure` renders inline when the caller's last commit attempt failed (plan §7) and reverts
/// the field to the re-read current name (plan §9) — never the rejected input. Because a
/// failure keeps `isRenaming` true, THIS SAME instance survives the failed attempt (found by
/// chunk review r2: an instance that stayed alive kept `hasCommitted = true` from the failed
/// Enter forever, so a following outside-click could never re-commit). `.onChange(of: failure)`
/// resets both dismissal guards whenever a new failure arrives, so a retry behaves like a fresh
/// attempt.
private struct RenamePopoverView: View {
  let initialName: String
  let failure: RenameFailure?
  let onCommit: (String) -> Void
  let onCancel: () -> Void
  @State private var name: String
  @State private var didCancelExplicitly = false
  @State private var hasCommitted = false
  private static let maxLength = 60

  init(
    initialName: String, failure: RenameFailure?, onCommit: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialName = initialName
    self.failure = failure
    self.onCommit = onCommit
    self.onCancel = onCancel
    self._name = State(initialValue: initialName)
  }

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
    .onChange(of: failure) { _, newValue in
      guard let newValue else { return }
      hasCommitted = false
      didCancelExplicitly = false
      name = newValue.currentName ?? ""
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
