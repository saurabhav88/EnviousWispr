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

  @Test("FluidVoice terms carry their own aliases array across as the word's aliases")
  func fluidVoiceReadsTermsWithAliases() throws {
    // Real shape: the keys beside `terms` are that app's ASR tuning knobs.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "alpha": 2.8, "minCtcScore": -2.2, "minSimilarity": 0.72, "minTermLength": 3,
        "terms": [ { "text": "FluidVoice", "aliases": ["fluid voice"], "weight": 10.0 },
                   { "text": "Kubernetes", "aliases": [], "weight": 1.0 },
                   { "text": "NoAliasKey", "weight": 1.0 } ] }
      """, to: dir, as: "v.json")

    #expect(
      try FluidVoiceAdapter().loadWords(at: url)
        == [
          SmartImportWord(canonical: "FluidVoice", aliases: ["fluid voice"]),
          SmartImportWord(canonical: "Kubernetes", aliases: []),
          SmartImportWord(canonical: "NoAliasKey", aliases: []),
        ])
  }

  @Test("a FluidVoice file with no terms key is a fresh install, not a failure")
  func fluidVoiceMissingTermsIsEmptyNotAnError() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "alpha": 2.8 }"#, to: dir, as: "v.json")
    #expect(try FluidVoiceAdapter().loadWords(at: url).isEmpty)
  }

  @Test("FluidVoice aliases present as a non-array refuses the whole import")
  func fluidVoiceAliasesAsNonArrayRefusesTheWholeImport() throws {
    // Newly-recognized field, newly validated: before this plan, an unknown
    // shape here was silently ignored. Now a malformed value is treated the
    // same as any other unreadable file, not a partial/best-effort read.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Kubernetes", "aliases": "k8s" } ] }"#, to: dir, as: "v.json")

    #expect(throws: SmartImportError.unreadable("FluidVoice")) {
      _ = try FluidVoiceAdapter().loadWords(at: url)
    }
  }

  @Test("a non-string element inside FluidVoice aliases refuses the whole import")
  func fluidVoiceNonStringAliasElementRefusesTheWholeImport() throws {
    // A distinct malformed shape from "aliases is not an array" — the array
    // itself decodes, but one of its elements does not.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Kubernetes", "aliases": ["k8s", 8] } ] }"#, to: dir, as: "v.json")

    #expect(throws: SmartImportError.unreadable("FluidVoice")) {
      _ = try FluidVoiceAdapter().loadWords(at: url)
    }
  }

  @Test("a term with no aliases key maps to .unspecified downstream, not .supplied([])")
  func fluidVoiceTermWithNoAliasesKeyMapsToUnspecifiedDownstream() async throws {
    // Strengthens the adapter-level `aliases == []` assertion above (§8's
    // three-way distinction: no opinion vs. authoritative-empty vs. found).
    // "This source found no misspelling" must never become "this source
    // asserts zero aliases" once it reaches the shared candidate type.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "NoAliasKey", "weight": 1.0 } ] }"#, to: dir, as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    let candidate = try #require(batch.candidates.first)
    #expect(candidate.canonical == "NoAliasKey")
    #expect(candidate.aliases == .unspecified)
  }

  // MARK: - Superwhisper

  @Test("Superwhisper vocabulary entries import with no alias")
  func superwhisperPlainVocabularyHasNoAlias() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "favoriteModelIDs": ["vad-v2"], "vocabulary": ["Saurabh"] }"#, to: dir,
      as: "settings.json"
    )

    #expect(try SuperwhisperAdapter().loadWords(at: url) == [SmartImportWord(canonical: "Saurabh")])
  }

  @Test("a Superwhisper replacement carries its original as the alias")
  func superwhisperReplacementCarriesOriginalAsAlias() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "replacements": [ { "id": "A", "original": "super whisper", "with": "Superwhisper" } ] }
      """, to: dir, as: "settings.json")

    #expect(
      try SuperwhisperAdapter().loadWords(at: url)
        == [SmartImportWord(canonical: "Superwhisper", aliases: ["super whisper"])])
  }

  @Test("a Superwhisper replacement missing original has no alias")
  func superwhisperReplacementMissingOriginalHasNoAlias() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "replacements": [ { "id": "A", "with": "Superwhisper" } ] }"#, to: dir,
      as: "settings.json")

    #expect(
      try SuperwhisperAdapter().loadWords(at: url) == [SmartImportWord(canonical: "Superwhisper")])
  }

  @Test("a Superwhisper replacement missing with is dropped, as today")
  func superwhisperReplacementMissingWithIsDropped() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "replacements": [ { "id": "A", "original": "super whisper" } ] }"#, to: dir,
      as: "settings.json")

    #expect(try SuperwhisperAdapter().loadWords(at: url).isEmpty)
  }

  @Test(
    "a Superwhisper replacement with an empty or whitespace-only with is dropped at the adapter")
  func superwhisperReplacementBlankWithIsDroppedAtTheAdapter() throws {
    // Previously this row was still emitted by the adapter and dropped one
    // hop later by SmartImportSource's own trim/blank filter; the outcome is
    // unchanged, but the filtering now happens here (§3, Grounded Review r3/r4).
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "replacements": [ { "id": "A", "original": "x", "with": "" },
                           { "id": "B", "original": "y", "with": "   " } ] }
      """, to: dir, as: "settings.json")

    #expect(try SuperwhisperAdapter().loadWords(at: url).isEmpty)
  }

  @Test("Superwhisper original present as a non-string value refuses the whole import")
  func superwhisperMalformedOriginalRefusesTheWholeImport() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "replacements": [ { "id": "A", "original": 8, "with": "Superwhisper" } ] }"#, to: dir,
      as: "settings.json")

    #expect(throws: SmartImportError.unreadable("Superwhisper")) {
      _ = try SuperwhisperAdapter().loadWords(at: url)
    }
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
    #expect(!words.map(\.canonical).contains("deleted word"))
  }

  @Test("Wispr Flow skips text-expansion snippets")
  func wisprFlowFiltersSnippets() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    // Snippets are a different feature, not vocabulary.
    let words = try WisprFlowAdapter().loadWords(at: url).map(\.canonical)
    #expect(!words.contains("my long signature"))
    #expect(!words.contains("sig"))
  }

  @Test("Wispr Flow takes the corrected spelling as canonical and the phrase as its alias")
  func wisprFlowPrefersReplacementOverPhraseAndCarriesPhraseAsAlias() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    let words = try WisprFlowAdapter().loadWords(at: url)
    // `btw → by the way`: the corrected side is the word worth having, and
    // the misspelling that prompted it comes across as the alias.
    #expect(words.contains(SmartImportWord(canonical: "by the way", aliases: ["btw"])))
    // No replacement at all: the phrase itself is the word, with no alias.
    #expect(words.contains(SmartImportWord(canonical: "Wispr Flow")))
  }

  @Test("a whitespace-only replacement falls back to the phrase with no alias")
  func wisprFlowTreatsBlankReplacementAsAbsent() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    // An empty-but-present replacement would otherwise import a blank word.
    let words = try WisprFlowAdapter().loadWords(at: url)
    #expect(words.contains(SmartImportWord(canonical: "blank replacement")))
  }

  @Test("a tab-only replacement falls back to the phrase, unlike the old SQL TRIM")
  func wisprFlowTabOnlyReplacementFallsBackToPhrase() throws {
    // SQLite's TRIM() (the old single-column query) strips ASCII spaces only,
    // so a tab-only replacement would have stayed as a non-empty (whitespace)
    // canonical under the exact old semantics. `.whitespacesAndNewlines` also
    // strips tabs, matching every other trim call in this file — a
    // deliberate, disclosed broadening (§3).
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      INSERT INTO Dictionary VALUES ('1','tab word','	',0,0);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    let words = try WisprFlowAdapter().loadWords(at: url)
    #expect(words == [SmartImportWord(canonical: "tab word")])
  }

  @Test("a self-referential Wispr Flow row still emits the alias at this layer")
  func wisprFlowSelfReferentialRowStillEmitsTheAliasHere() throws {
    // Not filtered at the adapter layer — the existing downstream
    // `enforceAliases` rule absorbs a self-referential alias at commit time
    // (§2.5.4, §7). Filtering it here would duplicate that authority.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      INSERT INTO Dictionary VALUES ('1','Superwhisper','Superwhisper',0,0);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    let words = try WisprFlowAdapter().loadWords(at: url)
    #expect(words == [SmartImportWord(canonical: "Superwhisper", aliases: ["Superwhisper"])])
  }

  @Test("Wispr Flow orders by the row's own stored id, not insertion order")
  func wisprFlowOrdersByStoredIdNotInsertionOrder() throws {
    // A bare LIMIT with no ORDER BY leaves row order unspecified, and the
    // alias-collision case (§7) needs a real, stable "earlier" for that to
    // mean anything. Inserted in the OPPOSITE order from `id` on purpose, to
    // prove the output follows the stored id rather than insertion sequence.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      INSERT INTO Dictionary VALUES ('z','zebra word',NULL,0,0);
      INSERT INTO Dictionary VALUES ('a','alpha word',NULL,0,0);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    let canonicals = try WisprFlowAdapter().loadWords(at: url).map(\.canonical)
    let alphaIndex = try #require(canonicals.firstIndex(of: "alpha word"))
    let zebraIndex = try #require(canonicals.firstIndex(of: "zebra word"))
    #expect(alphaIndex < zebraIndex)
  }

  @Test("phrase NOT NULL guarantees a value exists, not that it is non-blank")
  func wisprFlowBlankPhraseIsPassedThroughAtThisLayer() throws {
    // NOT NULL does not forbid an empty string. Downstream blank-filtering in
    // `SmartImportSource.loadRawCandidates()` produces no candidate for a row
    // like this, same as any other blank canonical — that is a separate,
    // already-covered guarantee (§9), not this adapter's job.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      INSERT INTO Dictionary VALUES ('1','',NULL,0,0);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    let words = try WisprFlowAdapter().loadWords(at: url)
    #expect(words == [SmartImportWord(canonical: "")])
  }

  @Test("a blank or whitespace-only phrase produces no candidate downstream")
  func wisprFlowBlankOrWhitespacePhraseProducesNoDownstreamCandidate() async throws {
    // Proves the §9 guarantee end to end, not just that the adapter passes
    // the row through unfiltered: `SmartImportSource.loadRawCandidates()`'s
    // own blank-filter is what actually absorbs this, same as any other
    // blank canonical.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      INSERT INTO Dictionary VALUES ('1','',NULL,0,0);
      INSERT INTO Dictionary VALUES ('2','   ',NULL,0,0);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    struct Fixed: SmartImportAdapter {
      let identifier = "wispr-flow"
      let displayName = "Wispr Flow"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try WisprFlowAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    #expect(batch.candidates.isEmpty)
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

  @Test("a live database with both sidecars is refused, not read WAL-aware")
  func liveDatabaseWithSidecarsIsRefused() throws {
    // Reading WAL-aware required a connection mode that can CREATE files, and
    // that mode is the only way this can ever write into another app's folder.
    // If the app quit between the check and the open, SQLite recreated empty
    // sidecars there — and the after-read check then saw a WAL again and
    // called the import good (Codex review, #1686).
    //
    // Refusing removes the writable mode entirely, so there is no window left
    // to lose. The cost is one step the error already asks for: quit the app.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)
    try Data("pretend wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
    try Data("pretend shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))

    #expect(throws: SmartImportError.unreadable("Wispr Flow")) {
      _ = try WisprFlowAdapter().loadWords(at: url)
    }
  }

  @Test("an -shm alone is refused too, whichever sidecar it is")
  func shmWithoutWalIsRefused() throws {
    // The rule is "any sidecar", not "the WAL": naming one of a pair is how
    // the earlier version left a case uncovered.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)
    try Data("pretend shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))

    #expect(throws: SmartImportError.unreadable("Wispr Flow")) {
      _ = try WisprFlowAdapter().loadWords(at: url)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
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
      func loadWords(at url: URL) throws -> [SmartImportWord] { [] }
    }
    await #expect(throws: SmartImportError.appNotFound("Nothing")) {
      _ = try await SmartImportSource(adapter: Missing()).loadCandidates()
    }
  }

  @Test("an imported word carries its source alias as authoritative")
  func importedWordsCarryTheirSourceAliasAsAuthoritative() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Kubernetes", "aliases": ["k8s"] } ] }"#, to: dir, as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    let candidate = try #require(batch.candidates.first)

    // This is the whole point of this phase: a source-provided alias is now
    // carried across as `.supplied`, not discarded.
    #expect(candidate.canonical == "Kubernetes")
    #expect(candidate.aliases == .supplied(["k8s"]))
    #expect(batch.sourceID == "fluidvoice")
  }

  @Test("an imported word claims no authority over any other field")
  func importedWordsClaimNoAuthorityOverAnyOtherField() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Kubernetes", "aliases": ["k8s"] } ] }"#, to: dir, as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    let candidate = try #require(batch.candidates.first)

    // Only aliases changed by this plan (§2.2). Every other authority field
    // stays exactly as unopinionated as it was before this phase.
    #expect(candidate.category == .unspecified)
    #expect(candidate.priority == .unspecified)
    #expect(candidate.forceReplace == .unspecified)
    #expect(candidate.caseSensitive == .unspecified)
    #expect(candidate.minSimilarityOverride == .unspecified)
    #expect(candidate.suggestedAliases.isEmpty)
  }

  @Test("an alias that is whitespace-only is dropped, never carried as .supplied([\"\"])")
  func whitespaceOnlyAliasIsDroppedNotSuppliedEmpty() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Kubernetes", "aliases": ["   "] } ] }"#, to: dir, as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    let candidate = try #require(batch.candidates.first)
    #expect(candidate.aliases == .unspecified)
  }

  @Test("duplicate rows are no longer merged at this layer")
  func duplicateRowsAreNotMergedAtThisLayer() async throws {
    // Merging same-canonical rows within one batch is now entirely
    // `CustomWordsImportCompareEngine.coalesceDuplicates`'s job, downstream
    // of this source (§3c). This layer emits every trimmed row as-is.
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
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try SuperwhisperAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    #expect(batch.candidates.map(\.canonical) == ["Superwhisper", "superwhisper", "Superwhisper"])
    #expect(
      batch.candidates.map(\.aliases) == [.unspecified, .unspecified, .supplied(["super whisper"])])
  }

  @Test("raw candidates differing only by internal whitespace stay separate at this layer")
  func rawCandidatesKeepInternalWhitespaceVariantsSeparate() async throws {
    // `SmartImportSource`'s own former local dedup used the STRONGER
    // `normalize` key, which collapsed this pair; the weaker `persistenceKey`
    // this plan delegates to downstream treats them as distinct (§3c, §4).
    // This layer must not pre-merge them either way — proving that requires
    // both to still be present here.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Claude Code" }, { "text": "Claude  Code" } ] }"#, to: dir,
      as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    #expect(batch.candidates.map(\.canonical) == ["Claude Code", "Claude  Code"])
  }

  @Test("raw candidates differing only by Unicode composition stay separate at this layer")
  func rawCandidatesKeepUnicodeCompositionVariantsSeparate() async throws {
    // A distinct axis from internal whitespace — tested as its own case so an
    // implementation cannot satisfy an "or" description by covering only one
    // (Grounded Review r2).
    let nfc = "caf\u{e9}"
    let nfd = "cafe\u{301}"
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "\#(nfc)" }, { "text": "\#(nfd)" } ] }"#, to: dir, as: "v.json")

    struct Fixed: SmartImportAdapter {
      let identifier = "fluidvoice"
      let displayName = "FluidVoice"
      let url: URL
      var candidatePaths: [URL] { [url] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        try FluidVoiceAdapter().loadWords(at: url)
      }
    }

    let batch = try await SmartImportSource(adapter: Fixed(url: url)).loadCandidates()
    // Swift `String ==` is canonically equivalent — nfc == nfd is TRUE, so
    // comparing `[String]` here would pass even if composition were silently
    // normalized away. Unicode scalars distinguish what canonical-equivalent
    // String comparison cannot (Codex chunk review r1).
    let actualScalars = batch.candidates.map { Array($0.canonical.unicodeScalars) }
    #expect(actualScalars == [Array(nfc.unicodeScalars), Array(nfd.unicodeScalars)])
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
    #expect(
      try FluidVoiceAdapter().loadWords(at: url) == [SmartImportWord(canonical: "Kubernetes")])
  }

  @Test("a truncated read is refused even though nothing shrinks it anymore")
  func truncatedReadIsRefusedBeforeConstruction() async throws {
    // The raw row-count ceiling still applies before candidate construction.
    // Unlike before this plan, nothing at this layer shrinks the list anymore
    // (the local dedup was deleted, §3c) — so this now proves the ceiling
    // check's POSITION (before any merging could ever hide an overflow)
    // rather than proving it survives a shrink that no longer happens.
    struct Flood: SmartImportAdapter {
      let identifier = "flood"
      let displayName = "Flood"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> [SmartImportWord] {
        // One past the ceiling, and all identical — would look like a tiny
        // successful import if this layer merged duplicates, which it no
        // longer does.
        Array(
          repeating: SmartImportWord(canonical: "duplicate"),
          count: CustomWordsImportLimits.maximumCandidates + 1)
      }
    }

    await #expect(
      throws: ImportFileError.tooManyWords(
        found: CustomWordsImportLimits.maximumCandidates + 1,
        limit: CustomWordsImportLimits.maximumCandidates)
    ) {
      _ = try await SmartImportSource(adapter: Flood()).loadCandidates()
    }
  }

  /// FluidVoice is the real amplification vector this ceiling exists for: its
  /// schema can attach an unbounded alias array to one term (§3 rationale).
  /// Routes the actual decoded JSON through the real adapter, not a synthetic
  /// double, so the ceiling is proven against the shape it was built for.
  private func writeFluidVoiceFixture(aliasCount: Int, to dir: URL) throws -> URL {
    let aliasesJSON = (0..<aliasCount).map { "\"a\($0)\"" }.joined(separator: ",")
    return try write(
      #"{ "terms": [ { "text": "Word", "aliases": [\#(aliasesJSON)] } ] }"#, to: dir, as: "v.json")
  }

  private struct FixedFluidVoice: SmartImportAdapter {
    let identifier = "fluidvoice"
    let displayName = "FluidVoice"
    let url: URL
    var candidatePaths: [URL] { [url] }
    func loadWords(at url: URL) throws -> [SmartImportWord] {
      try FluidVoiceAdapter().loadWords(at: url)
    }
  }

  @Test("the stored-value ceiling accepts a batch exactly at the limit")
  func storedValueCeilingAcceptsExactLimit() async throws {
    let limit = CustomWordsImportLimits.maximumExportedStoredValues
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // canonical (1) + aliasCount == limit exactly.
    let url = try writeFluidVoiceFixture(aliasCount: limit - 1, to: dir)

    let batch = try await SmartImportSource(adapter: FixedFluidVoice(url: url)).loadCandidates()
    #expect(batch.candidates.count == 1)
  }

  @Test("the stored-value ceiling refuses a batch one past the limit")
  func storedValueCeilingRefusesLimitPlusOne() async throws {
    let limit = CustomWordsImportLimits.maximumExportedStoredValues
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // canonical (1) + aliasCount == limit + 1.
    let url = try writeFluidVoiceFixture(aliasCount: limit, to: dir)

    await #expect(
      throws: ImportFileError.tooManyStoredValues(found: limit + 1, limit: limit)
    ) {
      _ = try await SmartImportSource(adapter: FixedFluidVoice(url: url)).loadCandidates()
    }
  }

  // MARK: - Pipeline: real adapter output through the real compare/commit boundary
  //
  // Proves the boundary this source relies on (§2.5.1 Hop 4, Hop 6), not just
  // the isolated unit tests that already cover `CustomWordsImportCompareEngine`
  // and `CustomWordsManager` generically. Every fixture here is real adapter
  // output run through `SmartImportSource.loadRawCandidates()`, then the real
  // `CustomWordsImportCompareEngine`/`CustomWordsManager` — never a
  // reimplementation of coalescing, collision detection, sanitization, or
  // persistence rules.

  /// Path substitution only: delegates decoding entirely to the real adapter.
  private struct PathSubstituteAdapter<Base: SmartImportAdapter>: SmartImportAdapter {
    let base: Base
    let url: URL
    var identifier: String { base.identifier }
    var displayName: String { base.displayName }
    var candidatePaths: [URL] { [url] }
    func loadWords(at url: URL) throws -> [SmartImportWord] {
      try base.loadWords(at: url)
    }
  }

  private func makeWisprFlowDatabase(in dir: URL, rows: String) throws -> URL {
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      \(rows)
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    return url
  }

  // MARK: 1. Superwhisper dual representation, preview

  @Test("Superwhisper's dual representation resolves to one .new comparison carrying the alias")
  func superwhisperDualRepresentationResolvesToOneNewComparisonWithAlias() async throws {
    // The founder-data-shaped end-to-end preview proof: a bare `vocabulary`
    // entry and a `replacements` entry resolving to the same canonical.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "vocabulary": ["Superwhisper"],
        "replacements": [ { "original": "super whisper", "with": "Superwhisper" } ] }
      """, to: dir, as: "settings.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: SuperwhisperAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 1)
    let comparison = try #require(comparisons.first)
    #expect(comparison.classification == .new)
    #expect(comparison.candidate.canonical == "Superwhisper")
    #expect(comparison.candidate.aliases == .supplied(["super whisper"]))
  }

  // MARK: 2-3. Canonicals differing only by one axis, preview

  @Test("canonicals differing only by internal whitespace stay two separate .new rows")
  func internalWhitespaceCanonicalsStayTwoSeparateNewRows() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "Claude Code" }, { "text": "Claude  Code" } ] }"#, to: dir,
      as: "v.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: FluidVoiceAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 2)
    #expect(comparisons.allSatisfy { $0.classification == .new })
    #expect(comparisons.map { $0.candidate.canonical } == ["Claude Code", "Claude  Code"])
  }

  @Test("canonicals differing only by Unicode composition coalesce to one .new row")
  func unicodeCompositionCanonicalsCoalesceToOneNewRow() async throws {
    // Corrected, Build Chunk 2 (2026-07-22): the approved plan originally
    // claimed this axis "stays separate" like internal whitespace. It does
    // not — Swift's own `String` equality is Unicode-canonical-equivalence-
    // aware regardless of `persistenceKey`'s trim+lowercase transform, so
    // these coalesce under both the old and new matching key. Verified
    // against the real `coalesceDuplicates`, escalated, and the plan
    // corrected (docs/audits/2026-07-22-issue1706-chunk2-nfc-nfd-escalation.txt).
    let nfc = "caf\u{e9}"
    let nfd = "cafe\u{301}"
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "terms": [ { "text": "\#(nfc)" }, { "text": "\#(nfd)" } ] }"#, to: dir, as: "v.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: FluidVoiceAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 1)
    let comparison = try #require(comparisons.first)
    #expect(comparison.classification == .new)
    // First row's spelling wins. Unicode scalars, not `String ==`, because
    // canonical-equivalent strings compare equal regardless of composition.
    #expect(Array(comparison.candidate.canonical.unicodeScalars) == Array(nfc.unicodeScalars))
  }

  // MARK: 4-6. Duplicate canonicals with aliases differing by one axis, preview

  @Test("duplicate canonicals with aliases differing only by case coalesce to one alias")
  func duplicateCanonicalsWithCaseOnlyAliasesCoalesce() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "terms": [ { "text": "Kubernetes", "aliases": ["k8s"] },
                    { "text": "Kubernetes", "aliases": ["K8S"] } ] }
      """, to: dir, as: "v.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: FluidVoiceAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 1)
    let comparison = try #require(comparisons.first)
    // First spelling wins on the union.
    #expect(comparison.candidate.aliases == .supplied(["k8s"]))
  }

  @Test("duplicate canonicals with aliases differing only by internal whitespace both survive")
  func duplicateCanonicalsWithWhitespaceOnlyAliasesBothSurvive() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "terms": [ { "text": "Kubernetes", "aliases": ["Claude Code"] },
                    { "text": "Kubernetes", "aliases": ["Claude  Code"] } ] }
      """, to: dir, as: "v.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: FluidVoiceAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 1)
    let comparison = try #require(comparisons.first)
    #expect(comparison.candidate.aliases == .supplied(["Claude Code", "Claude  Code"]))
  }

  @Test("duplicate canonicals with aliases differing only by Unicode composition coalesce")
  func duplicateCanonicalsWithUnicodeCompositionAliasesCoalesce() async throws {
    // Corrected, Build Chunk 2 (2026-07-22) — same root cause as the canonical
    // case above: Swift's `String` equality merges NFC/NFD regardless of
    // `persistenceKey`'s transform, so these coalesce to ONE alias, not two.
    let nfc = "caf\u{e9}"
    let nfd = "cafe\u{301}"
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "terms": [ { "text": "Kubernetes", "aliases": ["\(nfc)"] },
                    { "text": "Kubernetes", "aliases": ["\(nfd)"] } ] }
      """, to: dir, as: "v.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: FluidVoiceAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 1)
    let comparison = try #require(comparisons.first)
    guard case .supplied(let aliases) = comparison.candidate.aliases else {
      Issue.record("expected .supplied aliases, got \(comparison.candidate.aliases)")
      return
    }
    #expect(aliases.count == 1)
    if let firstAlias = aliases.first {
      #expect(Array(firstAlias.unicodeScalars) == Array(nfc.unicodeScalars))
    }
  }

  // MARK: 7-8. Self-referential alias: preview carries it, commit removes it

  @Test("a self-referential alias survives preview unremoved and uncollided")
  func selfReferentialAliasSurvivesPreview() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(
      in: dir, rows: "INSERT INTO Dictionary VALUES ('1','Superwhisper','Superwhisper',0,0);")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    let comparison = try #require(comparisons.first)
    #expect(comparison.classification == .new)
    #expect(comparison.candidate.aliases == .supplied(["Superwhisper"]))
    #expect(comparison.collidingAliases.isEmpty)
  }

  @Test("the self-referential candidate commits with no alias and no reported drop")
  @MainActor
  func selfReferentialAliasCommitsWithoutAliasAndWithoutReportedDrop() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = try makeWisprFlowDatabase(
      in: dir, rows: "INSERT INTO Dictionary VALUES ('1','Superwhisper','Superwhisper',0,0);")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowAdapter(), url: dbURL))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)
    let additions = comparisons.map(\.candidate)

    let manager = CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json"))
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: live),
        additions: additions, replacements: []),
      to: &live)

    let persisted = try #require(live.first { $0.canonical == "Superwhisper" })
    #expect(persisted.aliases.isEmpty)
    #expect(receipt.droppedAliasCollisions.isEmpty)
  }

  // MARK: 9. D15: an existing-library match never receives the imported alias

  @Test("an existing-library match classifies exact and receives no imported alias")
  func existingLibraryMatchClassifiesExactAndReceivesNoAlias() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      """
      { "vocabulary": ["Superwhisper"],
        "replacements": [ { "original": "super whisper", "with": "Superwhisper" } ] }
      """, to: dir, as: "settings.json")

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: SuperwhisperAdapter(), url: url))
    let batch = try await source.loadRawCandidates()

    let existing = CustomWord(canonical: "Superwhisper")
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [existing], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 1)
    let comparison = try #require(comparisons.first)
    #expect(comparison.classification == .exact(existing: existing))
    // D15: an .exact match is Skip-only. The existing word is a local value
    // untouched by comparison, and this row is never eligible for a commit
    // plan's additions/replacements (§2.2) — nothing here can persist it.
    #expect(existing.aliases.isEmpty)
    // The incoming alias is still CARRIED on the comparison, not discarded —
    // D15 is enforced by never committing this row, not by stripping data.
    #expect(comparison.candidate.aliases == .supplied(["super whisper"]))
  }

  // MARK: 10-11. Two canonicals sharing one alias: deterministic first owner

  @Test(
    "two different canonicals sharing one alias: the ID-sorted earlier candidate has no collisions"
  )
  func twoCanonicalsShareOneAliasEarlierWinsByStoredID() async throws {
    // IDs inserted in the OPPOSITE order from `id` on purpose, so `ORDER BY id
    // COLLATE BINARY ASC` — not insertion order — determines who claims the
    // shared alias first.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(
      in: dir,
      rows: """
        INSERT INTO Dictionary VALUES ('z','annie','Annabelle',0,0);
        INSERT INTO Dictionary VALUES ('a','annie','Anika',0,0);
        """)

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowAdapter(), url: url))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)

    #expect(comparisons.count == 2)
    let earlier = try #require(comparisons.first { $0.candidate.canonical == "Anika" })
    let later = try #require(comparisons.first { $0.candidate.canonical == "Annabelle" })
    #expect(earlier.collidingAliases.isEmpty)
    #expect(
      later.collidingAliases == [
        CustomWordsImportAliasCollision(alias: "annie", heldBy: earlier.candidate.id)
      ])
  }

  @Test("committing the shared-alias batch keeps the earlier canonical's alias, drops the later")
  @MainActor
  func sharedAliasBatchCommitKeepsEarlierDropsLaterWithReceipt() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = try makeWisprFlowDatabase(
      in: dir,
      rows: """
        INSERT INTO Dictionary VALUES ('z','annie','Annabelle',0,0);
        INSERT INTO Dictionary VALUES ('a','annie','Anika',0,0);
        """)

    let source = SmartImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowAdapter(), url: dbURL))
    let batch = try await source.loadRawCandidates()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: batch.candidates, against: [], fuzzyPolicy: .disabled)
    // Plan order preserved: both are `.new`, so both become additions in the
    // same order the comparison produced them.
    let additions = comparisons.map(\.candidate)

    let manager = CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json"))
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: live),
        additions: additions, replacements: []),
      to: &live)

    let anika = try #require(live.first { $0.canonical == "Anika" })
    let annabelle = try #require(live.first { $0.canonical == "Annabelle" })
    #expect(anika.aliases == ["annie"])
    #expect(annabelle.aliases.isEmpty)
    #expect(
      receipt.droppedAliasCollisions == [
        CustomWordsImportAliasCollision(alias: "annie", heldBy: anika.id)
      ])
  }
}
