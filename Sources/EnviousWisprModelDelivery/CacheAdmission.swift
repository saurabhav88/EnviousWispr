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
    let fm = FileManager.default
    for stamp in marker.files {
      let url = installDirectory.appendingPathComponent(stamp.path)
      guard let attrs = try? fm.attributesOfItem(atPath: url.path),
        (attrs[.size] as? Int64) == stamp.sizeBytes,
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
        let url = installDirectory.appendingPathComponent(file.path)
        guard Self.sizeMatches(url: url, expected: file.sizeBytes),
          await Self.streamingSHA256(of: url) == file.sha256
        else {
          componentOK = false
          break
        }
        onFileValidated?(file.path)
      }
      if componentOK { verified.insert(component) } else { failed.insert(component) }
    }
    return ValidationResult(verifiedComponents: verified, failedComponents: failed)
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
    if let entries = try? fm.contentsOfDirectory(atPath: installDirectory.path) {
      for entry in entries where !componentRoots.contains(entry) {
        try? fm.removeItem(at: installDirectory.appendingPathComponent(entry))
      }
    }

    // (4) The linearization point: stamp current on-disk reality.
    var stamps: [AdmissionMarker.FileStamp] = []
    for file in manifest.files {
      let url = installDirectory.appendingPathComponent(file.path)
      let attrs = try fm.attributesOfItem(atPath: url.path)
      guard let size = attrs[.size] as? Int64, size == file.sizeBytes,
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
      else {
        throw DeliveryFailure(
          reason: .cacheRepairFailed, detail: "post_promote_stamp:\(file.component)")
      }
      stamps.append(.init(path: file.path, sizeBytes: size, mtime: mtime))
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
        && fm.fileExists(atPath: installDirectory.appendingPathComponent(file.path).path)
    }
  }

  /// Delete a failed component from the install dir (repair pipeline).
  func removeComponent(_ component: String) {
    try? FileManager.default.removeItem(
      at: installDirectory.appendingPathComponent(component))
  }

  /// Top-level entry names the manifest claims (component dirs + loose files).
  static func componentRoots(of manifest: DeliveryManifest) -> Set<String> {
    Set(
      manifest.files.map { file in
        file.path.contains("/") ? String(file.path.split(separator: "/")[0]) : file.path
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
