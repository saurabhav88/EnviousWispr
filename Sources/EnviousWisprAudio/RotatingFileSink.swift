import Darwin
import Foundation
import os

/// Synchronous, lock-guarded file sink with append-with-rotation semantics.
///
/// Designed for diagnostic logs that must remain bounded on disk. Callers are
/// frequently in audio-thread-adjacent or RT-sensitive contexts that cannot
/// `await`, so this sink is intentionally NOT an actor — write operations are
/// nonisolated, lock-guarded syscalls.
///
/// ## Concurrency model
///
/// - In-process: `OSAllocatedUnfairLock` serializes `append` calls so the
///   open-write-rotate sequence is atomic.
/// - Cross-process: `flock(LOCK_EX)` on a *separate, stable* lock file
///   (`<base>.lock`) serializes writes from sibling processes. The lock is
///   intentionally NOT taken on the active log file's descriptor, since
///   rotation renames that file mid-sequence — flock follows the inode, so a
///   waiter that acquired before rename would still hold a lock on the rolled
///   file while another process opened a fresh active and proceeded. Using a
///   stable lock file avoids that race.
/// - The class is `@unchecked Sendable` because Swift 6 cannot prove the
///   safety automatically. The path/maxSize/maxFiles are immutable; the only
///   mutable state is the on-disk file itself, which is protected by the two
///   locks above.
///
/// ## Rotation policy
///
/// `maxFiles` is the **total file count** retained on disk (active +
/// rolled), so the disk ceiling is `maxSize * maxFiles`. After a rotation:
///
/// - `maxFiles == 1` → active is truncated (no archive kept).
/// - `maxFiles == 2` → active becomes `<base>.1`; total = 2 files.
/// - `maxFiles == 3` → `.1` becomes `.2`; active becomes `.1`; total = 3 files.
///
/// On `append`, post-write file size is checked. If it exceeds `maxSize`,
/// rotation runs synchronously while the cross-process lock is held.
///
/// ## Constraints (from architecture-rules)
///
/// Callers must NOT invoke `append` while holding the RT audio lock — see
/// `architecture-rules.md` Audio/ASR Danger Zones. Capture the message
/// outside the RT lock and emit afterwards.
public final class RotatingFileSink: @unchecked Sendable {
  private let path: URL
  private let lockFilePath: URL
  private let maxSize: Int
  private let maxFiles: Int
  private let lock = OSAllocatedUnfairLock()

  public init(path: URL, maxSize: Int = 5 * 1_024 * 1_024, maxFiles: Int = 3) {
    self.path = path
    // Stable companion file for cross-process flock. Never renamed, never
    // touched by rotation logic — its only role is to host an OS file lock
    // that survives renames of the active log.
    self.lockFilePath = path.deletingLastPathComponent()
      .appendingPathComponent("\(path.lastPathComponent).lock")
    self.maxSize = maxSize
    self.maxFiles = maxFiles
  }

  /// Append a single message to the sink. Synchronous and nonisolated; safe to
  /// call from non-RT audio paths. Failures are silent (best-effort logging).
  public func append(_ message: String) {
    let data = Data(message.utf8)
    lock.withLock {
      Self.atomicAppendWithRotation(
        path: path,
        lockFilePath: lockFilePath,
        data: data,
        maxSize: maxSize,
        maxFiles: maxFiles)
    }
  }

  // MARK: - File helpers (BSD syscalls)

  /// Opens a stable lock file, takes `flock(LOCK_EX)`, then opens the active
  /// log with O_APPEND and writes. If the post-write size exceeds `maxSize`,
  /// rotation runs while the cross-process lock is still held. The active-log
  /// fd is closed before rotation so its rename can proceed.
  ///
  /// All errors swallowed — diagnostic logs must not propagate failure.
  private static func atomicAppendWithRotation(
    path: URL,
    lockFilePath: URL,
    data: Data,
    maxSize: Int,
    maxFiles: Int
  ) {
    try? FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(),
      withIntermediateDirectories: true)

    // 1. Stable lock file — never renamed, immune to rotation churn.
    let lockFd = lockFilePath.path.withCString {
      open($0, O_WRONLY | O_CREAT, 0o644)
    }
    guard lockFd >= 0 else { return }
    defer { close(lockFd) }

    guard flock(lockFd, LOCK_EX) == 0 else { return }
    defer { _ = flock(lockFd, LOCK_UN) }

    // 2. Active log: open separately and write.
    let logFd = path.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
    guard logFd >= 0 else { return }

    _ = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
      guard let base = buf.baseAddress else { return 0 }
      return write(logFd, base, buf.count)
    }

    var st = stat()
    let sizeOk = fstat(logFd, &st) == 0
    let oversize = sizeOk && Int(st.st_size) > maxSize

    // 3. Close the active fd BEFORE rotation so rename can proceed cleanly.
    close(logFd)

    if oversize {
      rotate(path: path, maxFiles: maxFiles)
    }
  }

  /// Drops the oldest archive, shifts each `.i` → `.i+1`, and renames the
  /// active file to `.1`. `maxFiles` is the total count INCLUDING the active
  /// file: so `maxFiles == N` keeps `path` plus `.1` through `.(N - 1)`,
  /// for `N` files on disk.
  ///
  /// Caller must hold both the in-process lock and the cross-process lock.
  private static func rotate(path: URL, maxFiles: Int) {
    let fm = FileManager.default
    let dir = path.deletingLastPathComponent()
    let base = path.lastPathComponent

    // Total = active + (maxFiles - 1) archives.
    let archiveCount = max(0, maxFiles - 1)

    // Drop the oldest archive if it exists.
    if archiveCount >= 1 {
      let oldest = dir.appendingPathComponent("\(base).\(archiveCount)")
      try? fm.removeItem(at: oldest)
    }

    // Shift each `.i` → `.i+1`, walking from highest archive index downward.
    if archiveCount >= 2 {
      for i in stride(from: archiveCount - 1, through: 1, by: -1) {
        let src = dir.appendingPathComponent("\(base).\(i)")
        let dst = dir.appendingPathComponent("\(base).\(i + 1)")
        if fm.fileExists(atPath: src.path) {
          try? fm.moveItem(at: src, to: dst)
        }
      }
    }

    // Active → `.1` if there's any archive budget; otherwise truncate.
    if archiveCount >= 1 {
      let firstRolled = dir.appendingPathComponent("\(base).1")
      try? fm.moveItem(at: path, to: firstRolled)
      // Recreate an empty active file so consumers tailing the documented
      // path do not lose their target between rotation and the next append.
      fm.createFile(atPath: path.path, contents: nil)
    } else {
      // maxFiles == 1 — caller wants size-cap-and-truncate behaviour.
      // Truncate the active file in-place so the path keeps existing.
      try? Data().write(to: path)
    }
  }
}
