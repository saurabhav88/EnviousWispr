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

  // MARK: - Differential oracle for non-ASCII queries (#4586 H2)

  private static let differentialBase = Date(timeIntervalSinceReferenceDate: 780_000_000)

  /// Several hundred rows: common and rare ASCII, the locale traps, Devanagari, and 40 rows that
  /// hold an accented letter so one query matches beyond the first page of 30.
  private static let differentialRows: [Row] = {
    var fields: [[String]] = []
    for index in 0..<210 { fields.append(["common word \(index) budget"]) }
    for index in 0..<30 { fields.append(["rare quartz \(index)"]) }
    fields += [
      ["Straße"], ["STRASSE"], ["strasse"], ["ſtrasse"], ["café crème"], ["cafe\u{301} noir"], ["é"],
      ["Résumé"], ["नमस्ते दुनिया"], ["है"], ["हिन्दी भाषा में खोज"], ["日本語のメモ"], ["İstanbul"],
      ["istanbul"], ["ISTANBUL"], ["ıstanbul"], ["a\u{200D}b"], ["soft\u{00AD}hyphen"], ["emoji 🎉"],
      ["ｂｕｄｇｅｔ"], ["key"], ["Key"], ["\u{212A}ey"], ["ﬁle"], ["file"], ["caf", "é au lait"],
      ["i\u{307}stanbul"], ["I\u{307}ST"], ["x"],
    ]
    for index in 0..<40 { fields.append(["cafés nearby \(index)"]) }
    fields.append(["override only"])
    return fields.enumerated().map { index, fields in
      Row(
        key: .init(
          tab: .dictations,
          id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, UInt8(index >> 8), UInt8(index & 255)))),
        // The override-only row sits two days after the rest, so its day exists on page one only
        // through the override.
        date: differentialBase.addingTimeInterval(Double(index) * 1_200 + (fields == ["override only"] ? 172_800 : 0)),
        app: nil, fields: fields)
    }
  }()

  /// ASCII common and rare, 1 and 2 characters, every locale trap, admitted queries and a
  /// cross-field negative.
  private static let differentialQueries = [
    "budget", "quartz", "com", "a", "ab", "x", "1", "Straße", "STRAẞE", "ſtrasse", "strasse", "ﬁle",
    "café", "cafe\u{301}", "é", "\u{301}", "है", "नमस्ते", "हिन्दी", "日本", "İ", "ı", "I",
    "i\u{307}", "a\u{200D}b", "soft\u{00AD}hyphen", "🎉", "\u{212A}", "key", "k", "caf", "é au",
    "caf\né au", "zzz",
  ]

  private func utcCalendar() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    return calendar
  }

  /// Every page of a query, newest first, plus the first page's day counts.
  private func allPages(
    _ catalog: HistoryCatalog, _ query: HistoryCatalog.Query
  ) async throws -> (keys: [HistoryCatalog.Key], firstPage: HistoryCatalog.Page, pages: Int) {
    var keys: [HistoryCatalog.Key] = []
    var cursor: HistoryCatalog.Cursor?
    var first: HistoryCatalog.Page?
    var pages = 0
    repeat {
      let page = try await catalog.page(query, after: cursor, sourceRevision: "all") { _ in true }
      first = first ?? page
      keys += page.summaries.map(\.key)
      cursor = page.continuation
      pages += 1
    } while cursor != nil
    return (keys, try #require(first), pages)
  }

  /// Day counts for the first page (the newest 30 matches), from fixture rows only.
  private func expectedDayCounts(matching: [Row], calendar: Calendar) -> [Date: Int] {
    let firstPage = matching.sorted { $0.date > $1.date }.prefix(30)
    let days = Set(firstPage.map { calendar.startOfDay(for: $0.date) })
    return Dictionary(
      uniqueKeysWithValues: days.map { day in
        (day, matching.filter { calendar.isDate($0.date, inSameDayAs: day) }.count)
      })
  }

  @Test("Accented, non-Latin and Straße-family queries return exactly the rows, pages and day counts a plain Foundation scan finds")
  func nonASCIIQueriesMatchFoundation() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = try utcCalendar()
    let rows = Self.differentialRows
    #expect(rows.count > 300)
    // Expected results come from the raw fixture fields, before any catalog read.
    var expected: [String: [HistoryCatalog.Key]] = [:]
    for query in Self.differentialQueries { expected[query] = oracle(query, rows: rows) }
    // Canonically equal spellings are one String to Swift, so compare scalars.
    #expect(Set(Self.differentialQueries.map { $0.unicodeScalars.map(\.value) }).count == Self.differentialQueries.count)
    #expect((expected["é"] ?? []).count > 30, "an accented match beyond the first page")
    #expect((expected["caf\né au"] ?? []).isEmpty, "a match must not span two fields")
    #expect((expected["STRAẞE"] ?? []).count >= 3, "oracle premise: STRAẞE finds Straße, STRASSE and strasse rows")
    let catalog = try await makeCatalog(rows, in: folder)
    for query in Self.differentialQueries {
      let want = try #require(expected[query])
      let search = HistoryCatalog.Query(tab: .dictations, search: query, calendar: calendar)
      let keys = try await catalog.matchingKeys(search, sourceRevision: "all")
      #expect(keys == want, "matchingKeys for \(query.debugDescription)")
      let paged = try await allPages(catalog, search)
      #expect(paged.keys == want, "all pages for \(query.debugDescription)")
      if want.count > 30 { #expect(paged.pages > 1, "paged for \(query.debugDescription)") }
      let matchingRows = rows.filter { want.contains($0.key) }
      #expect(
        paged.firstPage.dayCounts == expectedDayCounts(matching: matchingRows, calendar: calendar),
        "day counts for \(query.debugDescription)")
    }
  }

  @Test("A true override on a non-matching row and a false override on a saved match win in keys, pages and page-one day counts")
  func overridesWithAccentedQuery() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = try utcCalendar()
    let rows = Self.differentialRows
    let asciiRow = try #require(rows.first { $0.fields == ["override only"] })
    let savedMatch = try #require(rows.first { $0.fields == ["cafés nearby 39"] })
    let base = oracle("é", rows: rows)
    #expect(base.contains(asciiRow.key) == false)
    #expect(base.contains(savedMatch.key))
    let expectedRows = rows.filter {
      $0.key == asciiRow.key || ($0.key != savedMatch.key && base.contains($0.key))
    }
    let expected = expectedRows.sorted { $0.date > $1.date }.map(\.key)
    let catalog = try await makeCatalog(rows, in: folder)
    let search = HistoryCatalog.Query(
      tab: .dictations, search: "é", calendar: calendar,
      meetingSearchOverrides: [asciiRow.key.id: true, savedMatch.key.id: false])
    #expect(try await catalog.matchingKeys(search, sourceRevision: "all") == expected)
    let paged = try await allPages(catalog, search)
    #expect(paged.keys == expected)
    let after = expectedDayCounts(matching: expectedRows, calendar: calendar)
    #expect(paged.firstPage.dayCounts == after)
    // Both overrides change a page-one day count, so ignoring either one is visible there.
    let before = expectedDayCounts(matching: rows.filter { base.contains($0.key) }, calendar: calendar)
    #expect(before[calendar.startOfDay(for: asciiRow.date)] == nil)
    #expect(after[calendar.startOfDay(for: asciiRow.date)] == 1)
    #expect(before[calendar.startOfDay(for: savedMatch.date)] != after[calendar.startOfDay(for: savedMatch.date)])
  }

  @Test("History search keeps the baseline SQL for ASCII and non-ASCII queries")
  func predicateSQL() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try await makeCatalog(Self.rows, in: folder)
    // Literals as the code before H2 produced them (HistoryCatalog.predicate(for:)).
    let head = "e.tab = ? AND (e.expires_at IS NULL OR e.expires_at > ?)"
    let trigram = "(e.ascii_only = 0 OR e.row_id IN (SELECT rowid FROM search WHERE search MATCH ?))"
    let contains = "history_contains(e.search_fields, ?)"
    let override = UUID()
    let cases: [(HistoryCatalog.Query, String)] = [
      (.init(tab: .dictations), head),
      (.init(tab: .dictations, search: "budget"), "\(head) AND \(trigram) AND \(contains)"),
      (.init(tab: .dictations, search: "Budget 2"), "\(head) AND \(trigram) AND \(contains)"),
      (.init(tab: .dictations, search: "bu"), "\(head) AND \(contains)"),
      (.init(tab: .dictations, search: "b"), "\(head) AND \(contains)"),
      (
        .init(tab: .dictations, search: "budget", app: "Mail"),
        "\(head) AND coalesce(e.app, '') = ? AND \(trigram) AND \(contains)"
      ),
      (
        .init(tab: .dictations, search: "budget", meetingSearchOverrides: [override: true]),
        "\(head) AND (e.id IN (SELECT value FROM json_each(?)) OR (e.id NOT IN (SELECT value FROM json_each(?)) AND \(trigram) AND \(contains)))"
      ),
      // Non-ASCII queries keep the plain full scan.
      (.init(tab: .dictations, search: "Straße"), "\(head) AND \(contains)"),
      (.init(tab: .dictations, search: "STRAẞE"), "\(head) AND \(contains)"),
      (.init(tab: .dictations, search: "日本"), "\(head) AND \(contains)"),
      (.init(tab: .dictations, search: "é"), "\(head) AND \(contains)"),
      (.init(tab: .dictations, search: "है"), "\(head) AND \(contains)"),
      (
        .init(tab: .dictations, search: "é", meetingSearchOverrides: [override: false]),
        "\(head) AND (e.id IN (SELECT value FROM json_each(?)) OR (e.id NOT IN (SELECT value FROM json_each(?)) AND \(contains)))"
      ),
    ]
    for (query, literal) in cases {
      let sql = await catalog.predicate(for: query).sql
      #expect(sql == literal, "SQL for \(query.search.debugDescription)")
    }
    let quoted = await catalog.predicate(
      for: .init(
        tab: .dictations, search: "a\"b", app: "Mail", now: Date(timeIntervalSinceReferenceDate: 42)))
    #expect(quoted.sql == "\(head) AND coalesce(e.app, '') = ? AND \(trigram) AND \(contains)")
    try #require(quoted.values.count == 5)
    guard case .number(let now) = quoted.values[1] else {
      Issue.record("Expected the expiration cutoff in binding 2")
      return
    }
    #expect(now == 42)
    let textBytes = quoted.values.compactMap { value -> [UInt8]? in
      guard case .text(let string) = value else { return nil }
      return Array(string.utf8)
    }
    #expect(textBytes == ["dictations", "Mail", "\"a\"\"b\"", "a\"b"].map { Array($0.utf8) })
  }
}
