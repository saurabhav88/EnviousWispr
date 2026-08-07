import CryptoKit
import EnviousWisprCore
import Foundation

/// The admission gate (contract invariants 1-4, D2 §§3-5): decides whether a
/// cache is ADMITTED, validates existing files against the manifest, promotes
/// verified staged components, and owns the admission marker — the ONLY door
/// through which bytes become servable. Presence of files is never truth;
/// the marker behind the hash gate is.
///
/// Not an actor: every call runs on the controller actor (the one writer per
/// identity, D4 §2). Pure filesystem + hashing; no networking, no state.
struct CacheAdmission {
  /// `<metadata-dir>/<cache-key>.admission.json` (D2 §3): written ONLY after
  /// every manifest file passed streaming SHA-256 and the set was promoted.
  /// Lives OUTSIDE the runtime's model folder (parked PR-2 sibling-metadata
  /// precedent) so no runtime mistakes it for a model file.
  struct AdmissionMarker: Codable, Equatable {
    struct FileStamp: Codable, Equatable {
      let path: String
      let sizeBytes: Int64
      let mtime: Double
    }

    let manifestDigest: String
    let admittedAt: Date
    let files: [FileStamp]
  }

  /// What existing-cache validation found (D2 §4 pipeline).
  struct ValidationResult: Equatable {
    /// Components whose files all exist and hash to the manifest — nothing to
    /// fetch for these.
    let verifiedComponents: Set<String>
    /// Components with any missing/short/corrupt file — delete + re-fetch at
    /// this grain (the #1339 poison classes, incl. the loose-vocab gap).
    let failedComponents: Set<String>
  }

  let manifest: DeliveryManifest
  let installDirectory: URL
  let metadataDirectory: URL

  var markerURL: URL {
    metadataDirectory.appendingPathComponent("\(manifest.identity.cacheKey).admission.json")
  }

  // MARK: - Admission check (the fast path)

  /// A cache is ADMITTED iff the marker exists, its digest equals the current
  /// manifest's, and every listed file's size+mtime match (D2 §3). No rehash
  /// on the fast path (D7 rows 11/16: marker untouched, no delivery events).
  func isAdmitted() -> Bool {
    guard let data = try? Data(contentsOf: markerURL),
      let marker = try? JSONDecoder().decode(AdmissionMarker.self, from: data),
      marker.manifestDigest == manifest.manifestDigest,
      marker.files.count == manifest.files.count
    else { return false }
    // The MANIFEST is the truth for WHAT must exist and its size; the marker
    // only contributes the admission-time mtime stamp. A corrupt marker with
    // the right digest/count can never bless a different file set
    // (exhaustive r7 finding 4).
    // Marker FileStamp.path stores the RESOLVED INSTALL path (contract §4b);
    // both write (promoteAndAdmit) and read (here) key by it, so a manifest
    // whose fetch name differs from its install name still round-trips. For a
    // v1 manifest (no installPath) resolvedInstallPath == path, so existing
    // markers stay valid with no migration.
    let stampsByPath = Dictionary(
      marker.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let fm = FileManager.default
    for file in manifest.files {
      guard let stamp = stampsByPath[file.resolvedInstallPath], stamp.sizeBytes == file.sizeBytes
      else {
        return false
      }
      let url = installDirectory.appendingPathComponent(file.resolvedInstallPath)
      guard let attrs = try? fm.attributesOfItem(atPath: url.path),
        (attrs[.size] as? Int64) == file.sizeBytes,
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
        mtime == stamp.mtime
      else { return false }
    }
    return true
  }

  // MARK: - Existing-cache validation (one full hash pass)

  /// Full SHA-256 validation of whatever is in the install dir against the
  /// manifest, at component granularity (D2 §4: pre-ModelDelivery caches,
  /// marker-less files, legacy partials, manual deletion — all the same
  /// pipeline). Size fast-gate first, then streaming hash off the caller's
  /// actor. `onFileValidated` ticks liveness so watchdogs stay quiet during a
  /// multi-second pass (D6 state 4).
  func validateExistingCache(onFileValidated: (@Sendable (String) -> Void)? = nil) async
    -> ValidationResult
  {
    var verified = Set<String>()
    var failed = Set<String>()
    for (component, files) in manifest.filesByComponent {
      var componentOK = true
      for file in files {
        let url = installDirectory.appendingPathComponent(file.resolvedInstallPath)
        guard Self.sizeMatches(url: url, expected: file.sizeBytes),
          await Self.streamingSHA256(of: url) == file.sha256
        else {
          componentOK = false
          break
        }
        onFileValidated?(file.resolvedInstallPath)
      }
      // Every manifest-listed file can hash correctly while a STALE file the
      // current manifest no longer lists survives beside them (#1372) — the
      // loop above only ever looks at files THIS manifest names, so it has no
      // way to notice one it doesn't. Catch it here, once, after the listed
      // files are already known-good.
      if componentOK,
        Self.hasExtraFiles(
          component: component, expectedFiles: files, installDirectory: installDirectory)
      {
        componentOK = false
      }
      if componentOK { verified.insert(component) } else { failed.insert(component) }
    }
    return ValidationResult(verifiedComponents: verified, failedComponents: failed)
  }

  /// Whether the component's on-disk directory contains any file NOT in
  /// `expectedFiles` — a stale leftover from a manifest revision that removed
  /// or renamed a file INSIDE a still-otherwise-valid component. A loose
  /// (non-directory) component has nothing to hide an extra file inside; only
  /// a directory component (e.g. a `.mlmodelc` bundle) can. Directory entries
  /// themselves are never compared (only regular files) — same trap
  /// `ModelDeliveryController.hasStagedPartials` already documents for this
  /// exact target (`subpathsOfDirectory` yields the directory name itself as
  /// an entry).
  static func hasExtraFiles(
    component: String, expectedFiles: [DeliveryManifest.File], installDirectory: URL
  ) -> Bool {
    let componentRoot = installDirectory.appendingPathComponent(component)

    // Cloud review P2: a legitimately-installed component is never itself a
    // symlink. Reject one without following it — `fileExists(atPath:
    // isDirectory:)` follows symlinks transparently, so a component root
    // symlinked to a directory containing stale files would pass the
    // directory check below; worse, `enumerator(at:)` can return ZERO
    // descendants when its OWN root is a symlink, so the loop below would
    // never even run and this function would wrongly report "no extra
    // files" having examined nothing. `.isSymbolicLinkKey` reports the URL
    // itself, not its target (`lstat` semantics, not `stat`).
    if let isSymlink = try? componentRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
      .isSymbolicLink, isSymlink
    {
      return true
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: componentRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }

    // `enumerator(at:)` returns OS-RESOLVED paths (e.g. `/private/tmp/...`
    // under a `/tmp` checkout); `componentRoot.path` is not resolved. Naive
    // string-prefix stripping between the two silently mismatches — the
    // exact trap `swift-testing-patterns.md` RULE:
    // repo-root-canonicalize-via-realpath-not-foundation-helpers documents
    // for this codebase. Resolve through POSIX `realpath(3)` before
    // comparing, not `URL.resolvingSymlinksInPath()` (documented there as
    // insufficient for the `/tmp` case).
    var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(componentRoot.path, &resolvedBuffer) != nil else { return true }
    let resolvedComponentRoot = String(cString: resolvedBuffer)

    let expected = Set(expectedFiles.map(\.resolvedInstallPath))
    // Without an explicit `errorHandler`, `FileManager.enumerator` SILENTLY
    // STOPS traversal on hitting an unreadable subdirectory rather than
    // throwing — a stale file hidden behind that failure would never be
    // seen, and the loop below would wrongly conclude the component is
    // clean. Record the failure and fail closed on it (whole-diff review
    // P2 finding).
    var traversalFailed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: componentRoot, includingPropertiesForKeys: [.isDirectoryKey],
        errorHandler: { _, _ in
          traversalFailed = true
          return false  // stop; the flag alone decides the verdict below
        })
    else { return true }  // cannot enumerate ⇒ cannot prove clean; fail closed, not open

    let prefixCount = resolvedComponentRoot.count + 1  // +1 drops the path separator
    for case let fileURL as URL in enumerator {
      // Cloud review P2: checking `isRegularFile` let an unlisted SYMLINK
      // (e.g. a dangling link from manual cache manipulation) skip the
      // check entirely, since a symlink is neither a regular file nor a
      // directory. Any non-directory leaf must be accounted for — a
      // directory is just a container and is walked into, never itself
      // compared against `expected`.
      guard
        let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory != true, fileURL.path.count > prefixCount
      else { continue }
      // Relative to the RESOLVED component root, then re-prefixed with the
      // component name as a plain string — never path arithmetic against
      // `installDirectory` again, which is what mismatched in the first place.
      let relativeToComponent = String(fileURL.path.dropFirst(prefixCount))
      let candidatePath = "\(component)/\(relativeToComponent)"
      if !expected.contains(candidatePath) {
        return true
      }
    }
    return traversalFailed
  }

  // MARK: - Promotion (grounded r1 revision 4 — explicit crash ordering)

  /// Promote verified staged components into the install dir and admit the
  /// set. Caller guarantees every file in `stagedComponents` already passed
  /// its hash in staging; `untouchedComponents` passed validation in place.
  ///
  /// Crash-ordered: (1) marker deleted FIRST — no stale marker can bless a
  /// mixed set; (2) per component: remove existing, move staged (same volume,
  /// one rename each); (3) orphan cleanup — anything in the repo install dir
  /// not in the manifest dies with the promotion (replaces revision eviction
  /// for the shared-dir layout); (4) marker written. A crash anywhere between
  /// (1) and (4) leaves an unadmitted cache the next launch revalidates.
  func promoteAndAdmit(
    stagedComponents: Set<String>, stagingDirectory: URL, untouchedComponents: Set<String>
  ) throws {
    let fm = FileManager.default
    // (1) Invalidate before any destructive touch.
    if fm.fileExists(atPath: markerURL.path) {
      try fm.removeItem(at: markerURL)
    }
    try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)

    // (2) Component-grain promote: each .mlmodelc dir or loose file is one
    // rename; old-or-new per component, marker gates the set.
    let componentRoots = Self.componentRoots(of: manifest)
    for component in stagedComponents {
      let staged = stagingDirectory.appendingPathComponent(component)
      let final = installDirectory.appendingPathComponent(component)
      if fm.fileExists(atPath: final.path) {
        try fm.removeItem(at: final)
      }
      try fm.moveItem(at: staged, to: final)
    }

    // (3) Orphan cleanup: the manifest is the exhaustive truth for this repo
    // dir; unlisted entries are stale revisions' leftovers or foreign debris.
    // A FAILED delete must block admission — writing the marker over a dir
    // the manifest says is dirty would admit a state we could not produce
    // (exhaustive r7 finding 5).
    if let entries = try? fm.contentsOfDirectory(atPath: installDirectory.path) {
      for entry in entries where !componentRoots.contains(entry) {
        do {
          try fm.removeItem(at: installDirectory.appendingPathComponent(entry))
        } catch {
          throw DeliveryFailure(reason: .cacheRepairFailed, detail: "orphan_cleanup")
        }
      }
    }

    // (4) The linearization point: stamp current on-disk reality.
    var stamps: [AdmissionMarker.FileStamp] = []
    for file in manifest.files {
      let url = installDirectory.appendingPathComponent(file.resolvedInstallPath)
      let attrs = try fm.attributesOfItem(atPath: url.path)
      guard let size = attrs[.size] as? Int64, size == file.sizeBytes,
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
      else {
        throw DeliveryFailure(
          reason: .cacheRepairFailed, detail: "post_promote_stamp:\(file.component)")
      }
      // Stamp by resolved install path — the read side (isAdmitted) keys by it.
      stamps.append(.init(path: file.resolvedInstallPath, sizeBytes: size, mtime: mtime))
    }
    _ = untouchedComponents  // documented: validation already proved these in place
    try fm.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
    let marker = AdmissionMarker(
      manifestDigest: manifest.manifestDigest, admittedAt: Date(), files: stamps)
    try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
  }

  /// Whether ANY manifest file of this component exists in the install dir
  /// (distinguishes repair-of-damage from a cold first download).
  func componentHasAnyFile(_ component: String) -> Bool {
    let fm = FileManager.default
    return manifest.files.contains { file in
      file.component == component
        && fm.fileExists(
          atPath: installDirectory.appendingPathComponent(file.resolvedInstallPath).path)
    }
  }

  /// Delete a failed component from the install dir (repair pipeline).
  func removeComponent(_ component: String) {
    try? FileManager.default.removeItem(
      at: installDirectory.appendingPathComponent(component))
  }

  /// Top-level entry names the manifest claims (component dirs + loose files).
  /// Derived from the resolved INSTALL path (contract §4b) — these are on-disk
  /// names, so a decoupled fetch name must not leak into orphan-prune roots.
  static func componentRoots(of manifest: DeliveryManifest) -> Set<String> {
    Set(
      manifest.files.map { file in
        let p = file.resolvedInstallPath
        return p.contains("/") ? String(p.split(separator: "/")[0]) : p
      })
  }

  static func sizeMatches(url: URL, expected: Int64) -> Bool {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil)
      == expected
  }

  /// Streaming SHA-256 (constant memory) off the caller's actor — EG-1's
  /// shipped shape (`EGOneModelStore.verifyAndInstall`). Returns nil when the
  /// file cannot be read.
  static func streamingSHA256(of url: URL) async -> String? {
    await Task.detached(priority: .utility) {
      // Task.detached: hashing hundreds of MB is pure CPU + IO that must not
      // hold the controller actor (progress/UI reads); @concurrent needs the
      // enclosing fn nonisolated — detached utility is the house shape
      // (EG-1 precedent).
      guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? handle.close() }
      var hasher = SHA256()
      while autoreleasepool(invoking: {
        guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else {
          return false
        }
        hasher.update(data: chunk)
        return true
      }) {}
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }.value
  }
}
