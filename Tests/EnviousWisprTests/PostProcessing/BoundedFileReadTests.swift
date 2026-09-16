import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2997 — the one read-to-ceiling loop three import sites share.
///
/// `.driftGuard`: it pins a property of OUR reader (returns up to ceiling-plus-one bytes,
/// byte for byte; loops over short reads to EOF; runs the pre-read hook before every chunk
/// and propagates its error unchanged) that three callers' contracts rest on. A user never
/// sees this suite fail directly; the callers' own suites carry the outcome.
@Suite("BoundedFileRead (#2997)", .tags(.driftGuard))
struct BoundedFileReadTests {

  /// Patterned bytes, so a wrong slice or a reordered chunk fails on CONTENT, not on count.
  private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
  }

  private func tempFile(_ bytes: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-bounded-\(UUID().uuidString).bin")
    try bytes.write(to: url)
    return url
  }

  @Test("A file exactly at the ceiling comes back whole, byte for byte")
  func exactCeilingReturnsEveryByte() throws {
    let bytes = pattern(1_000)
    let url = try tempFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try BoundedFileRead.read(at: url, ceiling: 1_000) == bytes)
  }

  @Test("A file one byte over the ceiling returns exactly ceiling-plus-one bytes; the caller decides")
  func oneOverReturnsCeilingPlusOne() throws {
    let bytes = pattern(1_001)
    let url = try tempFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try BoundedFileRead.read(at: url, ceiling: 1_000) == bytes)
  }

  @Test("A file far over the ceiling still returns only ceiling-plus-one bytes")
  func farOverReturnsCeilingPlusOne() throws {
    let bytes = pattern(5_000)
    let url = try tempFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try BoundedFileRead.read(at: url, ceiling: 1_000) == bytes.prefix(1_001))
  }

  @Test("Short reads accumulate to EOF: seven-byte reads of a 100-byte file return all 100")
  func shortReadsAccumulate() throws {
    let bytes = pattern(100)
    let url = try tempFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    var reads = 0
    let data = try BoundedFileRead.read(at: url, ceiling: 1_000, beforeEachRead: {}) {
      handle, count in
      reads += 1
      return try handle.read(upToCount: min(7, count))
    }
    #expect(data == bytes)
    #expect(reads == 16)  // 14 seven-byte reads, one two-byte read, then the EOF read.
  }

  @Test("A missing file is cannotOpen, never an empty read")
  func missingFileThrowsCannotOpen() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-bounded-missing-\(UUID().uuidString).bin")
    #expect(throws: BoundedFileRead.Failure.cannotOpen) {
      try BoundedFileRead.read(at: url, ceiling: 10)
    }
  }

  @Test("The pre-read hook runs before the first chunk and its error propagates unchanged")
  func beforeEachReadPropagatesItsOwnError() throws {
    struct Stop: Error {}
    let url = try tempFile(pattern(10))
    defer { try? FileManager.default.removeItem(at: url) }
    var calls = 0
    #expect(throws: Stop.self) {
      try BoundedFileRead.read(at: url, ceiling: 100) {
        calls += 1
        throw Stop()
      }
    }
    #expect(calls == 1)
  }

  @Test("Cancellation AFTER a short read propagates as CancellationError, not a reader failure")
  func cancellationAfterShortReadIsCancellationError() throws {
    let url = try tempFile(pattern(100))
    defer { try? FileManager.default.removeItem(at: url) }
    var hookCalls = 0
    #expect(throws: CancellationError.self) {
      try BoundedFileRead.read(
        at: url, ceiling: 1_000,
        beforeEachRead: {
          hookCalls += 1
          if hookCalls == 2 { throw CancellationError() }
        }
      ) { handle, count in try handle.read(upToCount: min(7, count)) }
    }
    #expect(hookCalls == 2)
  }

  @Test("The default hook is task cancellation: a cancelled task throws CancellationError")
  func defaultHookIsTaskCancellation() async throws {
    let url = try tempFile(pattern(10))
    defer { try? FileManager.default.removeItem(at: url) }
    let task = Task {
      // Cancelled from INSIDE the task, before the reader is called, so the first hook call
      // sees the flag; an external `cancel()` could lose the race to a completed read.
      withUnsafeCurrentTask { $0?.cancel() }
      return try BoundedFileRead.read(at: url, ceiling: 100)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
