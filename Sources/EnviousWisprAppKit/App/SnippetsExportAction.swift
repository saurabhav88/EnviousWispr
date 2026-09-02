import AppKit
import EnviousWisprCore
import EnviousWisprPostProcessing
import UniformTypeIdentifiers

/// Write the user's snippets to a file they choose (#628).
///
/// Shipped in v1 even though Import is deferred, and the order is deliberate: an export that
/// exists first means Import later lands against a format already in the wild, rather than
/// inventing one and then having to keep two. It is also the only way a user moving Macs keeps
/// snippets they typed by hand.
@MainActor
enum SnippetsExportAction {
  static let defaultFilename = "EnviousWispr Snippets.json"

  enum Outcome: Equatable {
    case cancelled
    case nothingToExport
    /// The destination IS the app's own store. Refused, never written.
    case refusedLiveStore
    case written(URL, count: Int)
    case failed(String)
  }

  /// The exported shape. Deliberately the same field names the store persists, so a file a user
  /// keeps for a year still means what it says, and Import has nothing to translate.
  struct Document: Encodable {
    let version: Int
    let keyword: String
    let snippets: [Snippet]
  }

  static func run(vocabulary: SnippetVocabulary) -> Outcome {
    // Checked BEFORE the panel: opening a save dialog and then announcing there was nothing to
    // save wastes the one interaction the user paid for.
    guard !vocabulary.snippets.isEmpty else { return .nothingToExport }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultFilename
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.message = summary(count: vocabulary.snippets.count)
    panel.directoryURL =
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
      .first

    guard panel.runModal() == .OK, let destination = panel.url else { return .cancelled }

    // The data-loss guard. Choosing the app's own store would replace it with this document,
    // and the next launch would archive it as corrupt — the user destroying their snippets by
    // backing them up. Compared through the filesystem, not the strings.
    if let live = SnippetsManager.liveFileURL,
      DurableJSONFile.isSameFile(destination, as: live)
    {
      return .refusedLiveStore
    }

    do {
      try DurableJSONFile.write(
        Document(
          version: SnippetsManager.currentVersion,
          keyword: vocabulary.keyword,
          snippets: vocabulary.snippets),
        to: destination,
        tempPrefix: ".ew-snippets-export")
      return .written(destination, count: vocabulary.snippets.count)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// What the panel says the export will contain, read in the dialog that produces it. No zero
  /// case: `run` returns before opening a panel when there is nothing to write.
  static func summary(count: Int) -> String {
    count == 1
      ? "Exporting 1 snippet and your keyword."
      : "Exporting \(count) snippets and your keyword."
  }

  /// One sentence per outcome, for the screen. `.cancelled` and `.written` say nothing — a
  /// cancel needs no explanation, and a successful save is visible in Finder.
  static func message(for outcome: Outcome) -> String? {
    switch outcome {
    case .cancelled, .written:
      return nil
    case .nothingToExport:
      return "There are no snippets to export yet."
    case .refusedLiveStore:
      return
        "That is EnviousWispr's own snippets file. Pick somewhere else — saving over it would erase your snippets."
    case .failed(let reason):
      return "The export did not finish. \(reason)"
    }
  }
}
