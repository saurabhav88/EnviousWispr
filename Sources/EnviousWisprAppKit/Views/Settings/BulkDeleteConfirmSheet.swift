import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// Confirmation surface shown before any bulk word deletion commits (#1703).
/// Shows an honest count and offers to export a backup first, framed as the
/// easy path rather than a warning to click past. Mirrors
/// `ContactsImportConfirm`'s shape.
struct BulkDeleteConfirmSheet: View {
  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator

  let ids: Set<UUID>
  let onDeleted: () -> Void
  let onCancel: () -> Void

  @State private var exportTask: Task<Void, Never>?
  @State private var exportNotice: CustomWordsExportNotice?
  @State private var deleteFailureMessage: String?

  private var isExporting: Bool { exportTask != nil }

  /// Whole sentences chosen by count, never "word" or "words" spliced in (#3142). A language
  /// with more plural forms adds variants to these entries in the catalog.
  static func title(count: Int) -> String {
    count == 1
      ? String(
        localized: "Delete 1 word?",
        comment: "Your Words, delete selected words: sheet title for one word.")
      : String(
        localized: "Delete \(String(count)) words?",
        comment:
          "Your Words, delete selected words: sheet title. %@ is the number of words, never 1.")
  }

  static func deleteLabel(count: Int) -> String {
    count == 1
      ? String(
        localized: "Delete 1 word",
        comment: "Your Words, delete selected words: button for one word.")
      : String(
        localized: "Delete \(String(count)) words",
        comment: "Your Words, delete selected words: button. %@ is the number of words, never 1.")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(Self.title(count: ids.count))
        .font(.title3)
        .bold()

      Text("This can't be undone.")
        .font(.body)

      if let exportNotice {
        Text(exportNotice.message)
          .font(.stHelper)
          .foregroundStyle(
            exportNotice.isFailure ? .stError : .stTextSecondary)
      }

      if let deleteFailureMessage {
        Text(deleteFailureMessage)
          .font(.stHelper)
          .foregroundStyle(.stError)
      }

      HStack {
        SettingsActionButton(
          title: "Cancel", isEnabled: !isExporting, shortcut: .cancelAction, action: onCancel)

        Spacer()

        // The ProgressView swap stays a raw Button: this control replaces its
        // whole label while exporting, which a title-taking control cannot do.
        Button {
          exportCopy()
        } label: {
          if isExporting {
            ProgressView().controlSize(.small)
          } else {
            Text("Export a copy first")
          }
        }
        .disabled(isExporting)

        // Deletes words permanently, and on this sheet it sat in the same grey
        // as Cancel with only the system's destructive ROLE separating them --
        // a role that renders as red TEXT on macOS and disappears entirely
        // against this palette.
        SettingsActionButton(
          verbatimTitle: Self.deleteLabel(count: ids.count),
          isEnabled: !isExporting,
          emphasis: .destructive
        ) {
          deleteSelection()
        }
      }
    }
    .padding(24)
    .frame(width: 420)
    .interactiveDismissDisabled(isExporting)
    .onDisappear {
      exportTask?.cancel()
    }
  }

  /// Export the user's own words as a backup before the destructive delete
  /// (#1703). Full library, not scoped to only the selected words — this is
  /// meant as a genuine backup, matching the founder's framing.
  ///
  /// The stored task both guards against a duplicate export attempt AND owns
  /// the task's lifecycle: it clears itself via `defer`, checks
  /// cancellation before opening the save panel and again before publishing
  /// a notice, so a torn-down sheet can never publish stale state. A
  /// cancelled-late export may still have written its file; cancellation
  /// only prevents surfacing a stale notice into a gone sheet, it does not
  /// and cannot reverse a write already reached by the writer.
  private func exportCopy() {
    guard exportTask == nil else { return }

    let proposed = CustomWordsExportAction.exportableWords(
      from: customWordsCoordinator.customWords)

    exportTask = Task {
      defer { exportTask = nil }

      guard !Task.isCancelled else { return }
      let outcome = await CustomWordsExportAction.run(
        coordinator: customWordsCoordinator,
        proposedExportWords: proposed,
        chooseDestination: {
          CustomWordsExportPanel.chooseDestination(exportableCount: proposed.count)
        },
        write: { document, destination in
          try await CustomWordsExportWriter.write(document, to: destination)
        }
      )
      guard !Task.isCancelled else { return }
      exportNotice = CustomWordsExportNotice.forOutcome(outcome)
    }
  }

  private func deleteSelection() {
    if let error = customWordsCoordinator.removeBatch(ids: Array(ids)) {
      deleteFailureMessage = error
      return
    }
    onDeleted()
  }
}
