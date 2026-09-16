import Foundation
import SQLite3

/// Builds rival-app stores in their real on-disk shapes for BOTH adapter suites, the word
/// adapters (`SmartImportSourceTests`) and the snippet adapters
/// (`SnippetImportAppAdaptersTests`, #2997), so the two cannot drift on what Wispr Flow's
/// table or TypeWhisper's store looks like. Column shapes were captured from live data on
/// 2026-07-19 (words) and 2026-09-15 (snippets).
enum RivalAppStoreFixtures {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// A fresh temporary directory the caller removes in a `defer`.
  static func makeDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-rival-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Wispr Flow's `Dictionary` table with the columns both adapters read, then `rows` (SQL
  /// `INSERT` statements). The connection is closed on return, so no sidecar remains: the
  /// state of a cleanly quit Wispr Flow, which is what the immutable read expects.
  static func makeWisprFlowDatabase(in dir: URL, rows: String) throws -> URL {
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      sqlite3_close(db)
      throw Failure(description: "could not create \(url.path)")
    }
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      \(rows)
      """
    try exec(db, schema)
    return url
  }

  /// A TypeWhisper Core Data store (`name`, e.g. `dictionary.store` or `snippets.store`) in
  /// WAL mode with auto-checkpoint OFF, holding `schema` (a `CREATE TABLE` plus inserts).
  ///
  /// Returns the url AND the open writer connection. The caller must keep that connection
  /// alive across the read and close it in a `defer`: closing it first CHECKPOINTS the WAL
  /// into the main file (measured, `-wal` drops to zero bytes), which destroys the very
  /// state the WAL tests exist to reproduce and quietly makes them pass against the design
  /// they exist to reject.
  ///
  /// `walOnlyInsert`, when given, is written AFTER a `TRUNCATE` checkpoint, so that row
  /// lives in the WAL alone and the main file cannot see it.
  static func makeTypeWhisperStore(
    named name: String, in dir: URL, schema: String, walOnlyInsert: String? = nil
  ) throws -> (url: URL, writer: OpaquePointer?) {
    let url = dir.appendingPathComponent(name)
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      sqlite3_close(db)
      throw Failure(description: "could not create \(url.path)")
    }
    // The open connection is the caller's only on success; a throw below must not leak it.
    var transferred = false
    defer {
      if !transferred { sqlite3_close(db) }
    }
    try exec(db, "PRAGMA journal_mode=WAL;")
    try exec(db, "PRAGMA wal_autocheckpoint=0;")
    try exec(db, schema)
    if let walOnlyInsert {
      try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
      try exec(db, walOnlyInsert)
    }
    transferred = true
    return (url, db)
  }

  /// A Wispr Flow `flow.sqlite` in WAL mode with auto-checkpoint OFF, matching a RUNNING
  /// Wispr Flow (#3012): `baselineRows` are checkpointed (TRUNCATE) into the main file, then
  /// `walOnlyRows`, when given, are written and live in the `-wal` alone. Returns the url AND
  /// the open writer connection; the caller MUST keep it alive across the read and close it in
  /// a `defer`, because closing it first checkpoints and drops the `-wal`, destroying the
  /// live-writer state these tests reproduce (same contract as `makeTypeWhisperStore`).
  static func makeWisprFlowDatabaseWAL(
    in dir: URL, baselineRows: String, walOnlyRows: String? = nil
  ) throws -> (url: URL, writer: OpaquePointer?) {
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      sqlite3_close(db)
      throw Failure(description: "could not create \(url.path)")
    }
    var transferred = false
    defer {
      if !transferred { sqlite3_close(db) }
    }
    try exec(db, "PRAGMA journal_mode=WAL;")
    try exec(db, "PRAGMA wal_autocheckpoint=0;")
    try exec(
      db,
      """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      """)
    try exec(db, baselineRows)
    try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    if let walOnlyRows {
      try exec(db, walOnlyRows)
    }
    transferred = true
    return (url, db)
  }

  private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(message)
      throw Failure(description: "sqlite3_exec failed: \(text)")
    }
  }
}
