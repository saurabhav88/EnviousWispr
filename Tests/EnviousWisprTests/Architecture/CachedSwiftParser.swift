import Darwin
import Foundation
import SwiftParser
import SwiftSyntax

/// Shared immutable preparation only. Every guard still runs its own semantic visitors/assertions.
/// File identity changes invalidate entries; fixture strings are deliberately parsed afresh.
enum CachedSwiftParser {
  #if DEBUG
    private static let maximumNestingLevel = 20
  #else
    private static let maximumNestingLevel = 256
  #endif

  /// Keep the pinned parser's configuration semantics when using Xcode's optimized libraries.
  static func parse(source: String) -> SourceFileSyntax {
    var parser = Parser(source, maximumNestingLevel: maximumNestingLevel)
    return SourceFileSyntax.parse(from: &parser)
  }

  struct Snapshot: Sendable {
    let source: String
    let tree: SourceFileSyntax
  }

  private static let shared = Cache(root: RepoRoot.url, treeIdentity: indexTree())

  static func snapshot(at url: URL) throws -> Snapshot {
    try shared.snapshot(at: url)
  }

  private static func indexTree() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", RepoRoot.url.path, "write-tree"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let tree = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return tree.count == 40 ? tree : nil
  }

  /// One instance per checkout/index tree and process. No disk verdict cache or mutable fixture cache.
  final class Cache: @unchecked Sendable {
    private struct Identity: Equatable {
      let device: dev_t
      let inode: ino_t
      let size: off_t
      let modifiedSeconds: Int
      let modifiedNanos: Int
      let changedSeconds: Int
      let changedNanos: Int
    }

    private struct Entry {
      let identity: Identity
      let snapshot: Snapshot
      let bytes: Int
    }

    private let root: URL
    private let treeIdentity: String?
    private let maximumSourceBytes: Int
    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]
    private var retainedBytes = 0
    private var parsedFiles = 0
    private var hits = 0

    init(root: URL, treeIdentity: String?, maximumSourceBytes: Int = 64 * 1024 * 1024) {
      self.root = root
      self.treeIdentity = treeIdentity
      self.maximumSourceBytes = maximumSourceBytes
    }

    var statistics: (parsedFiles: Int, hits: Int, retainedSourceBytes: Int) {
      lock.withLock { (parsedFiles, hits, retainedBytes) }
    }

    private func identity(at url: URL) -> Identity? {
      var value = stat()
      guard url.path.withCString({ lstat($0, &value) }) == 0,
        value.st_mode & S_IFMT == S_IFREG
      else { return nil }
      return Identity(
        device: value.st_dev, inode: value.st_ino, size: value.st_size,
        modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
        changedSeconds: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec)
    }

    func snapshot(at url: URL) throws -> Snapshot {
      try lock.withLock {
        let path = url.path
        let inSourceTree = path.hasPrefix(root.path + "/Sources/")
          || path.hasPrefix(root.path + "/Tests/")
        let before = identity(at: url)
        // Byte-exact paths avoid Swift String's Unicode-equivalent-key aliasing.
        let key = Data(((treeIdentity ?? "") + "\0" + path).utf8)
        let cacheable = treeIdentity != nil && inSourceTree && url.pathExtension == "swift"
          && before != nil
        if cacheable, let entry = entries[key], entry.identity == before,
          identity(at: url) == before
        {
          hits += 1
          return entry.snapshot
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let snapshot = Snapshot(source: source, tree: CachedSwiftParser.parse(source: source))
        parsedFiles += 1
        if let old = entries.removeValue(forKey: key) { retainedBytes -= old.bytes }
        let bytes = source.utf8.count
        if cacheable, let before, identity(at: url) == before, bytes <= maximumSourceBytes {
          if retainedBytes + bytes > maximumSourceBytes {
            entries.removeAll()
            retainedBytes = 0
          }
          entries[key] = Entry(identity: before, snapshot: snapshot, bytes: bytes)
          retainedBytes += bytes
        }
        return snapshot
      }
    }
  }
}
