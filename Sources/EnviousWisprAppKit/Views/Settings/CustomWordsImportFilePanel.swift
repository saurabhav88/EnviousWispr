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
    panel.message = "Choose a file you exported from EnviousWispr, or a plain text list of words."
    panel.allowedContentTypes = registry.acceptedContentTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    // `allowedContentTypes` filters by CONFORMANCE, but the registry parses by
    // EXACT extension — so on its own the panel would offer a `.csv` (which
    // conforms to plain text) and the import would then refuse it. The user
    // would have picked a file the app had just told them was acceptable
    // (cloud review, #1683).
    //
    // The delegate closes that gap by asking the registry the SAME question
    // the import will ask. Selectability is therefore defined in one place: a
    // format is offered exactly when a parser claims it, so the two can never
    // drift apart as formats are added.
    let delegate = RegistryFilter(registry: registry)
    panel.delegate = delegate

    let choice = panel.runModal() == .OK ? panel.url : nil
    // The panel holds its delegate weakly; keep it alive until the modal ends.
    withExtendedLifetime(delegate) {}
    return choice
  }

  /// Enables only the files the import can actually read.
  private final class RegistryFilter: NSObject, NSOpenSavePanelDelegate {
    private let registry: ImportFileRegistry

    init(registry: ImportFileRegistry) {
      self.registry = registry
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
      // Directories stay enabled or the user cannot navigate to their file.
      let isDirectory =
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      if isDirectory { return true }
      return registry.parser(for: url) != nil
    }
  }
}
