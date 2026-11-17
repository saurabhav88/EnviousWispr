import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import SQLite3
import Testing

@testable import EnviousWisprStorage

/// The catalog's storage choices keep History correct as it rebuilds and searches (#4586 N3, N4).
@Suite("History catalog storage rebuilds and counts correctly", .tags(.productOutcome))
struct HistoryCatalogStorageTests {
  /// SQLite opens the catalog without following links, and the temporary folder sits under /var.
  private func databasePath(_ folder: URL, _ name: String = "history.sqlite") -> String {
    guard let resolved = realpath(folder.path, nil) else { return folder.appendingPathComponent(name).path }
    defer { free(resolved) }
    return String(cString: resolved) + "/" + name
  }

  private func directory() -> URL {
    TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func key(_ index: Int) -> HistoryCatalog.Key {
    .init(
      tab: .dictations, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, UInt8(index))))
  }

  @Test("Day counts scan days outer and use both indexed date bounds")
  func dayCountPlan() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try HistoryCatalog(directory: folder, projectionContext: "en|en_US")
    let predicate = await catalog.predicate(
      for: .init(tab: .dictations, search: "budget", meetingSearchOverrides: [UUID(): true]))
    try await catalog.closeDatabase()
    let connection = try HistoryCatalogConnection(
      path: databasePath(folder))
    defer { try? connection.closeDatabase() }
    let bounds: [HistoryCatalogConnection.Value] = [
      .integer(0), .number(0), .number(1), .integer(1), .number(2), .number(3),
    ]
    let plan = try connection.rows(
      "EXPLAIN QUERY PLAN " + HistoryCatalog.dayCountSQL(days: 2, predicate: predicate.sql),
      bounds + predicate.values
    ) { HistoryCatalogConnection.text($0, 3) }
    let days = try #require(plan.firstIndex { $0.hasPrefix("SCAN days") }, "\(plan)")
    let entries = try #require(
      plan.firstIndex {
        $0.contains("USING INDEX saved_order (tab=? AND saved_at>? AND saved_at<?)")
      }, "\(plan)")
    #expect(days < entries, "\(plan)")
  }

  @Test("A catalog from the previous version is rebuilt, never read")
  func previousVersionRebuilds() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    try await HistoryCatalog(directory: folder, projectionContext: "en|en_US").closeDatabase()
    let connection = try HistoryCatalogConnection(
      path: databasePath(folder))
    try connection.execute("PRAGMA user_version = 5")
    try connection.closeDatabase()
    var refusal: (any Error)?
    do { _ = try HistoryCatalog(directory: folder, projectionContext: "en|en_US") } catch {
      refusal = error
    }
    #expect(HistoryCatalog.needsRebuild(try #require(refusal)))
  }

  @Test("Damaged search data asks for a rebuild instead of hiding rows")
  func damagedSearchDataRebuilds() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try HistoryCatalog(directory: folder, projectionContext: "en|en_US")
    try await catalog.apply(
      [
        .init(
          summary: .init(
            key: key(1), date: Date(timeIntervalSinceReferenceDate: 790_000_000), preview: "budget",
            sources: [.init(name: "record", fingerprint: Data([1]))]),
          searchableFields: ["budget", ""])
      ], certifiedRevision: "all")
    let matched = try await catalog.matchingKeys(
      .init(tab: .dictations, search: "budget"), sourceRevision: "all")
    #expect(matched == [key(1)])
    try await catalog.closeDatabase()
    let connection = try HistoryCatalogConnection(
      path: databasePath(folder))
    // A valid first field followed by a length that runs past the end.
    try connection.execute(
      "UPDATE entries SET search_fields = ?",
      [.bytes(SearchFields.encode(["budget"]) + Data([9, 0, 0, 0, 65]))])
    try connection.closeDatabase()
    let reopened = try HistoryCatalog(directory: folder, projectionContext: "en|en_US")
    var failure: (any Error)?
    do {
      _ = try await reopened.matchingKeys(
        .init(tab: .dictations, search: "budget"), sourceRevision: "all")
    } catch { failure = error }
    #expect(HistoryCatalog.needsRebuild(try #require(failure)))
  }

  @Test("Reused statements survive nesting, a wrong parameter count and cancellation, and still close")
  func reusedStatementsStayUsable() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let connection = try HistoryCatalogConnection(path: databasePath(folder, "plain.sqlite"))
    try connection.execute("CREATE TABLE t (v INTEGER)")
    for value in 1...3 { try connection.execute("INSERT INTO t VALUES (?)", [.integer(Int64(value))]) }
    let select = "SELECT v FROM t ORDER BY v"
    // The same SQL inside its own row reader runs on a second statement, not the one stepping.
    let nested = try connection.rows(select) { row in
      (sqlite3_column_int64(row, 0), try connection.rows(select) { sqlite3_column_int64($0, 0) })
    }
    #expect(nested.map(\.0) == [1, 2, 3])
    #expect(nested.allSatisfy { $0.1 == [1, 2, 3] })
    #expect(throws: HistoryCatalogConnection.Failure.self) {
      try connection.execute("INSERT INTO t VALUES (?)", [])
    }
    try connection.execute("INSERT INTO t VALUES (?)", [.integer(4)])
    // Awaited before the next use, so the two tasks never touch the connection at once.
    nonisolated(unsafe) let handoff = connection
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try handoff.rows(select) { sqlite3_column_int64($0, 0) }
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try connection.rows(select) { sqlite3_column_int64($0, 0) } == [1, 2, 3, 4])
    // Every cached or nested statement is finalized, so closing does not report SQLITE_BUSY.
    try connection.closeDatabase()
  }

  @Test("Search fields round-trip, including empty fields and an empty list")
  func searchFieldsRoundTrip() throws {
    for fields in [[], [""], ["a", "", "Straße\nzwei", "日本語"]] {
      let data = SearchFields.encode(fields)
      let decoded = data.withUnsafeBytes { SearchFields.decode($0) }
      #expect(decoded == fields)
    }
    let truncated = SearchFields.encode(["abc"]).dropLast()
    #expect(Data(truncated).withUnsafeBytes { SearchFields.decode($0) } == nil)
  }

  @Test("Reconciliation deletes exactly the rows no source still names")
  func keyReferenceCountsMatchAFullRecount() {
    // Oracle: the rule before #4586 N4, recounting every key after each batch.
    var generator = CatalogBatchGenerator(state: 4586)
    for _ in 0..<200 {
      var reference: [String: HistoryCatalog.SourceProgress] = [:]
      for path in 0..<6 where Bool.random(using: &generator) {
        let entry = HistoryCatalog.SourceProgress(
          path: "p\(path)", versions: [],
          key: Bool.random(using: &generator) ? key(Int.random(in: 0..<4, using: &generator)) : nil)
        reference[entry.path] = entry
      }
      var progress = HistoryCatalogReconciliation.KeyedProgress(reference)
      for _ in 0..<6 {
        // Batches may repeat a path and may carry no key.
        let batch = (0..<Int.random(in: 1...4, using: &generator)).map { _ in
          HistoryCatalog.SourceProgress(
            path: "p\(Int.random(in: 0..<6, using: &generator))", versions: [],
            key: Int.random(in: 0..<5, using: &generator) == 0 ? nil : key(Int.random(in: 0..<4, using: &generator)))
        }
        let oldKeys = Set(batch.compactMap { reference[$0.path]?.key })
        for entry in batch { reference[entry.path] = entry }
        let expected = oldKeys.subtracting(reference.values.compactMap(\.key))
        #expect(Set(progress.record(batch)) == expected)
        if let path = reference.keys.sorted().randomElement(using: &generator), Bool.random(using: &generator) {
          let removed = reference.removeValue(forKey: path)?.key
          let gone =
            removed.map { reference.values.compactMap(\.key).contains($0) == false } ?? false
          let actual = progress.remove(path)?.key
          #expect(actual == removed)
          #expect(actual.map(progress.isUnreferenced) ?? false == gone)
        }
      }
    }
  }

  /// About 200k recursive steps that return no row: a no-match scan with no per-row check.
  private static let longEmptyScan =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200000) SELECT x FROM c WHERE x < 0"

  private func plainConnection(_ folder: URL) throws -> HistoryCatalogConnection {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let connection = try HistoryCatalogConnection(path: databasePath(folder, "plain.sqlite"))
    try connection.execute("CREATE TABLE t (f BLOB NOT NULL)")
    try connection.transaction(write: true) {
      for index in 0..<2_000 {
        try connection.execute(
          "INSERT INTO t VALUES (?)", [.bytes(SearchFields.encode(["café \(index) Straße", "日本語"]))])
      }
    }
    return connection
  }

  @Test("A cancelled search stops, matches no row or not, and never reports an empty success (#4586 B2)")
  func cancelledSearchStops() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = try plainConnection(folder)
    defer { try? connection.closeDatabase() }
    let search = "SELECT rowid FROM t WHERE history_contains(f, ?)"
    let cases: [(String, [HistoryCatalogConnection.Value])] = [
      (search, [.text("zzzq")]),  // the real matcher over every stored row
      (Self.longEmptyScan, []),  // long, no row
      ("SELECT 1 WHERE 0", []),  // finishes before the handler's first check
    ]
    // Uncancelled, each finishes and returns nothing.
    for (sql, values) in cases {
      #expect(try connection.rows(sql, values, stopWhenCancelled: true) { sqlite3_column_int64($0, 0) }.isEmpty)
    }
    // Awaited before the next use, so the two tasks never touch the connection at once.
    nonisolated(unsafe) let handoff = connection
    for (sql, values) in cases {
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try handoff.rows(sql, values, stopWhenCancelled: true) { sqlite3_column_int64($0, 0) }
      }
      await #expect(throws: CancellationError.self, "\(sql)") { try await cancelled.value }
    }
    let found = try connection.rows(search, [.text("café 7 ")], stopWhenCancelled: true) { sqlite3_column_int64($0, 0) }
    #expect(found == [8])
  }

  @Test("A read that does not opt in runs to its end under cancellation, inside a search read too")
  func plainReadsAreNotStopped() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = try plainConnection(folder)
    defer { try? connection.closeDatabase() }
    struct Refused: Error {}
    nonisolated(unsafe) let handoff = connection
    let plain = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try handoff.rows(Self.longEmptyScan) { sqlite3_column_int64($0, 0) }
    }
    #expect(try await plain.value.isEmpty)
    // Rows 1 and 2 come back first, then the outer search steps through a long empty tail.
    let outer =
      "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200000) SELECT x FROM c WHERE x <= 2"
    nonisolated(unsafe) var innerAfterCancel: [Int64]?
    let read = Task {
      try handoff.rows(outer, stopWhenCancelled: true) { row in
        let value = sqlite3_column_int64(row, 0)
        if value == 2 {
          let count = try handoff.rows("SELECT count(*) FROM t") { sqlite3_column_int64($0, 0) }
          #expect(count == [2_000])
          var refused = false
          do { _ = try handoff.rows("SELECT 1") { _ -> Int64 in throw Refused() } } catch is Refused { refused = true }
          #expect(refused)
          withUnsafeCurrentTask { $0?.cancel() }
          // A plain read nested in the search read is still not stopped.
          innerAfterCancel = try handoff.rows(Self.longEmptyScan) { sqlite3_column_int64($0, 0) }
        }
        return value
      }
    }
    // After every inner read ends, the outer search is stoppable again.
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(innerAfterCancel == [])
    #expect(try connection.rows(outer, stopWhenCancelled: true) { sqlite3_column_int64($0, 0) } == [1, 2])
  }

  @Test("A write transaction whose task is cancelled still commits all of its writes")
  func cancelledTaskStillCommitsWrites() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = try plainConnection(folder)
    defer { try? connection.closeDatabase() }
    try connection.execute("CREATE TABLE w (v INTEGER)")
    nonisolated(unsafe) let handoff = connection
    let write = Task {
      try handoff.transaction(write: true) {
        withUnsafeCurrentTask { $0?.cancel() }
        try handoff.execute("INSERT INTO w VALUES (1)")
        // A long read inside the write, like reconciliation's progress read.
        _ = try handoff.rows(Self.longEmptyScan) { sqlite3_column_int64($0, 0) }
        try handoff.execute("INSERT INTO w VALUES (2)")
      }
    }
    try await write.value
    #expect(try connection.rows("SELECT v FROM w ORDER BY v") { sqlite3_column_int64($0, 0) } == [1, 2])
  }
}

/// A fixed sequence, so every run checks the same batches.
private struct CatalogBatchGenerator: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
