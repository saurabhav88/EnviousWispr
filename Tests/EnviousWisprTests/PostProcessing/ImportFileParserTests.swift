import EnviousWisprCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import EnviousWisprPostProcessing

/// #1683 (PR-U1) — reading a chosen file into import candidates.
///
/// The failure paths carry most of the weight: a user who picks the wrong file
/// should be told which wrong thing they picked, not handed "damaged" for a
/// perfectly healthy document.
@MainActor
@Suite("ImportFileParser")
struct ImportFileParserTests {

  private func write(_ contents: Data, as name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-file-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url)
    return url
  }

  private func write(_ text: String, as name: String) throws -> URL {
    try write(Data(text.utf8), as: name)
  }

  // MARK: - Exported words file

  @Test("an exported words file brings back every portable field")
  func exportedWordsFileBringsBackEveryPortableField() async throws {
    let original = CustomWord(
      canonical: "Kubernetes", aliases: ["k8s"], category: .brand, priority: 3,
      forceReplace: true, caseSensitive: true, minSimilarityOverride: 0.8)
    let data = try CustomWordsTransferDocument(words: [original]).encoded()
    let url = try write(data, as: "words.json")

    let batch = try await FileImportSource(url: url).loadCandidates()
    let candidate = try #require(batch.candidates.first)

    #expect(batch.sourceID == "exported-words")
    #expect(candidate.canonical == "Kubernetes")
    // An exported file is the one source with real authority over every
    // field: it is the user's own data going out and coming back.
    #expect(candidate.aliases == .supplied(["k8s"]))
    #expect(candidate.category == .supplied(.brand))
    #expect(candidate.priority == .supplied(3))
    #expect(candidate.forceReplace == .supplied(true))
    #expect(candidate.caseSensitive == .supplied(true))
    #expect(candidate.minSimilarityOverride == .supplied(0.8))
  }

  @Test("a JSON file that isn't ours says so, rather than reading as damaged")
  func foreignJSONReportsItDidNotComeFromEnviousWispr() async throws {
    let url = try write(#"{"format":"com.example.other","version":1,"words":[]}"#, as: "other.json")
    await #expect(throws: ImportFileError.exportedWords(.notAnEnviousWisprBackup)) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a file from a newer version says to update, not that it is damaged")
  func futureFileReportsVersionRatherThanDamage() async throws {
    let url = try write(
      #"{"format":"com.enviouswispr.custom-words","version":99,"words":[]}"#,
      as: "future.json")
    await #expect(throws: ImportFileError.exportedWords(.unsupportedVersion(99))) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  // MARK: - Plain text

  @Test("a plain list becomes one candidate per word")
  func plainTextParsesOneCandidatePerWord() async throws {
    let url = try write("Kubernetes\nAnthropic\nQualtrics", as: "words.txt")
    let batch = try await FileImportSource(url: url).loadCandidates()

    #expect(batch.sourceID == "plain-text")
    #expect(batch.candidates.map { $0.canonical } == ["Kubernetes", "Anthropic", "Qualtrics"])
  }

  @Test("a file list splits exactly like the paste box does")
  func plainTextUsesTheSameRulesAsPaste() async throws {
    // One parser, not two. A word list is a word list whether it was typed or
    // saved to a file, and two implementations would eventually disagree about
    // what "Envious Labs" or "C++" means.
    let text = "Envious Labs, C++\nand/or\nSmith; Jones\nGitHub\ngithub"
    let url = try write(text, as: "words.txt")
    let batch = try await FileImportSource(url: url).loadCandidates()

    let viaPaste = try PasteWordsParser.parse(text)
    #expect(batch.candidates.map { $0.canonical } == viaPaste)
    #expect(
      batch.candidates.map { $0.canonical }
        == ["Envious Labs", "C++", "and/or", "Smith; Jones", "GitHub"])
  }

  @Test("a plain list claims no authority over any field")
  func plainTextLeavesEveryAuthorityFieldUnspecified() async throws {
    let url = try write("Kubernetes", as: "words.txt")
    let candidate = try #require(
      try await FileImportSource(url: url).loadCandidates().candidates.first)

    #expect(candidate.aliases == .unspecified)
    #expect(candidate.category == .unspecified)
    #expect(candidate.priority == .unspecified)
    #expect(candidate.forceReplace == .unspecified)
    #expect(candidate.caseSensitive == .unspecified)
    #expect(candidate.minSimilarityOverride == .unspecified)
  }

  @Test("an empty file yields nothing to import rather than an error")
  func emptyFileYieldsNoCandidates() async throws {
    let url = try write("   \n\n  ", as: "empty.txt")
    let batch = try await FileImportSource(url: url).loadCandidates()
    #expect(batch.candidates.isEmpty)
  }

  @Test("text in an unknowable encoding is refused rather than guessed at")
  func latin1TextIsRefused() async throws {
    // Superseded contract (#1683). This previously asserted that Latin-1 text
    // "still reads" — which sounds generous and was in fact the catch-all that
    // imported mojibake as words, since Latin-1 accepts every byte and can
    // never report failure. Refusing beats storing a wrong word.
    let url = try write(try #require("Beyoncé".data(using: .isoLatin1)), as: "legacy.txt")
    await #expect(throws: ImportFileError.unreadable) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  // MARK: - Unsupported and unreadable

  @Test("a spreadsheet is named as unsupported, with somewhere to go")
  func spreadsheetReportsUnsupportedType() async throws {
    let url = try write("a,b,c", as: "words.csv")
    await #expect(throws: ImportFileError.unsupportedType(".csv")) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a spreadsheet is never quietly read as a word list")
  func csvIsRefusedRatherThanMangledByThePlainTextParser() async throws {
    // The bug this freezes: CSV conforms to public.plain-text, so a
    // conformance-based match handed spreadsheets to the plain-text parser.
    // That parser splits on commas, so this single row would have imported
    // three "words" — the header included — silently corrupting the user's
    // dictionary. Refusing the file is the only honest outcome until a real
    // CSV parser is registered.
    let url = try write("canonical,alias,category\nGitHub,git hub,brand", as: "words.csv")

    await #expect(throws: ImportFileError.unsupportedType(".csv")) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a tab-separated file is refused for the same reason")
  func tsvIsAlsoRefused() async throws {
    let url = try write("canonical\talias\nGitHub\tgit hub", as: "words.tsv")
    await #expect(throws: ImportFileError.unsupportedType(".tsv")) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("an unreadable file reports as unreadable")
  func unreadableFileReportsUnreadable() async throws {
    let url = try write("Kubernetes", as: "words.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    await #expect(throws: ImportFileError.unreadable) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test(
    "healthy JSON that isn't ours reads as a different file, not a damaged one",
    arguments: ["[1,2,3]", "\"just a string\"", "42", "[]"])
  func nonObjectJSONReportsForeignRatherThanDamaged(payload: String) async throws {
    // A config file, an API dump, a list saved as JSON — all valid documents
    // that simply aren't ours. Calling them damaged sends the user hunting for
    // corruption that isn't there (review r2).
    let url = try write(payload, as: "other.json")
    await #expect(throws: ImportFileError.exportedWords(.notAnEnviousWisprBackup)) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a file claiming to be ours but broken still reads as damaged")
  func ourFormatWithBrokenPayloadStillReadsAsDamaged() async throws {
    let url = try write(
      #"{"format":"com.enviouswispr.custom-words","version":1,"words":"not-an-array"}"#,
      as: "broken.json")
    await #expect(throws: ImportFileError.exportedWords(.malformed)) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  // MARK: - Limits

  @Test("an absurdly large file is refused before it is read into memory")
  func oversizedFileIsRefusedBeforeReading() async throws {
    // Refusing by size beats discovering it after allocating: a word list is
    // small, so anything this big is a mistaken selection.
    let url = try write(Data(count: CustomWordsImportLimits.maximumImportFileBytes + 1), as: "huge.txt")
    await #expect(throws: ImportFileError.tooLarge) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a file with more words than the limit is refused with both numbers")
  func tooManyWordsIsRefusedWithCounts() async throws {
    let limit = FileImportSource.maximumCandidates
    let words = (0...limit).map { "word\($0)" }.joined(separator: "\n")
    let url = try write(words, as: "many.txt")

    await #expect(
      throws: ImportFileError.tooManyWords(found: limit + 1, limit: limit)
    ) {
      _ = try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a file exactly at the limit is accepted")
  func fileAtExactlyTheLimitIsAccepted() async throws {
    let limit = FileImportSource.maximumCandidates
    let words = (1...limit).map { "word\($0)" }.joined(separator: "\n")
    let url = try write(words, as: "atlimit.txt")

    let batch = try await FileImportSource(url: url).loadCandidates()
    #expect(batch.candidates.count == limit)
  }

  // MARK: - Registry

  @Test("the picker offers exactly what the registry can read")
  func acceptedContentTypesComeFromTheRegistry() {
    // One source of truth, so a format cannot be selectable but unreadable —
    // or readable but unselectable.
    let types = ImportFileRegistry.v1.acceptedContentTypes
    #expect(types.contains(.json))
    #expect(types.contains(.plainText))
    #expect(!types.contains(.commaSeparatedText))
  }

  @Test("registering a format is all it takes to make it readable")
  func registryDispatchesByFileType() throws {
    let json = try write("{}", as: "a.json")
    let text = try write("a", as: "a.txt")

    #expect(ImportFileRegistry.v1.parser(for: json)?.identifier == "exported-words")
    #expect(ImportFileRegistry.v1.parser(for: text)?.identifier == "plain-text")
    #expect(ImportFileRegistry.v1.parser(for: try write("a", as: "a.csv")) == nil)
  }

  // MARK: - Text encodings

  @Test("a UTF-16 file imports its real words, not mojibake")
  func utf16FileDecodesToRealWords() async throws {
    // Latin-1 accepts every byte, so before the BOM check this decoded to
    // "ÿþK\0u\0b\0…" and imported NUL-laden garbage as words.
    let data = "Kubernetes\nPostgreSQL".data(using: .utf16LittleEndian)!
    let withBOM = Data([0xFF, 0xFE]) + data
    let url = try write(withBOM, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes", "PostgreSQL"])
  }

  @Test("a big-endian UTF-16 file decodes too")
  func utf16BigEndianDecodes() async throws {
    let data = "Kubernetes".data(using: .utf16BigEndian)!
    let url = try write(Data([0xFE, 0xFF]) + data, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes"])
  }

  @Test("a UTF-8 byte-order mark is not imported as part of the first word")
  func utf8ByteOrderMarkIsStripped() async throws {
    // Left in, the mark rides along invisibly and "Kubernetes" imports as a
    // DIFFERENT term than the same word typed anywhere else.
    let url = try write(
      Data([0xEF, 0xBB, 0xBF]) + Data("Kubernetes".utf8), as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes"])
  }

  @Test("a legacy Latin-1 file is refused rather than guessed at")
  func latin1FileIsRefused() async throws {
    // Latin-1 CANNOT fail — every byte is valid — so as a fallback it is a
    // catch-all that renames "I could not read this" to a confident wrong
    // answer. A "looks like words" guard only narrowed which wrong answers
    // survived; Windows-1252 and mixed-encoding files still landed as
    // plausible mojibake. Supported set is now exactly UTF-8 and marked
    // UTF-16, and anything else is refused.
    let url = try write("Beyoncé\nJalapeño".data(using: .isoLatin1)!, as: "words.txt")

    await #expect(throws: ImportFileError.unreadable) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("the same words as UTF-8 import fine")
  func sameWordsAsUTF8Import() async throws {
    // The accented words themselves were never the problem — the ENCODING
    // was. Saved as UTF-8, which is what everything modern writes, they import.
    let url = try write("Beyoncé\nJalapeño", as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Beyoncé", "Jalapeño"])
  }
  @Test("binary content is refused rather than laundered into words")
  func binaryContentIsRefused() async throws {
    let url = try write(Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x7F]), as: "words.txt")

    await #expect(throws: ImportFileError.unreadable) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }


  @Test("word lists in other scripts import intact")
  func internationalWordListsImportIntact() async throws {
    // Japanese, Hindi, Arabic, Korean, Russian, Greek, accented Latin, and a
    // word with a combining mark. If any script silently dropped or mangled,
    // custom words would be an English-only feature (founder question).
    let words = [
      "東京", "こんにちは", "नमस्ते", "مرحبا", "서울",
      "Москва", "Αθήνα", "Beyoncé", "Ångström", "Jalapeño",
    ]
    let url = try write(words.joined(separator: "\n"), as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == words)
  }

  @Test("words in other scripts are matched, not duplicated, on re-import")
  func internationalWordsCompareAgainstExistingLibrary() async throws {
    // Import equality runs through the compare engine's normalize(). If that
    // were ASCII-only, a re-import would add a SECOND "東京" every time.
    let normalized = CustomWordsImportCompareEngine.normalize("東京")
    #expect(normalized == CustomWordsImportCompareEngine.normalize("東京"))
    #expect(!normalized.isEmpty)

    // Case folding must still work for scripts that HAVE case...
    #expect(
      CustomWordsImportCompareEngine.normalize("Москва")
        == CustomWordsImportCompareEngine.normalize("МОСКВА"))
    // ...and accents must stay meaningful: "resume" is not "résumé".
    #expect(
      CustomWordsImportCompareEngine.normalize("résumé")
        != CustomWordsImportCompareEngine.normalize("resume"))
  }


  @Test("a non-English custom word actually corrects a transcript")
  func nonEnglishCustomWordCorrectsTranscript() async throws {
    // Import is only half the promise. If correction is ASCII-only, an
    // imported Japanese or Russian term would sit in the list and never fire
    // (founder question: does this work internationally?).
    let corrector = WordCorrector()
    let words = [
      CustomWord(canonical: "東京", aliases: ["とうきょう"], category: .general),
      CustomWord(canonical: "Москва", aliases: ["москва"], category: .general),
      CustomWord(canonical: "Jalapeño", aliases: ["jalapeno"], category: .general),
    ]

    let (japanese, _) = corrector.correct("とうきょう に行きます", against: words)
    let (russian, _) = corrector.correct("я живу в москва", against: words)
    let (accented, _) = corrector.correct("I ate a jalapeno", against: words)

    #expect(japanese.contains("東京"))
    #expect(russian.contains("Москва"))
    #expect(accented.contains("Jalapeño"))
  }


  @Test("a single CJK word WITH a byte-order mark imports fine")
  func singleCJKWordWithMarkImports() async throws {
    // Which is why the mark matters, and why real UTF-16 writers emit one.
    let data = Data([0xFF, 0xFE]) + "東京".data(using: .utf16LittleEndian)!
    let url = try write(data, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["東京"])
  }


  @Test("a library larger than the paste ceiling still exports and imports back")
  func oversizedLibraryRoundTrips() async throws {
    // Nothing caps how many words a library accumulates, so the app could
    // WRITE a file it then refused to read — telling the user to split a JSON
    // file by hand. An export you cannot import is not an export.
    let words = (0..<(CustomWordsImportLimits.maximumCandidates + 500)).map {
      CustomWord(canonical: "Term\($0)", aliases: [], category: .general)
    }
    let url = try write(try CustomWordsTransferDocument(words: words).encoded(), as: "words.json")

    let batch = try await FileImportSource(url: url).loadCandidates()

    #expect(batch.candidates.count == words.count)
  }

  @Test("a pasted-style text list is still held to the ceiling")
  func plainTextListStillCapped() async throws {
    // The ceiling is not gone, it is scoped: untrusted input still has one.
    let many = (0..<(CustomWordsImportLimits.maximumCandidates + 1))
      .map { "Term\($0)" }.joined(separator: "\n")
    let url = try write(many, as: "words.txt")

    await #expect(
      throws: ImportFileError.tooManyWords(
        found: CustomWordsImportLimits.maximumCandidates + 1,
        limit: CustomWordsImportLimits.maximumCandidates)
    ) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }




  @Test("UTF-16 without a byte-order mark is refused, never guessed at")
  func unmarkedUTF16IsRefused() async throws {
    // With no mark, BOTH byte orders decode to something for any even-length
    // input, so nothing in the bytes can settle which was meant: UTF-16LE 一
    // is 00 4E, identical to big-endian N. Guessing here corrupted data in
    // four separate review rounds. Refusing is the honest answer.
    for data in [
      "Kubernetes\nPostgreSQL".data(using: .utf16LittleEndian)!,
      "Kubernetes".data(using: .utf16BigEndian)!,
      "東京\n大阪".data(using: .utf16LittleEndian)!,
      Data([0x00, 0x4E]),
    ] {
      let url = try write(data, as: "words.txt")
      await #expect(throws: ImportFileError.unreadable) {
        try await FileImportSource(url: url).loadCandidates()
      }
    }
  }

  @Test("UTF-16 WITH a byte-order mark imports, including CJK")
  func markedUTF16Imports() async throws {
    // Which is the whole point of the mark, and why real UTF-16 writers emit
    // one. The supported path stays supported.
    let cases: [(Data, [String])] = [
      (Data([0xFF, 0xFE]) + "Kubernetes\nPostgreSQL".data(using: .utf16LittleEndian)!,
        ["Kubernetes", "PostgreSQL"]),
      (Data([0xFE, 0xFF]) + "Kubernetes".data(using: .utf16BigEndian)!, ["Kubernetes"]),
      (Data([0xFF, 0xFE]) + "東京\n大阪".data(using: .utf16LittleEndian)!, ["東京", "大阪"]),
      (Data([0xFF, 0xFE]) + "一".data(using: .utf16LittleEndian)!, ["一"]),
    ]
    for (data, expected) in cases {
      let url = try write(data, as: "words.txt")
      let candidates = try await FileImportSource(url: url).loadCandidates().candidates
      #expect(candidates.map { $0.canonical } == expected)
    }
  }


  @Test("an exported words file larger than the untrusted byte cap still imports")
  func oversizedExportedFileStillImports() async throws {
    // Capping the WORDS but not the BYTES left the same round-trip hole one
    // layer down: the size check runs before the parser is consulted, so the
    // app could still write a words file it then refused as .tooLarge.
    // Padded via alias text so the file genuinely exceeds the untrusted cap.
    let filler = String(repeating: "x", count: 400)
    let words = (0..<40_000).map {
      CustomWord(canonical: "Term\($0)", aliases: ["\(filler)\($0)"], category: .general)
    }
    let data = try CustomWordsTransferDocument(words: words).encoded()
    #expect(data.count > CustomWordsImportLimits.maximumImportFileBytes)
    let url = try write(data, as: "words.json")

    let batch = try await FileImportSource(url: url).loadCandidates()

    #expect(batch.candidates.count == words.count)
  }

  @Test("an untrusted text file is still held to the smaller byte cap")
  func oversizedTextFileStillRefused() async throws {
    // The cap is scoped, not removed.
    let big = String(
      repeating: "Term\n", count: CustomWordsImportLimits.maximumImportFileBytes / 4)
    let url = try write(big, as: "words.txt")

    await #expect(throws: ImportFileError.tooLarge) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }


  @Test("invisible control characters never become part of a word")
  func controlCharactersAreRefused() async throws {
    // The old check hand-rolled a range (below U+0020 plus DEL) and so missed
    // the C1 block: bytes C2 85 are valid UTF-8 for U+0085, which nothing
    // downstream splits or strips, so it imported as an invisible character
    // inside a custom word. Asking Unicode's category covers every control in
    // every block without a range to keep in sync.
    for bytes in [
      Data([0x4B, 0xC2, 0x85, 0x75]),  // C1 NEL inside a word
      Data([0x4B, 0xC2, 0x9B, 0x75]),  // C1 CSI
      Data([0x4B, 0x00, 0x75]),  // C0 NUL
    ] {
      let url = try write(bytes, as: "words.txt")
      await #expect(throws: ImportFileError.unreadable) {
        try await FileImportSource(url: url).loadCandidates()
      }
    }
  }

  @Test("zero-width joiners survive, because real scripts need them")
  func zeroWidthJoinersSurvive() async throws {
    // Rejecting the whole format category would have been the easy fix and
    // would have broken Hindi, Persian, and emoji sequences — the exact
    // international lists this is meant to support.
    let url = try write("क्‍ष\nحرف‌ها", as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.count == 2)
    #expect(candidates[0].canonical.unicodeScalars.contains { $0.value == 0x200D })
    #expect(candidates[1].canonical.unicodeScalars.contains { $0.value == 0x200C })
  }


  @Test("invisible and deceptive format characters are refused")
  func deceptiveFormatCharactersAreRefused() async throws {
    // Allowing the whole format category to protect joiners also admitted
    // these. Nothing downstream strips them, so they would be saved INSIDE a
    // word: a mid-file byte-order mark is invisible, and a bidi override makes
    // a word render as something other than what it is.
    for text in [
      "Kub\u{FEFF}ernetes",  // mid-file byte-order mark
      "Kub\u{202E}ernetes",  // right-to-left override
      "Kub\u{00AD}ernetes",  // soft hyphen
    ] {
      let url = try write(text, as: "words.txt")
      await #expect(throws: ImportFileError.unreadable) {
        try await FileImportSource(url: url).loadCandidates()
      }
    }
  }


  @Test("an exported file's word ceiling is raised, not removed")
  func exportedFileCeilingIsFiniteNotAbsent() async throws {
    // The "this is an EnviousWispr export" marker is self-declared and
    // unsigned, so any JSON can claim it. Removing the ceiling outright would
    // hand a crafted file an unbounded budget and hang the review screen; the
    // round trip only needs the ceiling RAISED above any real library.
    let ceiling = try #require(ExportedWordsFileParser().maximumCandidates)
    #expect(ceiling > CustomWordsImportLimits.maximumCandidates)
    #expect(ceiling == CustomWordsImportLimits.maximumExportedCandidates)
    // And the bytes are bounded too, so the two cannot drift apart again.
    #expect(
      ExportedWordsFileParser().maximumBytes
        == CustomWordsImportLimits.maximumExportedFileBytes)
  }

  @Test("reading a large export stops when the sheet is dismissed")
  func candidateConversionHonoursCancellation() async throws {
    // Decoding and converting is the expensive half of reading a big export.
    // Without a check inside it, the work carried on burning CPU and memory
    // after the user had closed the sheet.
    let words = (0..<5_000).map {
      CustomWord(canonical: "Term\($0)", aliases: [], category: .general)
    }
    let document = CustomWordsTransferDocument(words: words)

    let task = Task { try document.candidatesForImport() }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
  }


  @Test("a truncated UTF-16 file is refused, not imported as its prefix")
  func truncatedUTF16IsRefused() async throws {
    // Foundation ignores a dangling byte, so a partial write decoded to its
    // prefix and imported as if complete.
    let full = Data([0xFF, 0xFE]) + "Kubernetes\nPostgreSQL".data(using: .utf16LittleEndian)!
    let url = try write(full.dropLast(), as: "words.txt")

    await #expect(throws: ImportFileError.unreadable) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }


  @Test("a huge word list is refused without building every entry")
  func hugeListStopsAtTheCeiling() async throws {
    // Parsing everything and checking afterwards spent exactly the memory the
    // ceiling exists to save, and ignored cancellation until it finished.
    let limit = CustomWordsImportLimits.maximumCandidates
    let words = (0...(limit + 10)).map { "Term\($0)" }.joined(separator: "\n")

    let parsed = try PasteWordsParser.parse(words, limit: limit)

    // Stops one past the limit: enough to tell "at the limit" from "over".
    #expect(parsed.count == limit + 1)

    let url = try write(words, as: "words.txt")
    await #expect(
      throws: ImportFileError.tooManyWords(found: limit + 1, limit: limit)
    ) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("an exactly-at-the-limit list still imports")
  func exactlyAtLimitImports() async throws {
    // The off-by-one that a "+1" sentinel invites.
    let limit = CustomWordsImportLimits.maximumCandidates
    let words = (0..<limit).map { "Term\($0)" }.joined(separator: "\n")
    let url = try write(words, as: "words.txt")

    let batch = try await FileImportSource(url: url).loadCandidates()

    #expect(batch.candidates.count == limit)
  }


  @Test("routing does not depend on the system resolving extensions")
  func routingUsesExtensionsNotSystemTypes() async throws {
    // Dispatch previously round-tripped the filename through Launch Services;
    // in a restricted environment that returns dyn.* and EVERY supported
    // upload was rejected before the file was read.
    let registry = ImportFileRegistry.v1
    #expect(registry.parser(for: URL(fileURLWithPath: "/tmp/a.json"))?.identifier == "exported-words")
    #expect(registry.parser(for: URL(fileURLWithPath: "/tmp/a.txt"))?.identifier == "plain-text")
    // Case and path shape are irrelevant to the decision.
    #expect(registry.parser(for: URL(fileURLWithPath: "/tmp/A.JSON"))?.identifier == "exported-words")
    // Spreadsheets stay refused: the CSV split bug was the reason dispatch is
    // exact-match in the first place, and that must survive the mechanism change.
    #expect(registry.parser(for: URL(fileURLWithPath: "/tmp/a.csv")) == nil)
    #expect(registry.parser(for: URL(fileURLWithPath: "/tmp/a.tsv")) == nil)
    #expect(registry.parser(for: URL(fileURLWithPath: "/tmp/noextension")) == nil)
  }


  @Test("an oversized export is refused before candidates are built")
  func oversizedExportRefusedBeforeExpanding() async throws {
    // Same parse-then-check shape as the plain-text side: converting every
    // word and minting a UUID each, THEN checking, spends what the ceiling
    // exists to save. Both parsers now bound their own output.
    let ceiling = CustomWordsImportLimits.maximumExportedCandidates
    let words = (0...ceiling).map {
      CustomWord(canonical: "Term\($0)", aliases: [], category: .general)
    }
    let url = try write(try CustomWordsTransferDocument(words: words).encoded(), as: "words.json")

    await #expect(
      throws: ImportFileError.tooManyWords(found: ceiling + 1, limit: ceiling)
    ) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a tab separates words instead of hiding inside one")
  func tabSeparatesWords() async throws {
    // Accepted as whitespace but never split on, a tab was stored INSIDE a
    // canonical term where it is invisible — and comparison normalises it to a
    // space, so the saved word could never match a transcript.
    let url = try write("Kubernetes\tPostgreSQL\nGitHub", as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes", "PostgreSQL", "GitHub"])
    #expect(candidates.allSatisfy { !$0.canonical.contains("\t") })
  }


  @Test("a truncated UTF-16 file is refused, not read as Latin-1")
  func markedButBrokenFileDoesNotFallThrough() async throws {
    // A recognised mark is authoritative: if it says UTF-16 and the bytes fail
    // to decode, the file is broken, not secretly something else. Falling
    // through re-created the very bug the alignment check was added to fix —
    // [FF FE E9] became the plausible-looking word "ÿþé".
    let url = try write(Data([0xFF, 0xFE, 0xE9]), as: "words.txt")

    await #expect(throws: ImportFileError.unreadable) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("an over-limit file never states an exact word count")
  func overLimitMessageDoesNotInventACount() async throws {
    // The scan stops one past the limit rather than counting a file it is
    // going to refuse, so printing that figure would state a number nobody
    // measured.
    let limit = CustomWordsImportLimits.maximumCandidates
    let message = try #require(
      ImportFileError.tooManyWords(found: limit + 1, limit: limit).errorDescription)

    #expect(message.contains("more than \(limit)"))
    #expect(!message.contains("\(limit + 1)"))
  }


  // MARK: - One policy for every door (#1683 taxonomy P0s)

  @Test("an exported file cannot smuggle invisible characters into a word")
  func exportedFileIsHeldToTheSameCharacterPolicy() async throws {
    // The character rules lived inside the plain-text parser, so words
    // arriving from JSON skipped every one of them: the same bidi override
    // refused from a pasted list was accepted from a file. The policy is a
    // property of the STORE, so it now runs for every source.
    for hostile in ["Kub\u{202E}ernetes", "Kub\u{0000}ernetes", "Kub\u{FEFF}ernetes", "   "] {
      let word = CustomWord(canonical: hostile, aliases: [], category: .general)
      let url = try write(try CustomWordsTransferDocument(words: [word]).encoded(), as: "words.json")

      await #expect(throws: CustomWordsImportValidationError.self) {
        try await FileImportSource(url: url).loadCandidates()
      }
    }
  }

  @Test("an exported alias is held to the policy too, not just the word")
  func exportedAliasesAreValidated() async throws {
    let word = CustomWord(
      canonical: "Kubernetes", aliases: ["k8s", "kube\u{202E}rnetes"], category: .general)
    let url = try write(try CustomWordsTransferDocument(words: [word]).encoded(), as: "words.json")

    await #expect(throws: CustomWordsImportValidationError.self) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a clean exported file still imports, aliases intact")
  func cleanExportedFileStillImports() async throws {
    // The validator must not become a wall: real exports keep working, and
    // international words are not collateral damage.
    let words = [
      CustomWord(canonical: "Kubernetes", aliases: ["k8s"], category: .brand),
      CustomWord(canonical: "東京", aliases: ["とうきょう"], category: .general),
      CustomWord(canonical: "क्‍ष", aliases: [], category: .general),
    ]
    let url = try write(try CustomWordsTransferDocument(words: words).encoded(), as: "words.json")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes", "東京", "क्‍ष"])
    #expect(candidates[0].aliases == .supplied(["k8s"]))
  }


  @Test("line and paragraph separators cannot hide inside a stored word")
  func lineSeparatorsAreRefused() async throws {
    // U+2028 and U+2029 have their OWN Unicode categories, so a control-only
    // check let them through — invisible, inside a stored word, despite the
    // separator policy saying otherwise.
    for hidden in ["Kub\u{2028}ernetes", "Kub\u{2029}ernetes"] {
      let word = CustomWord(canonical: hidden, aliases: [], category: .general)
      let url = try write(try CustomWordsTransferDocument(words: [word]).encoded(), as: "words.json")

      await #expect(throws: CustomWordsImportValidationError.self) {
        try await FileImportSource(url: url).loadCandidates()
      }
    }
  }


  @Test("few words with millions of aliases is refused")
  func aliasSurfaceIsBounded() async throws {
    // Bounding words alone bounded one dimension of the wrong thing: the work
    // tracks total stored strings, so a handful of words each carrying a huge
    // alias list fits under both the word and byte ceilings while flooding
    // validation, comparison, and the collision index.
    let perWord = 5_000
    let wordCount =
      (CustomWordsImportLimits.maximumExportedStoredValues / perWord) + 2
    let words = (0..<wordCount).map { index in
      CustomWord(
        canonical: "Term\(index)",
        aliases: (0..<perWord).map { "a\(index)_\($0)" },
        category: .general)
    }
    let document = CustomWordsTransferDocument(words: words)
    #expect(document.words.count < CustomWordsImportLimits.maximumExportedCandidates)
    let url = try write(try document.encoded(), as: "words.json")

    await #expect(throws: ImportFileError.self) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a normal library with aliases is unaffected by the surface ceiling")
  func normalAliasSurfacePasses() async throws {
    let words = (0..<500).map {
      CustomWord(canonical: "Term\($0)", aliases: ["a\($0)", "b\($0)"], category: .general)
    }
    let url = try write(try CustomWordsTransferDocument(words: words).encoded(), as: "words.json")

    let batch = try await FileImportSource(url: url).loadCandidates()

    #expect(batch.candidates.count == 500)
  }


  @Test("the picker offers every extension the registry claims")
  func pickerCoversEveryRegisteredExtension() throws {
    // Declared types alone could hide a file the registry accepts: on a system
    // where an extension resolves to an unregistered dynamic type it conforms
    // to no generic text type, so the panel greyed out a file the parser
    // claims and the delegate never got the chance to enable it.
    let registry = ImportFileRegistry.v1
    let offered = Set(registry.acceptedContentTypes)

    for parser in registry.parsers {
      for ext in parser.fileExtensions {
        guard let type = UTType(filenameExtension: ext) else { continue }
        #expect(
          offered.contains(type) || offered.contains { type.conforms(to: $0) },
          "the picker hides .\(ext), which \(parser.identifier) claims")
      }
    }
  }

  @Test("a rejected pasted word does not blame a file")
  func validationCopyIsSourceNeutral() throws {
    // The validator runs for pasted text and files alike now, so naming a file
    // was wrong half the time.
    let message = try #require(
      CustomWordsImportValidationError.unusableWord(canonical: "Kub\u{202E}ernetes")
        .errorDescription)

    #expect(!message.lowercased().contains("file"))
    #expect(message.contains("Nothing was imported"))
  }


  @Test("a rejected character is named, never rendered, in the error")
  func rejectedCharacterIsNotEchoedIntoTheError() throws {
    // Echoing the raw value meant the very character rejected for rendering
    // deceptively got rendered into the message explaining its rejection,
    // where it can reorder the error text itself.
    let message = try #require(
      CustomWordsImportValidationError.unusableWord(canonical: "Kub\u{202E}ernetes")
        .errorDescription)

    #expect(!message.unicodeScalars.contains { $0.value == 0x202E })
    #expect(message.contains("<U+202E>"))
    // The readable part still survives, so the user can find the entry.
    #expect(message.contains("Kub"))
  }

  @Test("validation stops when the sheet is dismissed")
  func validationHonoursCancellation() async throws {
    // 400,000 stored values is long enough to outlive a dismissed sheet.
    let candidates = (0..<5_000).map {
      CustomWordsImportCandidate(canonical: "Term\($0)")
    }
    let batch = CustomWordsImportBatch(
      sourceID: "test", sourceDisplayName: "test", candidates: candidates)

    let task = Task { try batch.validated() }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
  }


  @Test("sanitising an error keeps ordinary spaces intact")
  func sanitisedErrorKeepsSpaces() throws {
    // Testing each scalar through the whole-VALUE check treated a standalone
    // space as blank, so a multi-word entry rendered as Foo<U+0020>Bar and
    // told the user their spaces were bad characters.
    let message = try #require(
      CustomWordsImportValidationError.unusableWord(canonical: "Foo Bar\u{202E}")
        .errorDescription)

    #expect(message.contains("Foo Bar"))
    #expect(!message.contains("<U+0020>"))
    #expect(message.contains("<U+202E>"))
  }

  @Test("validation stops mid-aliases when the sheet is dismissed")
  func aliasValidationHonoursCancellation() async throws {
    // One candidate can carry hundreds of thousands of aliases, so checking
    // only the outer loop left the inner one uninterruptible.
    let candidate = CustomWordsImportCandidate(
      canonical: "Kubernetes",
      aliases: .supplied((0..<20_000).map { "alias\($0)" }))
    let batch = CustomWordsImportBatch(
      sourceID: "test", sourceDisplayName: "test", candidates: [candidate])

    let task = Task { try batch.validated() }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
  }


  @Test("one enormous line is refused, not stored as a single word")
  func oneEnormousLineIsRefused() async throws {
    // A minified file or log picked by mistake passes the candidate ceiling as
    // ONE entry, so without a length cap it became a multi-megabyte "word":
    // copied through normalisation and comparison, rendered in Review, and
    // persisted.
    let huge = String(repeating: "x", count: 2_000_000)
    let url = try write(huge, as: "words.txt")

    await #expect(throws: CustomWordsImportValidationError.self) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("an exported file cannot smuggle an enormous word past the text cap")
  func exportedFileLengthIsCappedToo() async throws {
    // Both doors: the cap on the text scan means nothing if JSON can carry the
    // same value straight through.
    let word = CustomWord(
      canonical: String(repeating: "x", count: 5_000), aliases: [], category: .general)
    let url = try write(try CustomWordsTransferDocument(words: [word]).encoded(), as: "words.json")

    await #expect(throws: CustomWordsImportValidationError.self) {
      try await FileImportSource(url: url).loadCandidates()
    }
  }

  @Test("a long but realistic word still imports")
  func longRealisticWordImports() async throws {
    // The cap must clear real terms, including long compounds in scripts that
    // do not space-separate.
    let long = String(repeating: "り", count: 200)
    let url = try write(long, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == [long])
  }

}
