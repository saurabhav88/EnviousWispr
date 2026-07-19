import AppKit
import EnviousWisprPostProcessing
import UniformTypeIdentifiers

/// The open panel for choosing a file to import (#1683, PR-U1).
///
/// Content types come from the parser registry rather than a hardcoded list,
/// so registering a new format also makes it selectable — no second place to
/// update and no chance of offering a file the app then refuses to read.
@MainActor
enum CustomWordsImportFilePanel {
  static func chooseFile(registry: ImportFileRegistry = .v1) -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose a file to import"
    panel.prompt = "Import"
    panel.message = "Choose an EnviousWispr backup or a plain text list of words."
    panel.allowedContentTypes = registry.acceptedContentTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    return panel.runModal() == .OK ? panel.url : nil
  }
}
