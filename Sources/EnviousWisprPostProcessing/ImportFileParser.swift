import EnviousWisprCore
import Foundation
import UniformTypeIdentifiers

/// Why a chosen file could not become import candidates (#1683, PR-U1).
package enum ImportFileError: LocalizedError, Sendable, Equatable {
  case unreadable
  case unsupportedType(String)
  case tooLarge
  case tooManyWords(found: Int, limit: Int)
  case exportedWords(CustomWordsTransferError)

  package var errorDescription: String? {
    switch self {
    case .unreadable:
      return "That file couldn't be read."
    case .tooLarge:
      return "That file is too big to be a word list. Check you picked the right one."
    case .tooManyWords(let found, let limit):
      return
        "That file has \(found) words, which is more than EnviousWispr can import "
        + "at once (\(limit)). Try splitting it into smaller files."
    case .unsupportedType(let name):
      return
        "EnviousWispr can't read \(name) files yet. "
        + "Try a file you exported from EnviousWispr, or a plain text list."
    case .exportedWords(let underlying):
      // The decoder already distinguishes "not ours", "from a newer
      // version", and "damaged"; passing its sentence through keeps the user
      // from being told something less true by a wrapper.
      return underlying.errorDescription
    }
  }
}

/// One file format the picker can read.
///
/// A registry rather than a switch so CSV (and later Excel) is a pure addition:
/// a new conformer and one registry entry, with nothing existing rewritten.
/// That seam is the reason the plan asked for a registry at all, and it stays
/// even though v1 registers only two formats.
package protocol ImportFileParser: Sendable {
  /// Stable identifier, emitted as the batch's `sourceID` for telemetry.
  var identifier: String { get }
  /// What the user sees.
  var displayName: String { get }
  /// Content types this parser claims.
  var contentTypes: [UTType] { get }
  func parse(data: Data) throws -> [CustomWordsImportCandidate]
}

/// The file EnviousWispr itself exports.
///
/// Deliberately not called a "backup": the product has two ideas, import and
/// export, and naming the exported file a third thing invented a concept the
/// user never asked for (founder, 2026-07-19). Without this parser an export
/// could be produced but never read back, which would make Export a promise
/// the app could not keep.
package struct ExportedWordsFileParser: ImportFileParser {
  package let identifier = "exported-words"
  package let displayName = "EnviousWispr words file"
  package let contentTypes: [UTType] = [.json]

  package init() {}

  package func parse(data: Data) throws -> [CustomWordsImportCandidate] {
    do {
      return try CustomWordsTransferDocument(data: data).candidatesForImport()
    } catch let error as CustomWordsTransferError {
      throw ImportFileError.exportedWords(error)
    }
  }
}

/// A plain list of words.
///
/// Deliberately the SAME parser the Paste screen uses, not a second
/// implementation: a word list is a word list whether it was typed into a box
/// or saved to a file, and two parsers would eventually disagree about what
/// "C++" or "Envious Labs" means.
package struct PlainTextImportFileParser: ImportFileParser {
  package let identifier = "plain-text"
  package let displayName = "Plain text"
  package let contentTypes: [UTType] = [.plainText, .utf8PlainText, .text]

  package init() {}

  package func parse(data: Data) throws -> [CustomWordsImportCandidate] {
    // Accept UTF-8 first, then fall back to the platform's legacy encoding
    // rather than refusing a file a user exported from an older tool.
    guard
      let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
    else {
      throw ImportFileError.unreadable
    }
    return PasteWordsParser.parse(text).map {
      CustomWordsImportCandidate(canonical: $0)
    }
  }
}

/// Chooses a parser for a file and runs it.
package struct ImportFileRegistry: Sendable {
  package let parsers: [any ImportFileParser]

  /// v1 registers the two formats that need no parsing decisions: the file we
  /// author ourselves, and a plain word list. CSV is deliberately
  /// absent — it is the only format that needs the quoted-field state machine
  /// (or a dependency to supply one), and that call is the founder's to make.
  package static let v1 = ImportFileRegistry(
    parsers: [ExportedWordsFileParser(), PlainTextImportFileParser()])

  package init(parsers: [any ImportFileParser]) {
    self.parsers = parsers
  }

  package var acceptedContentTypes: [UTType] {
    parsers.flatMap(\.contentTypes)
  }

  package func parser(for url: URL) -> (any ImportFileParser)? {
    guard
      let type = UTType(filenameExtension: url.pathExtension.lowercased())
    else { return nil }
    // EXACT match, deliberately not conformance.
    //
    // CSV and TSV conform to `public.plain-text`, so a conformance match hands
    // a spreadsheet to the plain-text parser — which splits on commas, and
    // would silently turn one row of `GitHub,git hub,brand` into three words,
    // header rows and category names included. Quietly corrupting a
    // dictionary is far worse than refusing a file, so a format is readable
    // only when a parser claims it by name.
    //
    // The cost is that an unrecognised text subtype reports "unsupported"
    // rather than being read on a guess. That is the honest answer, and CSV
    // becomes supported by registering a real CSV parser — the seam this
    // registry exists for — not by widening this match.
    return parsers.first { $0.contentTypes.contains(type) }
  }
}

/// Reads a user-chosen file and turns it into a batch.
package struct FileImportSource: CustomWordsImportSource {
  /// Refuse before allocating. A word list is small; anything of this size is
  /// a mistaken selection (a video, a database, a disk image), and reading it
  /// into memory to discover that is the expensive way to find out.
  package static let maximumFileBytes = 16 * 1024 * 1024
  /// Shared with every other import source, so no door has a different limit.
  package static var maximumCandidates: Int { CustomWordsImportLimits.maximumCandidates }

  private let url: URL
  private let registry: ImportFileRegistry

  package init(url: URL, registry: ImportFileRegistry = .v1) {
    self.url = url
    self.registry = registry
  }

  /// `@concurrent` so reading and parsing always leave the caller's actor.
  /// The import model is `@MainActor`, and a plain `async` witness would
  /// inherit that isolation — a large, network-mounted, or cloud-backed file
  /// would then freeze the settings window while it was read (code review).
  @concurrent package func loadCandidates() async throws -> CustomWordsImportBatch {
    guard let parser = registry.parser(for: url) else {
      let name = url.pathExtension.isEmpty ? "those" : ".\(url.pathExtension.lowercased())"
      throw ImportFileError.unsupportedType(name)
    }

    try Task.checkCancellation()

    // Bound the READ itself, rather than checking the size and then reading
    // separately (code review r3). Between a stat and a load the file can grow
    // or be replaced — by a sync client, by whatever wrote it — and the ceiling
    // would be bypassed on exactly the input it exists to refuse. Reading one
    // byte past the limit from a single open handle answers "is this too big"
    // and "give me the bytes" as one operation, so there is no window between
    // the question and the answer.
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw ImportFileError.unreadable
    }
    defer { try? handle.close() }

    guard
      let data = try? handle.read(upToCount: Self.maximumFileBytes + 1)
    else {
      throw ImportFileError.unreadable
    }
    guard data.count <= Self.maximumFileBytes else {
      throw ImportFileError.tooLarge
    }

    try Task.checkCancellation()

    let candidates = try parser.parse(data: data)
    guard candidates.count <= Self.maximumCandidates else {
      throw ImportFileError.tooManyWords(
        found: candidates.count, limit: Self.maximumCandidates)
    }

    return CustomWordsImportBatch(
      sourceID: parser.identifier,
      sourceDisplayName: parser.displayName,
      candidates: candidates
    )
  }
}
