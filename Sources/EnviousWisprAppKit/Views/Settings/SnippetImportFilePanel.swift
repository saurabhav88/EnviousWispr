import AppKit
import EnviousWisprPostProcessing
import UniformTypeIdentifiers

/// The open panel for choosing a snippets file to import (#2997).
///
/// A twin of `CustomWordsImportFilePanel`, typed to the snippet registry: content types come
/// from the registry rather than a hardcoded list, and the delegate enables exactly the
/// files the import will read, so the panel can never offer a file the app then refuses.
@MainActor
enum SnippetImportFilePanel {
  /// The panel's text, apart from the panel so a test can pin the English (#3142).
  static var titleText: String {
    String(
      localized: "Choose a snippets file",
      comment: "Snippets import: the title of the file picker.")
  }

  static var promptText: String {
    String(
      localized: "fileImport.prompt",
      defaultValue: "Import",
      comment: "File picker: the button that imports the chosen file.")
  }

  static var messageText: String {
    String(
      localized:
        "Choose the \(SnippetsExportAction.defaultFilename) you exported, a CSV, or a plain list.",
      comment:
        "Snippets import: the line inside the file picker. %@ is the export file's name, such as EnviousWispr Snippets.json; keep it as is."
    )
  }

  static func chooseFile(registry: SnippetImportFileRegistry = .v1) -> URL? {
    let panel = NSOpenPanel()
    panel.title = titleText
    panel.prompt = promptText
    panel.message = messageText
    panel.allowedContentTypes = registry.acceptedContentTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    // `allowedContentTypes` filters by CONFORMANCE while the registry dispatches by EXACT
    // extension; the delegate asks the registry the same question the import will ask.
    let delegate = RegistryFilter(registry: registry)
    panel.delegate = delegate

    let choice = panel.runModal() == .OK ? panel.url : nil
    // The panel holds its delegate weakly; keep it alive until the modal ends.
    withExtendedLifetime(delegate) {}
    return choice
  }

  private final class RegistryFilter: NSObject, NSOpenSavePanelDelegate {
    private let registry: SnippetImportFileRegistry

    init(registry: SnippetImportFileRegistry) {
      self.registry = registry
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
      // Directories stay enabled or the user cannot navigate to their file.
      let isDirectory =
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      if isDirectory { return true }
      return registry.kind(for: url) != nil
    }
  }
}
