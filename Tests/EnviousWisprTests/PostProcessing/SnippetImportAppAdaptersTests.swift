import EnviousWisprCore
import Foundation
import SQLite3
import Testing

@testable import EnviousWisprPostProcessing

/// #2997 PR-B: reading snippets out of Wispr Flow and TypeWhisper.
///
/// When one of these fails the user sees a snippet missing, a placeholder pasted as the
/// letters `{{DATE}}`, a deleted snippet resurrected, a count that lies, or a rival app's
/// store written to. Fixtures mirror each app's real on-disk shape (`RivalAppStoreFixtures`).
@Suite("Snippet import from another app (#2997)", .tags(.productOutcome))
struct SnippetImportAppAdaptersTests {

  /// Path substitution only: the real adapter does every read.
  private struct PathSubstituteAdapter<Base: SnippetImportAppAdapter>: SnippetImportAppAdapter {
    let base: Base
    let url: URL
    var identifier: String { base.identifier }
    var displayName: String { base.displayName }
    var candidatePaths: [URL] { [url] }
    func loadSnippets(at url: URL) throws -> SnippetImportRows {
      try base.loadSnippets(at: url)
    }
  }

  private static let typeWhisperSchema = """
    CREATE TABLE ZSNIPPET (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
      ZCASESENSITIVE INTEGER, ZISENABLED INTEGER, ZUSAGECOUNT INTEGER, ZCREATEDAT TIMESTAMP,
      ZUPDATEDAT TIMESTAMP, ZREPLACEMENT VARCHAR, ZTRIGGER VARCHAR, ZID BLOB);
    """

  /// A TypeWhisper row in column order. `replacement` nil writes SQL NULL.
  private static func typeWhisperRow(
    _ pk: Int, enabled: Bool, trigger: String, replacement: String?
  ) -> String {
    let text = replacement.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
    return
      "INSERT INTO ZSNIPPET VALUES (\(pk),1,1,0,\(enabled ? 1 : 0),0,NULL,NULL,\(text),"
      + "'\(trigger.replacingOccurrences(of: "'", with: "''"))',NULL);"
  }

  private func makeTypeWhisperStore(
    in dir: URL, rows: [String], walOnlyInsert: String? = nil
  ) throws -> (url: URL, writer: OpaquePointer?) {
    try RivalAppStoreFixtures.makeTypeWhisperStore(
      named: "snippets.store", in: dir,
      schema: Self.typeWhisperSchema + rows.joined(separator: "\n"),
      walOnlyInsert: walOnlyInsert)
  }

  // MARK: - Wispr Flow

  @Test("Wispr Flow snippet rows come across as trigger and verbatim text")
  func wisprFlowImportsSnippetRows() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
      in: dir,
      rows: """
        INSERT INTO Dictionary VALUES ('1','my email address','hello@example.com',0,1);
        INSERT INTO Dictionary VALUES ('2','sig','Thanks,
        Saurabh  ',0,1);
        """)

    let rows = try WisprFlowSnippetAdapter().loadSnippets(at: url)
    #expect(rows.excludedCount == 0)
    #expect(rows.candidates.map(\.trigger) == ["my email address", "sig"])
    // The text is delivered as the source held it: the embedded line break and the trailing
    // spaces survive, because trimming would change what gets pasted.
    #expect(rows.candidates.map(\.expansion) == ["hello@example.com", "Thanks,\nSaurabh  "])
  }

  @Test("Wispr Flow words, deleted snippets, and empty text are counted, never imported")
  func wisprFlowExcludesAndCountsIncompatibleRows() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Resurrecting a snippet the user deleted is the worst thing this adapter could do, and
    // it would look like a successful import. A word row belongs to the Dictionary import.
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
      in: dir,
      rows: """
        INSERT INTO Dictionary VALUES ('1','btw','by the way',0,0);
        INSERT INTO Dictionary VALUES ('2','old sig','gone',1,1);
        INSERT INTO Dictionary VALUES ('3','empty','   ',0,1);
        INSERT INTO Dictionary VALUES ('4','null text',NULL,0,1);
        INSERT INTO Dictionary VALUES ('5','  ','has text but no trigger',0,1);
        INSERT INTO Dictionary VALUES ('6','keep','kept text',0,1);
        """)

    let rows = try WisprFlowSnippetAdapter().loadSnippets(at: url)
    #expect(rows.candidates.map(\.trigger) == ["keep"])
    #expect(rows.excludedCount == 5)
  }

  @Test("a live Wispr Flow database (sidecars present) is refused with the snippet sentence")
  func wisprFlowRefusesWhileLive() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
      in: dir, rows: "INSERT INTO Dictionary VALUES ('1','sig','text',0,1);")
    try Data().write(to: URL(fileURLWithPath: url.path + "-wal"))

    #expect(throws: SnippetImportAppError.unreadable("Wispr Flow")) {
      _ = try WisprFlowSnippetAdapter().loadSnippets(at: url)
    }
    // The refusal is the whole read: nothing was created beside the other app's files.
    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(contents == ["flow.sqlite", "flow.sqlite-wal"])
    #expect(
      SnippetImportAppError.unreadable("Wispr Flow").errorDescription
        == "Couldn't read your Wispr Flow snippets. If Wispr Flow is open, try quitting it and importing again."
    )
  }

  @Test("a Wispr Flow column of the wrong type refuses the whole read rather than guessing")
  func wisprFlowMalformedColumnRefuses() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // `isSnippet` holding text is a schema that drifted under us, not a snippet to skip.
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
      in: dir,
      rows: """
        INSERT INTO Dictionary VALUES ('1','sig','text',0,1);
        INSERT INTO Dictionary VALUES ('2','other','text',0,'yes');
        """)

    #expect(throws: SnippetImportAppError.unreadable("Wispr Flow")) {
      _ = try WisprFlowSnippetAdapter().loadSnippets(at: url)
    }
  }

  // MARK: - TypeWhisper

  @Test(
    "TypeWhisper enabled literal snippets come across; disabled, placeholder and empty rows are counted"
  )
  func typeWhisperImportsLiteralRowsAndCountsTheRest() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir,
      rows: [
        Self.typeWhisperRow(1, enabled: true, trigger: "Date", replacement: "{{DATE}}"),
        Self.typeWhisperRow(2, enabled: true, trigger: "Time", replacement: "{{TIME}}"),
        Self.typeWhisperRow(3, enabled: true, trigger: "Clipboard", replacement: "{{CLIPBOARD}}"),
        Self.typeWhisperRow(4, enabled: false, trigger: "off", replacement: "disabled text"),
        Self.typeWhisperRow(5, enabled: true, trigger: "blank", replacement: "  "),
        Self.typeWhisperRow(6, enabled: true, trigger: "nul", replacement: nil),
        Self.typeWhisperRow(
          7, enabled: true, trigger: "sig", replacement: "Thanks, Saurabh's team"),
        Self.typeWhisperRow(
          8, enabled: true, trigger: "brace", replacement: "one { brace } is fine"),
      ])
    defer { sqlite3_close(store.writer) }

    let rows = try TypeWhisperSnippetAdapter().loadSnippets(at: store.url)
    // The three built-ins are the founder's real store on 2026-09-15: every one a
    // placeholder TypeWhisper fills in at paste time, which here would paste the letters.
    #expect(rows.excludedCount == 6)
    #expect(rows.candidates.map(\.trigger) == ["sig", "brace"])
    #expect(
      rows.candidates.map(\.expansion) == ["Thanks, Saurabh's team", "one { brace } is fine"])
  }

  @Test("TypeWhisper rows held only in the un-checkpointed WAL still come across")
  func typeWhisperReadsRowsHeldOnlyInTheWAL() throws {
    // TypeWhisper never checkpoints: the founder's real `snippets.store` main file shows no
    // rows under `immutable=1` while its 164 KB WAL holds all three (2026-09-16). The
    // stable-copy acquisition is what makes them visible.
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir,
      rows: [Self.typeWhisperRow(1, enabled: true, trigger: "main", replacement: "in main")],
      walOnlyInsert: Self.typeWhisperRow(2, enabled: true, trigger: "wal", replacement: "in wal"))
    defer { sqlite3_close(store.writer) }

    let rows = try TypeWhisperSnippetAdapter().loadSnippets(at: store.url)
    #expect(rows.candidates.map(\.trigger) == ["main", "wal"])
  }

  @Test("reading TypeWhisper snippets leaves every byte of its store untouched")
  func typeWhisperLeavesTheSourceUnchanged() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir,
      rows: [Self.typeWhisperRow(1, enabled: true, trigger: "main", replacement: "in main")],
      walOnlyInsert: Self.typeWhisperRow(2, enabled: true, trigger: "wal", replacement: "in wal"))
    defer { sqlite3_close(store.writer) }

    func fingerprint() -> [String: Data] {
      var out: [String: Data] = [:]
      for suffix in ["", "-wal", "-shm"] {
        if let data = FileManager.default.contents(atPath: store.url.path + suffix) {
          out[suffix] = data
        }
      }
      return out
    }
    let before = fingerprint()
    #expect(before.keys.contains("-wal"))
    _ = try TypeWhisperSnippetAdapter().loadSnippets(at: store.url)
    #expect(fingerprint() == before)
  }

  @Test("a TypeWhisper snapshot whose parts change between the two passes is refused")
  func typeWhisperRefusesAnUnstableSnapshot() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir,
      rows: [Self.typeWhisperRow(1, enabled: true, trigger: "sig", replacement: "text")],
      walOnlyInsert: Self.typeWhisperRow(2, enabled: true, trigger: "wal", replacement: "in wal"))
    defer { sqlite3_close(store.writer) }

    nonisolated(unsafe) var pass = 0
    let unstable = TypeWhisperSnippetAdapter(readPart: { url in
      guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
      guard url.lastPathComponent.hasSuffix("-wal") else { return data }
      pass += 1
      return data + Data("\(pass)".utf8)
    })
    #expect(throws: SnippetImportAppError.unreadable("TypeWhisper")) {
      _ = try unstable.loadSnippets(at: store.url)
    }
    #expect(pass == 6, "three acquisitions x two complete reads each, as for words")
  }

  @Test("a TypeWhisper store over the byte ceiling is refused before any row is read")
  func typeWhisperOverCeilingRefuses() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir, rows: [Self.typeWhisperRow(1, enabled: true, trigger: "sig", replacement: "text")])
    defer { sqlite3_close(store.writer) }

    // The injected part reader stands in for a store that grew past the ceiling: the real
    // reader returns ceiling-plus-one bytes for such a part, and the aggregate check refuses.
    let oversized = TypeWhisperSnippetAdapter(readPart: { url in
      guard url.lastPathComponent.hasSuffix("-wal") else {
        return FileManager.default.contents(atPath: url.path)
      }
      return Data(count: TypeWhisperStoreSnapshot.maximumBytes + 1)
    })
    #expect(throws: SnippetImportAppError.unreadable("TypeWhisper")) {
      _ = try oversized.loadSnippets(at: store.url)
    }
  }

  @Test("a TypeWhisper boolean or text column of the wrong type is refused, never coerced")
  func typeWhisperMalformedColumnsRefuse() throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir,
      rows: [
        "INSERT INTO ZSNIPPET VALUES (1,1,1,0,'yes',0,NULL,NULL,'text','sig',NULL);"
      ])
    defer { sqlite3_close(store.writer) }

    #expect(throws: SnippetImportAppError.unreadable("TypeWhisper")) {
      _ = try TypeWhisperSnippetAdapter().loadSnippets(at: store.url)
    }
  }

  // MARK: - Registry and source

  @Test("the registry ships the two apps whose snippet stores were read on a live install")
  func registryNamesBothApps() {
    #expect(SnippetImportAppRegistry.v1.displayNames == ["Wispr Flow", "TypeWhisper"])
    #expect(
      SnippetImportAppRegistry.v1.adapters.map(\.identifier) == ["wispr_flow", "typewhisper"])
    #expect(
      SnippetImportAppRegistry.v1.adapter(withID: "typewhisper")?.displayName == "TypeWhisper")
    #expect(SnippetImportAppRegistry.v1.adapter(withID: "wispr-flow") == nil)
  }

  @Test("each adapter probes its app's real store location")
  func adaptersProbeTheRealLocations() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(
      WisprFlowSnippetAdapter().candidatePaths.map(\.path)
        == [home + "/Library/Application Support/Wispr Flow/flow.sqlite"])
    #expect(
      TypeWhisperSnippetAdapter().candidatePaths.map(\.path)
        == [home + "/Library/Application Support/TypeWhisper/snippets.store"])
  }

  @Test("an app that isn't installed reports not found with the snippet sentence")
  func missingAppReportsNotFound() async throws {
    let missing = PathSubstituteAdapter(
      base: WisprFlowSnippetAdapter(),
      url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/flow.sqlite"))
    await #expect(throws: SnippetImportAppError.appNotFound("Wispr Flow")) {
      _ = try await AppSnippetImportSource(adapter: missing).loadCandidates()
    }
    #expect(
      SnippetImportAppError.appNotFound("Wispr Flow").errorDescription
        == "Couldn't find any Wispr Flow snippets on this Mac.")
  }

  @Test("the source carries the adapter's identifier and display name")
  func sourceCarriesIdentity() async throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
      in: dir, rows: "INSERT INTO Dictionary VALUES ('1','sig','text',0,1);")
    let source = AppSnippetImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowSnippetAdapter(), url: url))

    #expect(source.sourceID == "wispr_flow")
    let batch = try await source.loadCandidates()
    #expect(batch.sourceID == "wispr_flow")
    #expect(batch.sourceDisplayName == "Wispr Flow")
    #expect(batch.candidates.map(\.trigger) == ["sig"])
    #expect(batch.notices.isEmpty)
  }

  @Test("a store that refused every row says how many, instead of claiming it was empty")
  func allExcludedEmitsACountedNotice() async throws {
    // The founder's real TypeWhisper store: three placeholders, nothing importable. "No
    // snippets were found" would be false; the notice count is what lets the result screen
    // say "Found 3 entries, but none could be imported".
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try makeTypeWhisperStore(
      in: dir,
      rows: [
        Self.typeWhisperRow(1, enabled: true, trigger: "Date", replacement: "{{DATE}}"),
        Self.typeWhisperRow(2, enabled: true, trigger: "Time", replacement: "{{TIME}}"),
        Self.typeWhisperRow(3, enabled: true, trigger: "Clipboard", replacement: "{{CLIPBOARD}}"),
      ])
    defer { sqlite3_close(store.writer) }
    let source = AppSnippetImportSource(
      adapter: PathSubstituteAdapter(base: TypeWhisperSnippetAdapter(), url: store.url))

    let batch = try await source.loadCandidates()
    #expect(batch.candidates.isEmpty)
    #expect(batch.notices == [.incompatibleSourceEntriesExcluded(count: 3)])
  }

  @Test("a genuinely empty store emits no notice, so it still reads as empty")
  func genuinelyEmptyStoreEmitsNoNotice() async throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(in: dir, rows: "")
    let batch = try await AppSnippetImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowSnippetAdapter(), url: url)
    ).loadCandidates()
    #expect(batch.candidates.isEmpty)
    #expect(batch.notices.isEmpty)
  }

  /// Every adapter exclusion, each in a MIXED store (one survivor beside it), asserting the
  /// notice count equals the excluded rows and the survivor reaches the batch. Parameterised
  /// so no exclusion can be forgotten (plan §11 `everyExclusionReportsExactCount`).
  enum Exclusion: String, CaseIterable {
    case wisprFlowWordRow, wisprFlowDeleted, wisprFlowEmptyText, wisprFlowNullText,
      wisprFlowBlankTrigger
    case typeWhisperDisabled, typeWhisperPlaceholder, typeWhisperEmptyText,
      typeWhisperNullText, typeWhisperBlankTrigger
  }

  @Test(
    "every exclusion in a mixed store is one counted notice beside the survivor",
    arguments: Exclusion.allCases)
  func everyExclusionReportsExactCount(_ exclusion: Exclusion) async throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var writer: OpaquePointer?
    defer { sqlite3_close(writer) }

    // One exhaustive switch: the compiler asks about every new exclusion at the moment it
    // is added, and no arm can fall into a default.
    enum App { case wisprFlow, typeWhisper }
    let app: App
    let excludedRow: String
    switch exclusion {
    case .wisprFlowWordRow: (app, excludedRow) = (.wisprFlow, "('2','btw','by the way',0,0)")
    case .wisprFlowDeleted: (app, excludedRow) = (.wisprFlow, "('2','old','gone',1,1)")
    case .wisprFlowEmptyText: (app, excludedRow) = (.wisprFlow, "('2','empty','  ',0,1)")
    case .wisprFlowNullText: (app, excludedRow) = (.wisprFlow, "('2','nul',NULL,0,1)")
    case .wisprFlowBlankTrigger:
      (app, excludedRow) = (.wisprFlow, "('2',' ','text without trigger',0,1)")
    case .typeWhisperDisabled:
      (app, excludedRow) = (
        .typeWhisper, Self.typeWhisperRow(2, enabled: false, trigger: "off", replacement: "text")
      )
    case .typeWhisperPlaceholder:
      (app, excludedRow) = (
        .typeWhisper,
        Self.typeWhisperRow(2, enabled: true, trigger: "Date", replacement: "{{DATE}}")
      )
    case .typeWhisperEmptyText:
      (app, excludedRow) = (
        .typeWhisper, Self.typeWhisperRow(2, enabled: true, trigger: "empty", replacement: " ")
      )
    case .typeWhisperNullText:
      (app, excludedRow) = (
        .typeWhisper, Self.typeWhisperRow(2, enabled: true, trigger: "nul", replacement: nil)
      )
    case .typeWhisperBlankTrigger:
      (app, excludedRow) = (
        .typeWhisper, Self.typeWhisperRow(2, enabled: true, trigger: " ", replacement: "text")
      )
    }

    let source: AppSnippetImportSource
    switch app {
    case .wisprFlow:
      let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
        in: dir,
        rows: """
          INSERT INTO Dictionary VALUES ('1','survivor','survivor text',0,1);
          INSERT INTO Dictionary VALUES \(excludedRow);
          """)
      source = AppSnippetImportSource(
        adapter: PathSubstituteAdapter(base: WisprFlowSnippetAdapter(), url: url))
    case .typeWhisper:
      let store = try makeTypeWhisperStore(
        in: dir,
        rows: [
          Self.typeWhisperRow(1, enabled: true, trigger: "survivor", replacement: "survivor text"),
          excludedRow,
        ])
      writer = store.writer
      source = AppSnippetImportSource(
        adapter: PathSubstituteAdapter(base: TypeWhisperSnippetAdapter(), url: store.url))
    }

    let batch = try await source.loadCandidates()
    #expect(batch.candidates.map(\.trigger) == ["survivor"], "\(exclusion)")
    #expect(batch.candidates.map(\.expansion) == ["survivor text"], "\(exclusion)")
    #expect(batch.notices == [.incompatibleSourceEntriesExcluded(count: 1)], "\(exclusion)")
  }

  @Test("the ceiling counts rows the adapter excluded, not just the survivors")
  func ceilingCountsScannedRowsNotSurvivors() async throws {
    struct MostlyExcluded: SnippetImportAppAdapter {
      let identifier = "mostly-excluded"
      let displayName = "MostlyExcluded"
      var candidatePaths: [URL] { [URL(fileURLWithPath: "/dev/null")] }
      func loadSnippets(at url: URL) throws -> SnippetImportRows {
        SnippetImportRows(
          candidates: [SnippetImportCandidate(trigger: "survivor", expansion: "text")],
          excludedCount: SnippetImportLimits.maximumCandidates)
      }
    }
    await #expect(
      throws: SnippetImportAppError.tooManySourceEntries(
        appName: "MostlyExcluded", limit: SnippetImportLimits.maximumCandidates)
    ) {
      _ = try await AppSnippetImportSource(adapter: MostlyExcluded()).loadCandidates()
    }
    #expect(
      SnippetImportAppError.tooManySourceEntries(appName: "Wispr Flow", limit: 5_000)
        .errorDescription
        == "Wispr Flow has more than 5000 snippets, including entries it may hide or disable. "
        + "EnviousWispr stopped without importing anything.")
  }

  @Test("a real store one past the ceiling is refused, and one at the ceiling is read")
  func realStoreAtAndPastTheCeiling() async throws {
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let limit = SnippetImportLimits.maximumCandidates
    func rows(_ count: Int) -> String {
      // One transaction: 5,000 autocommitted inserts would each sync the disk.
      "BEGIN;\n"
        + (1...count).map { "INSERT INTO Dictionary VALUES ('\($0)','t\($0)','x',0,1);" }
        .joined(separator: "\n") + "\nCOMMIT;"
    }
    let atLimit = try RivalAppStoreFixtures.makeWisprFlowDatabase(in: dir, rows: rows(limit))
    let batch = try await AppSnippetImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowSnippetAdapter(), url: atLimit)
    ).loadCandidates()
    #expect(batch.candidates.count == limit)

    let over = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: over) }
    let pastLimit = try RivalAppStoreFixtures.makeWisprFlowDatabase(in: over, rows: rows(limit + 1))
    await #expect(
      throws: SnippetImportAppError.tooManySourceEntries(appName: "Wispr Flow", limit: limit)
    ) {
      _ = try await AppSnippetImportSource(
        adapter: PathSubstituteAdapter(base: WisprFlowSnippetAdapter(), url: pastLimit)
      ).loadCandidates()
    }
  }

  @Test("a rival app's snippet goes through the shared validation like a pasted one")
  func sourceValidatesThroughTheSharedContract() async throws {
    // A trigger carrying a control character is refused by `validated()`, the same rule a
    // pasted list meets; an adapter cannot opt out of it by existing.
    let dir = RivalAppStoreFixtures.makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try RivalAppStoreFixtures.makeWisprFlowDatabase(
      in: dir, rows: "INSERT INTO Dictionary VALUES ('1','bad' || char(7) || 'trigger','text',0,1);"
    )
    let source = AppSnippetImportSource(
      adapter: PathSubstituteAdapter(base: WisprFlowSnippetAdapter(), url: url))

    await #expect(throws: SnippetImportValidationError.self) {
      _ = try await source.loadCandidates()
    }
  }
}
