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
  /// `INSERT` statements). This fixture stays in DELETE mode and closes without sidecars. It
  /// does not model #3032's WAL-header/no-sidecars state; use
  /// `makeWisprFlowDatabaseWALHeaderNoSidecars` for that shape.
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

  /// The shape the founder's real Wispr Flow store rests in and the one #3032 was about:
  /// header bytes 18 and 19 both `2` (WAL), and NO `-wal`, `-shm` or `-journal` beside it.
  ///
  /// Produced through SQLite's own lifecycle, never manufactured: enter WAL mode, commit
  /// `rows`, and close the LAST connection normally. On that close SQLite checkpoints the WAL
  /// into the main file and deletes both sidecars, but the header keeps saying WAL. A strictly
  /// read-only open of this shape answers `SQLITE_CANTOPEN` at prepare because it may not
  /// create the wal-index (measured on macOS SQLite 3.54.0); the two existing Wispr Flow
  /// fixtures never produce it, because `makeWisprFlowDatabase` never enters WAL mode and
  /// `makeWisprFlowDatabaseWAL` hands back an OPEN writer.
  ///
  /// One `sqlite3_file_control` is needed to get there on THIS Mac, and it is lifecycle
  /// configuration, not a shortcut: Apple's system SQLite defaults `SQLITE_FCNTL_PERSIST_WAL`
  /// to 1, so its normal close leaves a 0-byte `-wal` and a 32 KiB `-shm` behind (measured,
  /// 3.54.0). Upstream SQLite defaults it to 0 and deletes both, and that is the build Wispr
  /// Flow ships inside Electron, which is why the founder's store has no sidecars at all.
  /// Setting it to 0 here reproduces the rival's close, not ours.
  ///
  /// Every precondition THROWS. A fixture that silently returned some other shape would let
  /// the regression it exists for pass against the design it exists to reject, and a Swift
  /// `assert` would vanish from an optimized build.
  static func makeWisprFlowDatabaseWALHeaderNoSidecars(in dir: URL, rows: String) throws -> URL
  {
    let url = dir.appendingPathComponent("flow.sqlite")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      sqlite3_close(db)
      throw Failure(description: "could not create \(url.path)")
    }
    var closed = false
    defer { if !closed { sqlite3_close(db) } }
    try exec(db, "PRAGMA journal_mode=WAL;")
    var persistWAL: Int32 = 0
    let controlResult = sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
    guard controlResult == SQLITE_OK else {
      throw Failure(description: "SQLITE_FCNTL_PERSIST_WAL=0 returned \(controlResult)")
    }
    try exec(
      db,
      """
      CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255) NOT NULL,
        replacement VARCHAR(255), isDeleted TINYINT DEFAULT 0, isSnippet TINYINT DEFAULT 0);
      """)
    try exec(db, rows)
    // The normal close of the last connection is what checkpoints and removes the sidecars.
    let closeResult = sqlite3_close(db)
    if closeResult == SQLITE_OK { closed = true }
    guard closeResult == SQLITE_OK else {
      throw Failure(description: "close returned \(closeResult), not SQLITE_OK")
    }
    try requireWALHeaderWithNoSidecars(at: url)
    return url
  }

  /// The raw-byte and filesystem proof that `url` is the WAL-header/no-sidecars shape. Public
  /// to the suites so a test can re-prove the shape immediately before a read, independently
  /// of the production reader it is about to exercise.
  static func requireWALHeaderWithNoSidecars(at url: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
      throw Failure(description: "main file missing at \(url.path)")
    }
    let header = try Data(contentsOf: url, options: .alwaysMapped).prefix(100)
    guard header.count == 100 else {
      throw Failure(description: "header is \(header.count) bytes, expected 100")
    }
    // Offsets 18 and 19 are the file-format write and read versions: 1 = legacy (rollback
    // journal), 2 = WAL. https://www.sqlite.org/fileformat.html#file_format_version_numbers
    let writeVersion = header[header.startIndex + 18]
    let readVersion = header[header.startIndex + 19]
    guard writeVersion == 2, readVersion == 2 else {
      throw Failure(
        description: "header bytes 18,19 are \(writeVersion),\(readVersion), expected 2,2 (WAL)")
    }
    for suffix in ["-wal", "-shm", "-journal"] where fm.fileExists(atPath: url.path + suffix) {
      throw Failure(description: "sidecar \(suffix) is present; the shape requires none")
    }
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
