import Foundation

/// The one read-to-ceiling loop behind every bounded file read in this module (#2997).
///
/// Three sites used to carry their own copy of this loop — the user-chosen import file,
/// a competitor's vocabulary file, and one part of TypeWhisper's Core Data store — with
/// three different CONTRACTS around it. Only the mechanics are shared here; each caller
/// keeps its own contract: whether a missing file is `nil` or an error, what "too big"
/// throws, and whether the ceiling-plus-one bytes are returned for an aggregate check.
/// That is why this returns whatever it read and never decides overflow itself.
///
/// Properties every caller relies on, stated once:
/// - The size is bounded by the READ, not by a `stat` before it: between a stat and a
///   load the file can grow or be replaced, and the ceiling would be bypassed on exactly
///   the input it exists to refuse. Reading one byte past the ceiling from a single open
///   handle answers "is this too big" and "give me the bytes" as one operation.
/// - It loops to EOF. A single `read(upToCount:)` may return FEWER bytes without having
///   reached the end — routine for network-mounted and cloud-backed files — which would
///   silently hand back a truncated prefix and could miss that the file exceeds the limit.
/// - `read(upToCount:)` signals EOF with NIL and a genuine failure by throwing; the two are
///   kept apart, because collapsing them turned every successful read-to-completion into
///   "unreadable" once.
/// - `beforeEachRead` runs before every chunk and its error propagates UNCHANGED, so a
///   caller that passes `Task.checkCancellation` keeps cancellation between short reads
///   (a `CancellationError` must never be rewritten into the caller's "unreadable").
enum BoundedFileRead {
  enum Failure: Error, Equatable {
    case cannotOpen
    case readFailed
  }

  /// Read up to `ceiling + 1` bytes from `url`, or to EOF, whichever comes first.
  ///
  /// Returns MORE than `ceiling` bytes when the file is larger than the ceiling; the
  /// caller decides what that means.
  static func read(
    at url: URL,
    ceiling: Int,
    beforeEachRead: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> Data {
    try read(at: url, ceiling: ceiling, beforeEachRead: beforeEachRead) { handle, count in
      try handle.read(upToCount: count)
    }
  }

  /// The loop with its one read operation injected, so a test can force SHORT reads from
  /// a real file and prove accumulation and cancellation-after-a-short-read. Production
  /// passes `FileHandle.read(upToCount:)` through the overload above.
  static func read(
    at url: URL,
    ceiling: Int,
    beforeEachRead: () throws -> Void,
    readChunk: (FileHandle, Int) throws -> Data?
  ) throws -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.cannotOpen }
    defer { try? handle.close() }
    let limit = ceiling + 1
    var data = Data()
    while data.count < limit {
      try beforeEachRead()
      let chunk: Data?
      do {
        chunk = try readChunk(handle, limit - data.count)
      } catch {
        throw Failure.readFailed
      }
      guard let chunk, !chunk.isEmpty else { break }  // EOF
      data.append(chunk)
    }
    return data
  }
}
