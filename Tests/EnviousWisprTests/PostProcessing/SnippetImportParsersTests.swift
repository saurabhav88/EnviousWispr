import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2997 — pasted text and chosen files becoming snippet candidates, and the contract every
/// source is validated through.
///
/// `.productOutcome`: when this fails a user sees a snippet missing from review, a trigger
/// or expansion mangled, a good file refused, or a bad one silently accepted.
@Suite("Snippet import parsers and contract (#2997)", .tags(.productOutcome))
struct SnippetImportParsersTests {

  private func pairs(_ result: SnippetLineListParser.Result) -> [(String, String)] {
    result.candidates.map { ($0.trigger, $0.expansion) }
  }

  private func expectPairs(
    _ actual: [SnippetImportCandidate], _ expected: [(String, String)],
    _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.count == expected.count, comment, sourceLocation: sourceLocation)
    for (candidate, pair) in zip(actual, expected) {
      #expect(candidate.trigger == pair.0, comment, sourceLocation: sourceLocation)
      #expect(candidate.expansion == pair.1, comment, sourceLocation: sourceLocation)
    }
  }

  // MARK: - Line list

  @Test("Every separator in the grammar splits a line into trigger and text")
  func lineListSeparators() throws {
    let text = """
      tab\tby tab
      arrow => by fat arrow
      thin -> by thin arrow
      unicode → by unicode arrow
      equals = by equals
      comma, by comma
      colon: by colon
      """
    let result = try SnippetLineListParser.parse(text, limit: 100)
    expectPairs(
      result.candidates,
      [
        ("tab", "by tab"), ("arrow", "by fat arrow"), ("thin", "by thin arrow"),
        ("unicode", "by unicode arrow"), ("equals", "by equals"), ("comma", "by comma"),
        ("colon", "by colon"),
      ])
    #expect(result.skippedLines == 0)
  }

  @Test("An explicit separator wins over a comma, so the text keeps its comma")
  func explicitSeparatorBeatsComma() throws {
    let result = try SnippetLineListParser.parse("signature = Hello, world", limit: 10)
    expectPairs(result.candidates, [("signature", "Hello, world")])
  }

  @Test("A URL's colon is not a separator; the next colon is; a bare URL line is counted")
  func urlColonIsNotASeparator() throws {
    let result = try SnippetLineListParser.parse(
      "site: https://example.com\nhttps://example.com: homepage\nhttps://example.com",
      limit: 10)
    expectPairs(
      result.candidates, [("site", "https://example.com"), ("https://example.com", "homepage")])
    #expect(result.skippedLines == 1)
  }

  @Test("Windows and classic Mac line endings split lines like LF does")
  func lineListLineEndings() throws {
    let result = try SnippetLineListParser.parse("a = 1\r\nb = 2\rc = 3\n", limit: 10)
    expectPairs(result.candidates, [("a", "1"), ("b", "2"), ("c", "3")])
    #expect(result.skippedLines == 0)
  }

  @Test("Quotes around either side are stripped; a quoted CSV pair on one line splits")
  func quotedSides() throws {
    let text = """
      "my email" = "hello@example.com"
      "sig","Best, Saurabh"
      'single' -> 'quoted'
      """
    let result = try SnippetLineListParser.parse(text, limit: 10)
    expectPairs(
      result.candidates,
      [
        ("my email", "hello@example.com"), ("sig", "Best, Saurabh"), ("single", "quoted"),
      ])
  }

  @Test("Exactly one pair of matching quotes is removed; an unmatched quote stays")
  func oneQuotePairOnly() throws {
    let text = "a = \"\"hello\"\"\nb = 'hello\nc = \"mixed'\nd = \u{201C}curly\u{201D}"
    let result = try SnippetLineListParser.parse(text, limit: 10)
    expectPairs(
      result.candidates,
      [("a", "\"hello\""), ("b", "'hello"), ("c", "\"mixed'"), ("d", "curly")])
  }

  @Test("A typed backslash-n in the text becomes a line break")
  func backslashNEscape() throws {
    let result = try SnippetLineListParser.parse("sig = Best,\\nSaurabh", limit: 10)
    expectPairs(result.candidates, [("sig", "Best,\nSaurabh")])
  }

  @Test("A header on the first line is skipped; the same shape later is a snippet")
  func headerSkippedOnlyOnFirstLine() throws {
    let text = """
      Trigger, Expansion
      sig = hi
      trigger = expansion
      """
    let result = try SnippetLineListParser.parse(text, limit: 10)
    expectPairs(result.candidates, [("sig", "hi"), ("trigger", "expansion")])
    #expect(result.skippedLines == 0)
  }

  @Test("Only the named header words count: 'name = the expansion text' is a header, 'keyword = value' is a snippet")
  func headerWordsAreExact() throws {
    let header = try SnippetLineListParser.parse("name = the expansion text\nsig = hi", limit: 10)
    expectPairs(header.candidates, [("sig", "hi")])
    let notHeader = try SnippetLineListParser.parse("keyword = value\nsig = hi", limit: 10)
    expectPairs(notHeader.candidates, [("keyword", "value"), ("sig", "hi")])
  }

  @Test("Blank lines are ignored; lines without a separator or with an empty side are counted")
  func blankAndSeparatorlessLines() throws {
    let text = """

      sig = hi

      no separator on this line
      = missing trigger
      missing text =

      """
    let result = try SnippetLineListParser.parse(text, limit: 10)
    expectPairs(result.candidates, [("sig", "hi")])
    #expect(result.skippedLines == 3)
  }

  @Test("Parsing stops one past the limit and names it")
  func lineListLimitStop() throws {
    let text = "a = 1\nb = 2\nc = 3"
    #expect(throws: SnippetImportValidationError.tooManySnippets(limit: 2)) {
      try SnippetLineListParser.parse(text, limit: 2)
    }
    let within = try SnippetLineListParser.parse(text, limit: 3)
    #expect(within.candidates.count == 3)
  }

  // MARK: - CSV

  @Test("A quoted field keeps its comma; a doubled quote is one quote")
  func csvQuotedCommaAndDoubledQuote() throws {
    let text = "\"sig\",\"Hello, world\"\n\"quote\",\"He said \"\"hi\"\"\""
    let result = try SnippetCSVParser.parse(text, limit: 10)
    expectPairs(result.candidates, [("sig", "Hello, world"), ("quote", "He said \"hi\"")])
  }

  @Test("A quoted field carries a line break into the text, untouched")
  func csvEmbeddedNewline() throws {
    let text = "sig,\"Best,\nSaurabh\"\nnext,after"
    let result = try SnippetCSVParser.parse(text, limit: 10)
    expectPairs(result.candidates, [("sig", "Best,\nSaurabh"), ("next", "after")])
  }

  @Test("CRLF and CR line endings end records like LF does")
  func csvLineEndings() throws {
    let result = try SnippetCSVParser.parse("a,1\r\nb,2\rc,3\n", limit: 10)
    expectPairs(result.candidates, [("a", "1"), ("b", "2"), ("c", "3")])
  }

  @Test("A header record is skipped; extra columns are ignored; short records are counted")
  func csvHeaderExtraColumnsAndShortRecords() throws {
    let text = """
      trigger,expansion,notes
      sig,hi,ignored
      only a trigger
      ,only text
      """
    let result = try SnippetCSVParser.parse(text, limit: 10)
    expectPairs(result.candidates, [("sig", "hi")])
    #expect(result.skippedLines == 2)
  }

  @Test("An unclosed quote is refused, naming the line the record started on")
  func csvUnterminatedQuote() throws {
    let text = "a,b\n\"sig,text\nmore"
    #expect(throws: SnippetImportSourceError.malformedCSV(line: 2)) {
      try SnippetCSVParser.parse(text, limit: 10)
    }
  }

  @Test("CSV stops one past the limit, before reading the rest of the file")
  func csvLimitStop() throws {
    #expect(throws: SnippetImportValidationError.tooManySnippets(limit: 1)) {
      try SnippetCSVParser.parse("a,1\nb,2", limit: 1)
    }
    // Damaged text AFTER the limit is never reached: the limit is the error, not the quote.
    #expect(throws: SnippetImportValidationError.tooManySnippets(limit: 1)) {
      try SnippetCSVParser.parse("a,1\nb,2\n\"oops", limit: 1)
    }
  }

  @Test("A quote inside an unquoted field is literal; text after a closing quote is refused")
  func csvStrayQuotes() throws {
    let literal = try SnippetCSVParser.parse("sig,5\" screen", limit: 10)
    expectPairs(literal.candidates, [("sig", "5\" screen")])
    #expect(throws: SnippetImportSourceError.malformedCSV(line: 1)) {
      try SnippetCSVParser.parse("sig,\"hello\"x", limit: 10)
    }
  }

  @Test("Line breaks inside a quoted field are counted, so a later error names the right line")
  func csvErrorLineAfterEmbeddedBreaks() throws {
    #expect(throws: SnippetImportSourceError.malformedCSV(line: 3)) {
      try SnippetCSVParser.parse("a,\"x\ry\"\rc,\"oops", limit: 10)
    }
    #expect(throws: SnippetImportSourceError.malformedCSV(line: 3)) {
      try SnippetCSVParser.parse("a,\"x\r\ny\"\r\nc,\"oops", limit: 10)
    }
    let kept = try SnippetCSVParser.parse("a,\"x\r\ny\"", limit: 10)
    expectPairs(kept.candidates, [("a", "x\r\ny")])
  }

  @Test("A blank line is nothing; a record written as a comma or an empty quoted field is counted")
  func csvBlankLineVersusEmptyRecord() throws {
    let comma = try SnippetCSVParser.parse("a,1\n,\n\nb,2\n", limit: 10)
    expectPairs(comma.candidates, [("a", "1"), ("b", "2")])
    #expect(comma.skippedLines == 1)
    let quoted = try SnippetCSVParser.parse("a,1\n\"\"\nb,2\n\"   \"", limit: 10)
    expectPairs(quoted.candidates, [("a", "1"), ("b", "2")])
    #expect(quoted.skippedLines == 2)
    let spaces = try SnippetCSVParser.parse("a,1\n   \nb,2", limit: 10)
    #expect(spaces.skippedLines == 0)
  }

  @Test("Whitespace inside a CSV text field is preserved exactly")
  func csvPreservesExpansionWhitespace() throws {
    let result = try SnippetCSVParser.parse("sig,\"  two spaces  \"", limit: 10)
    expectPairs(result.candidates, [("sig", "  two spaces  ")])
  }

  // MARK: - Paste sniff

  @Test("The sniff picks JSON for a brace, CSV for a header or a quote, list otherwise")
  func pasteSniff() {
    #expect(SnippetPasteSniff.sniff("  {\"snippets\": []}") == .transferDocument)
    #expect(SnippetPasteSniff.sniff("trigger,expansion\na,b") == .csv)
    #expect(SnippetPasteSniff.sniff("\"a\",\"b\"") == .csv)
    #expect(SnippetPasteSniff.sniff("a = b\nc -> d") == .list)
    #expect(SnippetPasteSniff.sniff("a, b\nc, d") == .list)
    #expect(SnippetPasteSniff.sniff("") == .list)
  }

  @Test("The picker appears only when one line carries both a comma and an explicit separator")
  func ambiguityNeedsBothOnOneLine() {
    #expect(SnippetPasteSniff.sniff("a = b\nc, d") == .list)
    #expect(SnippetPasteSniff.sniff("sig,Hello=world") == .ambiguous)
    #expect(SnippetPasteSniff.sniff("sig\tHello, world") == .ambiguous)
    // A header or a quoted field settles it as CSV before ambiguity is considered.
    #expect(SnippetPasteSniff.sniff("trigger,expansion\nsig,Hello=world") == .csv)
  }

  @Test("Headerless comma text is read as a list by default, and differently as CSV")
  func headerlessCommaTextIsLineListNotCSV() throws {
    let text = "sig,Hello=world"
    let auto = try PasteSnippetsImportSource.parse(text: text, format: .auto)
    expectPairs(auto.candidates, [("sig,Hello", "world")], "auto resolves to list")
    let list = try PasteSnippetsImportSource.parse(text: text, format: .list)
    expectPairs(list.candidates, [("sig,Hello", "world")])
    let csv = try PasteSnippetsImportSource.parse(text: text, format: .csv)
    expectPairs(csv.candidates, [("sig", "Hello=world")])
  }

  @Test("A pasted export reads through the transfer document with fresh review ids")
  func pastedExportUsesTransferDocument() throws {
    let snippet = Snippet(trigger: "my email", expansion: "hello@example.com")
    let document = SnippetsTransferDocument(
      version: SnippetsManager.currentVersion, keyword: "backslash", snippets: [snippet])
    let encoder = JSONEncoder()
    let text = String(decoding: try encoder.encode(document), as: UTF8.self)
    let batch = try PasteSnippetsImportSource.parse(text: text, format: .auto)
    expectPairs(batch.candidates, [("my email", "hello@example.com")])
    #expect(batch.candidates[0].id != snippet.id)
    #expect(batch.sourceID == "paste")
  }

  @Test("Pasted JSON that is not ours is refused with the transfer document's reason")
  func pastedForeignJSONRefused() {
    #expect(
      throws: SnippetImportSourceError.exportedSnippets(.notAnEnviousWisprSnippetsFile)
    ) {
      try PasteSnippetsImportSource.parse(text: "{\"words\": []}", format: .auto)
    }
  }

  @Test("Skipped lines travel as a count beside the candidates")
  func pasteNoticesCarryCounts() throws {
    let batch = try PasteSnippetsImportSource.parse(text: "a = 1\nnothing here", format: .auto)
    #expect(batch.candidates.count == 1)
    #expect(batch.notices == [.linesSkipped(count: 1)])
    let clean = try PasteSnippetsImportSource.parse(text: "a = 1", format: .auto)
    #expect(clean.notices.isEmpty)
  }

  @Test("An oversized paste is refused before any parser sees it")
  func oversizedPasteRefusedBeforeParsing() {
    // Enough "a=b" lines to exceed the candidate limit many times over, so a parser that
    // ran would throw `tooManySnippets`; `tooLarge` proves the byte bound ran first.
    let line = "a=b\n"
    let count = SnippetImportLimits.maximumImportFileBytes / line.utf8.count + 1
    let text = String(repeating: line, count: count)
    #expect(text.utf8.count > SnippetImportLimits.maximumImportFileBytes)
    #expect(count > SnippetImportLimits.maximumCandidates)
    #expect(throws: SnippetImportSourceError.tooLarge) {
      try PasteSnippetsImportSource.parse(text: text, format: .auto)
    }
  }

  // MARK: - Contract

  private func batch(_ candidates: [SnippetImportCandidate]) -> SnippetImportBatch {
    SnippetImportBatch(sourceID: "test", sourceDisplayName: "Test", candidates: candidates)
  }

  @Test("Validation trims the trigger and leaves the text exactly as delivered")
  func validationTrimsTriggerOnly() throws {
    let validated = try batch([
      SnippetImportCandidate(trigger: "  sig \n", expansion: "  Best,\nSaurabh\n")
    ]).validated()
    expectPairs(validated.candidates, [("sig", "  Best,\nSaurabh\n")])
  }

  @Test("A trigger with a control character is refused, and the message names it safely")
  func controlCharacterInTriggerRefused() throws {
    let candidate = SnippetImportCandidate(trigger: "sig\u{0007}", expansion: "hi")
    let error = try #require(throws: SnippetImportValidationError.self) {
      try batch([candidate]).validated()
    }
    #expect(error == .unusableTrigger(trigger: "sig\u{0007}"))
    let message = try #require(error.errorDescription)
    #expect(message.contains("U+0007"))
    #expect(!message.unicodeScalars.contains("\u{0007}"))
  }

  @Test("A trigger nobody can say (punctuation only) is refused")
  func punctuationOnlyTriggerRefused() {
    #expect(throws: SnippetImportValidationError.unusableTrigger(trigger: "!!!")) {
      try batch([SnippetImportCandidate(trigger: "!!!", expansion: "hi")]).validated()
    }
  }

  @Test("A trigger cannot contain a line break; the text can")
  func lineBreakAllowedInExpansionNotTrigger() throws {
    #expect(throws: SnippetImportValidationError.unusableTrigger(trigger: "my\nsig")) {
      try batch([SnippetImportCandidate(trigger: "my\nsig", expansion: "hi")]).validated()
    }
    let ok = try batch([SnippetImportCandidate(trigger: "sig", expansion: "one\ntwo\tthree")])
      .validated()
    #expect(ok.candidates[0].expansion == "one\ntwo\tthree")
  }

  @Test("Text carrying a bidi override or a paragraph separator is refused")
  func invisibleScalarsInExpansionRefused() {
    for bad in ["Best\u{202E}Saurabh", "Best\u{2029}Saurabh"] {
      #expect(throws: SnippetImportValidationError.unusableExpansion(trigger: "sig")) {
        try batch([SnippetImportCandidate(trigger: "sig", expansion: bad)]).validated()
      }
    }
  }

  @Test("Validation is all or nothing: one bad row refuses the batch")
  func validationIsAllOrNothing() {
    let rows = [
      SnippetImportCandidate(trigger: "good", expansion: "fine"),
      SnippetImportCandidate(trigger: "", expansion: "no trigger"),
    ]
    #expect(throws: SnippetImportValidationError.unusableTrigger(trigger: "")) {
      try batch(rows).validated()
    }
  }

  @Test("Each ceiling refuses exactly one past its limit")
  func ceilings() throws {
    let tooMany = (0...SnippetImportLimits.maximumCandidates).map {
      SnippetImportCandidate(trigger: "t\($0)", expansion: "x")
    }
    #expect(
      throws: SnippetImportValidationError.tooManySnippets(
        limit: SnippetImportLimits.maximumCandidates)
    ) { try batch(tooMany).validated() }

    let longTrigger = String(
      repeating: "a", count: SnippetImportLimits.maximumTriggerScalars + 1)
    #expect(
      throws: SnippetImportValidationError.triggerTooLong(
        limit: SnippetImportLimits.maximumTriggerScalars)
    ) { try batch([SnippetImportCandidate(trigger: longTrigger, expansion: "x")]).validated() }
    let maxTrigger = String(repeating: "a", count: SnippetImportLimits.maximumTriggerScalars)
    #expect(
      try batch([SnippetImportCandidate(trigger: maxTrigger, expansion: "x")]).validated()
        .candidates.count == 1)

    let longExpansion = String(
      repeating: "a", count: SnippetImportLimits.maximumExpansionScalars + 1)
    #expect(
      throws: SnippetImportValidationError.expansionTooLong(
        trigger: "sig", limit: SnippetImportLimits.maximumExpansionScalars)
    ) {
      try batch([SnippetImportCandidate(trigger: "sig", expansion: longExpansion)]).validated()
    }

    // Under every per-entry ceiling and the count ceiling, over the total.
    let maxExpansion = String(repeating: "a", count: SnippetImportLimits.maximumExpansionScalars)
    let perEntry = maxExpansion.unicodeScalars.count + 2
    let entries = SnippetImportLimits.maximumStoredScalars / perEntry + 1
    #expect(entries < SnippetImportLimits.maximumCandidates)
    let tooMuch = (0..<entries).map {
      SnippetImportCandidate(trigger: String(format: "%02d", $0 % 100), expansion: maxExpansion)
    }
    #expect(
      throws: SnippetImportValidationError.tooMuchText(
        limit: SnippetImportLimits.maximumStoredScalars)
    ) { try batch(tooMuch).validated() }
  }

  @Test("The total-text ceiling is exact, and counts the trimmed trigger")
  func totalTextCeilingIsExactOnStoredForm() throws {
    let limit = SnippetImportLimits.maximumStoredScalars
    let expansionLength = SnippetImportLimits.maximumExpansionScalars
    let entries = limit / (expansionLength + 1)  // trigger of 1 scalar + expansion
    let remainder = limit - entries * (expansionLength + 1)
    #expect(entries < SnippetImportLimits.maximumCandidates)
    #expect(remainder >= 2)
    let expansion = String(repeating: "a", count: expansionLength)
    var rows = (0..<entries).map { index in
      // Padding around the trigger is NOT stored, so it must not count toward the ceiling.
      SnippetImportCandidate(trigger: "   \(Character(UnicodeScalar(0x4E00 + index)!))   ", expansion: expansion)
    }
    rows.append(
      SnippetImportCandidate(trigger: "z", expansion: String(repeating: "b", count: remainder - 1)))
    let exact = try batch(rows).validated()
    #expect(exact.candidates.count == entries + 1)
    #expect(exact.candidates.reduce(0) { $0 + $1.trigger.unicodeScalars.count + $1.expansion.unicodeScalars.count } == limit)

    rows[rows.count - 1] = SnippetImportCandidate(
      trigger: "z", expansion: String(repeating: "b", count: remainder))
    #expect(throws: SnippetImportValidationError.tooMuchText(limit: limit)) {
      try batch(rows).validated()
    }
  }

  @Test("Loading a source always validates: a bad paste never reaches review")
  func loadCandidatesValidates() async {
    let source = PasteSnippetsImportSource(text: "!!! = unspeakable")
    await #expect(throws: SnippetImportValidationError.unusableTrigger(trigger: "!!!")) {
      try await source.loadCandidates()
    }
  }

  // MARK: - File

  private func temporaryFile(_ name: String, _ bytes: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnippetImportParsersTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
  }

  @Test("The registry dispatches by extension and names the source per kind")
  func fileRegistry() {
    let registry = SnippetImportFileRegistry.v1
    #expect(registry.kind(for: URL(fileURLWithPath: "/x/Snippets.JSON")) == .exportedSnippets)
    #expect(registry.kind(for: URL(fileURLWithPath: "/x/list.csv")) == .csv)
    #expect(registry.kind(for: URL(fileURLWithPath: "/x/list.txt")) == .plainList)
    #expect(registry.kind(for: URL(fileURLWithPath: "/x/list.md")) == .plainList)
    #expect(registry.kind(for: URL(fileURLWithPath: "/x/list.numbers")) == nil)
    #expect(registry.kind(for: URL(fileURLWithPath: "/x/list")) == nil)
    #expect(SnippetFileImportSource(url: URL(fileURLWithPath: "/x/a.json")).sourceID == "file_json")
    #expect(SnippetFileImportSource(url: URL(fileURLWithPath: "/x/a.csv")).sourceID == "file_csv")
    #expect(SnippetFileImportSource(url: URL(fileURLWithPath: "/x/a.txt")).sourceID == "file_text")
    #expect(SnippetFileImportSource(url: URL(fileURLWithPath: "/x/a.xyz")).sourceID == "file_other")
    let accepted = registry.acceptedContentTypes.map { $0.identifier }
    #expect(accepted.contains("public.json"))
    #expect(accepted.contains("public.comma-separated-values-text"))
    #expect(accepted.contains("public.plain-text"))
  }

  @Test("A plain list file, a CSV file and an exported file each read through their parser")
  func fileKindsRead() async throws {
    let list = try temporaryFile("list.txt", Data("sig = hi\nemail -> a@b.c\n".utf8))
    let listBatch = try await SnippetFileImportSource(url: list).loadCandidates()
    expectPairs(listBatch.candidates, [("sig", "hi"), ("email", "a@b.c")])
    #expect(listBatch.sourceID == "file_text")

    let csv = try temporaryFile("list.csv", Data("trigger,expansion\nsig,\"Hi, there\"\n".utf8))
    let csvBatch = try await SnippetFileImportSource(url: csv).loadCandidates()
    expectPairs(csvBatch.candidates, [("sig", "Hi, there")])
    #expect(csvBatch.sourceID == "file_csv")

    let snippet = Snippet(trigger: "my email", expansion: "hello@example.com")
    let document = SnippetsTransferDocument(
      version: SnippetsManager.currentVersion, keyword: "backslash", snippets: [snippet])
    let json = try temporaryFile("EnviousWispr Snippets.json", try JSONEncoder().encode(document))
    let jsonBatch = try await SnippetFileImportSource(url: json).loadCandidates()
    expectPairs(jsonBatch.candidates, [("my email", "hello@example.com")])
    #expect(jsonBatch.candidates[0].id != snippet.id)
    #expect(jsonBatch.sourceID == "file_json")
  }

  @Test("A UTF-16 file with a byte-order mark decodes like the words importer's does")
  func utf16FileDecodes() async throws {
    var bytes = Data([0xFF, 0xFE])
    bytes.append("sig = héllo\n".data(using: .utf16LittleEndian)!)
    let url = try temporaryFile("list.txt", bytes)
    let batch = try await SnippetFileImportSource(url: url).loadCandidates()
    expectPairs(batch.candidates, [("sig", "héllo")])
  }

  @Test("An unknown extension, a missing file and an oversized file are each refused by name")
  func fileRefusals() async throws {
    let unknown = try temporaryFile("list.numbers", Data("a=b".utf8))
    await #expect(throws: SnippetImportSourceError.unsupportedType(".numbers")) {
      try await SnippetFileImportSource(url: unknown).loadCandidates()
    }
    let bare = try temporaryFile("list", Data("a=b".utf8))
    await #expect(throws: SnippetImportSourceError.unsupportedType("those")) {
      try await SnippetFileImportSource(url: bare).loadCandidates()
    }
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).txt")
    await #expect(throws: SnippetImportSourceError.unreadable) {
      try await SnippetFileImportSource(url: missing).loadCandidates()
    }
    let big = try temporaryFile(
      "big.txt", Data(repeating: UInt8(ascii: "a"), count: SnippetImportLimits.maximumImportFileBytes + 1))
    await #expect(throws: SnippetImportSourceError.tooLarge) {
      try await SnippetFileImportSource(url: big).loadCandidates()
    }
    let exact = try temporaryFile(
      "exact.txt",
      Data("a=b\n".utf8)
        + Data(repeating: UInt8(ascii: "\n"), count: SnippetImportLimits.maximumImportFileBytes - 4))
    let batch = try await SnippetFileImportSource(url: exact).loadCandidates()
    #expect(batch.candidates.count == 1)
  }

  @Test("The unsupported-type message sanitises the extension it names")
  func unsupportedTypeMessageIsSanitised() throws {
    let plain = try #require(SnippetImportSourceError.unsupportedType(".numbers").errorDescription)
    #expect(plain.contains(".numbers"))
    let hostile = try #require(
      SnippetImportSourceError.unsupportedType(".num\u{0007}bers").errorDescription)
    #expect(hostile.contains("U+0007"))
    #expect(!hostile.unicodeScalars.contains("\u{0007}"))
  }

  @Test("A damaged export file is refused as damaged, not as too big or unreadable")
  func damagedExportFile() async throws {
    let url = try temporaryFile("Snippets.json", Data("{\"snippets\": 5}".utf8))
    await #expect(throws: SnippetImportSourceError.exportedSnippets(.malformed)) {
      try await SnippetFileImportSource(url: url).loadCandidates()
    }
  }
}
