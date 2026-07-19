import EnviousWisprCore
import Foundation
import SQLite3
import Testing

@testable import EnviousWisprPostProcessing

/// #1686 — reading vocabulary out of other dictation apps.
///
/// Fixtures mirror each app's real on-disk shape, captured from live data on
/// 2026-07-19. The filter tests carry the most weight: importing a word the
/// user deliberately deleted in another app is the worst thing these adapters
/// could do, and it would look like success.
@Suite("SmartImport")
struct SmartImportSourceTests {

  private func makeDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-smart-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func write(_ text: String, to dir: URL, as name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  // MARK: - FluidVoice

  @Test("FluidVoice terms are read and its tuning parameters ignored")
  func fluidVoiceReadsOnlyTerms() throws {
    // Real shape: the keys beside `terms` are that app's ASR tuning knobs.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "alpha": 2.8, "minCtcScore": -2.2, "minSimilarity": 0.72, "minTermLength": 3,
        "terms": [ { "text": "FluidVoice", "aliases": ["fluid voice"], "weight": 10.0 },
                   { "text": "Kubernetes", "aliases": [], "weight": 1.0 } ] }
      """, to: dir, as: "v.json")

    #expect(try FluidVoiceAdapter().loadWords(at: url) == ["FluidVoice", "Kubernetes"])
  }

  @Test("a FluidVoice file with no terms key is a fresh install, not a failure")
  func fluidVoiceMissingTermsIsEmptyNotAnError() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "alpha": 2.8 }"#, to: dir, as: "v.json")
    #expect(try FluidVoiceAdapter().loadWords(at: url).isEmpty)
  }

  // MARK: - Superwhisper

  @Test("Superwhisper reads plain vocabulary and the corrected side of replacements")
  func superwhisperReadsVocabularyAndReplacementTargets() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "favoriteModelIDs": ["vad-v2"],
        "replacements": [ { "id": "A", "original": "super whisper", "with": "Superwhisper" } ],
        "vocabulary": ["Superwhisper", "Saurabh"] }
      """, to: dir, as: "settings.json")

    // The `with` side is the spelling the user actually wants. `original` is
    // the alias, and v1 does not import aliases.
    #expect(
      try SuperwhisperAdapter().loadWords(at: url)
        == ["Superwhisper", "Saurabh", "Superwhisper"])
  }

  @Test("a Superwhisper file missing both keys reads as empty")
  func superwhisperMissingKeysIsEmpty() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "modeKeys": [] }"#, to: dir, as: "settings.json")
    #expect(try SuperwhisperAdapter().loadWords(at: url).isEmpty)
  }

  @Test("Superwhisper probes the current location before the legacy one")
  func superwhisperProbesCurrentLocationFirst() {
    let paths = SuperwhisperAdapter().candidatePaths.map(\.path)
    // Checking only one silently reports "not found" for half the install
    // base — and ORDER matters just as much: an upgraded install can retain
    // both files, and probing legacy first reads vocabulary the user stopped
    // editing months ago while ignoring the file the app actually uses.
    #expect(paths.count == 2)
    #expect(!paths[0].contains("Documents"))
    #expect(paths[1].contains("Documents/superwhisper"))
  }

  @Test("a corrupt database is refused rather than importing whatever was read")
  func corruptDatabaseIsRefusedRatherThanPartiallyImported() throws {
    // A partial read presented as a complete import is the same false-pass
    // shape as a test that never runs: the user would see "imported 3 words"
    // and never learn the other forty were unreachable.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("flow.sqlite")
    // A file that opens as a database but whose table cannot be read.
    try Data("SQLite format 3\u{0}garbage-not-a-real-database".utf8).write(to: url)

    #expect(throws: SmartImportError.unreadable("Wispr Flow")) {
      _ = try WisprFlowAdapter().loadWords(at: url)
    }
  }

  // MARK: - Wispr Flow

  /// Builds a database with Wispr Flow's real column shape.
  private func makeWisprFlowDatabase(in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      INSERT INTO Dictionary VALUES ('1','Wispr Flow',NULL,0,0);
      INSERT INTO Dictionary VALUES ('2','btw','by the way',0,0);
      INSERT INTO Dictionary VALUES ('3','deleted word',NULL,1,0);
      INSERT INTO Dictionary VALUES ('4','sig','my long signature',0,1);
      INSERT INTO Dictionary VALUES ('5','blank replacement','   ',0,0);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    return url
  }

  @Test("Wispr Flow never imports a word the user deleted there")
  func wisprFlowFiltersSoftDeletedEntries() throws {
    // The worst thing this adapter could do is resurrect words someone
    // deliberately removed — and it would look like a successful import.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    let words = try WisprFlowAdapter().loadWords(at: url)
    #expect(!words.contains("deleted word"))
  }

  @Test("Wispr Flow skips text-expansion snippets")
  func wisprFlowFiltersSnippets() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    // Snippets are a different feature, not vocabulary.
    let words = try WisprFlowAdapter().loadWords(at: url)
    #expect(!words.contains("my long signature"))
    #expect(!words.contains("sig"))
  }

  @Test("Wispr Flow takes the corrected spelling when there is one")
  func wisprFlowPrefersReplacementOverPhrase() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    let words = try WisprFlowAdapter().loadWords(at: url)
    // `btw → by the way`: the corrected side is the word worth having.
    #expect(words.contains("by the way"))
    #expect(!words.contains("btw"))
    // No replacement at all: the phrase itself is the word.
    #expect(words.contains("Wispr Flow"))
  }

  @Test("a whitespace-only replacement falls back to the phrase")
  func wisprFlowTreatsBlankReplacementAsAbsent() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    // An empty-but-present replacement would otherwise import a blank word.
    #expect(try WisprFlowAdapter().loadWords(at: url).contains("blank replacement"))
  }

  @Test("a half-recovered database is refused rather than written into")
  func walWithoutShmIsRefused() throws {
    // -wal present but -shm missing means a crashed or mid-recovery Wispr
    // Flow. A plain read-only connection would CREATE the missing -shm inside
    // that app's directory, and immutable would skip real uncommitted content
    // and call a stale view complete. Neither is honest, so refuse and let the
    // error tell them to quit the app — which flushes the WAL and makes the
    // next attempt both safe and complete.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)
    try Data("pretend wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

    #expect(throws: SmartImportError.unreadable("Wispr Flow")) {
      _ = try WisprFlowAdapter().loadWords(at: url)
    }
    // And nothing was created on the way out.
    #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
  }

  @Test("a cleanly closed database is read without creating sidecars")
  func cleanDatabaseLeavesNoSidecarsBehind() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    _ = try WisprFlowAdapter().loadWords(at: url)

    // Reading another app's data must never write into its folder.
    #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
  }

  // MARK: - Source contract

  @Test("an app that isn't installed reports not found rather than failing oddly")
  func missingAppReportsNotFound() async throws {
    struct Missing: SmartImportAdapter {
      let identifier = "missing"
      let displayName = "Nothing"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/nonexistent/nope.json")] }
      func loadWords(at url: URL) throws -> [String] { [] }
    }
    await #expect(throws: SmartImportError.appNotFound("Nothing")) {
      _ = try await SmartImportSource(adapter: Missing()).loadCandidates()
    }
  }

  @Test("imported words carry no authority over any field")
  func candidatesClaimNoAuthority() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Kubernetes", "aliases": ["k8s"] } ] }"#, to: dir, as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [String] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    let candidate = try #require(batch.candidates.first)

    // v1 imports the main word only. Even though FluidVoice HAS aliases for
    // this term, they are not brought across — so an existing word is skipped
    // rather than modified.
    #expect(candidate.canonical == "Kubernetes")
    #expect(candidate.aliases == .unspecified)
    #expect(candidate.category == .unspecified)
    #expect(candidate.suggestedAliases.isEmpty)
    #expect(batch.sourceID == "fluidvoice")
  }

  @Test("duplicates across an app's own lists collapse once")
  func duplicatesCollapseUsingTheSharedKey() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "vocabulary": ["Superwhisper", "superwhisper"],
        "replacements": [ { "original": "super whisper", "with": "Superwhisper" } ] }
      """, to: dir, as: "settings.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "superwhisper"
      let displayName = "Superwhisper"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [String] {
        try SuperwhisperAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    // Same normalization the paste and file paths use, so a competitor list
    // dedups exactly the way a typed one does.
    #expect(batch.candidates.map(\.canonical) == ["Superwhisper"])
  }

  @Test("the registry ships the three verified apps and not the unverified one")
  func registryShipsOnlyVerifiedAdapters() {
    let ids = SmartImportRegistry.v1.adapters.map(\.identifier)
    #expect(ids.sorted() == ["fluidvoice", "superwhisper", "wispr-flow"])
    // TypeWhisper is absent deliberately: its table is empty on the only
    // machine available, so an adapter would be written against a shape nobody
    // has seen populated.
    #expect(!ids.contains("typewhisper"))
  }

  @Test("an implausibly large vocabulary file is refused before decoding")
  func oversizedVocabularyFileIsRefusedBeforeDecoding() throws {
    // Reading an arbitrary file into memory to discover it is too big can end
    // the app before the intended error is ever shown (code review r9).
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("v.json")
    let huge = Data(count: FluidVoiceAdapter.maximumVocabularyBytes + 1)
    try huge.write(to: url)

    #expect(throws: SmartImportError.unreadable("FluidVoice")) {
      _ = try FluidVoiceAdapter().loadWords(at: url)
    }
  }

  @Test("a normal-sized vocabulary file is still read")
  func normalSizedVocabularyFileIsAccepted() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "terms": [ { "text": "Kubernetes" } ] }"#, to: dir, as: "v.json")
    #expect(try FluidVoiceAdapter().loadWords(at: url) == ["Kubernetes"])
  }

  @Test("a truncated read is refused even when duplicates hide it")
  func truncatedReadIsRefusedEvenWhenDedupHidesIt() async throws {
    // The trap (code review r10): the adapter reads one past the ceiling so
    // "too many" is knowable, but deduplication SHRINKS the list — so a source
    // whose overflowing rows are duplicates would fall back under the limit
    // and report a successful import that had silently dropped the rest.
    // Every ceiling needs a signal for having been reached, and counting after
    // the shrink loses it.
    struct Flood: SmartImportAdapter {
      let identifier = "flood"
      let displayName = "Flood"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> [String] {
        // One past the ceiling, and all identical: dedup collapses this to a
        // single word, which would look like a tiny successful import.
        Array(
          repeating: "duplicate",
          count: CustomWordsImportLimits.maximumCandidates + 1)
      }
    }

    await #expect(
      throws: ImportFileError.tooManyWords(limit: CustomWordsImportLimits.maximumCandidates)
    ) {
      _ = try await SmartImportSource(adapter: Flood()).loadCandidates()
    }
  }
}
