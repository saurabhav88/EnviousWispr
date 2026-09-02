import Foundation

/// The one durable-write primitive for a user-owned JSON store on disk.
///
/// Extracted from `CustomWordsManager.saveFileWhileLocked` when #628 added a second store,
/// rather than writing the sequence twice. Every comment below is the original reasoning,
/// carried across with the code it explains — the crash-window this closes was found and fixed
/// twice (#1744, then a Codex review round on the directory sync), and a second copy of the
/// sequence would have started life one fix behind.
///
/// The order is load-bearing and each step answers a different failure:
///
/// 1. **Unique temp name**, not a fixed `.tmp`. Two writers on one fixed name can interleave.
/// 2. **`O_CREAT | O_EXCL | O_WRONLY, 0o600`** — the file is never world-readable, not even for
///    the instant between creation and a `chmod`.
/// 3. **`F_FULLFSYNC` on the file.** Atomic is not durable: the rename can be committed while
///    the bytes are still in the drive's write cache, so a power loss reverts to the prior save.
/// 4. **`rename` within the same directory**, which is what makes the swap atomic — same
///    directory means same filesystem.
/// 5. **`F_FULLFSYNC` on the DIRECTORY, best-effort.** Syncing the file makes the bytes durable
///    but not the rename itself. This one must NOT throw: by the time it runs the rename has
///    already succeeded and the new content is live, so reporting failure would make the caller
///    believe the save failed and skip updating its own state while the file on disk had
///    already changed. A failure here only narrows the crash window; it does not undo the save.
public enum DurableJSONFile {

  /// Why a cross-process lock could not be taken.
  public enum LockFailure: Error, Equatable {
    /// Another process holds the lock right now (non-blocking acquisition only).
    case busy
    /// The lock file could not be opened, or `flock` failed for a reason other than contention.
    case unavailable
  }

  /// Hold an exclusive cross-process lock while `body` runs (#1690, generalised by #628).
  ///
  /// Takes `flock` on a stable COMPANION file beside the store, never on the store itself: the
  /// store is replaced by rename on every save, so a lock held on it would be a lock on a file
  /// that no longer exists the moment it mattered.
  ///
  /// Non-blocking by default, so a mutation fails closed rather than freezing the main actor
  /// behind another process. Blocking acquisition is for a load path that can afford to wait.
  ///
  /// - Parameter lockSyscall: test seam. Production always passes the real `flock`; a test can
  ///   force a non-contention failure without needing a second process.
  public static func withExclusiveLock<T>(
    on storeURL: URL,
    blocking: Bool = false,
    lockSyscall: (Int32, Int32) -> Int32 = { flock($0, $1) },
    _ body: () throws -> T
  ) throws -> T {
    let lockURL = storeURL.appendingPathExtension("lock")
    let fd = lockURL.path.withCString {
      Foundation.open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    }
    guard fd >= 0 else { throw LockFailure.unavailable }
    defer { close(fd) }

    let flags: Int32 = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
    guard lockSyscall(fd, flags) == 0 else {
      if !blocking, errno == EWOULDBLOCK { throw LockFailure.busy }
      throw LockFailure.unavailable
    }
    defer { _ = flock(fd, LOCK_UN) }

    return try body()
  }

  /// Whether `destination` is the same file on disk as `live`.
  ///
  /// The guard behind every export: choosing the app's own store as the destination would
  /// atomically replace it with the transfer format, and the next launch would archive it as
  /// corrupt — the user destroying their own data by backing it up. Extracted from
  /// `CustomWordsExportWriter.wouldOverwriteLiveWords` when #628 gave a second store an export.
  ///
  /// Ask the FILESYSTEM, not the strings. macOS is case-insensitive by default, so
  /// `SNIPPETS.JSON` and `snippets.json` are ONE file that string equality calls two — and
  /// picking the shouty spelling would walk straight past the guard into the loss it prevents.
  ///
  /// The destination may not exist yet, so there is no identity to compare. The fallback is a
  /// case-insensitive path match: on the default volume that is the truth, and on a
  /// case-sensitive one it is merely stricter than necessary — the safe direction to be wrong.
  public static func isSameFile(_ destination: URL, as live: URL) -> Bool {
    let target = destination.resolvingSymlinksInPath().standardizedFileURL
    let liveURL = live.resolvingSymlinksInPath().standardizedFileURL

    if let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier,
      let liveID = try? liveURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        .fileResourceIdentifier
    {
      return targetID.isEqual(liveID)
    }
    return target.path.compare(liveURL.path, options: .caseInsensitive) == .orderedSame
  }

  /// Create the store's directory at 0700 and drop a `.metadata_never_index` Spotlight marker.
  ///
  /// Re-enforced on every init, in case a backup restore or a user action loosened permissions
  /// (V3 audit #561 / #562). Soft-fails on every filesystem operation: a store that cannot
  /// tighten its own directory must still work, and a throw here would take the app down at
  /// launch over a permission bit.
  public static func prepareDirectory(at url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    let marker = url.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      fm.createFile(atPath: marker.path, contents: Data(), attributes: nil)
    }
  }

  /// Force an existing store file to 0600. Migrates installs that pre-date this hardening.
  public static func tightenFileIfPresent(at url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// Encode and write `value` to `url`, atomically and durably.
  ///
  /// - Parameter tempPrefix: the dot-prefixed basename stem for the temp file, so a stray temp
  ///   left by a crash is identifiable as belonging to this store.
  public static func write<Value: Encodable>(
    _ value: Value, to url: URL, tempPrefix: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try write(data: try encoder.encode(value), to: url, tempPrefix: tempPrefix)
  }

  public static func write(data: Data, to url: URL, tempPrefix: String) throws {
    let directory = url.deletingLastPathComponent()
    let tmpURL = directory.appendingPathComponent("\(tempPrefix).\(UUID().uuidString).tmp")
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try handle.write(contentsOf: data)

      guard fcntl(fd, F_FULLFSYNC) != -1 else { throw posixError(path: tmpURL.path) }
      try handle.close()

      guard Foundation.rename(tmpURL.path, url.path) == 0 else {
        throw posixError(path: url.path)
      }

      // Best-effort by contract — see the header. Never promote this to a throw.
      let dirFD = Foundation.open(directory.path, O_RDONLY)
      if dirFD >= 0 {
        _ = fcntl(dirFD, F_FULLFSYNC)
        close(dirFD)
      }
    } catch {
      try? FileManager.default.removeItem(at: tmpURL)
      throw error
    }
  }

  private static func posixError(path: String) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain, code: Int(errno),
      userInfo: [
        NSLocalizedDescriptionKey: String(cString: strerror(errno)),
        NSFilePathErrorKey: path,
      ])
  }
}
