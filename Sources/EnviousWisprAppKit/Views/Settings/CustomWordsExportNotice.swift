import Foundation

/// Export-outcome-to-message mapping (#1703), extracted from the previously
/// private, DEBUG-only `YourWordsView.ExportNotice` so a release-visible
/// caller (`BulkDeleteConfirmSheet`) can present the identical copy. Two
/// kinds, deliberately: a real failure, and an honest outcome that is not a
/// failure. Sharing one "Export didn't finish" title for both would tell a
/// pack-only user their export broke when it worked exactly as designed
/// (#1697).
enum CustomWordsExportNotice: Equatable {
  case failure(String)
  case info(String)

  var title: String {
    switch self {
    case .failure: return "Export didn't finish"
    case .info: return "Nothing was exported"
    }
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
        "Your saved words couldn't be read this time, so there's nothing safe to export. "
          + "Relaunch EnviousWispr and try again.")
    // Neither of the next two is a failure, so neither wears the failure
    // title. A pack-only user pressing Export has done nothing wrong; they
    // need the reason their long word list produced no file (#1697).
    case .nothingToExport:
      return .info(
        "There are no words of your own to export yet. "
          + "Vocabulary packs are not included.")
    case .libraryChanged:
      return .info(
        // Says nothing about WHEN or WHERE the list moved, because two
        // different paths land here: the drift check after a folder was
        // chosen, and a stale empty count that never opened a dialog at
        // all (cloud review, #1715).
        "Your word list changed, so nothing was exported. "
          + "Try Export again.")
    case .failed(let message):
      return .failure(message)
    }
  }
}
