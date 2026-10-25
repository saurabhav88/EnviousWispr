import Darwin
import Foundation

/// The one temporary directory a test process writes into:
/// `<system temp>/EnviousWisprTests-<pid>/`, removed when the process exits.
///
/// Tests used `FileManager.default.temporaryDirectory` directly and most never
/// removed what they made. macOS only reaps that folder after about three days,
/// and hourly runs left roughly 25 GB a day there (measured 2026-10-25). Every
/// test temp path now hangs off this root, so one removal at exit covers every
/// test, including a test that throws before its own cleanup runs.
///
/// A process that dies without running `atexit` (crash, kill, a host that
/// calls `_exit`) leaves its root behind; the next test process removes every
/// sibling root whose pid is no longer running. `TestTemporaryDirectoryUsageTests`
/// keeps new test code from going around this root.
package enum TestTemporaryDirectory {
  /// Use exactly where `FileManager.default.temporaryDirectory` was used.
  package static var url: URL { root }

  /// Use exactly where `NSTemporaryDirectory()` was used (trailing slash kept).
  package static var path: String { root.path + "/" }

  private static let prefix = "EnviousWisprTests-"

  private static let root: URL = {
    let system = FileManager.default.temporaryDirectory
    removeRootsOfDeadProcesses(in: system)
    let root = system.appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    rootPathForExit = strdup(root.path)
    atexit {
      guard let path = rootPathForExit else { return }
      forceRemove(String(cString: path))
    }
    return root
  }()

  /// `atexit` takes a C function that cannot capture, so the root's path is
  /// parked here once, before the handler is registered, and never changes.
  nonisolated(unsafe) private static var rootPathForExit: UnsafeMutablePointer<CChar>?

  private static func removeRootsOfDeadProcesses(in system: URL) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: system.path) else { return }
    for name in names where name.hasPrefix(prefix) {
      guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid() else { continue }
      // `kill(pid, 0)` probes without signalling; ESRCH means no such process.
      // EPERM means alive under another user, so it is left alone.
      if kill(pid, 0) == -1 && errno == ESRCH {
        forceRemove(system.appendingPathComponent(name, isDirectory: true).path)
      }
    }
  }

  /// `removeItem` stops at the first folder a test left read-only or file it
  /// left immutable (permission and `uchg` tests restore them in cleanup that
  /// a crash skips), so restore owner access and clear flags on the way down.
  private static func forceRemove(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    _ = lchflags(path, 0)
    if info.st_mode & S_IFMT == S_IFDIR {
      _ = chmod(path, S_IRWXU)
      if let children = try? FileManager.default.contentsOfDirectory(atPath: path) {
        for child in children { forceRemove(path + "/" + child) }
      }
      _ = rmdir(path)
    } else {
      _ = unlink(path)
    }
  }
}
