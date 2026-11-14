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
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(path: String) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
    let result = sqlite3_open_v2(path, &handle, flags, nil)
    guard result == SQLITE_OK, let handle else {
      sqlite3_close(handle)
      throw Failure(code: result)
    }
    let registered = sqlite3_create_function_v2(
      handle, "history_contains", 2, SQLITE_UTF8, nil,
      { context, count, arguments in
        guard count == 2, let arguments,
          let json = sqlite3_value_text(arguments[0]),
          let search = sqlite3_value_text(arguments[1])
        else {
          sqlite3_result_error_code(context, SQLITE_MISMATCH)
          return
        }
        let data = Data(bytes: json, count: Int(sqlite3_value_bytes(arguments[0])))
        let query = String(decoding: UnsafeBufferPointer(
          start: search, count: Int(sqlite3_value_bytes(arguments[1]))), as: UTF8.self)
        do {
          let fields = try JSONDecoder().decode([String].self, from: data)
          sqlite3_result_int(context, fields.contains { $0.localizedCaseInsensitiveContains(query) } ? 1 : 0)
        } catch {
          sqlite3_result_error_code(context, SQLITE_CORRUPT)
        }
      }, nil, nil, nil)
    guard registered == SQLITE_OK else {
      sqlite3_close(handle)
      throw Failure(code: registered)
    }
    database = handle
  }

  deinit { sqlite3_close(database) }

  func closeDatabase() throws {
    guard let database else { return }
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
      var rows: [Row] = []
      var result = sqlite3_step(statement)
      while result == SQLITE_ROW {
        try Task.checkCancellation()
        rows.append(try read(statement))
        result = sqlite3_step(statement)
      }
      guard result == SQLITE_DONE else { throw Failure(code: result) }
      return rows
    }
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
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard result == SQLITE_OK, let statement else { throw Failure(code: result) }
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
