import CryptoKit
import Foundation

/// The shared mechanism for retiring a legacy on-disk artifact we can prove is ours.
///
/// Pure mechanism, **per-entry**, no store policy. EG-1 and WhisperKit both call it and
/// each keeps its own store knowledge: EG-1's old-store layout and sidecar sweeps have no
/// business in a type that also serves a foreign Hugging Face cache, and WhisperKit's
/// Documents/TCC concerns must never leak into EG-1.
///
/// Extracted from `EGOneLegacyUpgradeCoordinator` (#1386 PR-2a), which keeps 100% of its
/// policy and calls this for the mechanism. That coordinator's 29 tests are this
/// extraction's oracle and must pass unmodified.
public enum LegacyRetirement {

  // MARK: - Inputs

  /// A file we can prove is ours: a manifest-pinned path, size, and digest.
  public struct TrustedFile: Sendable, Equatable {
    /// Path relative to the retirement root. May contain `/` — the WhisperKit manifest
    /// nests up to three components deep (e.g. `AudioEncoder.mlmodelc/analytics/coremldata.bin`).
    public let relativePath: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(relativePath: String, sizeBytes: Int64, sha256: String) {
      self.relativePath = relativePath
      self.sizeBytes = sizeBytes
      self.sha256 = sha256
    }
  }

  /// Cheap identity of a file, captured without reading it.
  ///
  /// `dev`+`inode` is what makes this identity rather than a path: a path can be relinked
  /// between the moment we fingerprint it and the moment we unlink it, and deleting by path
  /// alone would then destroy a file we never examined.
  public struct FileIdentity: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let sizeBytes: Int64
    /// Whole seconds AND nanoseconds. Second-granularity alone is not identity: a file
    /// rewritten in place with different bytes of the same length within the same second
    /// would compare equal, and we would then delete bytes we never hashed.
    public let modifiedAtSeconds: Int64
    public let modifiedAtNanoseconds: Int64
    /// Inode change time. Catches metadata-only edits that leave mtime untouched — `mtime`
    /// is writable via `utimes`, `ctime` is not.
    public let changedAtSeconds: Int64
    public let changedAtNanoseconds: Int64

    public init(
      device: Int32, inode: UInt64, sizeBytes: Int64,
      modifiedAtSeconds: Int64, modifiedAtNanoseconds: Int64,
      changedAtSeconds: Int64, changedAtNanoseconds: Int64
    ) {
      self.device = device
      self.inode = inode
      self.sizeBytes = sizeBytes
      self.modifiedAtSeconds = modifiedAtSeconds
      self.modifiedAtNanoseconds = modifiedAtNanoseconds
      self.changedAtSeconds = changedAtSeconds
      self.changedAtNanoseconds = changedAtNanoseconds
    }
  }

  /// What we concluded about the SET. Deliberately identity-free: a 24-file aggregate has no
  /// truthful single identity, and returning some arbitrary member's would be a lie a caller
  /// could act on. Identities live on the per-entry verdicts, where they are true.
  public enum SetVerdict: Sendable, Equatable {
    case absent
    case match
    case mismatch
    case unreadable
  }

  /// What we concluded about one entry.
  public enum EntryVerdict: Sendable, Equatable {
    /// Nothing is there. `ENOENT`/`ENOTDIR` only — never a permission or I/O failure.
    case absent
    /// Ours, with the identity captured at the moment we proved it.
    case match(FileIdentity)
    /// Not our bytes, or the path is not shaped the way our manifest says. Permanent.
    case mismatch
    /// We could not tell. Permission, TCC, I/O, or an iCloud stub whose bytes are not on
    /// this Mac. Retryable in principle.
    case unreadable
  }

  // MARK: - Fingerprint

  /// Classify every trusted file under `root`, hashing only what earns it.
  ///
  /// `async throws` is deliberate and load-bearing: a `CancellationError` MUST reach the
  /// caller as a thrown error rather than collapsing into `.unreadable`. Callers persist a
  /// declined record from `.unreadable`, so conflating the two would let a user who pressed
  /// Cancel permanently brand their own good copy as un-examinable.
  ///
  /// - Parameter hashFile: injected so tests can drive it; production passes `streamingSHA256`.
  /// - Parameter hashFile: test/override seam. When nil (production), the digest is taken
  ///   from the same descriptor the identity came from — see `fingerprintOne`.
  public static func fingerprint(
    root: URL,
    files: [TrustedFile],
    hashFile: (@Sendable (URL) async throws -> String)? = nil
  ) async throws -> [String: EntryVerdict] {
    var verdicts: [String: EntryVerdict] = [:]
    verdicts.reserveCapacity(files.count)

    for file in files {
      // The cancellation contract belongs to `fingerprint`, not to whoever happens to hash.
      // An all-absent or all-size-mismatch set never reaches the hasher, and a cancel landing
      // just after the last digest would otherwise be swallowed — either way the caller would
      // go on to delete and refetch after the user said stop.
      try Task.checkCancellation()
      verdicts[file.relativePath] = try await fingerprintOne(
        root: root, file: file, hashFile: hashFile)
    }
    try Task.checkCancellation()
    return verdicts
  }

  /// A relative path we are willing to walk at all.
  ///
  /// `..` is the hole this closes: it `lstat`s as a perfectly ordinary directory, so a
  /// component walk waves it through and the leaf lands outside the root — where this type
  /// would then hash a stranger's file, call it a match, and unlink it. Our manifests are
  /// pinned and contain no traversal, but this is a public deletion primitive and must not
  /// depend on its callers being careful.
  private static func isWalkablePath(_ relativePath: String) -> Bool {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return false }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty else { return false }
    return components.allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty }
  }

  private static func fingerprintOne(
    root: URL,
    file: TrustedFile,
    hashFile: (@Sendable (URL) async throws -> String)?
  ) async throws -> EntryVerdict {
    // Not `.absent`: a traversing path is a statement about the manifest, not about the disk.
    guard isWalkablePath(file.relativePath) else { return .mismatch }
    // The root itself is a component. The walk below starts at the root's CHILDREN, so a
    // root that is itself a symlink (`cache/legacy -> ~/Documents/foreign`) would never be
    // inspected, and every file "under" it would be outside the intended store.
    switch classifyIntermediate(at: root) {
    case .ok: break
    // A missing store is `.absent`, never `.mismatch`: the ~465 users who never had the
    // model must not have a permanent decline persisted for a copy they never owned.
    case .absent: return .absent
    case .unreadable: return .unreadable
    case .mismatch: return .mismatch
    }

    // Walk every component with lstat before touching the leaf. Checking only the final
    // file follows an escaping parent symlink — and unlike an import, which merely READS
    // through such a link, we DELETE through it. This carries the guard out of
    // `ModelDeliveryController.importLocalCandidate` before that primitive is retired.
    var walk = root
    for component in file.relativePath.split(separator: "/").dropLast() {
      walk.appendPathComponent(String(component))
      switch classifyIntermediate(at: walk) {
      case .ok: continue
      case .absent: return .absent
      case .mismatch: return .mismatch
      case .unreadable: return .unreadable
      }
    }

    let url = root.appendingPathComponent(file.relativePath)
    let name = (file.relativePath as NSString).lastPathComponent

    // Open ONCE, through a pinned parent, and do everything through this descriptor:
    // identity, size, type, and the hash itself.
    //
    // Hashing by path after `lstat`ing by path proves nothing about the file we then delete.
    // A concurrent writer in the shared cache can swap the path to a decoy holding trusted
    // bytes, let us hash THAT, then restore the original — whose identity still matches what
    // we captured, so `unlinkUnchanged` deletes bytes that were never hashed. Binding both
    // proofs to one descriptor makes the identity and the digest describe the same inode by
    // construction: whatever happens to the NAME afterwards, the fd still refers to the file
    // we actually read.
    let dirfd: Int32
    switch openParentDirectory(root: root, relativePath: file.relativePath) {
    case .opened(let opened): dirfd = opened
    // `lstat` succeeds on a directory we may not open, so the walk above cannot see a
    // permission wall — only this can. Classify it, never collapse it to `.mismatch`.
    case .failed(let code): return verdict(forOpenErrno: code)
    }
    defer { close(dirfd) }

    let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      // ELOOP means the leaf is a symlink: not our file, and a permanent answer.
      if errno == ELOOP { return .mismatch }
      return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
    }
    defer { close(fd) }

    var info = Foundation.stat()
    guard fstat(fd, &info) == 0 else { return .unreadable }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return .mismatch }
    let captured = identity(of: info)
    guard captured.sizeBytes == file.sizeBytes else { return .mismatch }
    // An iCloud stub reports the real size while its bytes live in the cloud. The foreign
    // cache sits in ~/Documents, which users can have synced, so hashing one would quietly
    // pull 1.6 GB down to answer a question we ask on every launch. `.unreadable` is the
    // honest verdict: we genuinely cannot read it, and it may become readable later.
    guard !isDatalessStub(fd: fd, fallback: url) else { return .unreadable }

    do {
      let digest = try await hash(fd: fd, url: url, using: hashFile)
      return digest == file.sha256 ? .match(captured) : .mismatch
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .unreadable
    }
  }

  /// Production hashes the descriptor we verified; an injected seam (tests, EG-1 overrides)
  /// still gets the URL, because a test fixture has no concurrent writer to race it.
  private static func hash(
    fd: Int32, url: URL, using injected: (@Sendable (URL) async throws -> String)?
  ) async throws -> String {
    if let injected { return try await injected(url) }
    return try await streamingSHA256(fd: fd)
  }

  /// Every intermediate component is a real directory, right now.
  /// Open the directory holding `relativePath`, walking component by component with
  /// `openat` + `O_NOFOLLOW` from a pinned root descriptor.
  ///
  /// This is the single answer to a whole family of defects. `O_NOFOLLOW` protects only the
  /// FINAL component, so `open("<root>/a/b/c.bin", O_NOFOLLOW)` happily follows a symlink at
  /// `a` or `b` — and an `lstat` walk beforehand cannot help, because the path is resolved
  /// again, from scratch, at open time. Every ancestor is a TOCTOU window.
  ///
  /// Walking with `openat` closes the family at once: each step is relative to a descriptor
  /// we already hold, so once a directory is pinned, nothing done to its NAME can redirect
  /// us. What we open is what we walked.
  ///
  /// This does NOT make the `lstat` walk redundant, and the two are not interchangeable. The
  /// walk classifies (absent vs unreadable vs mismatch — the verdict vocabulary callers
  /// depend on); this pins (races). A static symlinked ancestor is refused by either one, so
  /// no test discriminates them; the pinning earns its place against the window BETWEEN the
  /// walk and the open, which is exactly the kind of defect a test cannot stage and a reader
  /// cannot see. Keep both.
  ///
  /// - Returns: a directory descriptor the caller must close, or nil if any component is
  ///   missing, is a link, or is not a directory.
  private enum ParentOpen {
    case opened(Int32)
    /// Carries the failing `errno` so the caller can classify. `close` clobbers `errno`, so
    /// it is captured at the point of failure, not read afterwards.
    case failed(Int32)
  }

  private static func openParentDirectory(root: URL, relativePath: String) -> ParentOpen {
    guard isWalkablePath(relativePath) else { return .failed(EINVAL) }

    var current = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { return .failed(errno) }

    for component in relativePath.split(separator: "/").dropLast() {
      let next = openat(
        current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let failure = next < 0 ? errno : 0
      close(current)
      guard next >= 0 else { return .failed(failure) }
      current = next
    }
    return .opened(current)
  }

  /// Map an `open`/`openat` failure to a verdict. Same errno vocabulary as the `lstat` walk:
  /// only "nothing there" is `.absent`, only a link or a non-directory is a permanent
  /// `.mismatch`, and anything else — permission, TCC, I/O — is "we cannot tell".
  private static func verdict(forOpenErrno code: Int32) -> EntryVerdict {
    switch code {
    case ENOENT, ENOTDIR: return .absent
    case ELOOP, EINVAL: return .mismatch
    default: return .unreadable
    }
  }

  /// Is this an iCloud placeholder whose bytes are not on this Mac?
  ///
  /// Ported from `ModelDeliveryController.importLocalCandidate`, which refuses these as
  /// `.datalessPlaceholder`. It is the seventh of that primitive's guards and the one this
  /// extraction had missed.
  /// Asked of the descriptor we opened (via `F_GETPATH`), not the path we were handed, so a
  /// leaf swapped after `open` cannot make us answer about a different file.
  ///
  /// This is a hydration guard, not a safety guard: iCloud status has no fd-based API, so
  /// `F_GETPATH` is the closest binding available. If it were ever wrong the cost is a slow
  /// hash or a spurious `.unreadable`, both recoverable (L4 re-examines) — it can never cause
  /// a wrong deletion, because deletion is gated by identity, not by this.
  private static func isDatalessStub(fd: Int32, fallback: URL) -> Bool {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let url =
      fcntl(fd, F_GETPATH, &buffer) == 0
      ? URL(fileURLWithPath: String(cString: buffer)) : fallback
    guard
      let values = try? url.resourceValues(forKeys: [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      ])
    else { return false }
    guard values.isUbiquitousItem == true else { return false }
    return values.ubiquitousItemDownloadingStatus != .current
  }

  /// A root we are willing to walk at all: a real directory, not a link to one.
  private static func rootIsARealDirectory(_ root: URL) -> Bool {
    guard let info = lstatIdentity(at: root) else { return false }
    return info.isDirectoryNotLink
  }

  private static func pathIsFreeOfLinks(root: URL, relativePath: String) -> Bool {
    guard isWalkablePath(relativePath), rootIsARealDirectory(root) else { return false }
    var walk = root
    for component in relativePath.split(separator: "/").dropLast() {
      walk.appendPathComponent(String(component))
      guard let info = lstatIdentity(at: walk), info.isDirectoryNotLink else { return false }
    }
    return true
  }

  private enum IntermediateVerdict { case ok, absent, mismatch, unreadable }

  private static func classifyIntermediate(at url: URL) -> IntermediateVerdict {
    guard let info = lstatIdentity(at: url) else {
      return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
    }
    // A symlink or a non-directory where the manifest says a directory belongs is not our
    // tree, whatever it points at.
    return info.isDirectoryNotLink ? .ok : .mismatch
  }

  // MARK: - Roll-up

  /// Reduce per-entry verdicts to one answer for the set. Deterministic and total.
  ///
  /// Order matters: `unreadable` outranks `mismatch` because "we could not tell" must never
  /// be reported as "we can tell, and it is not ours" — the second is permanent, the first
  /// is not. Every other mixture, including `match`+`absent` (a partially-deleted set), is
  /// `mismatch`: a partial match is not our artifact.
  public static func rollUp(_ verdicts: [String: EntryVerdict]) -> SetVerdict {
    // Empty in, absent out: no entries examined means nothing is there to retire. Stated
    // rather than left to fall through, because "total" is a promise the caller relies on.
    guard !verdicts.isEmpty else { return .absent }
    let values = Array(verdicts.values)

    if values.contains(where: {
      if case .unreadable = $0 { return true }
      return false
    }) {
      return .unreadable
    }
    if values.allSatisfy({
      if case .absent = $0 { return true }
      return false
    }) {
      return .absent
    }
    if values.allSatisfy({
      if case .match = $0 { return true }
      return false
    }) {
      return .match
    }
    return .mismatch
  }

  // MARK: - Unlink

  /// Unlink only what still matches the identity we captured, and report what we preserved.
  ///
  /// Re-`lstat`s immediately before each unlink: the file may have been relinked or rewritten
  /// since the fingerprint, and the whole point of `FileIdentity` is that we refuse to delete
  /// a file we did not examine.
  /// - Parameter removeItem: test seam only. When nil (production), removal goes through
  ///   `unlinkat` against a directory handle — see `unlinkVerified`.
  @discardableResult
  public static func unlinkUnchanged(
    root: URL,
    verdicts: [String: EntryVerdict],
    removeItem: ((URL) throws -> Void)? = nil
  ) -> (unlinked: [String], preserved: [String]) {
    var unlinked: [String] = []
    var preserved: [String] = []

    for relativePath in verdicts.keys.sorted() {
      guard case .match(let captured) = verdicts[relativePath] else {
        preserved.append(relativePath)
        continue
      }
      // Re-walk the intermediates, not just the leaf. `lstat` declines to follow only the
      // FINAL component, so an intermediate directory swapped for a symlink after the
      // fingerprint would silently redirect this removal outside the root. The identity check
      // below already refuses the redirected file, but a delete path must not depend on a
      // second guard catching what the first one let through.
      guard pathIsFreeOfLinks(root: root, relativePath: relativePath) else {
        preserved.append(relativePath)
        continue
      }
      let url = root.appendingPathComponent(relativePath)
      guard let now = lstatIdentity(at: url), now.isRegularFileNotLink,
        now.identity == captured
      else {
        preserved.append(relativePath)
        continue
      }
      if removeItem == nil, unlinkVerified(root: root, relativePath: relativePath, is: captured) {
        unlinked.append(relativePath)
        continue
      }
      if let removeItem {
        do {
          try removeItem(url)
          unlinked.append(relativePath)
        } catch {
          preserved.append(relativePath)
        }
        continue
      }
      preserved.append(relativePath)
    }
    return (unlinked, preserved)
  }

  /// Re-verify identity through a *directory handle*, then `unlinkat` against that same
  /// handle.
  ///
  /// A path-based `removeItem` resolves the whole path again at delete time, so anything that
  /// moved underneath us between the check and the delete is silently followed. Holding an
  /// `O_DIRECTORY | O_NOFOLLOW` handle to the parent pins the directory: `fstatat` and
  /// `unlinkat` then address the same directory object regardless of what happens to the path
  /// above it, which removes the intermediate-swap race entirely.
  ///
  /// **What remains, and why it is not closable here.** POSIX offers no "unlink this exact
  /// inode" call: between `fstatat` and `unlinkat` a writer can still swap the name. The
  /// window is now a few instructions against a pinned directory rather than a full path
  /// re-resolution, and this is the shared-cache residual the plan already accepts (§8.1) —
  /// a foreign writer racing us in `~/Documents/huggingface` can defeat any identity check,
  /// because the check and the delete cannot be made one atom. Do not "fix" this with a lock:
  /// we do not own the other writer.
  private static func unlinkVerified(
    root: URL, relativePath: String, is captured: FileIdentity
  ) -> Bool {
    let name = (relativePath as NSString).lastPathComponent
    guard case .opened(let dirfd) = openParentDirectory(root: root, relativePath: relativePath)
    else { return false }
    defer { close(dirfd) }

    var info = Foundation.stat()
    guard fstatat(dirfd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      identity(of: info) == captured
    else { return false }

    return unlinkat(dirfd, name, 0) == 0
  }

  // MARK: - Containment

  /// Is `candidate` genuinely inside `root`, after resolving both?
  ///
  /// Resolve-then-compare, never compare-then-resolve: a symlink that escapes the root
  /// compares fine as a string and escapes in fact.
  public static func isContained(_ candidate: URL, within root: URL) -> Bool {
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    return resolvedCandidate.path == resolvedRoot.path
      || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
  }

  // MARK: - Marker

  /// Write a zero-byte marker atomically. Returns false rather than throwing: a caller that
  /// cannot write the marker must delete nothing, and that is a decision, not an error.
  /// `Data.write(options: .atomic)` already writes to a temporary file and renames it into
  /// place; hand-rolling that dance around `replaceItemAt` would add failure modes without
  /// adding atomicity. This is EG-1's shipped implementation, moved verbatim.
  public static func writeMarkerAtomically(_ url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  /// Clear a marker. Idempotent: clearing an absent marker is success, because the
  /// postcondition the caller needs — no marker on disk — already holds.
  public static func clearMarker(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    {
      return
    }
  }

  // MARK: - Hashing

  /// SHA-256 in 4 MB chunks, off the calling actor, and **actually cancellable**.
  ///
  /// Two requirements pull in opposite directions, which is how the original got it wrong.
  /// The read must leave the caller's actor — callers are `@MainActor` coordinators, and
  /// hashing 1.6 GB on the main actor would freeze the UI, which is why the original reached
  /// for `Task.detached`. But a detached task does **not** inherit cancellation, so its
  /// `checkCancellation` could never observe the parent's cancel and the read ran to
  /// completion after the user asked us to stop.
  ///
  /// Keep the detached task for the isolation; add the link it was missing.
  /// Hash an already-open descriptor. `dup` because the reader takes ownership, and the
  /// caller's `defer { close(fd) }` must stay correct.
  static func streamingSHA256(fd: Int32) async throws -> String {
    let duplicate = dup(fd)
    guard duplicate >= 0 else { throw POSIXError(.EBADF) }
    guard lseek(duplicate, 0, SEEK_SET) == 0 else {
      close(duplicate)
      throw POSIXError(.ESPIPE)
    }
    let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    return try await streamingSHA256(handle: handle)
  }

  public static func streamingSHA256(of url: URL) async throws -> String {
    try await streamingSHA256(handle: try FileHandle(forReadingFrom: url))
  }

  private static func streamingSHA256(handle: FileHandle) async throws -> String {
    let work = Task.detached(priority: .utility) {
      defer { try? handle.close() }

      var hasher = SHA256()
      while true {
        try Task.checkCancellation()
        let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    return try await withTaskCancellationHandler {
      try await work.value
    } onCancel: {
      work.cancel()
    }
  }

  // MARK: - lstat

  private struct StatInfo {
    let identity: FileIdentity
    let isRegularFileNotLink: Bool
    let isDirectoryNotLink: Bool
  }

  private static func identity(of info: Foundation.stat) -> FileIdentity {
    FileIdentity(
      device: info.st_dev,
      inode: UInt64(info.st_ino),
      sizeBytes: Int64(info.st_size),
      modifiedAtSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedAtNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changedAtSeconds: Int64(info.st_ctimespec.tv_sec),
      changedAtNanoseconds: Int64(info.st_ctimespec.tv_nsec))
  }

  /// `lstat`, never `stat`: it must describe the link itself, not what the link aims at.
  private static func lstatIdentity(at url: URL) -> StatInfo? {
    var info = Foundation.stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    let mode = info.st_mode & S_IFMT
    return StatInfo(
      identity: identity(of: info),
      isRegularFileNotLink: mode == S_IFREG,
      isDirectoryNotLink: mode == S_IFDIR)
  }
}
