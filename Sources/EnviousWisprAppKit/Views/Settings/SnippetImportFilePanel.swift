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
  static func chooseFile(registry: SnippetImportFileRegistry = .v1) -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose a snippets file"
    panel.prompt = "Import"
    panel.message =
      "Choose the \(SnippetsExportAction.defaultFilename) you exported, a CSV, or a plain list."
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
