import Foundation
import Testing

@testable import EnviousWisprCore

/// #2450: the Help Center article `spoken-punctuation-and-emoji` is the only list of spoken punctuation
/// commands a user can read, since the app no longer carries a phrase table. This suite binds that
/// article's command tables to what the engine really accepts.
///
/// **Drift Guard.** When it fails the article tells a user to say a phrase that does nothing, or leaves
/// out one that works. The non-English side reads the rules from `SpokenPunctuationRules`, the
/// authority the cleanup pass itself reads. The English side reads literals written here, taken from
/// `SpokenPunctuationToggleTests`, because the English table is a private regex and has no list to read.
///
/// The article is read from THIS checkout (`RepoRoot`), and the Markdown is parsed under an explicit
/// contract: one heading per section, exactly one table under it, a fixed header, two cells in every
/// row. A missing section, an empty table, a second table, a malformed row or a duplicate row is a
/// failure, never a row that quietly disappears. Nothing is normalised: a wrong accent, a wrong case
/// or a wrong mark fails.
@Suite("Spoken punctuation help article parity (#2450)", .tags(.driftGuard))
struct SpokenPunctuationHelpArticleParityTests {

  // MARK: - The parser contract

  /// One data row of a command table, after the label in the second cell is turned into the text the
  /// engine writes.
  struct Row: Equatable, Comparable {
    let say: String
    let result: String
    static func < (lhs: Row, rhs: Row) -> Bool {
      (lhs.say, lhs.result) < (rhs.say, rhs.result)
    }
  }

  enum ContractError: Error, Equatable, CustomStringConvertible {
    case headingMissing(String)
    case headingRepeated(String)
    case noTable(String)
    case moreThanOneTable(String)
    case badHeader(String)
    case badSeparator(String)
    case malformedRow(String, line: String)
    case emptyTable(String)
    case duplicateRow(String, say: String)
    case unknownLabel(String, label: String)

    var description: String {
      switch self {
      case .headingMissing(let h): return "heading missing: \(h)"
      case .headingRepeated(let h): return "heading appears more than once: \(h)"
      case .noTable(let h): return "no table under \(h)"
      case .moreThanOneTable(let h): return "more than one table under \(h)"
      case .badHeader(let h): return "table header under \(h) is not '| Say this | You get |'"
      case .badSeparator(let h): return "table separator under \(h) is not '|---|---|'"
      case .malformedRow(let h, let line): return "malformed row under \(h): \(line)"
      case .emptyTable(let h): return "table under \(h) has no data rows"
      case .duplicateRow(let h, let say): return "duplicate row under \(h): \(say)"
      case .unknownLabel(let h, let label): return "unknown result label under \(h): \(label)"
      }
    }
  }

  /// What the second column says for a line or paragraph break. The article uses words, because a
  /// real line break cannot sit in a table cell; this is the one place a label becomes text.
  static let breakLabels: [String: String] = [
    "a line break": "\n",
    "a blank line": "\n\n",
  ]

  /// Parse the one table under `heading` (an exact line such as `#### German`). The section ends at the
  /// next heading of the same or a higher level. A backslash result is written as a single `\` in the
  /// article, and Markdown renders it as one backslash, so a cell of one backslash is that mark.
  static func parseTable(markdown: String, heading: String) throws -> [Row] {
    let lines = markdown.components(separatedBy: "\n")
    let matches = lines.indices.filter { lines[$0] == heading }
    guard let start = matches.first else { throw ContractError.headingMissing(heading) }
    guard matches.count == 1 else { throw ContractError.headingRepeated(heading) }

    let level = heading.prefix(while: { $0 == "#" }).count
    var section: [String] = []
    for line in lines[(start + 1)...] {
      let hashes = line.prefix(while: { $0 == "#" }).count
      if hashes > 0, hashes <= level, line.dropFirst(hashes).hasPrefix(" ") { break }
      section.append(line)
    }

    // Group consecutive lines that start with a pipe into tables.
    var tables: [[String]] = []
    var current: [String] = []
    for line in section {
      if line.contains("|") {
        current.append(line)
      } else if current.isEmpty == false {
        tables.append(current)
        current = []
      }
    }
    if current.isEmpty == false { tables.append(current) }

    guard let table = tables.first else { throw ContractError.noTable(heading) }
    guard tables.count == 1 else { throw ContractError.moreThanOneTable(heading) }
    guard table[0] == "| Say this | You get |" else { throw ContractError.badHeader(heading) }
    guard table.count >= 2, table[1] == "|---|---|" else {
      throw ContractError.badSeparator(heading)
    }
    let body = table.dropFirst(2)
    guard body.isEmpty == false else { throw ContractError.emptyTable(heading) }

    var rows: [Row] = []
    var seen = Set<String>()
    for line in body {
      guard line.hasPrefix("| "), line.hasSuffix(" |") else {
        throw ContractError.malformedRow(heading, line: line)
      }
      let inner = String(line.dropFirst(2).dropLast(2))
      let cells = inner.components(separatedBy: " | ")
      guard cells.count == 2, cells.allSatisfy({ $0.isEmpty == false }) else {
        throw ContractError.malformedRow(heading, line: line)
      }
      let say = cells[0]
      let label = cells[1]
      // A mark is one character. Anything longer must be a break label, so a typo in a label is a
      // failure here and not a mark the comparison below would have to explain.
      if label.count > 1, breakLabels[label] == nil {
        throw ContractError.unknownLabel(heading, label: label)
      }
      let result = breakLabels[label] ?? label
      guard seen.insert(say).inserted else {
        throw ContractError.duplicateRow(heading, say: say)
      }
      rows.append(Row(say: say, result: result))
    }
    return rows
  }

  // MARK: - The article

  private static let articlePath = "website/src/content/help/spoken-punctuation-and-emoji.md"

  private static func article() throws -> String {
    let url = RepoRoot.url.appending(path: articlePath)
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The English commands the setting gates, written here from `SpokenPunctuationToggleTests`'
  /// literals (the engine's table is a private regex). The two-word "back slash" alias is accepted by
  /// the engine but is not displayed, so it is not a row. Line and paragraph breaks are written as the
  /// text they insert, apart from the labels the article uses.
  private static let englishExpected: [Row] =
    SpokenPunctuationToggleTests.gatedTriggers
    .filter { $0.spoken != "back slash" }
    .map { Row(say: $0.spoken, result: $0.mark) }
    + [
      Row(say: "new line", result: "\n"),
      Row(say: "new paragraph", result: "\n\n"),
    ]

  @Test("The English table lists exactly the English commands, once each")
  func englishTable() throws {
    #expect(Self.englishExpected.count == 11, "the English expectation itself drifted")
    let rows = try Self.parseTable(
      markdown: Self.article(), heading: "### Dictate a comma, full stop or new line")
    #expect(rows.sorted() == Self.englishExpected.sorted())
  }

  /// Heading, language code and the language's own name, in the order the article lists them.
  private static let languages: [(heading: String, code: String)] = [
    ("#### German", "de"), ("#### French", "fr"), ("#### Spanish", "es"), ("#### Italian", "it"),
  ]

  /// Every form of every command, each behind the default start word, with the text it inserts. This
  /// is the full population the cleanup pass accepts for a language, so a form missing from the
  /// article, a form the article invents, a wrong start word and a wrong mark all differ from it.
  private static func expectedRows(for code: String) throws -> [Row] {
    let rules = try #require(SpokenPunctuationRules.rules(for: code))
    let start = try #require(SpokenPunctuationRules.defaultStartWord(for: code))
    return rules.flatMap { rule in
      rule.spokenForms.map { Row(say: start + " " + $0, result: rule.replacement) }
    }
  }

  @Test("Each non-English table lists every command form behind its default start word, once")
  func nonEnglishTables() throws {
    let markdown = try Self.article()
    for (heading, code) in Self.languages {
      let rows = try Self.parseTable(markdown: markdown, heading: heading)
      let expected = try Self.expectedRows(for: code)
      let missing = Set(expected.map(\.say)).subtracting(rows.map(\.say)).sorted()
      let extra = Set(rows.map(\.say)).subtracting(expected.map(\.say)).sorted()
      #expect(missing.isEmpty, "\(heading): missing \(missing)")
      #expect(extra.isEmpty, "\(heading): not accepted by the engine \(extra)")
      #expect(rows.sorted() == expected.sorted(), "\(heading): a row says the wrong thing")
      #expect(
        rows.count == expected.count, "\(heading): \(rows.count) rows, expected \(expected.count)")
    }
  }

  @Test("The default start words in the article are the shipped ones")
  func defaultsAreNamed() throws {
    let markdown = try Self.article()
    for (_, code) in Self.languages {
      let start = try #require(SpokenPunctuationRules.defaultStartWord(for: code))
      #expect(markdown.contains("**\(start)**"), "the article does not name the default \(start)")
    }
  }

  @Test("The four language sections appear once each and in the listed order")
  func sectionOrder() throws {
    let lines = try Self.article().components(separatedBy: "\n")
    let positions = Self.languages.map { entry in lines.firstIndex(of: entry.heading) }
    #expect(positions.allSatisfy { $0 != nil })
    #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
  }

  @Test("The article uses the app's own label and the real Settings location")
  func labelsMatchTheApp() throws {
    let markdown = try Self.article()
    #expect(markdown.contains("Convert spoken punctuation") == false)
    #expect(markdown.contains("**Spoken punctuation**"))
    #expect(markdown.contains("**Dictation Settings** > **Engine**"))
    #expect(markdown.contains("> **Transcription**") == false)
    #expect(markdown.contains("\u{2014}") == false && markdown.contains("\u{2013}") == false)
  }

  // MARK: - The parser cannot pass vacuously

  private static func table(_ rows: [String], header: String = "| Say this | You get |") -> String {
    (["#### Test", "", header, "|---|---|"] + rows).joined(separator: "\n") + "\n"
  }

  @Test("A well-formed table parses, with a break label turned into its text")
  func parserAcceptsAGoodTable() throws {
    let rows = try Self.parseTable(
      markdown: Self.table(["| Setze Punkt | . |", "| Setze neue Zeile | a line break |"]),
      heading: "#### Test")
    #expect(
      rows == [Row(say: "Setze Punkt", result: "."), Row(say: "Setze neue Zeile", result: "\n")])
  }

  @Test("A missing heading, a repeated heading, no table and an empty table all fail")
  func parserRejectsStructure() {
    #expect(throws: ContractError.headingMissing("#### Nope")) {
      try Self.parseTable(markdown: Self.table(["| a b | . |"]), heading: "#### Nope")
    }
    #expect(throws: ContractError.headingRepeated("#### Test")) {
      try Self.parseTable(
        markdown: Self.table(["| a b | . |"]) + "\n#### Test\n", heading: "#### Test")
    }
    #expect(throws: ContractError.noTable("#### Test")) {
      try Self.parseTable(markdown: "#### Test\n\nJust prose.\n", heading: "#### Test")
    }
    #expect(throws: ContractError.emptyTable("#### Test")) {
      try Self.parseTable(markdown: Self.table([]), heading: "#### Test")
    }
  }

  @Test("A label that is neither a mark nor a known break label fails")
  func parserRejectsAnUnknownLabel() {
    #expect(throws: ContractError.unknownLabel("#### Test", label: "a line brek")) {
      try Self.parseTable(markdown: Self.table(["| a b | a line brek |"]), heading: "#### Test")
    }
  }

  @Test("A second table, a changed header, a malformed row and a duplicate row all fail")
  func parserRejectsRows() {
    #expect(throws: ContractError.moreThanOneTable("#### Test")) {
      try Self.parseTable(
        markdown: Self.table(["| a b | . |"])
          + "\ntext\n\n| Say this | You get |\n|---|---|\n| c d | , |\n",
        heading: "#### Test")
    }
    #expect(throws: ContractError.badHeader("#### Test")) {
      try Self.parseTable(
        markdown: Self.table(["| a b | . |"], header: "| Say | Get |"), heading: "#### Test")
    }
    #expect(throws: ContractError.malformedRow("#### Test", line: "| only one cell |")) {
      try Self.parseTable(markdown: Self.table(["| only one cell |"]), heading: "#### Test")
    }
    #expect(throws: ContractError.malformedRow("#### Test", line: "| a b | . | extra |")) {
      try Self.parseTable(markdown: Self.table(["| a b | . | extra |"]), heading: "#### Test")
    }
    // A line the website renders as a row without a leading pipe must not slip past the parser.
    #expect(throws: ContractError.malformedRow("#### Test", line: "Setze extra | .")) {
      try Self.parseTable(
        markdown: Self.table(["| Setze Punkt | . |"]) + "Setze extra | .\n",
        heading: "#### Test")
    }
    #expect(throws: ContractError.duplicateRow("#### Test", say: "a b")) {
      try Self.parseTable(
        markdown: Self.table(["| a b | . |", "| a b | , |"]), heading: "#### Test")
    }
  }

  @Test("The section ends at the next heading, so a table below it is not counted")
  func parserStopsAtTheNextHeading() throws {
    let markdown =
      Self.table(["| a b | . |"])
      + "\n#### Next\n\n| Say this | You get |\n|---|---|\n| c d | , |\n"
    let rows = try Self.parseTable(markdown: markdown, heading: "#### Test")
    #expect(rows == [Row(say: "a b", result: ".")])
  }

  @Test("A wrong accent, a wrong case or a wrong mark is a difference, never normalised away")
  func comparisonIsExact() {
    let expected = [Row(say: "Insère point", result: ".")]
    #expect([Row(say: "Insere point", result: ".")] != expected)
    #expect([Row(say: "insère point", result: ".")] != expected)
    #expect([Row(say: "Insère point", result: ",")] != expected)
  }
}
