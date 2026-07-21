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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Delete \(ids.count) \(ids.count == 1 ? "word" : "words")?")
        .font(.title3)
        .bold()

      Text("This can't be undone.")
        .font(.body)

      if let exportNotice {
        Text(exportNotice.message)
          .font(.stHelper)
          .foregroundStyle(
            exportNotice.title == "Export didn't finish" ? .stError : .stTextSecondary)
      }

      if let deleteFailureMessage {
        Text(deleteFailureMessage)
          .font(.stHelper)
          .foregroundStyle(.stError)
      }

      HStack {
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isExporting)

        Spacer()

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

        Button("Delete \(ids.count) \(ids.count == 1 ? "word" : "words")", role: .destructive) {
          deleteSelection()
        }
        .disabled(isExporting)
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
