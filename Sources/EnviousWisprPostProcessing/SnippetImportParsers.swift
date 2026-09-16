import EnviousWisprCore
import Foundation
import UniformTypeIdentifiers

/// Why pasted text or a chosen file could not become snippet candidates (#2997).
package enum SnippetImportSourceError: LocalizedError, Sendable, Equatable {
  case unreadable
  case unsupportedType(String)
  case tooLarge
  case malformedCSV(line: Int)
  case exportedSnippets(SnippetsTransferError)

  package var errorDescription: String? {
    switch self {
    case .unreadable:
      return "That couldn't be read."
    case .tooLarge:
      return "That is too big to be a snippet list. Check you picked the right one."
    case .unsupportedType(let name):
      // The extension comes off a user's file name, so it is sanitised like any other
      // imported text before it is rendered into a sentence.
      return
        "EnviousWispr can't read \(CustomWordsImportValidationError.describe(name)) files yet. "
        + "Try the EnviousWispr Snippets.json you exported, a CSV, or a plain list."
    case .malformedCSV(let line):
      return "That CSV has a quoting problem on line \(line). Nothing was imported."
    case .exportedSnippets(let underlying):
      return underlying.errorDescription
    }
  }
}

// MARK: - Line list

/// One snippet per line: the trigger, a separator, the text (#2997).
///
/// The approved design's grammar, ported from its prototype: `=`, a tab, `->`, `=>`, `→`, a
/// comma, or a colon. EXPLICIT separators are tried first so `signature = Hello, world`
/// keeps its comma; the bare comma and the colon are last resorts. A line with no separator
/// or an empty side is skipped and COUNTED, never guessed at. A blank line is nothing at all.
package enum SnippetLineListParser {
  package struct Result: Sendable, Equatable {
    package let candidates: [SnippetImportCandidate]
    package let skippedLines: Int
  }

  /// The explicit separators, all tried before a quoted pair, the comma and the colon; the
  /// earliest one in the line wins.
  static let explicitSeparators = ["\t", "=>", "->", "\u{2192}", "="]

  /// Lines by any line break: LF, CR, or CRLF as ONE break. `Character.isNewline` sees CRLF
  /// as a single grapheme, which a split on `"\n"` alone does not.
  static func lines(_ text: String) -> [Substring] {
    text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
  }

  /// True when a line is a header: the left side is exactly `name`, `snippet` or `trigger`
  /// and the right side contains `text` or `expansion` (plan §3.2). Checked on the first
  /// non-blank line only.
  static func isHeader(_ line: String) -> Bool {
    guard let split = splitOnFirstSeparator(line) else { return false }
    let left = strippingOneQuotePair(split.0.trimmingCharacters(in: .whitespaces)).lowercased()
    let right = strippingOneQuotePair(split.1.trimmingCharacters(in: .whitespaces)).lowercased()
    return ["trigger", "name", "snippet"].contains(left)
      && (right.contains("text") || right.contains("expansion"))
  }

  /// Matching pairs of surrounding quotes. ONE pair is removed, and only when both ends
  /// match: `""hello""` becomes `"hello"`, and `'hello` keeps its apostrophe. The same pairs
  /// open a QUOTED TRIGGER (`closingQuote(ofLeadingFieldIn:)`).
  static let quotePairs: [(Character, Character)] = [
    ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
  ]

  static func strippingOneQuotePair(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last else { return value }
    guard quotePairs.contains(where: { $0.0 == first && $0.1 == last }) else { return value }
    return String(value.dropFirst().dropLast())
  }

  /// The closing quote of a field that starts at the line's first character with ANY of the
  /// supported opening quotes (`"`, `'`, `\u{201C}`, `\u{2018}`), matched by its own closer,
  /// with a doubled closer inside the field skipped (the same walk the sniff does for `"`).
  /// Nil when the line does not start with a quote or the quote is never closed.
  static func closingQuote(ofLeadingFieldIn line: String) -> String.Index? {
    guard let first = line.first,
      let closer = quotePairs.first(where: { $0.0 == first })?.1
    else { return nil }
    var tail = line.dropFirst()
    while let close = tail.firstIndex(of: closer) {
      let afterClose = line.index(after: close)
      if afterClose < line.endIndex, line[afterClose] == closer {
        tail = line[line.index(after: afterClose)...]
        continue
      }
      return close
    }
    return nil
  }

  /// The joiners a line may use, in the order a bare (unquoted) trigger tries them: the
  /// explicit ones first (earliest in the line wins, longest on a tie), then a comma, then a
  /// colon not followed by `//`. A QUOTED trigger is different in kind: its separator is
  /// whatever follows the closing quote, and nothing inside the quotes is searched, so
  /// `"sig": "Use x = y"` is `sig` / `Use x = y` and `"a","b"` is `a` / `b`. The two shapes
  /// are the whole grammar; a line is one or the other by its first character.
  private static func splitOnFirstSeparator(_ line: String) -> (String, String)? {
    if let close = closingQuote(ofLeadingFieldIn: line) {
      let rest = line[line.index(after: close)...]
      let after = rest.drop(while: { $0 == " " })
      let left = String(line[...close])
      for separator in explicitSeparators.sorted(by: { $0.count > $1.count })
      where after.hasPrefix(separator) {
        return (left, String(after.dropFirst(separator.count)))
      }
      if after.hasPrefix(",") { return (left, String(after.dropFirst())) }
      if after.hasPrefix(":"), !after.hasPrefix("://") { return (left, String(after.dropFirst())) }
      // A quoted trigger with no joiner after it: fall through to the bare search, so a
      // line like `"quoted words" and more = x` still reads by its explicit separator.
    }
    let ranges = explicitSeparators.compactMap { line.range(of: $0) }
    if let range = ranges.min(by: {
      $0.lowerBound == $1.lowerBound
        ? $0.upperBound > $1.upperBound : $0.lowerBound < $1.lowerBound
    }) {
      return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }
    if let comma = line.firstIndex(of: ",") {
      return (String(line[..<comma]), String(line[line.index(after: comma)...]))
    }
    // The first colon NOT followed by `//`, so `https://example.com: homepage` splits at the
    // second colon rather than being skipped.
    var searchFrom = line.startIndex
    while let colon = line[searchFrom...].firstIndex(of: ":") {
      let next = line[line.index(after: colon)...]
      if !next.hasPrefix("//") {
        return (String(line[..<colon]), String(next))
      }
      searchFrom = line.index(after: colon)
    }
    return nil
  }

  /// Stops one past `limit` so "too many" is knowable without parsing the rest.
  package static func parse(_ text: String, limit: Int) throws -> Result {
    var candidates: [SnippetImportCandidate] = []
    var skipped = 0
    var sawFirstLine = false
    for rawLine in lines(text) {
      // Per line, so dismissing the sheet mid-parse stops the work (plan §3.2).
      try Task.checkCancellation()
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      if !sawFirstLine {
        sawFirstLine = true
        if isHeader(line) { continue }
      }
      guard let (rawLeft, rawRight) = splitOnFirstSeparator(line) else {
        skipped += 1
        continue
      }
      let trigger = strippingOneQuotePair(rawLeft.trimmingCharacters(in: .whitespaces))
      // `\n` typed as two characters means a line break in the text.
      let expansion = strippingOneQuotePair(rawRight.trimmingCharacters(in: .whitespaces))
        .replacingOccurrences(of: "\\n", with: "\n")
      guard !trigger.isEmpty, !expansion.isEmpty else {
        skipped += 1
        continue
      }
      candidates.append(SnippetImportCandidate(trigger: trigger, expansion: expansion))
      if candidates.count > limit {
        throw SnippetImportValidationError.tooManySnippets(limit: limit)
      }
    }
    return Result(candidates: candidates, skippedLines: skipped)
  }
}

// MARK: - CSV

/// RFC 4180 with two columns that matter: trigger, expansion (#2997).
///
/// A field may be quoted with `"`; a quoted field may contain commas, doubled quotes, and
/// line breaks, which is the only way a multi-line expansion travels through a spreadsheet.
/// Records end at CR, LF or CRLF outside quotes. A four-state machine over scalars, no regex
/// (`code-design-rules.md` RULE: parse-structured-input-dont-regex-and-iterate).
///
/// Two departures from a strict reading, each deliberate: a `"` INSIDE an unquoted field is
/// kept literally (a hand-written `5" screen` has one honest reading, and no spreadsheet
/// writes that shape), while text after a CLOSING quote is refused (`"hello"x` has two
/// readings, and guessing would store one of them).
package enum SnippetCSVParser {
  package typealias Result = SnippetLineListParser.Result

  private enum State { case fieldStart, unquoted, quoted, quoteInQuoted }

  /// Feeds every record to `onRecord` as it completes, so a caller can stop early. The second
  /// argument is true when the record was written EXPLICITLY (a quote or a comma appeared),
  /// which is what tells `""` or `,` apart from a physically blank line once the fields are
  /// decoded to the same empty strings. Throws `malformedCSV` naming the line the record
  /// started on for an unterminated quote at EOF or for text after a closing quote.
  static func scan(_ text: String, onRecord: ([String], _ explicit: Bool) throws -> Void) throws
  {
    var record: [String] = []
    var field = ""
    var explicit = false
    var state = State.fieldStart
    var line = 1
    var recordStartLine = 1
    var scalars = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = scalars.next()

    func endField() {
      record.append(field)
      field = ""
    }
    func endRecord() throws {
      endField()
      let finished = record
      let wasExplicit = explicit
      record = []
      explicit = false
      // Every caller has already advanced `line` past the terminator it consumed.
      recordStartLine = line
      try onRecord(finished, wasExplicit)
    }
    /// Consumes the LF of a CRLF so the pair counts as one break.
    func consumeLFAfterCR() {
      if pending == "\n" { pending = scalars.next() }
    }

    var scanned = 0
    while let c = pending {
      pending = scalars.next()
      scanned += 1
      if scanned.isMultiple(of: 4_096) { try Task.checkCancellation() }
      switch state {
      case .fieldStart, .unquoted:
        if c == "\"" && state == .fieldStart {
          explicit = true
          state = .quoted
        } else if c == "," {
          explicit = true
          endField()
          state = .fieldStart
        } else if c == "\r" {
          consumeLFAfterCR()
          line += 1
          try endRecord()
          state = .fieldStart
        } else if c == "\n" {
          line += 1
          try endRecord()
          state = .fieldStart
        } else {
          field.unicodeScalars.append(c)
          state = .unquoted
        }
      case .quoted:
        if c == "\"" {
          state = .quoteInQuoted
        } else {
          // Line breaks inside a quoted field are content, kept byte for byte, and still
          // counted so a later error names the right line. CRLF is one line.
          field.unicodeScalars.append(c)
          if c == "\r" {
            line += 1
            if pending == "\n" {
              field.unicodeScalars.append("\n")
              pending = scalars.next()
            }
          } else if c == "\n" {
            line += 1
          }
        }
      case .quoteInQuoted:
        if c == "\"" {
          field.unicodeScalars.append("\"")
          state = .quoted
        } else if c == "," {
          endField()
          state = .fieldStart
        } else if c == "\r" {
          consumeLFAfterCR()
          line += 1
          try endRecord()
          state = .fieldStart
        } else if c == "\n" {
          line += 1
          try endRecord()
          state = .fieldStart
        } else {
          throw SnippetImportSourceError.malformedCSV(line: recordStartLine)
        }
      }
    }
    if state == .quoted { throw SnippetImportSourceError.malformedCSV(line: recordStartLine) }
    // A final terminator has already ended the last record; anything else still open is one.
    if state != .fieldStart || !record.isEmpty || !field.isEmpty || explicit {
      try endRecord()
    }
  }

  /// Every record, materialised. For the sniff and for tests; `parse` streams instead.
  static func records(_ text: String) throws -> [[String]] {
    var records: [[String]] = []
    try scan(text) { fields, _ in records.append(fields) }
    return records
  }

  /// A header record: the first column is exactly `trigger`, `name` or `snippet` and the
  /// second exactly `expansion` or `text` (plan §3.2).
  static func isHeader(_ record: [String]) -> Bool {
    guard record.count >= 2 else { return false }
    let left = record[0].trimmingCharacters(in: .whitespaces).lowercased()
    let right = record[1].trimmingCharacters(in: .whitespaces).lowercased()
    return ["trigger", "name", "snippet"].contains(left)
      && ["expansion", "text"].contains(right)
  }

  /// True for a physical blank line, which is nothing at all. A record written explicitly
  /// (`,`, `""`, `"   "`) is a real record with nothing in it, and is COUNTED.
  private static func isBlankLine(_ record: [String], explicit: Bool) -> Bool {
    !explicit && record.count == 1 && record[0].trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Streams records into candidates and stops one past `limit`, so an oversized file is
  /// refused without every record being built first.
  package static func parse(_ text: String, limit: Int) throws -> Result {
    var candidates: [SnippetImportCandidate] = []
    var skipped = 0
    var first = true
    try scan(text) { record, explicit in
      try Task.checkCancellation()
      if isBlankLine(record, explicit: explicit) { return }
      if first {
        first = false
        if isHeader(record) { return }
      }
      let trigger = record.count > 0 ? record[0].trimmingCharacters(in: .whitespaces) : ""
      let expansion = record.count > 1 ? record[1] : ""
      guard !trigger.isEmpty, !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        skipped += 1
        return
      }
      candidates.append(SnippetImportCandidate(trigger: trigger, expansion: expansion))
      if candidates.count > limit {
        throw SnippetImportValidationError.tooManySnippets(limit: limit)
      }
    }
    return Result(candidates: candidates, skippedLines: skipped)
  }
}

// MARK: - Paste

/// How a paste should be read. `auto` sniffs; the user can override when the sniff reports
/// the text as ambiguous (a line carrying both a comma and an explicit separator).
package enum SnippetPasteFormat: String, Sendable, Equatable, CaseIterable {
  case auto
  case list
  case csv
}

package enum SnippetPasteSniff: Sendable, Equatable {
  case transferDocument
  case csv
  case list
  /// No header, no quoted field (leading, or right after a comma), and at least one line
  /// carries both a comma and an explicit separator, so CSV and the line grammar would read
  /// it differently. The paste screen shows "Read as: List | CSV"; `auto` resolves to `list`.
  case ambiguous

  /// True when the text after the leading quoted field's closing quote starts with an
  /// explicit separator or a colon: the LINE grammar's quoted trigger, not a CSV field.
  private static func leadingQuotedFieldIsAListSide(_ line: String) -> Bool {
    guard let close = SnippetLineListParser.closingQuote(ofLeadingFieldIn: line) else {
      return false
    }
    let suffix = line[line.index(after: close)...].drop(while: { $0 == " " })
    return (SnippetLineListParser.explicitSeparators + [":"]).contains { suffix.hasPrefix($0) }
  }

  /// True when a line carries a quoted field right after a comma with no explicit separator
  /// before it (`sig,"Best,` followed by more lines is a multi-line CSV expansion).
  private static func hasQuotedFieldAfterComma(_ line: String) -> Bool {
    guard let quotedComma = line.range(of: ",\"") else { return false }
    return !SnippetLineListParser.explicitSeparators.contains {
      guard let range = line.range(of: $0) else { return false }
      return range.lowerBound < quotedComma.lowerBound
    }
  }

  package static func sniff(_ text: String) -> SnippetPasteSniff {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // A brace that opens VALID JSON goes to the export decoder, whose messages then say
    // "not ours" or "damaged" truthfully. A brace that does not (`{date} = September 16`, a
    // list line whose trigger starts with a brace, which `SnippetText.normalize` strips) is
    // a list line, not a damaged export.
    if trimmed.hasPrefix("{"), SnippetsTransferDocument.isJSON(Data(trimmed.utf8)) {
      return .transferDocument
    }
    let lines = SnippetLineListParser.lines(trimmed).map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    guard let firstLine = lines.first(where: { !$0.isEmpty }) else { return .list }
    // A leading `"` followed, after its closing quote, by an explicit separator or a colon is
    // the LINE grammar's quoted trigger (`"my email" = "x@y"`), not CSV; a leading `"` followed
    // by anything else is a CSV field. The other quote pairs are never CSV quotes. EVERY
    // quote signal is read on EVERY line, never the first only: a headerless CSV whose
    // first row is unquoted and whose later row is `"say ""hi""",hello` or `sig,"Best,` then
    // more lines is still CSV. A quoted field right after a comma counts unless an explicit
    // separator comes before it on that line (`sig = Hello,"Sam"` is a list line whose text
    // holds a quote, and the ambiguity rule below offers the picker).
    if firstLine.hasPrefix("\""), leadingQuotedFieldIsAListSide(firstLine) { return .list }
    for line in lines where !line.isEmpty {
      if line.hasPrefix("\"") && !leadingQuotedFieldIsAListSide(line) { return .csv }
      if hasQuotedFieldAfterComma(line) { return .csv }
    }
    if let record = try? SnippetCSVParser.records(firstLine).first, SnippetCSVParser.isHeader(record) {
      return .csv
    }
    let ambiguous = lines.contains { line in
      line.contains(",")
        && SnippetLineListParser.explicitSeparators.contains(where: { line.contains($0) })
    }
    return ambiguous ? .ambiguous : .list
  }
}

/// Reads pasted text into a batch. Refuses an oversized paste BEFORE any parser or the live
/// counter sees it, so one enormous expansion cannot tie up the sheet.
package struct PasteSnippetsImportSource: SnippetImportSource {
  package let sourceID = "paste"
  private let text: String
  private let format: SnippetPasteFormat

  package init(text: String, format: SnippetPasteFormat = .auto) {
    self.text = text
    self.format = format
  }

  @concurrent package func loadRawCandidates() async throws -> SnippetImportBatch {
    try Self.parse(text: text, format: format)
  }

  /// The screen's live count and Continue share this one reading, so the count can never
  /// disagree with what Continue produces.
  package static func parse(text: String, format: SnippetPasteFormat) throws -> SnippetImportBatch {
    try preview(text: text, choice: format).batch
  }

  /// The grammar the text will be read with, given the sniff and the user's choice. The
  /// choice matters ONLY for an ambiguous paste (plan §3.2): for anything else the sniff
  /// decides, so a "Read as: CSV" picked for an earlier paste cannot silently override a
  /// later plain list or exported JSON once the picker has gone.
  package static func resolvedFormat(
    sniff: SnippetPasteSniff, choice: SnippetPasteFormat
  ) -> SnippetPasteFormat {
    guard sniff == .ambiguous else { return .auto }
    return choice == .csv ? .csv : .list
  }

  /// Bound, sniff, resolve, parse, in that order: the byte ceiling runs before the sniff
  /// touches the text, so an enormous paste never reaches a line split or a CSV scan.
  package static func preview(
    text: String, choice: SnippetPasteFormat
  ) throws -> (sniff: SnippetPasteSniff, batch: SnippetImportBatch) {
    guard text.utf8.count <= SnippetImportLimits.maximumImportFileBytes else {
      throw SnippetImportSourceError.tooLarge
    }
    let limit = SnippetImportLimits.maximumCandidates
    let sniff = SnippetPasteSniff.sniff(text)
    let resolved: SnippetPasteSniff
    switch resolvedFormat(sniff: sniff, choice: choice) {
    case .auto: resolved = sniff
    case .list: resolved = .list
    case .csv: resolved = .csv
    }
    // Validated here too, so the live count can never disagree with Continue: a trigger
    // nobody can say, or an expansion past its ceiling, is refused where it can still be
    // edited rather than on the terminal failure screen.
    let batch = try parse(text: text, as: resolved, limit: limit).validated()
    return (sniff, batch)
  }

  private static func parse(
    text: String, as resolved: SnippetPasteSniff, limit: Int
  ) throws -> SnippetImportBatch {
    switch resolved {
    case .transferDocument:
      let document: SnippetsTransferDocument
      do {
        document = try SnippetsTransferDocument(data: Data(text.utf8))
      } catch let error as SnippetsTransferError {
        throw SnippetImportSourceError.exportedSnippets(error)
      }
      return SnippetImportBatch(
        sourceID: "paste", sourceDisplayName: "Pasted export",
        candidates: document.candidatesForImport())
    case .csv:
      let result = try SnippetCSVParser.parse(text, limit: limit)
      return SnippetImportBatch(
        sourceID: "paste", sourceDisplayName: "Pasted CSV",
        candidates: result.candidates,
        notices: result.skippedLines > 0 ? [.linesSkipped(count: result.skippedLines)] : [])
    case .list, .ambiguous:
      let result = try SnippetLineListParser.parse(text, limit: limit)
      return SnippetImportBatch(
        sourceID: "paste", sourceDisplayName: "Pasted list",
        candidates: result.candidates,
        notices: result.skippedLines > 0 ? [.linesSkipped(count: result.skippedLines)] : [])
    }
  }
}

// MARK: - File

/// One file format the picker can read; dispatch is by EXACT extension, as for words.
package enum SnippetImportFileKind: String, Sendable, CaseIterable {
  case exportedSnippets = "file_json"
  case csv = "file_csv"
  case plainList = "file_text"

  package var fileExtensions: [String] {
    switch self {
    case .exportedSnippets: return ["json"]
    case .csv: return ["csv"]
    case .plainList: return ["txt", "text", "md", "list"]
    }
  }

  package var displayName: String {
    switch self {
    case .exportedSnippets: return "EnviousWispr snippets file"
    case .csv: return "CSV file"
    case .plainList: return "Plain list"
    }
  }

  package var maximumBytes: Int {
    switch self {
    case .exportedSnippets: return SnippetImportLimits.maximumExportedFileBytes
    case .csv, .plainList: return SnippetImportLimits.maximumImportFileBytes
    }
  }
}

/// Chooses a kind for a file, and tells the open panel what to enable.
package struct SnippetImportFileRegistry: Sendable {
  package static let v1 = SnippetImportFileRegistry()

  package init() {}

  package func kind(for url: URL) -> SnippetImportFileKind? {
    let ext = url.pathExtension.lowercased()
    guard !ext.isEmpty else { return nil }
    return SnippetImportFileKind.allCases.first { $0.fileExtensions.contains(ext) }
  }

  package var acceptedContentTypes: [UTType] {
    var seen = Set<UTType>()
    return SnippetImportFileKind.allCases
      .flatMap(\.fileExtensions)
      .compactMap { UTType(filenameExtension: $0) }
      .filter { seen.insert($0).inserted }
  }
}

/// Reads a user-chosen file and turns it into a batch.
package struct SnippetFileImportSource: SnippetImportSource {
  private let url: URL
  private let registry: SnippetImportFileRegistry

  package init(url: URL, registry: SnippetImportFileRegistry = .v1) {
    self.url = url
    self.registry = registry
  }

  package var sourceID: String { registry.kind(for: url)?.rawValue ?? "file_other" }

  /// `@concurrent` so reading and parsing always leave the caller's actor (the import model
  /// is `@MainActor`; a network-mounted file would otherwise freeze the settings window).
  @concurrent package func loadRawCandidates() async throws -> SnippetImportBatch {
    guard let kind = registry.kind(for: url) else {
      let name = url.pathExtension.isEmpty ? "those" : ".\(url.pathExtension.lowercased())"
      throw SnippetImportSourceError.unsupportedType(name)
    }
    try Task.checkCancellation()

    let data: Data
    do {
      data = try BoundedFileRead.read(at: url, ceiling: kind.maximumBytes)
    } catch is BoundedFileRead.Failure {
      throw SnippetImportSourceError.unreadable
    }
    guard data.count <= kind.maximumBytes else { throw SnippetImportSourceError.tooLarge }
    try Task.checkCancellation()

    let limit = SnippetImportLimits.maximumCandidates
    switch kind {
    case .exportedSnippets:
      let document: SnippetsTransferDocument
      do {
        document = try SnippetsTransferDocument(data: data)
      } catch let error as SnippetsTransferError {
        throw SnippetImportSourceError.exportedSnippets(error)
      }
      return SnippetImportBatch(
        sourceID: kind.rawValue, sourceDisplayName: kind.displayName,
        candidates: document.candidatesForImport())
    case .csv, .plainList:
      // The same decoder the words path uses: UTF-8, or UTF-16/UTF-8 with a byte-order
      // mark; anything else is refused rather than guessed at.
      guard let text = PlainTextImportFileParser.decode(data) else {
        throw SnippetImportSourceError.unreadable
      }
      let result =
        kind == .csv
        ? try SnippetCSVParser.parse(text, limit: limit)
        : try SnippetLineListParser.parse(text, limit: limit)
      return SnippetImportBatch(
        sourceID: kind.rawValue, sourceDisplayName: kind.displayName,
        candidates: result.candidates,
        notices: result.skippedLines > 0 ? [.linesSkipped(count: result.skippedLines)] : [])
    }
  }
}

extension SnippetsTransferDocument {
  /// The file's snippets as review candidates, with fresh review ids; the file's `id`s are
  /// never reused, so importing the same export twice cannot collide on identity.
  package func candidatesForImport() -> [SnippetImportCandidate] {
    snippets.map { SnippetImportCandidate(trigger: $0.trigger, expansion: $0.expansion) }
  }
}
