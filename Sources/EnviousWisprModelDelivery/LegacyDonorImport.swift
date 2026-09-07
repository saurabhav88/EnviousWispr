import Foundation

/// Reproduces model bytes a user already has, from a directory we may only READ
/// (#2483).
///
/// The point of #2483 is that EnviousWispr installs into its own directory and
/// never mutates FluidAudio's shared tree. Moving there naively would make every
/// existing user re-download the pinned set — 483,256,769 bytes — and would also
/// throw away a copy a *different* FluidAudio app already downloaded. This type
/// is the answer to both: copy out, leave the original exactly as it was.
///
/// **Nothing here opens the donor for writing, and nothing here deletes.** The
/// donor is addressed only through `FileManager.copyItem` and `clonefile`, both
/// of which read it. That is the whole safety argument, and it is structural
/// rather than a check that could be wrong: there is no write API on this path
/// to reach.
///
/// **KNOWN LIMIT, deliberately not closed: path checks are not atomic.** A hostile
/// process running as the same user can replace a checked directory with a symlink
/// between the check and the copy, and only descriptor-relative no-follow
/// operations would close that. It is not closed here because the attacker it
/// requires already has the capability the attack would gain: anything that can
/// write inside our staging directory can write into the donor directly, without
/// involving us. The promise this type makes is that OUR code does not write in
/// the donor, not that a same-user attacker cannot. Cloud review round 5,
/// classified HYPOTHETICAL per `validation-discipline.md`
/// RULE: validate-automated-review-findings.
///
/// **It also does not verify.** Files land in the caller's staging directory,
/// and `ManifestFetchTask` already refuses to skip a staged file unless its size
/// AND streaming SHA-256 match the manifest (`ManifestFetchTask.swift:144-148`),
/// then `CacheAdmission.promoteAndAdmit` stamps only what verified. Re-checking
/// here would be a second answer to a question that already has one, and the
/// existing answer is the one that gates admission. A donor file that is
/// truncated, stale, from another revision, or actively being rewritten by its
/// owner therefore costs one wasted copy and falls through to a normal download.
public enum LegacyDonorImport {

  /// What one attempt did, for telemetry and for the caller's log line.
  public struct Outcome: Sendable, Equatable {
    /// Files copied into staging. Not "files admitted" — verification is
    /// downstream and may still reject them.
    public let filesReproduced: Int
    /// Bytes read from the donor, by the manifest's reckoning.
    public let bytesReproduced: Int64
    /// True when every copy went through APFS copy-on-write rather than a full
    /// byte copy. Reported rather than assumed: cloning needs one filesystem
    /// that supports it, and a user whose home is on a volume that does not
    /// gets a real copy and real allocation.
    public let clonedThroughout: Bool

    public static let none = Outcome(
      filesReproduced: 0, bytesReproduced: 0, clonedThroughout: true)
  }

  /// The result of one attempt, with REFUSAL kept distinct from "imported
  /// nothing" (cloud round 2 P1).
  ///
  /// Collapsing the two was a real hole: an unsafe staging root returned an
  /// empty `Outcome`, the caller read that as an ordinary miss, and then handed
  /// the SAME unsafe staging URL to the fetcher, which writes through it — and
  /// promotion then moves component roots out of whatever it resolves to. A
  /// refusal here is a statement about the destination, not about the donor, so
  /// the caller must abandon the attempt rather than continue without us.
  public enum Result: Sendable, Equatable {
    case imported(Outcome)
    /// Staging, or an ancestor of it, resolves inside the donor. Nothing was
    /// written. The caller MUST NOT proceed to fetch with this staging
    /// directory, because the fetcher would write through it.
    case unsafeStagingRoot(detail: String)
  }

  /// Copy every manifest file of `components` from `donor` into `staging`.
  ///
  /// Best-effort per file by design: a partial result is useful, because each
  /// file the fetch path finds already staged and verified is one it does not
  /// download. A donor that is absent, unreadable, or holds a different revision
  /// simply yields fewer files.
  ///
  /// - Parameter donor: a directory this process may only read.
  public static func reproduce(
    manifest: DeliveryManifest, components: Set<String>, donor: URL, staging: URL
  ) -> Result {
    let fm = FileManager.default

    // THE WHOLE GUARD, and it is deliberately this small.
    //
    // An earlier version proved staging sat inside a "trusted root" as well.
    // That apparatus produced four defects across three review rounds — two of
    // which would have broken the product for every user — and the fourth was
    // that it CREATED the trusted root before checking it, so an ancestor
    // symlinked into the donor got directories made inside the donor by the very
    // code meant to prevent writes there. It was also never load-bearing:
    // `ManifestFetchTask` writes into this same staging directory with no such
    // check and always has, so guarding one writer among several was a door in a
    // wall with other doors open.
    //
    // The hazard is exactly one sentence — "could a copy of mine land inside the
    // donor" — and that is now exactly one question, asked against the nearest
    // EXISTING ancestor first, so nothing is created before it is answered.
    guard let donorRoot = resolved(donor) else { return .imported(.none) }
    guard let anchor = nearestExistingAncestor(of: staging), let anchorPath = resolved(anchor),
      !contained(anchorPath, in: donorRoot)
    else { return .unsafeStagingRoot(detail: "staging_ancestor_inside_donor") }
    if !fm.fileExists(atPath: staging.path) {
      try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
    }
    guard let stagingRoot = resolved(staging) else {
      return .unsafeStagingRoot(detail: "staging_uncreatable")
    }
    guard !contained(stagingRoot, in: donorRoot) else {
      return .unsafeStagingRoot(detail: "staging_inside_donor")
    }

    var files = 0
    var bytes: Int64 = 0
    var everyCopyCloned = true

    for file in manifest.files where components.contains(file.component) {
      // Cloud round 2 P2: cooperative cancellation. A fallback copy moves
      // hundreds of megabytes, and `cancel(_:)` waits for the attempt to drain —
      // without this the user's cancel sits pending until the whole copy ends.
      if Task.isCancelled { break }
      let source = donor.appendingPathComponent(file.resolvedInstallPath)
      // Size is the cheap gate that keeps us from copying a whole tree of the
      // wrong revision. It is NOT the correctness check — that is the staged
      // SHA-256 downstream — so a size match here still proves nothing and is
      // not reported as if it did.
      guard CacheAdmission.sizeMatches(url: source, expected: file.sizeBytes) else { continue }

      let destination = staging.appendingPathComponent(file.resolvedInstallPath)
      // Second-pass finding 9: an existing staged file is LEFT ALONE. An earlier
      // attempt can have staged a complete, correct file; replacing it with a
      // same-size donor copy that is corrupt turns a resumable offline attempt
      // into a failed one. The fetcher already owns "is this staged file good"
      // and will resume or discard it, so this path must not pre-empt that.
      guard !fm.fileExists(atPath: destination.path) else { continue }
      // Cloud round P2: check containment BEFORE creating anything. Creating the
      // parents first and validating afterwards is too late — if an existing
      // staging component is a symlink into the shared tree,
      // `createIntermediateDirectories` follows it and has already made
      // directories under FluidAudio by the time a later guard declines the
      // copy. So walk up to the nearest ancestor that EXISTS, resolve THAT, and
      // require it inside the staging root; only then create the rest.
      guard let fileAnchor = Self.nearestExistingAncestor(of: destination),
        let fileAnchorPath = Self.resolved(fileAnchor),
        // Both halves, and the staging half is the one round 5 caught: rejecting
        // only the donor let a staging component symlinked to some UNRELATED
        // directory pass, and `createDirectory` then made manifest subdirectories
        // there before the post-creation check noticed. Checking the anchor needs
        // nothing created first, so there is no reason to learn it late.
        !Self.contained(fileAnchorPath, in: donorRoot),
        Self.contained(fileAnchorPath, in: stagingRoot)
      else { continue }
      try? fm.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      // And again after creating, because the step above can itself traverse a
      // link that appeared between the two.
      guard let parent = Self.resolved(destination.deletingLastPathComponent()),
        !Self.contained(parent, in: donorRoot), Self.contained(parent, in: stagingRoot)
      else { continue }

      if cloneItem(at: source, to: destination) {
        files += 1
        bytes += file.sizeBytes
        continue
      }
      everyCopyCloned = false
      // Fall back to a real copy, which allocates. The caller has already
      // reserved headroom for exactly this case.
      //
      // CHUNKED, not `FileManager.copyItem`. Cancelling a Swift task does not
      // interrupt a synchronous `copyItem`, and the shipped manifest's encoder
      // weight is 445,187,200 bytes — about 92% of the import — so a check
      // between files would let a cancel wait for almost the entire copy while
      // `cancel(_:)` blocks on the drain.
      do {
        try copyInterruptibly(from: source, to: destination)
        files += 1
        bytes += file.sizeBytes
      } catch {
        // Leave nothing half-written for the fetch path to resume onto: a
        // partial file whose SIZE happened to match would be skipped as
        // "already staged" and then fail its hash, which is a slower and more
        // confusing route to the same download.
        try? fm.removeItem(at: destination)
      }
    }

    return .imported(
      Outcome(
        filesReproduced: files, bytesReproduced: bytes,
        clonedThroughout: everyCopyCloned && files > 0))
  }

  /// Whether `path` is the root itself or sits beneath it. Both arguments must
  /// already be `realpath`-resolved; comparing unresolved paths here would be the
  /// same mistake one level down.
  private static func contained(_ path: String, in root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }

  /// The closest ancestor of `url` that exists on disk, so containment can be
  /// judged without creating anything first.
  private static func nearestExistingAncestor(of url: URL) -> URL? {
    var candidate = url.deletingLastPathComponent()
    let fm = FileManager.default
    while candidate.path != "/" {
      if fm.fileExists(atPath: candidate.path) { return candidate }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { break }
      candidate = parent
    }
    return fm.fileExists(atPath: candidate.path) ? candidate : nil
  }

  /// The fully link-resolved path, or nil when it does not resolve.
  ///
  /// `realpath(3)` rather than `URL.resolvingSymlinksInPath()`, which this
  /// repo documents as insufficient for the `/private/tmp` case that every
  /// temporary-directory test runs in.
  private static func resolved(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return nil }
    return String(cString: buffer)
  }

  /// Copies in chunks, aborting between chunks when the task is cancelled.
  ///
  /// Throws `CancellationError` on abort so the caller's existing catch removes
  /// the partial file — a half-written file whose size happened to match would
  /// otherwise be skipped by the fetcher as "already staged" and then fail its
  /// hash.
  private static func copyInterruptibly(from source: URL, to destination: URL) throws {
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: destination)
    defer { try? writer.close() }
    // 4 MiB: large enough that the syscall overhead is irrelevant against a
    // 445 MB file, small enough that a cancel is felt immediately.
    let chunkBytes = 4 * 1024 * 1024
    while true {
      if Task.isCancelled { throw CancellationError() }
      let chunk = try reader.read(upToCount: chunkBytes) ?? Data()
      if chunk.isEmpty { break }
      try writer.write(contentsOf: chunk)
    }
  }

  /// APFS copy-on-write. Both paths end up independent — writing to one never
  /// affects the other — while sharing their blocks until something writes.
  ///
  /// Apple documents the independence, not zero allocation, so this is
  /// "usually little extra space", never a guarantee of none. It fails when the
  /// two paths are on different filesystems, when the filesystem does not
  /// support cloning, or when the destination exists; every one of those falls
  /// back to a real copy above rather than being treated as an error.
  private static func cloneItem(at source: URL, to destination: URL) -> Bool {
    source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else { return false }
        return clonefile(sourcePath, destinationPath, 0) == 0
      }
    }
  }
}
