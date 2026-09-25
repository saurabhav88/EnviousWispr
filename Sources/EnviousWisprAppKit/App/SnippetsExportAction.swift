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

  /// Ask for a destination on the main actor, then WRITE off it.
  ///
  /// The write and its full filesystem sync are not free on a network, external or cloud-synced
  /// destination, and running them here would freeze the settings window until the storage
  /// answers. Only the panel needs the main actor; the bytes do not. Matches the custom-words
  /// export path, which learned this in its own review.
  /// - Parameter currentVocabulary: re-read AFTER the panel closes. A save panel is modal for
  ///   this process and not for any other, so a second EnviousWispr — a shipped copy beside a
  ///   dev build, which is routine — can add or delete a snippet while the dialog is open. A
  ///   backup written from the pre-panel snapshot would silently omit what was added and keep
  ///   what was deleted, and the user would not find out until they restored it.
  static func run(
    vocabulary: SnippetVocabulary,
    currentVocabulary: () -> SnippetVocabulary = { .empty }
  ) async -> Outcome {
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

    // Re-read here, not before the panel: this is the latest moment before the bytes are
    // written, and it is the only read whose result the file actually reflects.
    let latest = currentVocabulary()
    let exported = latest.snippets.isEmpty ? vocabulary : latest
    return await write(document(for: exported), to: destination, count: exported.snippets.count)
  }

  /// The file's contents for a vocabulary. `SnippetsTransferDocument` is the one definition of
  /// the file, shared with Import (#2997); `SnippetsExportRoundTripTests` writes this through
  /// the same writer and reads it back through the importer.
  static func document(for vocabulary: SnippetVocabulary) -> SnippetsTransferDocument {
    SnippetsTransferDocument(
      version: SnippetsManager.currentVersion,
      keyword: vocabulary.keyword,
      snippets: vocabulary.snippets)
  }

  /// `@concurrent` so this always runs OFF the caller's actor. A plain `async` on a `@MainActor`
  /// type would inherit that isolation and put the slow write straight back on the main thread —
  /// the whole point of splitting it out.
  @concurrent
  private static func write(
    _ document: SnippetsTransferDocument, to destination: URL, count: Int
  ) async -> Outcome {
    do {
      try DurableJSONFile.write(document, to: destination, tempPrefix: ".ew-snippets-export")
      return .written(destination, count: count)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// What the panel says the export will contain, read in the dialog that produces it. No zero
  /// case: `run` returns before opening a panel when there is nothing to write.
  static func summary(count: Int) -> String {
    count == 1
      ? String(
        localized: "Exporting 1 snippet and your keyword.",
        comment: "Snippets export: the line inside the save dialog, one snippet.")
      : String(
        localized: "Exporting \(String(count)) snippets and your keyword.",
        comment:
          "Snippets export: the line inside the save dialog. %@ is the number of snippets, never 1."
      )
  }

  /// One sentence per outcome, for the screen. `.cancelled` and `.written` say nothing — a
  /// cancel needs no explanation, and a successful save is visible in Finder.
  static func message(for outcome: Outcome) -> String? {
    switch outcome {
    case .cancelled, .written:
      return nil
    case .nothingToExport:
      return String(
        localized: "There are no snippets to export yet.",
        comment: "Snippets, export: notice when the list is empty.")
    case .refusedLiveStore:
      return String(
        localized:
          "That is EnviousWispr's own snippets file. Pick somewhere else — saving over it would erase your snippets.",
        comment: "Snippets, export: refusal when the chosen file is the app's own snippet store.")
    case .failed(let reason):
      return String(
        localized: "The export did not finish. \(reason)",
        comment:
          "Snippets, export: error. %@ is the system's reason, already in the user's language.")
    }
  }
}
