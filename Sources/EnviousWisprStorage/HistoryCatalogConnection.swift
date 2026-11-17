import Foundation
import SQLite3

/// Owned by HistoryCatalog's actor. Statements and their pointers never leave its synchronous
/// operations. The SQLite callbacks use only their supplied row values.
final class HistoryCatalogConnection {
  struct Failure: Error {
    let code: Int32
  }

  enum Value {
    case null
    case text(String)
    case number(Double)
    case integer(Int64)
    case bytes(Data)
  }

  private var database: OpaquePointer?
  /// Prepared statements by SQL text, reset and reused (#4586 H6). A statement is checked out
  /// while it runs, so a nested call with the same SQL prepares its own instead of resetting one
  /// that is still stepping.
  private var statements: [String: OpaquePointer] = [:]
  /// The SQL texts are fixed literals plus the few shapes `HistoryCatalog` builds from a query;
  /// the cap only bounds a future caller that builds unbounded SQL.
  private static let maxStatements = 64
  /// Nested `rows` calls in progress. The outermost one installs and removes the progress handler.
  private var readDepth = 0
  /// SQLite VM steps between cancellation checks while `rows` steps (#4586 B2). Measured on the
  /// 27k-row synthetic catalog (M5 Max, Debug): an uncancelled no-match scan is not measurably
  /// slower, and a cancelled one stops within about a millisecond (p95 1.2 ms, was 125 ms).
  private static let progressInterval: Int32 = 1000
  private static let transient = transientDestructor

  init(path: String) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
    let result = sqlite3_open_v2(path, &handle, flags, nil)
    guard result == SQLITE_OK, let handle else {
      sqlite3_close(handle)
      throw Failure(code: result)
    }
    var registered = sqlite3_create_function_v2(
      handle, "history_contains", 2, SQLITE_UTF8, nil,
      { context, count, arguments in
        guard count == 2, let arguments, sqlite3_value_type(arguments[0]) != SQLITE_NULL,
          let search = sqlite3_value_text(arguments[1])
        else {
          sqlite3_result_error_code(context, SQLITE_MISMATCH)
          return
        }
        let query = String(decoding: UnsafeBufferPointer(
          start: search, count: Int(sqlite3_value_bytes(arguments[1]))), as: UTF8.self)
        switch SearchFields.contains(query, in: SearchFields.bytes(of: arguments[0])) {
        case .some(let found): sqlite3_result_int(context, found ? 1 : 0)
        case .none: sqlite3_result_error_code(context, SQLITE_CORRUPT)
        }
      }, nil, nil, nil)
    if registered == SQLITE_OK {
      // The trigram index body for a stored row: its fields joined by newlines, the same text
      // `HistoryCatalog.apply` indexes, so the rare full index rebuild stays one streamed statement.
      registered = sqlite3_create_function_v2(
        handle, "history_search_body", 1, SQLITE_UTF8, nil,
        { context, count, arguments in
          guard count == 1, let arguments, sqlite3_value_type(arguments[0]) != SQLITE_NULL,
            let fields = SearchFields.decode(SearchFields.bytes(of: arguments[0]))
          else {
            sqlite3_result_error_code(context, SQLITE_CORRUPT)
            return
          }
          let body = fields.joined(separator: "\n")
          sqlite3_result_text64(context, body, UInt64(body.utf8.count), transientDestructor, UInt8(SQLITE_UTF8))
        }, nil, nil, nil)
    }
    guard registered == SQLITE_OK else {
      sqlite3_close(handle)
      throw Failure(code: registered)
    }
    database = handle
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close(database)
  }

  func closeDatabase() throws {
    guard let database else { return }
    // `sqlite3_close` refuses with SQLITE_BUSY while any prepared statement is unfinalized.
    for statement in statements.values { sqlite3_finalize(statement) }
    statements.removeAll()
    let result = sqlite3_close(database)
    guard result == SQLITE_OK else { throw Failure(code: result) }
    self.database = nil
  }

  func execute(_ sql: String, _ parameters: [Value] = []) throws {
    try withStatement(sql, parameters) { statement in
      var result = sqlite3_step(statement)
      while result == SQLITE_ROW { result = sqlite3_step(statement) }
      guard result == SQLITE_DONE else { throw Failure(code: result) }
    }
  }

  func rows<Row>(
    _ sql: String, _ parameters: [Value] = [], _ read: (OpaquePointer) throws -> Row
  ) throws -> [Row] {
    try withStatement(sql, parameters) { statement in
      try stoppingWhenCancelled {
        var rows: [Row] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
          try Task.checkCancellation()
          rows.append(try read(statement))
          result = sqlite3_step(statement)
        }
        if result == SQLITE_INTERRUPT, Task.isCancelled { throw CancellationError() }
        guard result == SQLITE_DONE else { throw Failure(code: result) }
        return rows
      }
    }
  }

  /// A statement that matches few or no rows never reaches the per-row check above, so a search
  /// superseded by the next keystroke would scan every row while the catalog actor makes the
  /// next read wait (#4586 B2). This handler ends the step with SQLITE_INTERRUPT once the calling
  /// Task is cancelled. It runs synchronously inside that Task, between VM steps, so one
  /// `history_contains` call already running still finishes first. `execute` stays without it.
  private func stoppingWhenCancelled<Result>(_ run: () throws -> Result) throws -> Result {
    guard let database else { throw Failure(code: SQLITE_ABORT) }
    if readDepth == 0 {
      sqlite3_progress_handler(database, Self.progressInterval, { _ in Task.isCancelled ? 1 : 0 }, nil)
    }
    readDepth += 1
    defer {
      readDepth -= 1
      if readDepth == 0 { sqlite3_progress_handler(database, 0, nil, nil) }
    }
    return try run()
  }

  func transaction<Result>(write: Bool = false, _ run: () throws -> Result) throws -> Result {
    try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
    do {
      let result = try run()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    guard let text = sqlite3_column_text(statement, column) else { return "" }
    let count = Int(sqlite3_column_bytes(statement, column))
    return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
  }

  private func withStatement<Result>(
    _ sql: String, _ parameters: [Value], _ run: (OpaquePointer) throws -> Result
  ) throws -> Result {
    guard let database else { throw Failure(code: SQLITE_ABORT) }
    let statement: OpaquePointer
    if let cached = statements.removeValue(forKey: sql) {
      statement = cached
    } else {
      var prepared: OpaquePointer?
      let result = sqlite3_prepare_v3(database, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
      guard result == SQLITE_OK, let prepared else {
        sqlite3_finalize(prepared)
        throw Failure(code: result)
      }
      statement = prepared
    }
    defer {
      // Reset reports the last step's error again; the caller has already thrown it. Reset also
      // releases the read snapshot of a statement whose rows were not all stepped.
      let reset = sqlite3_reset(statement)
      let cleared = sqlite3_clear_bindings(statement)
      if reset == SQLITE_OK, cleared == SQLITE_OK, self.database != nil, statements[sql] == nil,
        statements.count < Self.maxStatements
      {
        statements[sql] = statement
      } else {
        sqlite3_finalize(statement)
      }
    }
    guard sqlite3_bind_parameter_count(statement) == parameters.count else {
      throw Failure(code: SQLITE_MISUSE)
    }
    for (offset, value) in parameters.enumerated() {
      let index = Int32(offset + 1)
      let bound: Int32
      switch value {
      case .null:
        bound = sqlite3_bind_null(statement, index)
      case .text(let text):
        bound = text.withCString {
          sqlite3_bind_text64(statement, index, $0, UInt64(text.utf8.count), Self.transient, UInt8(SQLITE_UTF8))
        }
      case .number(let value):
        bound = sqlite3_bind_double(statement, index, value)
      case .integer(let value):
        bound = sqlite3_bind_int64(statement, index, value)
      case .bytes(let data) where data.isEmpty:
        // An empty buffer has no base address, and a NULL pointer binds SQL NULL, not a BLOB.
        bound = sqlite3_bind_zeroblob(statement, index, 0)
      case .bytes(let data):
        bound = data.withUnsafeBytes {
          sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(data.count), Self.transient)
        }
      }
      guard bound == SQLITE_OK else { throw Failure(code: bound) }
    }
    return try run(statement)
  }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The searchable fields of one catalog row as one BLOB (#4586 N3): each field is a 4-byte
/// little-endian UTF-8 byte count followed by its bytes. Search walks it without a JSON decoder
/// and still tests every field on its own, so a match never spans two fields.
enum SearchFields {
  static func encode(_ fields: [String]) -> Data {
    var data = Data()
    data.reserveCapacity(fields.reduce(0) { $0 + 4 + $1.utf8.count })
    for field in fields {
      withUnsafeBytes(of: UInt32(field.utf8.count).littleEndian) { data.append(contentsOf: $0) }
      data.append(contentsOf: field.utf8)
    }
    return data
  }

  /// A zero-length BLOB reads as a NULL pointer; it holds no fields.
  static func bytes(of value: OpaquePointer?) -> UnsafeRawBufferPointer {
    UnsafeRawBufferPointer(start: sqlite3_value_blob(value), count: Int(sqlite3_value_bytes(value)))
  }

  /// Nil when the bytes are not a whole sequence of length-prefixed fields.
  static func decode(_ bytes: UnsafeRawBufferPointer) -> [String]? {
    ranges(of: bytes)?.map { String(decoding: UnsafeRawBufferPointer(rebasing: bytes[$0]), as: UTF8.self) }
  }

  /// History search's final matcher: Foundation's locale-aware, case-insensitive test on each
  /// field. Nil when the bytes are malformed anywhere, even after a matching field.
  static func contains(_ query: String, in bytes: UnsafeRawBufferPointer) -> Bool? {
    ranges(of: bytes)?.contains {
      String(decoding: UnsafeRawBufferPointer(rebasing: bytes[$0]), as: UTF8.self)
        .localizedCaseInsensitiveContains(query)
    }
  }

  private static func ranges(of bytes: UnsafeRawBufferPointer) -> [Range<Int>]? {
    var ranges: [Range<Int>] = []
    var offset = 0
    while offset < bytes.count {
      guard bytes.count - offset >= 4 else { return nil }
      let length = (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
      offset += 4
      guard bytes.count - offset >= length else { return nil }
      ranges.append(offset..<offset + length)
      offset += length
    }
    return ranges
  }
}
