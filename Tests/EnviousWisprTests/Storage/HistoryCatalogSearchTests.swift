import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprStorage

/// Search and day counts return exactly what Foundation's matcher says (#4586 N3). The oracle is
/// `localizedCaseInsensitiveContains` over each row's own fields, never the catalog's reader.
@Suite("History search finds the same rows in every language", .tags(.productOutcome))
struct HistoryCatalogSearchTests {
  private struct Row {
    let key: HistoryCatalog.Key
    let date: Date
    let app: String?
    let fields: [String]
  }

  private static let base = Date(timeIntervalSinceReferenceDate: 790_000_000)

  /// Each row has its own minute, so the oracle's newest-first order is unambiguous.
  private static let rows: [Row] = {
    let fields: [[String]] = [
      ["Client budget review"],
      ["Straße und Gasse"],
      ["ﬁle naming"],
      ["cafe\u{301} au lait"],
      ["café crème"],
      ["ｂｕｄｇｅｔ wide"],
      ["İstanbul trip"],
      ["istanbul notes"],
      ["日本語のメモ"],
      ["emoji 🎉 party"],
      ["line one\nline two"],
      ["quote \"here\" and back\\slash"],
      ["über alles", "Custom title", "recording.m4a"],
      ["", "Speaker Ünal", "Bob"],
      [],
      ["ok"],
      ["A"],
      ["Résumé", "naïve"],
      ["budget"],
      ["Client"],
    ]
    return fields.enumerated().map { index, fields in
      Row(
        key: .init(
          tab: .dictations,
          id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, UInt8(index)))),
        date: base.addingTimeInterval(Double(index) * 60),
        app: index.isMultiple(of: 2) ? "Mail" : nil,
        fields: fields)
    }
  }()

  /// 1, 2 and 3+ characters; ASCII and not; case-changed; and text that spans two fields.
  private static let queries = [
    "a", "A", "é", "ü", "日", "ok", "Ok", "st", "ße", "日本", "🎉", "strasse", "STRASSE", "file",
    "café",
    "CAFÉ", "cafe", "budget", "BUDGET", "istanbul", "İstanbul", "line one\nline", "\"here\"",
    "\\slash",
    "title\nrecording", "budget\nClient", "über", "UBER", "Ünal", "speaker", "résumé", "naive",
    "zzz",
  ]

  private func oracle(_ query: String, rows: [Row]) -> [HistoryCatalog.Key] {
    rows.filter { row in row.fields.contains { $0.localizedCaseInsensitiveContains(query) } }
      .sorted { $0.date > $1.date }.map(\.key)
  }

  private func makeCatalog(_ rows: [Row], in directory: URL) async throws -> HistoryCatalog {
    let catalog = try HistoryCatalog(directory: directory, projectionContext: "en|en_US")
    try await catalog.apply(
      rows.map { row in
        .init(
          summary: .init(
            key: row.key, date: row.date, appKey: row.app, preview: row.fields.first ?? "",
            sources: [.init(name: "record", fingerprint: Data(row.key.id.uuidString.utf8))]),
          searchableFields: row.fields)
      }, certifiedRevision: "all")
    return catalog
  }

  /// SQLite opens the catalog without following links, and the temporary folder sits under /var.
  private func databasePath(_ folder: URL, _ name: String = "history.sqlite") -> String {
    guard let resolved = realpath(folder.path, nil) else { return folder.appendingPathComponent(name).path }
    defer { free(resolved) }
    return String(cString: resolved) + "/" + name
  }

  private func directory() -> URL {
    TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  @Test("Every query returns exactly the rows whose own fields match, newest first")
  func searchMatchesFoundation() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try await makeCatalog(Self.rows, in: folder)
    // The measured locale cases from the trigram review must match through every path.
    for (field, query) in [("Straße", "strasse"), ("ﬁle", "file"), ("cafe\u{301}", "café")] {
      #expect(field.localizedCaseInsensitiveContains(query), "oracle premise: \(field) / \(query)")
    }
    for query in Self.queries {
      let expected = oracle(query, rows: Self.rows)
      let keys = try await catalog.matchingKeys(
        .init(tab: .dictations, search: query), sourceRevision: "all")
      #expect(keys == expected, "query \(query.debugDescription)")
      let page = try await catalog.page(
        .init(tab: .dictations, search: query), sourceRevision: "all"
      ) {
        _ in true
      }
      #expect(page.summaries.map(\.key) == expected, "page for \(query.debugDescription)")
      let mail = try await catalog.matchingKeys(
        .init(tab: .dictations, search: query, app: "Mail"), sourceRevision: "all")
      let mailRows = Self.rows.filter { $0.app == "Mail" }
      #expect(mail == oracle(query, rows: mailRows), "Mail filter for \(query.debugDescription)")
    }
    #expect(oracle("budget\nClient", rows: Self.rows).isEmpty)
    #expect(oracle("strasse", rows: Self.rows).count == 1)
  }

  @Test("Date bounds and meeting overrides keep the same matching rows")
  func filtersAndOverrides() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try await makeCatalog(Self.rows, in: folder)
    let included = Self.rows[19].key
    let excluded = Self.rows[18].key
    let dates = DateInterval(start: Self.base.addingTimeInterval(60), end: Self.base.addingTimeInterval(1_200))
    let expected = Self.rows.filter {
      $0.date >= dates.start && $0.date < dates.end
        && ($0.key == included
          || ($0.key != excluded && $0.fields.contains { $0.localizedCaseInsensitiveContains("budget") }))
    }.sorted { $0.date > $1.date }.map(\.key)
    #expect(expected == [included])
    let actual = try await catalog.matchingKeys(
      .init(
        tab: .dictations, search: "budget", dates: dates,
        meetingSearchOverrides: [included.id: true, excluded.id: false]),
      sourceRevision: "all")
    #expect(actual == expected)
  }

  @Test("Paging newer from a cursor returns the same matches in the same order")
  func newerPagesMatch() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try await makeCatalog(Self.rows, in: folder)
    let expected = oracle("a", rows: Self.rows)
    let anchor = try #require(expected.last)
    let cursor = try #require(
      try await catalog.cursorBefore(anchor.id, query: .init(tab: .dictations, search: "a")))
    let newer = try await catalog.page(
      .init(tab: .dictations, search: "a"), after: cursor, newer: true, sourceRevision: "all"
    ) { _ in true }
    let older = try await catalog.page(
      .init(tab: .dictations, search: "a"), after: cursor, sourceRevision: "all"
    ) { _ in true }
    // The cursor is the match just newer than the anchor; each direction excludes the cursor row.
    #expect(cursor.id == expected[expected.count - 2].id)
    #expect(newer.summaries.map(\.key) + [expected[expected.count - 2]] + older.summaries.map(\.key) == expected)
  }

  @Test("Day counts match a per-day count across a daylight saving change")
  func dayCountsAcrossDaylightSaving() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    // 2026-03-07 to 2026-03-10 local, across the 2026-03-08 spring-forward day.
    let start = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 0, minute: 30)))
    let rows = (0..<48).map { index in
      Row(
        key: .init(
          tab: .dictations,
          id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, UInt8(index)))),
        date: start.addingTimeInterval(Double(index) * 7_200), app: nil,
        fields: [index.isMultiple(of: 3) ? "Straße" : "budget \(index)"])
    }
    let catalog = try await makeCatalog(rows, in: folder)
    for query in ["", "strasse", "budget", "b"] {
      let page = try await catalog.page(
        .init(tab: .dictations, search: query, calendar: calendar), sourceRevision: "all"
      ) { _ in true }
      let matching =
        query.isEmpty ? rows : rows.filter { $0.fields[0].localizedCaseInsensitiveContains(query) }
      let days = Set(page.summaries.map { calendar.startOfDay(for: $0.date) })
      let expected = Dictionary(
        uniqueKeysWithValues: days.map { day in
          (day, matching.filter { calendar.isDate($0.date, inSameDayAs: day) }.count)
        })
      #expect(page.dayCounts == expected, "query \(query.debugDescription)")
      #expect(days.count > 1, "the page spans several days for \(query.debugDescription)")
    }
  }

  @Test("A rebuilt trigram index still finds quotes, backslashes and empty rows stay unmatched")
  func rebuiltIndexFindsTheSameRows() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
      let catalog = try await makeCatalog(Self.rows, in: folder)
      try await catalog.closeDatabase()
    }
    // Ask the next open to rebuild the trigram index from the stored fields.
    let raw = try HistoryCatalogConnection(
      path: databasePath(folder))
    try raw.execute("UPDATE search_rebuild SET needed = 1")
    try raw.closeDatabase()
    let reopened = try HistoryCatalog(directory: folder, projectionContext: "en|en_US")
    for query in ["\"here\"", "\\slash", "budget", "line two", "zzz"] {
      let keys = try await reopened.matchingKeys(
        .init(tab: .dictations, search: query), sourceRevision: "all")
      #expect(keys == oracle(query, rows: Self.rows), "query \(query.debugDescription)")
    }
    let all = try await reopened.matchingKeys(.init(tab: .dictations), sourceRevision: "all")
    #expect(all.count == Self.rows.count)
    // Many statements ran; closing must still succeed.
    try await reopened.closeDatabase()
  }
}
