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

    #expect(batch.candidates.map { $0.canonical } == PasteWordsParser.parse(text))
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

  @Test("text that isn't UTF-8 still reads rather than being refused")
  func latin1TextIsAccepted() async throws {
    let url = try write(try #require("Beyoncé".data(using: .isoLatin1)), as: "legacy.txt")
    let batch = try await FileImportSource(url: url).loadCandidates()
    #expect(batch.candidates.map { $0.canonical } == ["Beyoncé"])
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
    let url = try write(Data(count: FileImportSource.maximumFileBytes + 1), as: "huge.txt")
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

  @Test("a legacy Latin-1 file still imports")
  func latin1FileStillImports() async throws {
    // The fallback must keep working for its real case; the fix narrows WHEN
    // it is reached, it does not remove it.
    let url = try write("Beyoncé\nJalapeño".data(using: .isoLatin1)!, as: "words.txt")

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


  @Test("UTF-16 without a byte-order mark still imports real words")
  func utf16WithoutByteOrderMarkDecodes() async throws {
    // NUL is a legal UTF-8 byte, so these bytes decode "successfully" as UTF-8
    // to "K\0u\0b\0…". Gating only the Latin-1 path let that straight
    // through — the plausibility check has to guard EVERY decode step.
    let url = try write(
      "Kubernetes\nPostgreSQL".data(using: .utf16LittleEndian)!, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes", "PostgreSQL"])
  }

  @Test("big-endian UTF-16 without a byte-order mark decodes too")
  func utf16BigEndianWithoutByteOrderMarkDecodes() async throws {
    let url = try write("Kubernetes".data(using: .utf16BigEndian)!, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["Kubernetes"])
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


  @Test("a multi-word CJK list in UTF-16 imports correctly")
  func multiWordCJKUTF16Imports() async throws {
    // The realistic shape: line breaks supply the NUL bytes the detector
    // reads, so a Japanese word list saved as UTF-16 works.
    let url = try write("東京\n大阪\n京都".data(using: .utf16LittleEndian)!, as: "words.txt")

    let candidates = try await FileImportSource(url: url).loadCandidates().candidates

    #expect(candidates.map { $0.canonical } == ["東京", "大阪", "京都"])
  }

  @Test("a single CJK word in UTF-16 with no mark is refused, not corrupted")
  func singleCJKWordWithoutMarkIsRefused() async throws {
    // Genuinely ambiguous: these four bytes are a valid Latin-1 word list AND
    // valid UTF-16. Guessing UTF-16 here would corrupt real Latin-1 files
    // (Beyoncé/Jalapeño decodes to plausible-looking CJK), so refusing is the
    // honest answer. Refused beats "qg¬N" imported as a word.
    let url = try write("東京".data(using: .utf16LittleEndian)!, as: "words.txt")

    await #expect(throws: ImportFileError.unreadable) {
      try await FileImportSource(url: url).loadCandidates()
    }
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



}
