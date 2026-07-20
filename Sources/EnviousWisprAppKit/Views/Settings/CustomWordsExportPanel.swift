import AppKit
import UniformTypeIdentifiers

/// The app's first save panel (#1680, PR-E1).
///
/// Nothing is read from the word list until this returns a destination, so
/// cancelling is a clean no-op rather than a snapshot taken and thrown away.
/// That ordering is load-bearing and is defended in `CustomWordsExportAction`:
/// refreshing before this point can migrate, archive, or publish library state,
/// so a cancelled export would stop being free (#1696, grounded review r2).
@MainActor
enum CustomWordsExportPanel {
  /// The one runtime authority for what an exported file is called (#1699).
  ///
  /// The import screen names this file so the user can recognise what they are
  /// holding. Two literals would let the exporter rename the file and leave the
  /// import copy describing one that no longer exists.
  static let defaultFilename = "EnviousWispr Words.json"

  /// Where the panel starts (#1696).
  ///
  /// Split out from panel construction because an `NSSavePanel` cannot run in a
  /// test, so the nil branch would otherwise be unreachable from one. Production
  /// passes the user-domain Downloads URLs; tests pass an empty array.
  static func startingDirectory(searchResults: [URL]) -> URL? {
    searchResults.first
  }

  static func chooseDestination() -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export your words"
    panel.prompt = "Export"
    panel.nameFieldStringValue = defaultFilename
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    // Downloads every time, not "last used" (#1696). Today's behaviour is
    // whatever this app last wrote to, which on a fresh build is a temp path.
    // Nothing chose temp; we chose nothing. If Downloads cannot be resolved,
    // leave it unset — a missing start directory is not worth failing over.
    panel.directoryURL = startingDirectory(
      searchResults: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask))
    // Said before the choice, not after: the file lands wherever the user
    // points it, including a synced folder, and it can contain real names.
    //
    // The word COUNT deliberately does not live here. It is shown on the Your
    // Words screen before Export is pressed, because the count must come from
    // the same snapshot the file is built from, and building that snapshot here
    // would need a refresh this panel is not allowed to trigger (#1697).
    panel.message =
      "Exported files may contain personal names and other private terms. "
      + "Usage history is not included."

    return panel.runModal() == .OK ? panel.url : nil
  }
}
