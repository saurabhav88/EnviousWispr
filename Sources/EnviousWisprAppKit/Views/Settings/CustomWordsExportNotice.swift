import Foundation

/// Export-outcome-to-message mapping (#1703), extracted from the previously
/// private `YourWordsView.ExportNotice` so both export entry points
/// (`YourWordsView` and `BulkDeleteConfirmSheet`) present identical copy. Two
/// kinds, deliberately: a real failure, and an honest outcome that is not a
/// failure. Sharing one "Export didn't finish" title for both would tell a
/// pack-only user their export broke when it worked exactly as designed
/// (#1697).
enum CustomWordsExportNotice: Equatable {
  case failure(String)
  case info(String)

  var title: String {
    switch self {
    case .failure:
      return String(
        localized: "Export didn't finish",
        comment: "Your Words, export: alert title after a failure.")
    case .info:
      return String(
        localized: "Nothing was exported",
        comment: "Your Words, export: alert title when there was nothing to export; not a failure.")
    }
  }

  /// Whether this is a real failure. Callers style by this, never by the title text (#3142).
  var isFailure: Bool {
    if case .failure = self { return true }
    return false
  }

  var message: String {
    switch self {
    case .failure(let text), .info(let text): return text
    }
  }

  /// Maps a `CustomWordsExportAction.Outcome` to a notice, or `nil` when
  /// there is nothing to say (`.cancelled` or `.exported`).
  static func forOutcome(_ outcome: CustomWordsExportAction.Outcome) -> CustomWordsExportNotice? {
    switch outcome {
    case .cancelled, .exported:
      return nil
    case .refusedUnsafeLibrary:
      return .failure(
        String(
          localized:
            "Your saved words couldn't be read this time, so there's nothing safe to export. Relaunch EnviousWispr and try again.",
          comment: "Your Words, export: the saved list could not be read."))
    // Neither of the next two is a failure, so neither wears the failure
    // title. A pack-only user pressing Export has done nothing wrong; they
    // need the reason their long word list produced no file (#1697).
    case .nothingToExport:
      return .info(
        String(
          localized:
            "There are no words of your own to export yet. Vocabulary packs are not included.",
          comment: "Your Words, export: only vocabulary packs exist."))
    case .libraryChanged:
      return .info(
        // Says nothing about WHEN or WHERE the list moved, because two
        // different paths land here: the drift check after a folder was
        // chosen, and a stale empty count that never opened a dialog at
        // all (cloud review, #1715).
        String(
          localized: "Your word list changed, so nothing was exported. Try Export again.",
          comment:
            "Your Words, export: the list changed during export; Export is the button's name."))
    case .failed(let message):
      return .failure(message)
    }
  }
}
