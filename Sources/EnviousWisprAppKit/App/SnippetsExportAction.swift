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
  struct Document: Encodable, Sendable {
    let version: Int
    let keyword: String
    let snippets: [Snippet]
  }

  /// Ask for a destination on the main actor, then WRITE off it.
  ///
  /// The write and its full filesystem sync are not free on a network, external or cloud-synced
  /// destination, and running them here would freeze the settings window until the storage
  /// answers. Only the panel needs the main actor; the bytes do not. Matches the custom-words
  /// export path, which learned this in its own review.
  static func run(vocabulary: SnippetVocabulary) async -> Outcome {
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

    let document = Document(
      version: SnippetsManager.currentVersion,
      keyword: vocabulary.keyword,
      snippets: vocabulary.snippets)
    return await write(document, to: destination, count: vocabulary.snippets.count)
  }

  /// `@concurrent` so this always runs OFF the caller's actor. A plain `async` on a `@MainActor`
  /// type would inherit that isolation and put the slow write straight back on the main thread —
  /// the whole point of splitting it out.
  @concurrent
  private static func write(
    _ document: Document, to destination: URL, count: Int
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
