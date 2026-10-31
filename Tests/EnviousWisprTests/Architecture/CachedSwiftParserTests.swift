import Darwin
import Foundation
import EnviousWisprAppKitTestSupport
import SwiftSyntax
import Testing

@Suite("Shared source preparation keeps current file identity (#4089)", .tags(.harnessContract, .localParallel))
struct CachedSwiftParserTests {
  private func fixture() throws -> (URL, URL) {
    let root = TestTemporaryDirectory.url.appendingPathComponent("ast-cache-\(UUID())")
    let sources = root.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    return (root, sources.appendingPathComponent("File.swift"))
  }

  @Test("unchanged files share one parse and preserve exact source bytes")
  func unchangedFileReusesPreparation() throws {
    let (root, file) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "let value = 1\n"
    try source.write(to: file, atomically: true, encoding: .utf8)
    let cache = CachedSwiftParser.Cache(root: root, treeIdentity: "fixture-tree")
    let first = try cache.snapshot(at: file)
    let second = try cache.snapshot(at: file)
    #expect(first.tree.id == second.tree.id)
    #expect(Array(second.tree.description.utf8) == Array(source.utf8))
    #expect(cache.statistics.parsedFiles == 1)
    #expect(cache.statistics.hits == 1)
  }

  @Test("same-size edits invalidate even when modification time is restored")
  func changedBytesInvalidatePreparation() throws {
    let (root, file) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let cache = CachedSwiftParser.Cache(root: root, treeIdentity: "fixture-tree")
    _ = try cache.snapshot(at: file)
    var original = stat()
    try #require(file.path.withCString { lstat($0, &original) } == 0)
    let changed = "let value = 2\n"
    try changed.write(to: file, atomically: false, encoding: .utf8)
    var times = [original.st_atimespec, original.st_mtimespec]
    let restored = times.withUnsafeMutableBufferPointer { buffer in
      file.path.withCString { utimensat(AT_FDCWD, $0, buffer.baseAddress, 0) }
    }
    try #require(restored == 0)
    var current = stat()
    try #require(file.path.withCString { lstat($0, &current) } == 0)
    try #require(current.st_ino == original.st_ino && current.st_size == original.st_size)
    try #require(current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
    try #require(current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
    try #require(
      current.st_ctimespec.tv_sec != original.st_ctimespec.tv_sec
        || current.st_ctimespec.tv_nsec != original.st_ctimespec.tv_nsec)
    #expect(Array(try cache.snapshot(at: file).tree.description.utf8) == Array(changed.utf8))
    #expect(cache.statistics.parsedFiles == 2)
  }

  @Test("different files and Unicode spellings keep their own syntax identities")
  func filesAndUnicodeStayDistinct() throws {
    let (root, first) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let second = first.deletingLastPathComponent().appendingPathComponent("Other.swift")
    let third = first.deletingLastPathComponent().appendingPathComponent("Unicode.swift")
    let composed = "let café = 1\n"
    let decomposed = "let cafe\u{301} = 1\n"
    try #require(composed == decomposed)
    try composed.write(to: first, atomically: true, encoding: .utf8)
    try composed.write(to: second, atomically: true, encoding: .utf8)
    try decomposed.write(to: third, atomically: true, encoding: .utf8)
    let cache = CachedSwiftParser.Cache(root: root, treeIdentity: "fixture-tree")
    let a = try cache.snapshot(at: first)
    let b = try cache.snapshot(at: second)
    let c = try cache.snapshot(at: third)
    #expect(a.tree.id != b.tree.id)
    #expect(Array(a.tree.description.utf8) == Array(composed.utf8))
    #expect(Array(c.tree.description.utf8) == Array(decomposed.utf8))
    #expect(cache.statistics.parsedFiles == 3)
  }

  @Test("missing tree identity and exhausted preparation budget recompute current source")
  func unavailableCacheRecomputes() throws {
    let (root, file) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "let value = 1\n"
    try source.write(to: file, atomically: true, encoding: .utf8)
    for cache in [
      CachedSwiftParser.Cache(root: root, treeIdentity: nil),
      CachedSwiftParser.Cache(root: root, treeIdentity: "fixture-tree", maximumSourceBytes: 1),
    ] {
      for _ in 0..<2 {
        #expect(Array(try cache.snapshot(at: file).tree.description.utf8) == Array(source.utf8))
      }
      #expect(cache.statistics.parsedFiles == 2)
      #expect(cache.statistics.retainedSourceBytes == 0)
    }
  }

  @Test("concurrent readers share preparation without racing the syntax arena")
  func concurrentReadersParseOnce() async throws {
    let (root, file) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "let value = 1\n"
    try source.write(to: file, atomically: true, encoding: .utf8)
    let cache = CachedSwiftParser.Cache(root: root, treeIdentity: "fixture-tree")
    try await withThrowingTaskGroup(of: [UInt8].self) { group in
      for _ in 0..<8 {
        group.addTask { Array(try cache.snapshot(at: file).tree.description.utf8) }
      }
      for try await bytes in group { #expect(bytes == Array(source.utf8)) }
    }
    #expect(cache.statistics.parsedFiles == 1)
    #expect(cache.statistics.hits == 7)
  }
}
