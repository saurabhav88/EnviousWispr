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
  /// How many words this format may carry, or nil for "as many as the file
  /// size allows".
  ///
  /// The ceiling exists to bound UNTRUSTED input — a pasted or hand-made list
  /// of unknown provenance. It is a property of the format, not of importing
  /// in general, which is why it lives here rather than at the one call site.
  var maximumCandidates: Int? { get }
  /// How many BYTES a file of this format may be.
  ///
  /// Same reasoning as the word ceiling, and it has to move with it: capping
  /// the words but not the bytes left the identical round-trip hole one layer
  /// down, since the byte check runs BEFORE the parser is consulted.
  var maximumBytes: Int { get }
  func parse(data: Data) throws -> [CustomWordsImportCandidate]
}

extension ImportFileParser {
  /// Formats default to the shared ceilings; a format opts out deliberately.
  package var maximumCandidates: Int? { CustomWordsImportLimits.maximumCandidates }
  package var maximumBytes: Int { CustomWordsImportLimits.maximumImportFileBytes }
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

  /// No word ceiling, because this file is the user's OWN library coming home.
  ///
  /// Nothing caps how many words a library may accumulate — contacts import
  /// and hand-added terms both grow it freely — so the shared ceiling made the
  /// app able to WRITE a file it would then refuse to read, advising the user
  /// to split a JSON file by hand (cloud review, #1683). An export you cannot
  /// import is not an export.
  ///
  /// The byte ceiling moves with it, for the same reason: capping the words
  /// but not the bytes left the identical hole one layer down, since the size
  /// check runs BEFORE the parser is consulted (cloud review, #1683). Fixing
  /// the word count alone was a fix to the instance, not to the rule.
  ///
  /// Still bounded, just far above any real library: a words file this large
  /// would hold over a million terms, so a mistakenly chosen disk image is
  /// still refused rather than read into memory.
  package let maximumCandidates: Int? = nil
  package let maximumBytes = CustomWordsImportLimits.maximumExportedFileBytes

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
    guard let text = Self.decode(data) else { throw ImportFileError.unreadable }
    return PasteWordsParser.parse(text).map {
      CustomWordsImportCandidate(canonical: $0)
    }
  }

  /// Turns file bytes into text, or refuses.
  ///
  /// Only two things are trusted: a byte-order mark, which NAMES its encoding,
  /// and UTF-8, which fails loudly when the bytes are not UTF-8. Everything
  /// else is a guess, and four review rounds were spent learning that guesses
  /// here corrupt data quietly (cloud reviews, #1683):
  ///
  ///  - Latin-1 cannot fail, so as a fallback it is a catch-all that turned
  ///    UTF-16 into `ÿþK\0u\0…` and imported it as words.
  ///  - Trying each encoding and keeping what "looks like text" picks the
  ///    WRONG one confidently: `Beyoncé\nJalapeño` read as UTF-16 decodes to
  ///    敂潹据૩慊慬数濱 — real letters, no symbols.
  ///  - Inferring byte order from where the NUL bytes fall is not proof
  ///    either: UTF-16LE `一` is `00 4E`, indistinguishable from big-endian
  ///    `N`.
  ///
  /// That last one is not a bug to fix, it is the shape of the problem: with
  /// no mark, BOTH byte orders decode to something for ANY even-length input,
  /// so no evidence in the bytes can settle it. So unmarked UTF-16 is refused
  /// rather than guessed at. Real UTF-16 writers emit a mark — that is what it
  /// is for — and refusing a file beats silently importing the wrong word.
  ///
  /// Latin-1 survives as the last resort for genuinely legacy lists, but must
  /// look like WORDS rather than merely printable characters, which is what
  /// stops un-recognised encodings from landing there as `qg¬N`.
  static func decode(_ data: Data) -> String? {
    if let marked = decodeUsingByteOrderMark(data), isPlausiblyText(marked) {
      return strippingBOM(marked)
    }
    if let utf8 = String(data: data, encoding: .utf8), isPlausiblyText(utf8) {
      return strippingBOM(utf8)
    }
    guard let latin1 = String(data: data, encoding: .isoLatin1),
      looksLikeWords(latin1)
    else { return nil }
    return strippingBOM(latin1)
  }

  private static func decodeUsingByteOrderMark(_ data: Data) -> String? {
    let bom = Array(data.prefix(3))
    if bom.starts(with: [0xFF, 0xFE]) {
      return String(data: data, encoding: .utf16LittleEndian).map(strippingBOM)
    }
    if bom.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16BigEndian).map(strippingBOM)
    }
    if bom.starts(with: [0xEF, 0xBB, 0xBF]) {
      return String(data: data, encoding: .utf8).map(strippingBOM)
    }
    return nil
  }

  /// Whether text read through the catch-all encoding is plausibly a WORD
  /// LIST, rather than some other encoding misread as Latin-1.
  ///
  /// Non-ASCII characters must be letters, marks, or digits — the things words
  /// are made of. Symbols are the tell: UTF-16 misread as Latin-1 produces
  /// runs like `qg¬N`, where `¬` is a maths symbol no one puts in a
  /// vocabulary entry, while a real Latin-1 list (`Beyoncé`, `Jalapeño`)
  /// contains only accented letters. ASCII passes freely so `C++` and `.NET`
  /// are unaffected.
  ///
  /// This is a REFUSAL, not a repair: a single CJK word saved as UTF-16 with
  /// no byte-order mark and no line break is genuinely ambiguous — the same
  /// bytes are a valid Latin-1 list — and the wrong guess would corrupt real
  /// data either way. Refusing says so honestly instead of importing nonsense.
  /// (Multi-word CJK lists are unaffected: the line breaks supply the NUL
  /// bytes the detector above reads.)
  private static func looksLikeWords(_ text: String) -> Bool {
    guard !text.isEmpty, isPlausiblyText(text) else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
      if scalar.isASCII { return true }
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
        .otherLetter, .nonspacingMark, .spacingMark, .decimalNumber, .otherNumber:
        return true
      default:
        return false
      }
    }
  }

  /// The mark itself is metadata, not a character the user typed. Left in, it
  /// rides along on the first word and imports as a different term than the
  /// same word further down the file.
  private static func strippingBOM(_ text: String) -> String {
    text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
  }

  /// Real word lists do not contain NULs or stray control characters. This is
  /// what stops ANY decode step from laundering binary — or text in an
  /// encoding we guessed wrong — into candidates. It is the single check that
  /// makes trying several encodings safe: a wrong guess fails it and the next
  /// encoding gets its turn, rather than the first lucky decode winning.
  private static func isPlausiblyText(_ text: String) -> Bool {
    !text.unicodeScalars.contains { scalar in
      guard scalar.value < 0x20 || scalar.value == 0x7F else { return false }
      return scalar != "\n" && scalar != "\r" && scalar != "\t"
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
    //
    // Reviewed twice (r4, r5) as "UTType returns a dynamic dyn.* type here, so
    // every .json and .txt upload is rejected; 19 tests fail." Not reproduced
    // in either environment: a direct probe resolves json → public.json and
    // txt → public.plain-text, both non-dynamic and both matching, and the
    // 19-test suite passes under BOTH scripts/xcode-test.sh and swift test.
    // Left as-is deliberately rather than trading verified behaviour for an
    // unverified claim. If some future environment genuinely yields dynamic
    // types, the fix is an explicit extension→parser mapping here, keeping the
    // CSV/TSV refusal intact.
    return parsers.first { $0.contentTypes.contains(type) }
  }
}

/// Reads a user-chosen file and turns it into a batch.
package struct FileImportSource: CustomWordsImportSource {
  /// Refuse before allocating. A word list is small; anything of this size is
  /// a mistaken selection (a video, a database, a disk image), and reading it
  /// into memory to discover that is the expensive way to find out.
  package static var maximumFileBytes: Int { CustomWordsImportLimits.maximumImportFileBytes }
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

    // Loop until EOF or one byte past the ceiling (code review r4). A single
    // `read(upToCount:)` may return FEWER bytes without having reached the end
    // — routine for network-mounted and cloud-backed files — which would have
    // silently imported a truncated prefix of the user's list and could also
    // miss that the file exceeds the limit. Accumulating until the file says
    // it is done makes "how much is there" a fact rather than a guess.
    var data = Data()
    let ceiling = parser.maximumBytes + 1
    while data.count < ceiling {
      try Task.checkCancellation()
      // `read(upToCount:)` signals EOF with NIL, and a genuine failure by
      // throwing. Collapsing those two with `try?` turned every successful
      // read-to-completion into "unreadable" — caught immediately by the
      // existing tests, which is what they are for.
      let chunk: Data?
      do {
        chunk = try handle.read(upToCount: ceiling - data.count)
      } catch {
        throw ImportFileError.unreadable
      }
      guard let chunk, !chunk.isEmpty else { break }  // EOF
      data.append(chunk)
    }
    guard data.count <= parser.maximumBytes else {
      throw ImportFileError.tooLarge
    }

    try Task.checkCancellation()

    let candidates = try parser.parse(data: data)
    if let ceiling = parser.maximumCandidates, candidates.count > ceiling {
      throw ImportFileError.tooManyWords(found: candidates.count, limit: ceiling)
    }

    return CustomWordsImportBatch(
      sourceID: parser.identifier,
      sourceDisplayName: parser.displayName,
      candidates: candidates
    )
  }
}
