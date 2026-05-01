import Darwin
import Foundation
import Testing

@testable import EnviousWisprAudio

/// Validates Phase R4: `RotatingFileSink` enforces a bounded disk ceiling and
/// stays correct under concurrent writers (in-process and cross-process).
///
/// Tests use a unique per-test directory under `NSTemporaryDirectory()` so
/// parallel tests cannot collide and the developer's real
/// `~/Library/Logs/EnviousWispr/` is never touched.
@Suite("RotatingFileSink")
struct RotatingFileSinkTests {

  /// Builds a fresh isolated directory for one test. Cleaned via the
  /// per-test cleanup callback — never assumes a specific path.
  private static func makeIsolatedDirectory(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "RotatingFileSinkTests-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Basic append

  @Test("Writes are appended in order and visible on disk")
  func appendOrderPreserved() throws {
    let dir = try Self.makeIsolatedDirectory("append-order")
    defer { Self.cleanup(dir) }

    let path = dir.appendingPathComponent("sink.log")
    let sink = RotatingFileSink(path: path, maxSize: 1_000_000, maxFiles: 3)

    sink.append("first\n")
    sink.append("second\n")
    sink.append("third\n")

    let contents = try String(contentsOf: path, encoding: .utf8)
    #expect(contents == "first\nsecond\nthird\n")
  }

  // MARK: - Rotation

  @Test("Rotation caps total retention at maxFiles (active + archives)")
  func rotationCapsRetention() throws {
    let dir = try Self.makeIsolatedDirectory("rotate-cap")
    defer { Self.cleanup(dir) }

    let path = dir.appendingPathComponent("sink.log")
    // 1 KB ceiling, 3-file retention. Each line is roughly 64 bytes; ~24
    // appends will produce multiple rotations before the test ends.
    let sink = RotatingFileSink(path: path, maxSize: 1_024, maxFiles: 3)

    let line = String(repeating: "x", count: 60) + "\n"
    for _ in 0..<60 { sink.append(line) }

    let active = path
    let one = dir.appendingPathComponent("sink.log.1")
    let two = dir.appendingPathComponent("sink.log.2")
    let three = dir.appendingPathComponent("sink.log.3")

    // maxFiles = TOTAL file count: active + .1 + .2 = 3 files. Archive .3
    // must NEVER appear — oldest is dropped on each rotation.
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(FileManager.default.fileExists(atPath: one.path))
    #expect(FileManager.default.fileExists(atPath: two.path))
    #expect(!FileManager.default.fileExists(atPath: three.path))

    // Ceiling check: total bytes on disk are bounded by maxFiles * maxSize
    // (each file just under the cap when it rolled), plus a small slack for
    // the post-write size check that triggered the most recent rotation.
    let urls = [active, one, two]
    let totalBytes = urls.reduce(0) { acc, url in
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
      return acc + ((attrs?[.size] as? Int) ?? 0)
    }
    #expect(totalBytes <= 3 * 1_024 + 1_024)
  }

  // MARK: - Concurrent writers (in-process)

  @Test("Concurrent in-process writers do not produce torn lines")
  func concurrentInProcessWritersAreAtomic() async throws {
    let dir = try Self.makeIsolatedDirectory("concurrent")
    defer { Self.cleanup(dir) }

    let path = dir.appendingPathComponent("sink.log")
    let sink = RotatingFileSink(path: path, maxSize: 10_000_000, maxFiles: 1)

    // Each writer task emits a distinct full line. After all tasks finish,
    // every emitted line must appear intact on disk.
    let writers = 8
    let perWriter = 100
    await withTaskGroup(of: Void.self) { group in
      for w in 0..<writers {
        group.addTask {
          for n in 0..<perWriter {
            sink.append("writer-\(w)-msg-\(n)\n")
          }
        }
      }
    }

    let contents = try String(contentsOf: path, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

    #expect(lines.count == writers * perWriter)
    // Every line matches the expected shape — no torn writes from interleaving.
    for line in lines {
      #expect(line.hasPrefix("writer-"))
      #expect(line.contains("-msg-"))
    }
  }

  // MARK: - Cross-process safety smoke

  @Test("Sibling process appends survive a rotation triggered by us")
  func siblingProcessAppendsSurviveRotation() throws {
    let dir = try Self.makeIsolatedDirectory("cross-process")
    defer { Self.cleanup(dir) }

    let path = dir.appendingPathComponent("sink.log")
    // 256-byte cap, 3-file retention. Sibling write + bounded filler triggers
    // at most one rotation; total bytes written stay under maxFiles × maxSize
    // so the sibling line cannot be evicted past retention.
    let sink = RotatingFileSink(path: path, maxSize: 256, maxFiles: 3)

    // Simulate a sibling-process write by hand: open with O_APPEND outside the
    // sink. The sibling line must appear in the active file or one of the
    // rolled files when we're done — never lost.
    let siblingMarker = "SIBLING-\(UUID().uuidString)"
    let siblingLine = "\(siblingMarker)\n"
    let cPath = path.path
    let fd = cPath.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
    #expect(fd >= 0)
    if fd >= 0 {
      _ = siblingLine.withCString { ptr in
        write(fd, ptr, strlen(ptr))
      }
      close(fd)
    }

    // 6 × ~50-byte filler keeps total bytes under (maxFiles × maxSize), so
    // the sibling line lands in the active file or `.1` after one rotation.
    let filler = String(repeating: "f", count: 48) + "\n"
    for _ in 0..<6 { sink.append(filler) }

    let candidates = [
      path,
      dir.appendingPathComponent("sink.log.1"),
      dir.appendingPathComponent("sink.log.2"),
      dir.appendingPathComponent("sink.log.3"),
    ]

    let foundSomewhere = candidates.contains { url in
      guard let s = try? String(contentsOf: url, encoding: .utf8) else { return false }
      return s.contains(siblingMarker)
    }
    #expect(foundSomewhere)
  }

  // MARK: - writeAllBytes loop (Codex finding #478)

  /// Issue #478: `write(2)` may return fewer bytes than requested, or fail
  /// with `EINTR`, even on regular files. The previous append path discarded
  /// the return value, silently truncating log lines and breaking the sink's
  /// "no torn lines" invariant. These tests pin the retry loop's behaviour.

  @Test("writeAllBytes succeeds when underlying write reports a full success")
  func writeAllBytes_fullWriteSucceeds() throws {
    let payload = Array("abcdefghij".utf8)
    var calls = 0
    let ok = payload.withUnsafeBufferPointer { buf -> Bool in
      RotatingFileSink.writeAllBytes(
        UnsafeRawPointer(buf.baseAddress!),
        buf.count
      ) { _, n in
        calls += 1
        return n
      }
    }
    #expect(ok)
    #expect(calls == 1)
  }

  @Test("writeAllBytes advances cursor across multiple short writes")
  func writeAllBytes_shortWritesAdvanceCursor() throws {
    let payload = Array(repeating: UInt8(0xAB), count: 256)
    // Closure returns 100, 100, 56 — two short writes followed by the tail.
    var schedule = [100, 100, 56]
    var seen: [Int] = []
    let ok = payload.withUnsafeBufferPointer { buf -> Bool in
      let basePtr = UnsafeRawPointer(buf.baseAddress!)
      return RotatingFileSink.writeAllBytes(basePtr, buf.count) { ptr, n in
        let chunk = schedule.removeFirst()
        // Each call should see a cursor advanced by the previous chunks.
        let offset = ptr.distance(to: basePtr) * -1
        seen.append(offset)
        return min(chunk, n)
      }
    }
    #expect(ok)
    #expect(schedule.isEmpty)
    #expect(seen == [0, 100, 200])
  }

  @Test("writeAllBytes retries on EINTR")
  func writeAllBytes_retriesOnEINTR() throws {
    let payload = Array("retry-payload".utf8)
    var calls = 0
    let ok = payload.withUnsafeBufferPointer { buf -> Bool in
      RotatingFileSink.writeAllBytes(
        UnsafeRawPointer(buf.baseAddress!),
        buf.count
      ) { _, n in
        calls += 1
        if calls == 1 {
          errno = EINTR
          return -1
        }
        return n
      }
    }
    #expect(ok)
    #expect(calls == 2)
  }

  @Test("writeAllBytes bails on a hard error (errno != EINTR)")
  func writeAllBytes_failsOnHardError() throws {
    let payload = Array("hard-error".utf8)
    var calls = 0
    let ok = payload.withUnsafeBufferPointer { buf -> Bool in
      RotatingFileSink.writeAllBytes(
        UnsafeRawPointer(buf.baseAddress!),
        buf.count
      ) { _, _ in
        calls += 1
        errno = EIO
        return -1
      }
    }
    #expect(!ok)
    #expect(calls == 1)
  }

  @Test("writeAllBytes bails on a zero-byte return so it does not spin")
  func writeAllBytes_failsOnZeroWrite() throws {
    let payload = Array("zero-write".utf8)
    var calls = 0
    let ok = payload.withUnsafeBufferPointer { buf -> Bool in
      RotatingFileSink.writeAllBytes(
        UnsafeRawPointer(buf.baseAddress!),
        buf.count
      ) { _, _ in
        calls += 1
        return 0
      }
    }
    #expect(!ok)
    #expect(calls == 1)
  }

  // MARK: - Production-path integration (large buffer)

  @Test("Large append lands intact through the production write loop")
  func largeBufferAppendIsIntact() throws {
    let dir = try Self.makeIsolatedDirectory("large-append")
    defer { Self.cleanup(dir) }

    let path = dir.appendingPathComponent("sink.log")
    // Size cap large enough that no rotation fires; exercises the writeAll
    // loop end-to-end through `RotatingFileSink.append`.
    let sink = RotatingFileSink(path: path, maxSize: 8 * 1_024 * 1_024, maxFiles: 1)

    // 256 KB single message — large enough that a real short write or
    // signal interruption is plausible under load. We assert byte equality.
    let body = String(repeating: "x", count: 256 * 1_024)
    let payload = body + "\n"
    sink.append(payload)

    let read = try String(contentsOf: path, encoding: .utf8)
    #expect(read == payload)
  }
}
