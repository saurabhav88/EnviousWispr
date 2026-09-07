import Foundation

/// Reproduces model bytes a user already has, from a directory we may only READ,
/// into the directory EnviousWispr owns (#2697).
///
/// **Why this is not a step inside a delivery attempt.** #2483 moved Parakeet out
/// of FluidAudio's shared tree and copied the donor's bytes forward so nobody
/// re-downloaded 483 MB. That copy lived inside `ensureModelAvailable`, which made
/// it reachable only by callers who run a delivery attempt. The kill-switch branch
/// does not, so a user we had told to disable delivery re-downloaded the model
/// online and could not warm up at all offline — with a complete copy on disk the
/// whole time. The copy is a property of the LOCATION, not of the attempt, so it
/// lives here and every consumer of the location passes through it.
///
/// **Nothing here opens the donor for writing, and nothing here deletes inside
/// it.** The donor is addressed only through `clonefile`, which reads it. That is
/// structural rather than a check that could be wrong: there is no write API on
/// this path to reach.
///
/// **Clone-only, deliberately.** `clonefile` is copy-on-write, so a migration
/// normally allocates almost nothing and takes almost no time. When it fails —
/// `EXDEV` across filesystems, `ENOSPC`, `EEXIST`, `EACCES` — this abandons and
/// the ordinary delivery path downloads. The accepted cost, stated rather than
/// argued away: a cross-filesystem OFFLINE user who would have been repaired by a
/// full byte copy now needs a download. Accepted because model bytes are
/// reproducible and no irreplaceable user data is involved.
///
/// **Nothing incomplete is ever visible.** Files are cloned into a private
/// candidate, every file is verified against the manifest's size AND SHA-256, and
/// only a whole verified component root is published, by an atomic replace. A
/// crash at any instant therefore leaves either an untouched installation or a
/// complete component, never a half one.
public enum LegacyDonorMigration {

  // MARK: - Durable record

  /// Three states, and the third is why this is a record rather than a
  /// directory-existence check.
  ///
  /// `absent` (no readable record) means migration has not run to completion —
  /// including the case where it published a component and then died before
  /// recording, which is why the record is written only after the whole
  /// installed set re-validates. `completed` means done. `declined` means the
  /// user REMOVED the model deliberately, and without it every launch would
  /// helpfully resurrect what they just deleted.
  public enum RecordedState: String, Codable, Sendable {
    case completed
    case declined
  }

  private struct Record: Codable {
    let state: RecordedState
    /// Ties the record to the manifest it was taken against, so a model revision
    /// bump re-opens the question instead of inheriting an answer about
    /// different bytes.
    let manifestDigest: String
  }

  static func recordURL(metadataDirectory: URL, manifest: DeliveryManifest) -> URL {
    metadataDirectory.appendingPathComponent(
      "\(manifest.identity.cacheKey).legacy-migration.json")
  }

  /// The recorded state, or `nil` when there is none, it is unreadable, or it
  /// describes a different manifest. Every one of those means "ask again", which
  /// is the fail-safe direction: re-running a clone costs almost nothing, while
  /// trusting an unreadable record would strand a user with no model.
  public static func recordedState(
    metadataDirectory: URL, manifest: DeliveryManifest
  ) -> RecordedState? {
    let url = recordURL(metadataDirectory: metadataDirectory, manifest: manifest)
    guard let data = try? Data(contentsOf: url),
      let record = try? JSONDecoder().decode(Record.self, from: data),
      record.manifestDigest == manifest.manifestDigest
    else { return nil }
    return record.state
  }

  /// Writes the record durably. `.atomic` renames a fully written temporary file
  /// into place, so a crash mid-write leaves the previous state rather than a
  /// truncated one.
  @discardableResult
  public static func record(
    _ state: RecordedState, metadataDirectory: URL, manifest: DeliveryManifest
  ) -> Bool {
    let url = recordURL(metadataDirectory: metadataDirectory, manifest: manifest)
    do {
      try FileManager.default.createDirectory(
        at: metadataDirectory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(
        Record(state: state, manifestDigest: manifest.manifestDigest))
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  // MARK: - Outcome

  public struct Outcome: Sendable, Equatable {
    /// Component roots published into the install directory. The unit that
    /// matters: a file count can be non-zero while nothing became usable.
    public let componentsPublished: Int
    public let filesReproduced: Int
    public let bytesReproduced: Int64
    /// False when any clone fell back or failed. Reported rather than assumed:
    /// cloning needs a filesystem that supports it, and a user whose home is on
    /// one that does not gets no migration at all.
    public let clonedThroughout: Bool

    public static let none = Outcome(
      componentsPublished: 0, filesReproduced: 0, bytesReproduced: 0, clonedThroughout: true)

    public var didAnything: Bool { componentsPublished > 0 }
  }

  #if DEBUG
    /// Live UAT seam (#2697). Lets a scenario stop the app at an exact point —
    /// notably BETWEEN the atomic publish and the durable record write, which is
    /// otherwise unreachable from outside. DEBUG only, never compiled into a
    /// shipped build, and it pauses a lifecycle step rather than bypassing a
    /// safety check.
    public nonisolated(unsafe) static var stallHook: (@Sendable (String) async -> Void)?
  #endif

  private static func stall(_ point: String) async {
    #if DEBUG
      if let hook = stallHook { await hook(point) }
    #endif
  }

  // MARK: - The migration

  /// Bring the install directory up to the manifest using bytes the user already
  /// has, without touching the donor and without the network.
  ///
  /// - Parameter onProgress: called as each file is cloned and each file is
  ///   verified. The hash pass over a 445 MB file is multi-second, and the
  ///   sessionless wedge guard reads silence as a wedge, so this must tick
  ///   during the work rather than after each file completes.
  public static func migrate(
    registration: DeliveryRegistration,
    onProgress: (@Sendable () -> Void)? = nil
  ) async -> Outcome {
    let manifest = registration.manifest
    let install = registration.installDirectory
    let metadata = registration.metadataDirectory
    let fm = FileManager.default

    // Already answered, either way. `declined` is the load-bearing half: without
    // it, deleting the model would be undone by the next launch.
    if recordedState(metadataDirectory: metadata, manifest: manifest) != nil { return .none }

    let admission = CacheAdmission(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)

    // The common case for everyone who is already fine: the cheap admitted check,
    // not a hash pass. Recording it here is what stops this running again.
    if admission.isAdmitted() {
      record(.completed, metadataDirectory: metadata, manifest: manifest)
      return .none
    }

    // No donor is the normal state for a new user and for anyone who never had
    // FluidAudio installed, and recording it is what stops us walking the
    // manifest on every launch forever.
    //
    // **But "there is no donor" and "I could not look" are different answers and
    // only the first may be written down.** A donor directory can be present and
    // unreadable — root-owned 700 is the same class of misconfiguration that
    // produced #2690's root-owned 755 — and `FileManager.fileExists` and a
    // `try?`-swallowed read both report that as absence. Recording `completed`
    // there would tell a user with a complete model on disk that they have
    // nothing to migrate, permanently, including after their machine is repaired,
    // and no later build could tell them apart from someone who never had
    // FluidAudio. Found by the #2695 session reading this branch.
    guard let donorRoot = registration.legacyDonorDirectory else {
      record(.completed, metadataDirectory: metadata, manifest: manifest)
      return .none
    }
    switch PathSafety.reachability(of: donorRoot) {
    case .absent:
      record(.completed, metadataDirectory: metadata, manifest: manifest)
      return .none
    case .unreadable, .indeterminate:
      // Deliberately no record. The next launch asks again.
      return .none
    case nil:
      break
    }
    guard let donorPath = PathSafety.resolvedPath(donorRoot) else { return .none }

    // The install directory must not BE the donor, or sit inside it. This is a
    // pathname assumption everywhere else in the delivery layer, and it is the
    // one that would put our clones and the vendor's downloads back inside the
    // shared tree. Answered against the nearest EXISTING ancestor so nothing is
    // created before the question is asked.
    guard let installAnchor = PathSafety.nearestExistingAncestor(of: install),
      let installAnchorPath = PathSafety.resolvedPath(installAnchor),
      !PathSafety.contained(installAnchorPath, in: donorPath)
    else { return .none }

    let candidateRoot = metadata.appendingPathComponent(
      "legacy-migration/\(manifest.identity.cacheKey)", isDirectory: true)
    // Review P1: the recursive delete below is the most dangerous line in this
    // type, and it was unguarded. If `legacy-migration` is a symlink to some
    // other directory holding a child of that name, `removeItem` deletes the
    // FAR SIDE. Neither the install-versus-donor check above nor the staging
    // check elsewhere protects this path — they answer about different
    // directories. So the candidate's own ancestry is proven to sit inside the
    // metadata directory we own, against the nearest EXISTING ancestor, before
    // anything is deleted, created or cloned here.
    guard PathSafety.resolvesInside(candidateRoot, root: metadata) else { return .none }
    // A candidate left by an interrupted run is DISCARDED, never resumed. It was
    // never verified as a whole, and resuming onto it would let a file that
    // happened to match its size be inherited rather than re-proven.
    try? fm.removeItem(at: candidateRoot)
    defer { try? fm.removeItem(at: candidateRoot) }

    var componentsPublished = 0
    var filesReproduced = 0
    var bytesReproduced: Int64 = 0
    var clonedThroughout = true

    for (component, componentFiles) in manifest.filesByComponent {
      if Task.isCancelled { break }

      // TWO ATTEMPTS, and the second one is review finding B1. The first prefers
      // the user's OWN files so a partially complete installation is repaired
      // rather than replaced — the offline case that would otherwise need the
      // network. But an owned file is chosen by SIZE, and a same-size corrupt
      // file then fails the hash and used to take the whole component down with
      // it, leaving an offline user with no model while a perfectly good donor
      // copy sat on disk. So a failed first attempt retries from the donor
      // alone before the component is abandoned.
      var verified = false
      for attempt in [Attempt.preferOwned, .donorOnly] {
        if Task.isCancelled { return partial() }
        try? fm.removeItem(at: candidateRoot.appendingPathComponent(component))

        var built = true
        for file in componentFiles {
          if Task.isCancelled { return partial() }
          let destination = candidateRoot.appendingPathComponent(file.resolvedInstallPath)
          try? fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

          let owned = install.appendingPathComponent(file.resolvedInstallPath)
          let donated = donorRoot.appendingPathComponent(file.resolvedInstallPath)
          // Size is the cheap gate for CHOOSING a source. It is not the
          // correctness check — that is the candidate hash below — so a size
          // match here proves nothing and is not treated as if it did.
          var source: URL?
          if attempt == .preferOwned,
            CacheAdmission.sizeMatches(url: owned, expected: file.sizeBytes)
          {
            source = owned
          } else if CacheAdmission.sizeMatches(url: donated, expected: file.sizeBytes) {
            source = donated
          }
          guard let source else {
            built = false
            break
          }
          guard
            await reproduce(
              from: source, to: destination, sizeBytes: file.sizeBytes,
              clonedThroughout: &clonedThroughout)
          else {
            built = false
            break
          }
          filesReproduced += 1
          bytesReproduced += file.sizeBytes
          onProgress?()
        }
        await stall("after_clone")
        guard built else { continue }

        // Verify the CANDIDATE, never the donor. The donor can be rewritten by
        // its owner while we read it, so a hash taken there is a statement about
        // a file we did not keep. These are the bytes that will be published.
        var attemptVerified = true
        for file in componentFiles {
          if Task.isCancelled { return partial() }
          let staged = candidateRoot.appendingPathComponent(file.resolvedInstallPath)
          guard CacheAdmission.sizeMatches(url: staged, expected: file.sizeBytes),
            await CacheAdmission.streamingSHA256(of: staged) == file.sha256
          else {
            attemptVerified = false
            break
          }
          onProgress?()
        }
        await stall("after_verify")
        if attemptVerified {
          verified = true
          break
        }
      }
      guard verified else {
        try? fm.removeItem(at: candidateRoot.appendingPathComponent(component))
        continue
      }

      // Last check before the only write that leaves this type's own directory.
      // A cancel arriving during the multi-second hash above means the caller has
      // moved on — `remove()` is the one that matters — and publishing after it
      // would resurrect a component the user just deleted.
      if Task.isCancelled { return partial() }
      if publish(component: component, from: candidateRoot, to: install) {
        componentsPublished += 1
      }
      await stall("after_publish")
    }

    // The record is written only after the WHOLE installed set re-validates, so a
    // crash between a publish and this line leaves `absent` and the next launch
    // re-proves rather than trusts. Existence on disk never authorises success.
    //
    // Gated on having published something, because `validateExistingCache` is a
    // full hash pass over 483 MB. A donor holding a DIFFERENT revision publishes
    // nothing, and hashing on every launch to re-learn that would be a multi-second
    // cost paid forever. Not recording is the right answer there too: re-asking
    // costs one size check per file, and the donor is a directory other apps write.
    if componentsPublished > 0 && !Task.isCancelled {
      let validation = await admission.validateExistingCache()
      if validation.failedComponents.isEmpty {
        record(.completed, metadataDirectory: metadata, manifest: manifest)
      }
    }

    func partial() -> Outcome {
      Outcome(
        componentsPublished: componentsPublished, filesReproduced: filesReproduced,
        bytesReproduced: bytesReproduced, clonedThroughout: clonedThroughout)
    }
    return partial()
  }

  // MARK: - Publication

  /// Replace one component root in the install directory with the verified
  /// candidate, atomically.
  ///
  /// `replaceItemAt` is the atomic swap for an existing destination; `moveItem`
  /// is a rename when there is nothing to replace. Neither leaves a window in
  /// which the component is half present.
  private static func publish(component: String, from candidateRoot: URL, to install: URL) -> Bool {
    let fm = FileManager.default
    let source = candidateRoot.appendingPathComponent(component)
    let destination = install.appendingPathComponent(component)
    guard fm.fileExists(atPath: source.path) else { return false }
    do {
      try fm.createDirectory(at: install, withIntermediateDirectories: true)
      if fm.fileExists(atPath: destination.path) {
        _ = try fm.replaceItemAt(destination, withItemAt: source)
      } else {
        try fm.moveItem(at: source, to: destination)
      }
      return true
    } catch {
      return false
    }
  }

  // MARK: - Reproducing one file

  /// Which sources an attempt is allowed to use. See the two-attempt loop above.
  private enum Attempt {
    /// The user's own valid files first, so a partial installation is repaired.
    case preferOwned
    /// Donor only, for when a same-size owned file failed its hash.
    case donorOnly
  }

  /// Clone if the filesystem can, copy if it cannot.
  ///
  /// **The fallback is back after being deleted, and the deletion was the
  /// mistake (review B2).** Clone-only looked like a clean simplification: both
  /// directories normally sit on one volume, so `clonefile` all but always
  /// works. But `EXDEV`, `ENOSPC`, `EEXIST` and `EACCES` are all real, and when
  /// one fires the user is not merely slower — an OFFLINE user with a complete
  /// model on disk gets nothing at all, because the only other route to bytes is
  /// the network. Reproducible model bytes are a fine reason to accept a
  /// re-download; they are not a reason to accept "cannot dictate".
  ///
  /// The copy is chunked and checks cancellation between chunks because the
  /// largest single file in the shipped manifest is 445 MB, and a check only
  /// between FILES would let a cancel wait for almost the whole thing.
  private static func reproduce(
    from source: URL, to destination: URL, sizeBytes: Int64,
    clonedThroughout: inout Bool
  ) async -> Bool {
    if cloneItem(at: source, to: destination) { return true }
    clonedThroughout = false
    // A clone costs almost nothing; a copy allocates every byte. Refuse rather
    // than start one that cannot finish, because a half-written file whose size
    // happened to match would be inherited by a later attempt as if it were
    // staged and good.
    guard hasRoomFor(sizeBytes, at: destination) else { return false }
    do {
      try copyInterruptibly(from: source, to: destination)
      return true
    } catch {
      // Leave nothing half-written behind, including on cancellation.
      try? FileManager.default.removeItem(at: destination)
      return false
    }
  }

  /// Whether the destination's filesystem has room for `bytes`, with the same
  /// headroom the delivery preflight uses for a download.
  private static func hasRoomFor(_ bytes: Int64, at destination: URL) -> Bool {
    let directory = destination.deletingLastPathComponent()
    guard
      let values = try? directory.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]),
      let available = values.volumeAvailableCapacityForImportantUsage
    else {
      // Could not ask. Allow the copy and let it fail honestly rather than
      // refusing on an answer we do not have.
      return true
    }
    return available > bytes
  }

  /// Copies in chunks, aborting between chunks when the task is cancelled.
  private static func copyInterruptibly(from source: URL, to destination: URL) throws {
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: destination)
    defer { try? writer.close() }
    // 4 MiB: large enough that syscall overhead is irrelevant against a 445 MB
    // file, small enough that a cancel is felt immediately.
    let chunkBytes = 4 * 1024 * 1024
    while true {
      if Task.isCancelled { throw CancellationError() }
      let chunk = try reader.read(upToCount: chunkBytes) ?? Data()
      if chunk.isEmpty { break }
      try writer.write(contentsOf: chunk)
    }
  }

  // MARK: - Filesystem helpers

  /// APFS copy-on-write. Both paths end up independent — writing to one never
  /// affects the other — while sharing their blocks until something writes.
  ///
  /// Apple documents the independence, not zero allocation, so this is "usually
  /// little extra space", never a guarantee of none.
  private static func cloneItem(at source: URL, to destination: URL) -> Bool {
    source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else { return false }
        return clonefile(sourcePath, destinationPath, 0) == 0
      }
    }
  }
}
