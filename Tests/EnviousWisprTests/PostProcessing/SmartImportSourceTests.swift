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
      try FluidVoiceAdapter().loadWords(at: url).words
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
    #expect(try FluidVoiceAdapter().loadWords(at: url).words.isEmpty)
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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

    #expect(
      try SuperwhisperAdapter().loadWords(at: url).words == [SmartImportWord(canonical: "Saurabh")])
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
      try SuperwhisperAdapter().loadWords(at: url).words
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
      try SuperwhisperAdapter().loadWords(at: url).words == [
        SmartImportWord(canonical: "Superwhisper")
      ])
  }

  @Test("a Superwhisper replacement missing with is dropped, as today")
  func superwhisperReplacementMissingWithIsDropped() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "replacements": [ { "id": "A", "original": "super whisper" } ] }"#, to: dir,
      as: "settings.json")

    #expect(try SuperwhisperAdapter().loadWords(at: url).words.isEmpty)
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

    #expect(try SuperwhisperAdapter().loadWords(at: url).words.isEmpty)
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
    #expect(try SuperwhisperAdapter().loadWords(at: url).words.isEmpty)
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

    let words = try WisprFlowAdapter().loadWords(at: url).words
    #expect(!words.map(\.canonical).contains("deleted word"))
  }

  @Test("Wispr Flow skips text-expansion snippets")
  func wisprFlowFiltersSnippets() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    // Snippets are a different feature, not vocabulary.
    let words = try WisprFlowAdapter().loadWords(at: url).words.map(\.canonical)
    #expect(!words.contains("my long signature"))
    #expect(!words.contains("sig"))
  }

  @Test("Wispr Flow takes the corrected spelling as canonical and the phrase as its alias")
  func wisprFlowPrefersReplacementOverPhraseAndCarriesPhraseAsAlias() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeWisprFlowDatabase(in: dir)

    let words = try WisprFlowAdapter().loadWords(at: url).words
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
    let words = try WisprFlowAdapter().loadWords(at: url).words
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

    let words = try WisprFlowAdapter().loadWords(at: url).words
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

    let words = try WisprFlowAdapter().loadWords(at: url).words
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

    let canonicals = try WisprFlowAdapter().loadWords(at: url).words.map(\.canonical)
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

    let words = try WisprFlowAdapter().loadWords(at: url).words
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        SmartImportReadResult(words: [])
      }
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
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

  @Test("the registry ships every app whose store has been read on a live install")
  func registryShipsOnlyVerifiedAdapters() {
    let ids = SmartImportRegistry.v1.adapters.map(\.identifier)
    #expect(
      ids.sorted() == [
        "fluidvoice", "handy", "juno", "spokenly", "superwhisper", "typewhisper", "vox",
        "wispr-flow",
      ])
    // Identifiers drive adapter lookup and label the import batch, so a
    // collision would make the registry ambiguous. They reach no telemetry:
    // `CustomWordsImportBatch.sourceID` has no consumer (#2052).
    #expect(Set(ids).count == ids.count)
  }

  // MARK: - Handy

  private func handyStore(_ json: String, in dir: URL) throws -> URL {
    try write(json, to: dir, as: "settings_store.json")
  }

  @Test("Handy words import from the nested key with no alias")
  func handyWordsImport() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try handyStore(
      #"{ "settings": { "custom_words": ["Handyfold", "Quixotropic"], "word_correction_threshold": 0.18 } }"#,
      in: dir)

    let result = try HandyAdapter().loadWords(at: url)
    #expect(
      result.words == [
        SmartImportWord(canonical: "Handyfold"), SmartImportWord(canonical: "Quixotropic"),
      ])
    // Handy excludes nothing of its own: it ships no seed vocabulary, verified
    // by letting 0.9.5 author a store from scratch (it wrote `[]`).
    #expect(result.excludedCount == 0)
  }

  @Test("a top-level custom_words is not Handy's key and is never imported")
  func handyIgnoresTopLevelKey() throws {
    // The trap #2052 names: the list lives one level down, so a top-level read
    // looks like "this user has no custom words" rather than like a path bug.
    // Empty is the right answer here, not a refusal — Handy itself defaults a
    // missing `settings` object to an empty vocabulary.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try handyStore(#"{ "custom_words": ["NeverImportMe"] }"#, in: dir)
    #expect(try HandyAdapter().loadWords(at: url).words.isEmpty)
  }

  @Test("Handy's own missing-field defaults are an empty vocabulary, not a damaged store")
  func handyMissingFieldsAreEmpty() throws {
    // Verified in cjpais/Handy at commit db003f38, src-tauri/src/settings.rs:
    // container-level #[serde(default)] on AppSettings (338-340), field-level
    // on custom_words (398-399), and the test empty_store_parses_with_defaults
    // (1140). Refusing these would tell the user their store is unreadable
    // while Handy opens the same file and shows them an empty list.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    for (label, json) in [
      ("absent settings", #"{ "other": 1 }"#),
      ("absent custom_words", #"{ "settings": { "debug_mode": false } }"#),
      ("empty array", #"{ "settings": { "custom_words": [] } }"#),
      // Null takes a different route to the same place: Vec<String> cannot
      // deserialize from null, so Handy's strict decode fails and its
      // salvage_settings (1002) drops the field and keeps the default.
      ("explicit null", #"{ "settings": { "custom_words": null } }"#),
    ] {
      let url = try handyStore(json, in: dir)
      #expect(try HandyAdapter().loadWords(at: url).words.isEmpty, "\(label) should read as empty")
    }
  }

  @Test("a Handy word list of the wrong type refuses the whole import")
  func handyWrongTypeRefuses() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    for json in [
      #"{ "settings": { "custom_words": ["Quorvex", 7] } }"#,
      #"{ "settings": { "custom_words": { "a": "b" } } }"#,
      #"{ "settings": { "custom_words": "Quorvex" } }"#,
      #"{ "settings": "not an object" }"#,
      #"{ not json at all "#,
    ] {
      let url = try handyStore(json, in: dir)
      #expect(throws: SmartImportError.unreadable("Handy")) {
        _ = try HandyAdapter().loadWords(at: url)
      }
    }
  }

  @Test("an unrelated wrongly-typed Handy setting does not block the word list")
  func handyUnrelatedPoisonedFieldStillImports() throws {
    // Handy salvages such a document field by field and keeps valid vocabulary
    // out of it — its own salvage_drops_only_wrong_typed_fields (1293) puts
    // exactly this `paste_delay_ms` in and still asserts the words survive. A
    // reader that decoded Handy's WHOLE settings object would refuse a file
    // Handy reads happily; ours decodes two keys, so it matches by design.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try handyStore(
      #"{ "settings": { "custom_words": ["Handyfold"], "paste_delay_ms": "sixty" } }"#, in: dir)
    #expect(try HandyAdapter().loadWords(at: url).words.map(\.canonical) == ["Handyfold"])
  }

  @Test("Handy multi-word and non-ASCII entries survive unchanged")
  func handyPreservesEntriesVerbatim() throws {
    // Handy's own Add button refuses a space and accepts an umlaut (both
    // measured on 0.9.5). We inherit neither judgement: the file is the
    // contract, our shared text policy decides what is storable, and a
    // hand-edited file may legitimately hold a phrase.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try handyStore(
      #"{ "settings": { "custom_words": ["Envious Labs", "Müller"] } }"#, in: dir)

    let words = try HandyAdapter().loadWords(at: url).words
    #expect(words.map(\.canonical) == ["Envious Labs", "Müller"])
    // Compared by scalars: a normalization slip would still pass a == on the
    // rendered string in some fonts.
    #expect(Array(words[1].canonical.unicodeScalars) == Array("Müller".unicodeScalars))
  }

  @Test("an unknown Handy schema version still imports, and only a moved key reads as empty")
  func handyForwardCompatibility() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Fail-open: a future version we do not recognise must not break an import
    // whose word list is still exactly where we look for it.
    let future = try handyStore(
      #"{ "settings": { "settings_schema_version": 99, "custom_words": ["Zephyrine"], "brand_new_key": {} } }"#,
      in: dir)
    #expect(try HandyAdapter().loadWords(at: future).words.map(\.canonical) == ["Zephyrine"])

    // ACCEPTED LIMIT, frozen here so nobody "fixes" it into a refusal without
    // reading why: a future Handy that MOVED the key is indistinguishable from
    // a user with no custom words, because Handy defines a missing key AS an
    // empty vocabulary. Refusing this shape would refuse today's legitimate
    // partial stores to defend against a schema nobody has seen (#2052).
    let moved = try handyStore(
      #"{ "settings": { "settings_schema_version": 99, "vocabulary": ["Zephyrine"] } }"#, in: dir)
    #expect(try HandyAdapter().loadWords(at: moved).words.isEmpty)
  }

  @Test("a Handy store caught mid-rewrite is re-read rather than refused or misread")
  func handyRetriesATornRead() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try handyStore(#"{ "settings": { "custom_words": ["Handyfold"] } }"#, in: dir)

    // Handy rewrites this file in place, so a reader can catch the truncation
    // window: measured 2 zero-byte reads in 604,959 across three writes. Two
    // EMPTY reads agree perfectly, which is why acceptance must live inside the
    // retry — outside it, this exact sequence would consume the whole budget on
    // attempt one and throw.
    nonisolated(unsafe) var reads = 0
    let torn = HandyAdapter(readData: { real in
      reads += 1
      if reads <= 2 { return Data() }
      return try Data(contentsOf: real)
    })
    #expect(try torn.loadWords(at: url).words.map(\.canonical) == ["Handyfold"])
    // Exactly two acquisitions: the first pair agreed but did not decode, the
    // second pair did. Without this the test would pass against an adapter that
    // never entered the recovery path at all.
    #expect(reads == 4)

    // Two-way control: a reader that is torn forever refuses, so the success
    // above is the recovery working and not the injection being ignored.
    nonisolated(unsafe) var alwaysTorn = 0
    let hopeless = HandyAdapter(readData: { _ in
      alwaysTorn += 1
      return Data()
    })
    #expect(throws: SmartImportError.unreadable("Handy")) {
      _ = try hopeless.loadWords(at: url)
    }
    #expect(alwaysTorn == 6, "three acquisitions × two reads")
  }

  @Test("Handy bytes that disagree between the two reads are never spliced into a word list")
  func handyRefusesDisagreeingReads() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try handyStore(#"{ "settings": { "custom_words": ["Handyfold"] } }"#, in: dir)

    // Both reads decode fine and describe DIFFERENT vocabularies. Decoding
    // alone cannot catch this, which is the whole reason acceptance is not the
    // agreement check.
    nonisolated(unsafe) var flip = 0
    let unstable = HandyAdapter(readData: { _ in
      flip += 1
      let word = flip % 2 == 0 ? "Second" : "First"
      return Data(#"{ "settings": { "custom_words": ["\#(word)"] } }"#.utf8)
    })
    #expect(throws: SmartImportError.unreadable("Handy")) {
      _ = try unstable.loadWords(at: url)
    }
  }

  // MARK: - Shared SQLite reader

  private func makeReaderDatabase(in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("reader.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(
      sqlite3_exec(
        db,
        """
        CREATE TABLE T (a VARCHAR, b VARCHAR);
        INSERT INTO T VALUES ('one', NULL);
        INSERT INTO T VALUES ('two', 'Two');
        """, nil, nil, nil) == SQLITE_OK)
    return url
  }

  @Test("a row mapper returning nil is an exclusion; a mapper that throws is a failure")
  func readerDistinguishesExclusionFromFailure() throws {
    // These are different things and an earlier draft conflated them: nil
    // means "this row is not vocabulary", a throw means "this database is not
    // what we think it is".
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeReaderDatabase(in: dir)

    let excluded = try SmartImportSQLiteReader.read(
      uri: "file:\(url.path)?mode=ro", sql: "SELECT a, b FROM T ORDER BY a", appName: "Probe"
    ) { statement in
      let a = try SmartImportSQLiteReader.requiredText(statement, 0, "Probe")
      return a == "one" ? nil : SmartImportWord(canonical: a)
    }
    #expect(excluded.words.map(\.canonical) == ["two"])
    #expect(excluded.excludedCount == 1)

    struct Boom: Error {}
    #expect(throws: Boom.self) {
      _ = try SmartImportSQLiteReader.read(
        uri: "file:\(url.path)?mode=ro", sql: "SELECT a, b FROM T", appName: "Probe"
      ) { _ in throw Boom() }
    }
  }

  @Test("afterRowsRead runs while the connection is still open, and its throw refuses the read")
  func readerRunsValidationBeforeCleanup() throws {
    // Wispr Flow's post-read sidecar recheck sits exactly here. Running it
    // after the reader returned would move it past finalize and close and
    // widen the window it exists to close.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try makeReaderDatabase(in: dir)

    struct Refused: Error {}
    var sawRows = false
    #expect(throws: Refused.self) {
      _ = try SmartImportSQLiteReader.read(
        uri: "file:\(url.path)?mode=ro", sql: "SELECT a, b FROM T", appName: "Probe",
        mapRow: { statement in
          sawRows = true
          return SmartImportWord(
            canonical: try SmartImportSQLiteReader.requiredText(statement, 0, "Probe"))
        },
        afterRowsRead: { throw Refused() })
    }
    // Ordering: every row was stepped BEFORE validation ran, and no partial
    // result escaped.
    #expect(sawRows)
  }

  @Test("a result other than SQLITE_DONE refuses rather than returning a prefix")
  func readerRefusesAPartialRead() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("corrupt.sqlite")
    try Data("SQLite format 3\u{0}garbage-not-a-real-database".utf8).write(to: url)
    #expect(throws: SmartImportError.unreadable("Probe")) {
      _ = try SmartImportSQLiteReader.read(
        uri: "file:\(url.path)?mode=ro", sql: "SELECT a FROM T", appName: "Probe"
      ) { _ in nil }
    }
  }

  @Test("strict column reads refuse a NULL or wrongly-typed required value")
  func readerStrictColumnTypes() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("types.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(
      sqlite3_exec(
        db,
        """
        CREATE TABLE T (required VARCHAR, flag INTEGER);
        INSERT INTO T VALUES (NULL, 1);
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    #expect(throws: SmartImportError.unreadable("Probe")) {
      _ = try SmartImportSQLiteReader.read(
        uri: "file:\(url.path)?mode=ro", sql: "SELECT required, flag FROM T", appName: "Probe"
      ) { statement in
        SmartImportWord(
          canonical: try SmartImportSQLiteReader.requiredText(statement, 0, "Probe"))
      }
    }
  }

  // MARK: - TypeWhisper

  /// Builds a store with TypeWhisper's real Core Data column shape.
  ///
  /// Returns the url AND the open writer connection. The caller must keep that
  /// connection alive across the read and close it in a `defer`: closing it
  /// first CHECKPOINTS the WAL into the main file (measured — `-wal` drops to
  /// zero bytes), which destroys the very state the WAL tests exist to
  /// reproduce and quietly makes them pass against the design they exist to
  /// reject.
  private func makeTypeWhisperStore(
    in dir: URL, walOnlyRow: Bool
  ) throws -> (url: URL, writer: OpaquePointer?) {
    let url = dir.appendingPathComponent("dictionary.store")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
    let schema = """
      CREATE TABLE ZDICTIONARYENTRY (Z_PK INTEGER PRIMARY KEY, ZISENABLED INTEGER,
        ZCASESENSITIVE INTEGER, ZENTRYTYPE VARCHAR, ZORIGINAL VARCHAR, ZREPLACEMENT VARCHAR);
      INSERT INTO ZDICTIONARYENTRY VALUES (1,1,1,'term','Nuxt',NULL);
      INSERT INTO ZDICTIONARYENTRY VALUES (2,1,0,'correction','envius wisper','EnviousWispr');
      INSERT INTO ZDICTIONARYENTRY VALUES (3,0,0,'term','DisabledWord',NULL);
      INSERT INTO ZDICTIONARYENTRY VALUES (4,1,0,'snippet','sig','my long signature');
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    if walOnlyRow {
      // Force everything so far into the main file, then write one more row
      // that must stay in the WAL alone.
      sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
      sqlite3_exec(
        db, "INSERT INTO ZDICTIONARYENTRY VALUES (5,1,0,'term','WalOnlyWord',NULL);",
        nil, nil, nil)
    }
    return (url, db)
  }

  @Test("TypeWhisper terms and corrections both map through one structural rule")
  func typeWhisperMapsBothEntryTypes() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(in: dir, walOnlyRow: false)
    defer { sqlite3_close(store.writer) }

    let result = try TypeWhisperAdapter().loadWords(at: store.url)
    // A `term` carries the word with no replacement; a `correction` carries
    // the wrong spelling and the right one.
    #expect(
      result.words == [
        SmartImportWord(canonical: "Nuxt", caseSensitive: .supplied(true)),
        SmartImportWord(
          canonical: "EnviousWispr", aliases: ["envius wisper"], caseSensitive: .supplied(false)),
      ])
    // The disabled row and the non-allowlisted `snippet` type.
    #expect(result.excludedCount == 2)
  }

  @Test("TypeWhisper never imports a row the user disabled, or a type we have not verified")
  func typeWhisperExcludesDisabledAndUnknownTypes() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(in: dir, walOnlyRow: false)
    defer { sqlite3_close(store.writer) }

    let canonicals = try TypeWhisperAdapter().loadWords(at: store.url).words.map(\.canonical)
    #expect(!canonicals.contains("DisabledWord"))
    // `snippet` is not in the allowlist. Text expansions are the one thing
    // Wispr Flow's adapter exists to exclude, and TypeWhisper ships a separate
    // snippets store, so admitting an unverified type is the wrong direction.
    #expect(!canonicals.contains("my long signature"))
    #expect(!canonicals.contains("sig"))
  }

  @Test("rows that live only in an un-checkpointed WAL still come across")
  func typeWhisperReadsRowsHeldOnlyInTheWAL() throws {
    // The regression test for the defect that redesigned this adapter.
    // TypeWhisper never checkpoints: quit the app and the WAL still holds rows
    // the main file does not have. Reading the main file `immutable=1` — which
    // skips WAL processing — returned 36 rows against a true 38 on the real
    // store, silently.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(in: dir, walOnlyRow: true)
    defer { sqlite3_close(store.writer) }

    // Precondition, so a pass means something: the main file alone genuinely
    // cannot see the WAL-only row. Without this the test would still pass
    // against the design it exists to reject.
    let mainOnly = dir.appendingPathComponent("main-only.store")
    try FileManager.default.copyItem(at: store.url, to: mainOnly)
    var probe: OpaquePointer?
    #expect(
      sqlite3_open_v2(
        "file:\(mainOnly.path)?immutable=1", &probe,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(
      sqlite3_prepare_v2(
        probe, "SELECT COUNT(*) FROM ZDICTIONARYENTRY WHERE ZORIGINAL = 'WalOnlyWord'", -1,
        &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 0)
    sqlite3_finalize(statement)
    sqlite3_close(probe)

    let canonicals = try TypeWhisperAdapter().loadWords(at: store.url).words.map(\.canonical)
    #expect(canonicals.contains("WalOnlyWord"))
  }

  @Test("reading TypeWhisper leaves every byte of its store untouched")
  func typeWhisperLeavesTheSourceUnchanged() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(in: dir, walOnlyRow: true)
    defer { sqlite3_close(store.writer) }

    func fingerprint() -> [String: Data] {
      var out: [String: Data] = [:]
      for suffix in ["", "-wal", "-shm"] {
        let path = store.url.path + suffix
        if let data = FileManager.default.contents(atPath: path) { out[suffix] = data }
      }
      return out
    }
    let before = fingerprint()
    _ = try TypeWhisperAdapter().loadWords(at: store.url)
    // Opening the SOURCE read-only also returns the right rows, but it
    // MODIFIES their `-shm`. Writing inside another app's data directory is
    // what #1686 removed, so the copy is the point rather than an optimisation.
    #expect(fingerprint() == before)
  }

  @Test("a snapshot whose parts change between the two passes is refused, not read")
  func typeWhisperRefusesAnUnstableSnapshot() throws {
    // Copying main and WAL one after another can capture two different
    // generations if the other app checkpoints in between — a snapshot that
    // never existed. The reader takes two passes and accepts only a matching
    // pair; this drives the injected byte reader so the branch is reachable
    // deterministically rather than by racing a real app.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(in: dir, walOnlyRow: true)
    defer { sqlite3_close(store.writer) }

    nonisolated(unsafe) var pass = 0
    let unstable = TypeWhisperAdapter(readPart: { url in
      guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
      guard url.lastPathComponent.hasSuffix("-wal") else { return data }
      // A different WAL on every read: no two passes can ever agree.
      pass += 1
      return data + Data("\(pass)".utf8)
    })
    #expect(throws: SmartImportError.unreadable("TypeWhisper")) {
      _ = try unstable.loadWords(at: store.url)
    }
    // Freezes the ATTEMPT COUNT, not just the outcome. The counter above has
    // always existed and was never asserted, so this test passed equally
    // against an adapter that gave up after one attempt — which is exactly the
    // regression moving this loop into the shared helper could cause (#2052).
    #expect(pass == 6, "three acquisitions × two complete reads each")

    // Positive counterpart: a reader that returns stable bytes succeeds, so
    // the refusal above is the instability and not the injection itself.
    let stable = TypeWhisperAdapter(readPart: { url in
      FileManager.default.contents(atPath: url.path)
    })
    #expect(try !stable.loadWords(at: store.url).words.isEmpty)
  }

  @Test("a TypeWhisper store whose columns hold the wrong types is refused, never guessed")
  func typeWhisperMalformedColumnsRefuse() throws {
    // SQLite columns are dynamically typed, so a schema that drifts under us
    // can hand back a BLOB where text belongs. Converting silently turns a
    // malformed source into plausible-looking words.
    //
    // A BLOB rather than an integer on purpose: `VARCHAR` carries TEXT
    // AFFINITY, so SQLite converts an integer literal to text on insert and
    // the column reads back as SQLITE_TEXT — an integer fixture here asserts
    // nothing at all. Affinity does not convert blobs.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("dictionary.store")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let schema = """
      CREATE TABLE ZDICTIONARYENTRY (Z_PK INTEGER PRIMARY KEY, ZISENABLED INTEGER,
        ZCASESENSITIVE INTEGER, ZENTRYTYPE VARCHAR, ZORIGINAL VARCHAR, ZREPLACEMENT VARCHAR);
      INSERT INTO ZDICTIONARYENTRY VALUES (1,1,1,'term',x'DEADBEEF',NULL);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    #expect(throws: SmartImportError.unreadable("TypeWhisper")) {
      _ = try TypeWhisperAdapter().loadWords(at: url)
    }
  }

  @Test("a TypeWhisper boolean outside 0 and 1 is refused rather than coerced")
  func typeWhisperNonBooleanFlagRefuses() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("dictionary.store")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let schema = """
      CREATE TABLE ZDICTIONARYENTRY (Z_PK INTEGER PRIMARY KEY, ZISENABLED INTEGER,
        ZCASESENSITIVE INTEGER, ZENTRYTYPE VARCHAR, ZORIGINAL VARCHAR, ZREPLACEMENT VARCHAR);
      INSERT INTO ZDICTIONARYENTRY VALUES (1,7,0,'term','Weird',NULL);
      """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    #expect(throws: SmartImportError.unreadable("TypeWhisper")) {
      _ = try TypeWhisperAdapter().loadWords(at: url)
    }
  }

  // MARK: - Spokenly

  private func spokenlyEnvelope(_ items: String) -> Data {
    Data(
      #"{"dirty":true,"serverVersion":0,"envelope":{"orderUpdatedAt":1,"items":[\#(items)],"tombstones":[{"id":"gone","deletedAt":2}]}}"#
        .utf8)
  }

  private func spokenlyItem(
    _ original: String, _ replacement: String, isRegex: Bool = false
  ) -> String {
    #"{"updatedAt":1,"value":{"id":"x","original":"\#(original)","replacement":"\#(replacement)","isRegex":\#(isRegex),"timing":"beforeAI","createdAt":1}}"#
  }

  @Test("a Spokenly replacement takes the corrected spelling and carries its original as the alias")
  func spokenlyMapsReplacementDirection() throws {
    let data = spokenlyEnvelope(spokenlyItem("hanooman", "Hanuman"))
    let result = try SpokenlyAdapter(readDomain: { _ in data })
      .loadWords(at: URL(fileURLWithPath: "/unused"))
    #expect(result.words == [SmartImportWord(canonical: "Hanuman", aliases: ["hanooman"])])
    #expect(result.excludedCount == 0)
  }

  @Test("a Spokenly regex rule is never imported as a word")
  func spokenlyRegexRuleIsExcluded() throws {
    // `original` holds a PATTERN, not a word — verified by creating one
    // through Spokenly's own Use Regular Expression checkbox.
    let data = spokenlyEnvelope(
      spokenlyItem("hanooman", "Hanuman") + ","
        + spokenlyItem(#"\\bk\\s*eight\\s*s\\b"#, "k8s", isRegex: true))
    let result = try SpokenlyAdapter(readDomain: { _ in data })
      .loadWords(at: URL(fileURLWithPath: "/unused"))
    #expect(result.words.map(\.canonical) == ["Hanuman"])
    #expect(result.excludedCount == 1)
  }

  @Test("a Spokenly rule with an empty replacement has no word in it")
  func spokenlyEmptyReplacementIsExcluded() throws {
    let data = spokenlyEnvelope(spokenlyItem("zylo fantric", "") + "," + spokenlyItem("q", "Q"))
    let result = try SpokenlyAdapter(readDomain: { _ in data })
      .loadWords(at: URL(fileURLWithPath: "/unused"))
    #expect(result.words.map(\.canonical) == ["Q"])
    #expect(result.excludedCount == 1)
  }

  @Test("a Spokenly entry the user deleted is already absent and cannot come back")
  func spokenlyTombstonesAreNotItems() throws {
    // Deleting REMOVES the entry from `items` and leaves only `{id, deletedAt}`
    // behind — verified by creating five and deleting one. This proves the
    // tombstone block is not read as a source of words: the fixture's tombstone
    // carries no text at all, and a hand-crafted item with the same id IS
    // returned, so the adapter keys on `items` and nothing else.
    let withoutItem = try SpokenlyAdapter(readDomain: { _ in self.spokenlyEnvelope("") })
      .loadWords(at: URL(fileURLWithPath: "/unused"))
    #expect(withoutItem.words.isEmpty)

    let resurrected =
      #"{"updatedAt":1,"value":{"id":"gone","original":"a","replacement":"Alive","isRegex":false,"timing":"beforeAI","createdAt":1}}"#
    let withItem = try SpokenlyAdapter(readDomain: { _ in self.spokenlyEnvelope(resurrected) })
      .loadWords(at: URL(fileURLWithPath: "/unused"))
    #expect(withItem.words.map(\.canonical) == ["Alive"])
  }

  @Test("Spokenly bytes that are not valid UTF-8 JSON refuse the whole import")
  func spokenlyMalformedBytesRefuse() throws {
    for bytes in [Data([0xFF, 0xFE, 0xFD]), Data("not json".utf8), Data("[1,2,3]".utf8)] {
      #expect(throws: SmartImportError.unreadable("Spokenly")) {
        _ = try SpokenlyAdapter(readDomain: { _ in bytes })
          .loadWords(at: URL(fileURLWithPath: "/unused"))
      }
    }
  }

  @Test("with no live value and only the App Store store, Spokenly says how to migrate")
  func spokenlyLegacyStoreAsksForMigration() throws {
    // "No live value" does not prove "App Store build", so this keys on WHICH
    // store was detected. Reading the pre-migration container copy directly
    // would import words the user stopped editing weeks ago and call it
    // success; naming the button they actually have does not.
    let container = URL(
      fileURLWithPath:
        "/Users/x/Library/Containers/app.spokenly/Data/Library/Preferences/app.spokenly.plist")
    #expect(throws: SmartImportError.legacyMigrationRequired("Spokenly")) {
      _ = try SpokenlyAdapter(readDomain: { _ in nil }).loadWords(at: container)
    }

    // Positive counterpart: the CURRENT store with nothing live is an ordinary
    // not-found, not a migration instruction.
    let outer = URL(fileURLWithPath: "/Users/x/Library/Preferences/app.spokenly.plist")
    #expect(throws: SmartImportError.appNotFound("Spokenly")) {
      _ = try SpokenlyAdapter(readDomain: { _ in nil }).loadWords(at: outer)
    }
  }

  @Test("a live value always wins over the legacy store")
  func spokenlyLiveValueWinsOverLegacy() throws {
    // Even when the detected path IS the container, a live domain value is
    // decoded rather than the legacy bytes — so a migrated user can never be
    // served the stale copy.
    let container = URL(
      fileURLWithPath:
        "/Users/x/Library/Containers/app.spokenly/Data/Library/Preferences/app.spokenly.plist")
    let data = spokenlyEnvelope(spokenlyItem("q", "Quorvex"))
    let words = try SpokenlyAdapter(readDomain: { _ in data }).loadWords(at: container).words
    #expect(words.map(\.canonical) == ["Quorvex"])
  }

  // MARK: - Vox

  @Test("Vox terms import with no alias")
  func voxTermsImport() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "dictionary": ["Zylophantric", "K8s dashboard"], "context": "I am a founder." }"#,
      to: dir, as: "vox-settings.json")

    let result = try VoxAdapter().loadWords(at: url)
    #expect(
      result.words == [
        SmartImportWord(canonical: "Zylophantric"), SmartImportWord(canonical: "K8s dashboard"),
      ])
    #expect(result.excludedCount == 0)
  }

  @Test("Vox's personal context paragraph is never imported as a word")
  func voxContextIsNotVocabulary() throws {
    // `context` is a paragraph the user writes about themselves for Vox's
    // polish step. Importing it would drop a whole sentence into the
    // custom-words list.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
      #"{ "dictionary": ["Quorvex"], "context": "I work on billing at Acme." }"#,
      to: dir, as: "vox-settings.json")

    let words = try VoxAdapter().loadWords(at: url).words
    #expect(words.map(\.canonical) == ["Quorvex"])
  }

  @Test("a Vox file with no dictionary key is a fresh install, not a failure")
  func voxMissingDictionaryKeyIsEmpty() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "hotkey": "Cmd+Alt+Period" }"#, to: dir, as: "vox-settings.json")
    #expect(try VoxAdapter().loadWords(at: url).words.isEmpty)
  }

  @Test("a Vox dictionary present as a non-array refuses the whole import")
  func voxNonArrayDictionaryRefuses() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "dictionary": "Quorvex" }"#, to: dir, as: "vox-settings.json")
    #expect(throws: SmartImportError.unreadable("Vox")) {
      _ = try VoxAdapter().loadWords(at: url)
    }
  }

  @Test("a non-string element inside the Vox dictionary refuses the whole import")
  func voxNonStringElementRefuses() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(#"{ "dictionary": ["Quorvex", 7] }"#, to: dir, as: "vox-settings.json")
    #expect(throws: SmartImportError.unreadable("Vox")) {
      _ = try VoxAdapter().loadWords(at: url)
    }
  }

  // MARK: - Juno

  private func junoLexicon(_ rows: String, in dir: URL) throws -> URL {
    try write(rows, to: dir, as: "lexicon.json")
  }

  @Test("Juno imports only vocabulary the user authored, never its shipped seeds")
  func junoKeepsOnlyUserAuthoredEntries() throws {
    // Measured on a real install: 400 of 401 rows are Juno's own seed list,
    // including bare lowercase words like `accessibility` that would actively
    // bias transcription if imported as custom words.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try junoLexicon(
      """
      [{"term":"Saurabh","canonical_form":"Saurabh","aliases":[],"source":"user_edit"},
       {"term":"accessibility","canonical_form":"accessibility","aliases":[],
        "source":"seed_promotion"},
       {"term":"Chrome","canonical_form":"Chrome","aliases":[],"source":"seed_promotion"}]
      """, in: dir)

    let result = try JunoAdapter().loadWords(at: url)
    #expect(result.words.map(\.canonical) == ["Saurabh"])
    #expect(result.excludedCount == 2)
  }

  @Test("an unrecognised Juno provenance is refused, not admitted")
  func junoUnknownProvenanceIsRefused() throws {
    // The allowlist's own two-way control. A denylist on the seed value would
    // ADMIT this row, and an unseen provenance is far more likely to be
    // another machine-generated list than something the user typed.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try junoLexicon(
      """
      [{"term":"Kept","canonical_form":"Kept","aliases":[],"source":"user_edit"},
       {"term":"Learned","canonical_form":"Learned","aliases":[],"source":"auto_learned"},
       {"term":"NoSource","canonical_form":"NoSource","aliases":[]},
       {"term":"NullSource","canonical_form":"NullSource","aliases":[],"source":null}]
      """, in: dir)

    let result = try JunoAdapter().loadWords(at: url)
    #expect(result.words.map(\.canonical) == ["Kept"])
    #expect(result.excludedCount == 3)
  }

  @Test("Juno prefers the canonical form over the key it is filed under")
  func junoPrefersCanonicalForm() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try junoLexicon(
      """
      [{"term":"apple silicon","canonical_form":"Apple Silicon",
        "aliases":["apple silicon chip"],"source":"user_edit"},
       {"term":"Fallback","canonical_form":"   ","aliases":[],"source":"user_edit"}]
      """, in: dir)

    let words = try JunoAdapter().loadWords(at: url).words
    #expect(
      words[0] == SmartImportWord(canonical: "Apple Silicon", aliases: ["apple silicon chip"]))
    // A blank canonical form falls back to the term rather than dropping the row.
    #expect(words[1].canonical == "Fallback")
  }

  @Test("a Juno lexicon that is not an array refuses the whole import")
  func junoNonArrayRefuses() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try junoLexicon(#"{"term":"Saurabh"}"#, in: dir)
    #expect(throws: SmartImportError.unreadable("Juno")) {
      _ = try JunoAdapter().loadWords(at: url)
    }
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
      try FluidVoiceAdapter().loadWords(at: url).words == [SmartImportWord(canonical: "Kubernetes")]
    )
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
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        // One past the ceiling, and all identical — would look like a tiny
        // successful import if this layer merged duplicates, which it no
        // longer does.
        SmartImportReadResult(
          words: Array(
            repeating: SmartImportWord(canonical: "duplicate"),
            count: CustomWordsImportLimits.maximumCandidates + 1))
      }
    }

    // Deliberately NOT `ImportFileError.tooManyWords` since #1773: its copy
    // says "That file" and "split it into smaller files", which is false for a
    // competitor's database, and it would call deleted rows and snippets
    // "words".
    await #expect(
      throws: SmartImportError.tooManySourceEntries(
        appName: "Flood", limit: CustomWordsImportLimits.maximumCandidates)
    ) {
      _ = try await SmartImportSource(adapter: Flood()).loadCandidates()
    }
  }

  @Test("the ceiling counts rows the adapter excluded, not just the survivors")
  func ceilingCountsScannedRowsNotSurvivors() async throws {
    // Before #1773 the adapters filtered in SQL, so the ceiling only ever saw
    // survivors: a source that refused 25,001 rows down to one looked like a
    // one-row import. Counting what was SCANNED closes that.
    struct MostlyExcluded: SmartImportAdapter {
      let identifier = "mostly-excluded"
      let displayName = "MostlyExcluded"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        SmartImportReadResult(
          words: [SmartImportWord(canonical: "survivor")],
          excludedCount: CustomWordsImportLimits.maximumCandidates)
      }
    }
    await #expect(
      throws: SmartImportError.tooManySourceEntries(
        appName: "MostlyExcluded", limit: CustomWordsImportLimits.maximumCandidates)
    ) {
      _ = try await SmartImportSource(adapter: MostlyExcluded()).loadCandidates()
    }
  }

  @Test("a source that refused every row says so instead of claiming it was empty")
  func allExcludedEmitsACountedNotice() async throws {
    // "No words were found" is a false statement to a Juno user whose 401
    // entries were all built-in seeds. The notice is what lets the result
    // screen tell the two apart, and it carries a COUNT only.
    struct AllExcluded: SmartImportAdapter {
      let identifier = "all-excluded"
      let displayName = "AllExcluded"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        SmartImportReadResult(words: [], excludedCount: 401)
      }
    }
    let batch = try await SmartImportSource(adapter: AllExcluded()).loadCandidates()
    #expect(batch.candidates.isEmpty)
    #expect(batch.notices == [.incompatibleSourceEntriesExcluded(count: 401)])
  }

  @Test("a genuinely empty source emits no notice, so it still reads as empty")
  func genuinelyEmptySourceEmitsNoNotice() async throws {
    // The positive counterpart: without this, any empty result would claim
    // entries had been refused.
    struct Empty: SmartImportAdapter {
      let identifier = "empty"
      let displayName = "Empty"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        SmartImportReadResult(words: [])
      }
    }
    let batch = try await SmartImportSource(adapter: Empty()).loadCandidates()
    #expect(batch.candidates.isEmpty)
    #expect(batch.notices.isEmpty)
  }

  @Test("blank canonicals dropped by shared normalization count as exclusions too")
  func blankCanonicalsCountTowardTheNotice() async throws {
    // Otherwise a source whose every row normalizes to blank still reports
    // "no words found" — the same untruth one layer further down.
    struct AllBlank: SmartImportAdapter {
      let identifier = "all-blank"
      let displayName = "AllBlank"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        SmartImportReadResult(words: [SmartImportWord(canonical: "   ")])
      }
    }
    let batch = try await SmartImportSource(adapter: AllBlank()).loadCandidates()
    #expect(batch.notices == [.incompatibleSourceEntriesExcluded(count: 1)])
  }

  @Test("TypeWhisper case sensitivity reaches the candidate in both directions")
  func caseSensitivityTravelsToTheCandidate() async throws {
    // A one-way test passes for an implementation that returns a constant.
    struct Fixed: SmartImportAdapter {
      let identifier = "typewhisper"
      let displayName = "TypeWhisper"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadWords(at url: URL) throws -> SmartImportReadResult {
        SmartImportReadResult(
          words: [
            SmartImportWord(canonical: "Sensitive", caseSensitive: .supplied(true)),
            SmartImportWord(canonical: "Insensitive", caseSensitive: .supplied(false)),
            SmartImportWord(canonical: "Unstated"),
          ])
      }
    }
    let batch = try await SmartImportSource(adapter: Fixed()).loadCandidates()
    #expect(
      batch.candidates.map(\.caseSensitive) == [.supplied(true), .supplied(false), .unspecified])
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
    func loadWords(at url: URL) throws -> SmartImportReadResult {
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

  @Test("blank/whitespace-only alias padding does not count against the stored-value ceiling")
  func blankAliasPaddingDoesNotCountAgainstStoredValueCeiling() async throws {
    // Fixed, GitHub cloud review (PR #1748): the ceiling used to count raw,
    // pre-trim aliases, so a term padded with blank slots that were always
    // going to be dropped could trip the ceiling and refuse an import that
    // never actually approached the real stored-surface limit.
    let limit = CustomWordsImportLimits.maximumExportedStoredValues
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Far more raw aliases than the limit, every one blank — the trimmed
    // surface is just the one canonical.
    let aliasesJSON = (0..<(limit + 100)).map { _ in "\"   \"" }.joined(separator: ",")
    let url = try write(
      #"{ "terms": [ { "text": "Word", "aliases": [\#(aliasesJSON)] } ] }"#, to: dir, as: "v.json")

    let batch = try await SmartImportSource(adapter: FixedFluidVoice(url: url)).loadCandidates()
    let candidate = try #require(batch.candidates.first)
    #expect(candidate.canonical == "Word")
    #expect(candidate.aliases == .unspecified)
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
    func loadWords(at url: URL) throws -> SmartImportReadResult {
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
