import Darwin
import EnviousWisprCore
import Foundation
import SQLite3

/// A disposable read model. Its caller verifies source versions and certifies coverage
/// independently of the database. Mutations to saved History never rely on this file.
package actor HistoryCatalog {
  package struct Key: Hashable, Codable, Sendable {
    package let tab: HistoryTab
    package let id: UUID

    package init(tab: HistoryTab, id: UUID) {
      self.tab = tab
      self.id = id
    }
  }

  package struct SourceVersion: Codable, Equatable, Sendable {
    package let name: String
    package let fingerprint: Data

    package init(name: String, fingerprint: Data) {
      self.name = name
      self.fingerprint = fingerprint
    }
  }

  package struct Summary: Codable, Equatable, Sendable {
    package let key: Key
    package let date: Date
    package let appKey: String?
    package let title: String?
    package let preview: String
    package let sources: [SourceVersion]
    package let expiresAt: Date?

    package init(
      key: Key, date: Date, appKey: String? = nil, title: String? = nil, preview: String,
      sources: [SourceVersion], expiresAt: Date? = nil
    ) {
      self.key = key
      self.date = date
      self.appKey = appKey
      self.title = title
      self.preview = preview
      self.sources = sources
      self.expiresAt = expiresAt
    }
  }

  package struct Projection: Sendable {
    package let summary: Summary
    let searchableFields: [String]

    package init(summary: Summary, searchableFields: [String]) {
      self.summary = summary
      self.searchableFields = searchableFields
    }
  }

  package struct Query: Sendable {
    let tab: HistoryTab
    let search: String
    let dates: DateInterval?
    let app: String?
    let calendar: Calendar
    let now: Date

    package init(
      tab: HistoryTab, search: String = "", dates: DateInterval? = nil, app: String? = nil,
      calendar: Calendar = .current, now: Date = Date()
    ) {
      self.tab = tab
      self.search = search
      self.dates = dates
      self.app = app
      self.calendar = calendar
      self.now = now
    }
  }

  package struct Cursor: Equatable, Sendable {
    let date: Date
    let id: UUID
  }

  package struct Page: Sendable {
    package let summaries: [Summary]
    package let continuation: Cursor?
    package let dayCounts: [Date: Int]?
  }

  package enum Failure: Error {
    case incompatibleSchema
    case incompleteCoverage
    case invalidProjection
  }

  private static let pageSize = 30
  private let connection: HistoryCatalogConnection
  private let hasTrigram: Bool

  /// The directory is dedicated to the catalog, outside all canonical source namespaces.
  package init(directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let marker = directory.appendingPathComponent(".metadata_never_index")
    if manager.fileExists(atPath: marker.path) == false {
      guard manager.createFile(atPath: marker.path, contents: Data()) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }

    // macOS can return a temporary directory under /var, a system symlink. Resolve
    // the parent only so SQLite still refuses a symlink at the database file itself.
    guard let resolved = realpath(directory.path, nil) else {
      throw CocoaError(.fileReadUnknown)
    }
    defer { free(resolved) }
    let path = String(cString: resolved) + "/history.sqlite"
    let connection = try HistoryCatalogConnection(path: path)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    try connection.execute("PRAGMA secure_delete = ON")
    let schema = try connection.rows("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first
    guard schema == 0 || schema == 1 else { throw Failure.incompatibleSchema }
    if schema == 0 {
      try connection.transaction(write: true) {
        try connection.execute("""
          CREATE TABLE entries (
            row_id INTEGER PRIMARY KEY, tab TEXT NOT NULL, id TEXT NOT NULL, saved_at REAL NOT NULL,
            app TEXT, expires_at REAL, summary BLOB NOT NULL, fields TEXT NOT NULL, ascii_only INTEGER NOT NULL,
            UNIQUE (tab, id)
          )
          """)
        try connection.execute("CREATE INDEX saved_order ON entries(tab, saved_at DESC, id DESC)")
        try connection.execute("CREATE TABLE coverage (id INTEGER PRIMARY KEY CHECK(id = 0), revision TEXT)")
        try connection.execute("INSERT INTO coverage VALUES (0, NULL)")
        try connection.execute("CREATE TABLE search_rebuild (needed INTEGER NOT NULL)")
        try connection.execute("INSERT INTO search_rebuild VALUES (1)")
        try connection.execute("""
          CREATE TABLE source_progress (
            path TEXT PRIMARY KEY, versions BLOB NOT NULL, tab TEXT, id TEXT
          ) WITHOUT ROWID
          """)
        try connection.execute("PRAGMA user_version = 1")
      }
    }
    hasTrigram = try Self.prepareSearch(using: connection)
    self.connection = connection
  }

  /// Call only after closing the previous catalog instance. Delete only known derived SQLite
  /// files; even a stray original file in this folder is left in place.
  package static func discardFiles(in directory: URL) throws {
    for name in ["history.sqlite-shm", "history.sqlite-wal", "history.sqlite-journal", "history.sqlite"] {
      do {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
      } catch CocoaError.fileNoSuchFile {
        continue
      }
    }
  }

  /// Certifying a revision means an external source inventory has accounted for every record.
  /// A partial batch can be shown once its individual sources pass verification.
  package func apply(
    _ projections: [Projection], removing keys: [Key] = [], certifiedRevision: String? = nil
  ) throws {
    try apply(projections, removing: keys, certifiedRevision: certifiedRevision, recording: [])
  }

  func apply(
    _ projections: [Projection], removing keys: [Key], certifiedRevision: String? = nil,
    recording progress: [SourceProgress], dropping paths: [String] = []
  ) throws {
    try Task.checkCancellation()
    try connection.transaction(write: true) {
      if hasTrigram == false, keys.isEmpty == false || projections.isEmpty == false {
        try connection.execute("UPDATE search_rebuild SET needed = 1")
      }
      for key in keys {
        if hasTrigram {
          try connection.execute(
            "DELETE FROM search WHERE rowid IN (SELECT row_id FROM entries WHERE tab = ? AND id = ?)",
            key.parameters)
        }
        try connection.execute("DELETE FROM entries WHERE tab = ? AND id = ?", key.parameters)
      }
      let encoder = JSONEncoder()
      for projection in projections {
        try Task.checkCancellation()
        let row = projection.summary
        guard row.date.timeIntervalSinceReferenceDate.isFinite, row.sources.isEmpty == false else {
          throw Failure.invalidProjection
        }
        let fields = String(decoding: try encoder.encode(projection.searchableFields), as: UTF8.self)
        let text = projection.searchableFields.joined(separator: "\n")
        let asciiOnly = text.utf8.allSatisfy { $0 < 128 }
        let parameters = row.key.parameters + [
          .number(row.date.timeIntervalSinceReferenceDate),
          row.appKey.map(HistoryCatalogConnection.Value.text) ?? .null,
          row.expiresAt.map { .number($0.timeIntervalSinceReferenceDate) } ?? .null,
          .bytes(try encoder.encode(row)), .text(fields), .number(asciiOnly ? 1 : 0),
        ]
        let rowID = try connection.rows("""
          INSERT INTO entries(tab, id, saved_at, app, expires_at, summary, fields, ascii_only)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(tab, id) DO UPDATE SET
            saved_at=excluded.saved_at, app=excluded.app, expires_at=excluded.expires_at,
            summary=excluded.summary,
            fields=excluded.fields, ascii_only=excluded.ascii_only
          RETURNING row_id
          """, parameters) { sqlite3_column_int64($0, 0) }.first
        if hasTrigram, let rowID {
          try connection.execute("DELETE FROM search WHERE rowid = ?", [.integer(rowID)])
          try connection.execute(
            "INSERT INTO search(rowid, body) VALUES (?, ?)", [.integer(rowID), .text(text)])
        }
      }
      for path in paths {
        try connection.execute("DELETE FROM source_progress WHERE path = ?", [.text(path)])
      }
      for step in progress {
        let key = step.key?.parameters ?? [.null, .null]
        try connection.execute("""
          INSERT OR REPLACE INTO source_progress(path, versions, tab, id) VALUES (?, ?, ?, ?)
          """, [.text(step.path), .bytes(try encoder.encode(step.versions))] + key)
      }
      try connection.execute(
        "UPDATE coverage SET revision = ? WHERE id = 0", [certifiedRevision.map { .text($0) } ?? .null])
    }
  }

  package func page(
    _ query: Query, after cursor: Cursor? = nil, sourceRevision: String? = nil,
    verify: @Sendable (Summary) throws -> Bool
  ) throws -> Page {
    try connection.transaction {
      let predicate = predicate(for: query)
      var parameters = predicate.values
      var boundary = ""
      if let cursor {
        boundary = " AND (e.saved_at, e.id) < (?, ?)"
        parameters += [.number(cursor.date.timeIntervalSinceReferenceDate), .text(cursor.id.uuidString)]
      }
      let rows = try connection.rows("""
        SELECT e.summary FROM entries AS e WHERE \(predicate.sql)\(boundary)
        ORDER BY e.saved_at DESC, e.id DESC LIMIT \(Self.pageSize + 1)
        """, parameters, decodeSummary)
      let candidates = Array(rows.prefix(Self.pageSize))
      let visible = try candidates.filter(verify)
      let certified = try visible.count == candidates.count && hasCoverage(sourceRevision)
      let continuation = rows.count > Self.pageSize
        ? candidates.last.map { Cursor(date: $0.date, id: $0.key.id) } : nil
      let days = Set(visible.map { query.calendar.startOfDay(for: $0.date) })
      var counts: [Date: Int]? = nil
      if certified {
        counts = [:]
        for day in days {
          guard let interval = query.calendar.dateInterval(of: .day, for: day) else { continue }
          let count = try connection.rows("""
            SELECT count(*) FROM entries AS e WHERE \(predicate.sql) AND e.saved_at >= ? AND e.saved_at < ?
            """, predicate.values + [.number(interval.start.timeIntervalSinceReferenceDate),
                                    .number(interval.end.timeIntervalSinceReferenceDate)]) {
              Int(sqlite3_column_int64($0, 0))
            }.first
          counts?[day] = count
        }
      }
      return Page(summaries: visible, continuation: continuation, dayCounts: counts)
    }
  }

  package func matchingKeys(_ query: Query, sourceRevision: String) throws -> [Key] {
    try connection.transaction {
      guard try hasCoverage(sourceRevision) else { throw Failure.incompleteCoverage }
      let predicate = predicate(for: query)
      return try connection.rows(
        "SELECT e.id FROM entries AS e WHERE \(predicate.sql) ORDER BY e.saved_at DESC, e.id DESC",
        predicate.values
      ) { row in
        guard let id = UUID(uuidString: HistoryCatalogConnection.text(row, 0)) else {
          throw Failure.incompatibleSchema
        }
        return Key(tab: query.tab, id: id)
      }
    }
  }

  struct SourceProgress: Sendable {
    let path: String
    let versions: [SourceVersion]
    let key: Key?
  }

  func sourceProgress() throws -> [String: SourceProgress] {
    let decoder = JSONDecoder()
    let rows = try connection.rows("SELECT path, versions, tab, id FROM source_progress") { row in
      let path = HistoryCatalogConnection.text(row, 0)
      guard let bytes = sqlite3_column_blob(row, 1) else { throw Failure.incompatibleSchema }
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 1)))
      let versions = try decoder.decode([SourceVersion].self, from: data)
      let key: Key?
      if let tab = HistoryTab(rawValue: HistoryCatalogConnection.text(row, 2)),
        let id = UUID(uuidString: HistoryCatalogConnection.text(row, 3))
      {
        key = Key(tab: tab, id: id)
      } else {
        key = nil
      }
      return (path, SourceProgress(path: path, versions: versions, key: key))
    }
    return Dictionary(uniqueKeysWithValues: rows)
  }

  private func hasCoverage(_ revision: String?) throws -> Bool {
    guard let revision else { return false }
    return try connection.rows("SELECT revision FROM coverage WHERE revision = ?", [.text(revision)]) {
      HistoryCatalogConnection.text($0, 0)
    }.first == revision
  }

  private func predicate(for query: Query) -> (sql: String, values: [HistoryCatalogConnection.Value]) {
    var conditions = ["e.tab = ?", "(e.expires_at IS NULL OR e.expires_at > ?)"]
    var values: [HistoryCatalogConnection.Value] = [
      .text(query.tab.rawValue), .number(query.now.timeIntervalSinceReferenceDate),
    ]
    if let dates = query.dates {
      conditions.append("e.saved_at >= ? AND e.saved_at < ?")
      values += [.number(dates.start.timeIntervalSinceReferenceDate), .number(dates.end.timeIntervalSinceReferenceDate)]
    }
    if let app = query.app {
      conditions.append("coalesce(e.app, '') = ?")
      values.append(.text(app))
    }
    if query.search.isEmpty == false {
      if hasTrigram, query.search.utf8.count >= 3, query.search.utf8.allSatisfy({ (32...126).contains($0) }) {
        // Only use trigram as a candidate filter for ASCII fields. A locale may match an ASCII
        // query to a non-ASCII field. Foundation remains the final matcher for every result.
        conditions.append("(e.ascii_only = 0 OR e.row_id IN (SELECT rowid FROM search WHERE search MATCH ?))")
        values.append(.text("\"\(query.search.replacingOccurrences(of: "\"", with: "\"\""))\""))
      }
      conditions.append("history_contains(e.fields, ?)")
      values.append(.text(query.search))
    }
    return (conditions.joined(separator: " AND "), values)
  }

  private func decodeSummary(_ row: OpaquePointer) throws -> Summary {
    let count = Int(sqlite3_column_bytes(row, 0))
    guard let bytes = sqlite3_column_blob(row, 0) else { throw Failure.incompatibleSchema }
    return try JSONDecoder().decode(Summary.self, from: Data(bytes: bytes, count: count))
  }

  private static func prepareSearch(using connection: HistoryCatalogConnection) throws -> Bool {
    // Probe in TEMP so lack of OS support does not alter the persisted index.
    do {
      try connection.execute("CREATE VIRTUAL TABLE temp.trigram_probe USING fts5(body, tokenize='trigram')")
    } catch let error as HistoryCatalogConnection.Failure where error.code == SQLITE_ERROR {
      return false
    }
    try connection.execute("DROP TABLE temp.trigram_probe")
    try connection.transaction(write: true) {
      let exists = try connection.rows("SELECT 1 FROM sqlite_schema WHERE name = 'search'") {
        sqlite3_column_int($0, 0)
      }.isEmpty == false
      let needsRebuild = try connection.rows("SELECT needed FROM search_rebuild") {
        sqlite3_column_int($0, 0)
      }.first != 0
      if exists == false {
        try connection.execute("CREATE VIRTUAL TABLE search USING fts5(body, tokenize='trigram')")
      }
      if exists == false || needsRebuild {
        try connection.execute("DELETE FROM search")
        // Use the decoded fields, just like incremental insertion. JSON escaping must not
        // remove genuine substring candidates such as quotes or backslashes.
        try connection.execute("""
          INSERT INTO search(rowid, body)
          SELECT e.row_id, (SELECT group_concat(value, char(10)) FROM json_each(e.fields))
          FROM entries e
          """)
        try connection.execute("UPDATE search_rebuild SET needed = 0")
      }
    }
    return true
  }
}

extension HistoryCatalog.Key {
  fileprivate var parameters: [HistoryCatalogConnection.Value] { [.text(tab.rawValue), .text(id.uuidString)] }
}
