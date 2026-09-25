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

  /// Says what Export will actually produce, read in the dialog that produces it
  /// (#1715).
  ///
  /// #1697 put this sentence on the Your Words screen instead, on the reasoning
  /// that a panel message must exist before the panel opens and the count could
  /// only come from a refresh the panel is not allowed to trigger. Half of that
  /// is true: the refresh must stay after the ask. But the count never needed
  /// one — it is read from the in-memory coordinator and handed in. Knowing the
  /// number and refreshing the library are independent, and conflating them put
  /// a paragraph on a screen of controls.
  ///
  /// There is no zero case: `CustomWordsExportAction.run` returns before opening
  /// a panel when the proposal is empty, so an empty export cannot be described
  /// here. That is enforced by the action, not defended by a branch here.
  static func exportSummary(exportableCount: Int) -> String {
    exportableCount == 1
      ? String(
        localized: "Exporting 1 word of your own. Vocabulary packs aren't included.",
        comment: "Your Words export: the line inside the save dialog, one word.")
      : String(
        localized:
          "Exporting \(String(exportableCount)) words of your own. Vocabulary packs aren't included.",
        comment:
          "Your Words export: the line inside the save dialog. %@ is the number of words, never 1.")
  }

  /// The panel's text, apart from the panel so a test can pin the English (#3142).
  static var titleText: String {
    String(
      localized: "Export your words",
      comment:
        "Your Words export: the button on the Your Words page, and the save dialog's title.")
  }

  static var promptText: String {
    String(
      localized: "fileExport.prompt",
      defaultValue: "Export",
      comment: "Save dialog: the button that writes the export file.")
  }

  /// The dialog's whole message: the count, then the privacy note as its own paragraph. Two
  /// complete paragraphs, so joining them splits no sentence.
  static func messageText(exportableCount: Int) -> String {
    exportSummary(exportableCount: exportableCount) + "\n\n" + privacyNote
  }

  static var privacyNote: String {
    String(
      localized:
        "Exported files may contain personal names and other private words. Usage history is not included.",
      comment: "Your Words export: the privacy note inside the save dialog, under the count.")
  }

  /// - Parameter exportableCount: the size of the proposed snapshot the file
  ///   will be built from. The action re-derives and compares the whole payload
  ///   after a destination is chosen, so this number is what gets written or
  ///   nothing is.
  static func chooseDestination(exportableCount: Int) -> URL? {
    let panel = NSSavePanel()
    panel.title = titleText
    panel.prompt = promptText
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
    panel.message = messageText(exportableCount: exportableCount)

    return panel.runModal() == .OK ? panel.url : nil
  }
}
