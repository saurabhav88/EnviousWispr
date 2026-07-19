import AppKit
import UniformTypeIdentifiers

/// The app's first save panel (#1680, PR-E1).
///
/// Nothing is read from the word list until this returns a destination, so
/// cancelling is a clean no-op rather than a snapshot taken and thrown away.
@MainActor
enum CustomWordsExportPanel {
  static func chooseDestination() -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export your words"
    panel.prompt = "Export"
    panel.nameFieldStringValue = "EnviousWispr Custom Words.json"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    // Said before the choice, not after: the file lands wherever the user
    // points it, including a synced folder, and it can contain real names.
    panel.message =
      "Exported files may contain personal names and other private terms. "
      + "Usage history is not included."

    return panel.runModal() == .OK ? panel.url : nil
  }
}
