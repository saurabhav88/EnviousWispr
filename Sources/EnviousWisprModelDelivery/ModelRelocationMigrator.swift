import Darwin  // clonefile(2): APFS copy-on-write clone (see `relocate`).
import EnviousWisprCore
import Foundation

/// One-time relocation of model bytes from a legacy on-disk home into the
/// app-owned `EnviousWispr/Models/<family>` layout (#1386, ModelDelivery epic
/// #1348 Phase 4).
///
/// Sibling of `CacheAdmission`, and deliberately NOT an actor: every call runs
/// from the composition root before any engine loads (the migration latch), so
/// there is exactly one caller. Pure filesystem; no networking, no hashing of
/// its own (it delegates verification to `CacheAdmission`).
///
/// Two outcomes matter, and they are NOT the same thing:
///
/// 1. **Relocatable** — the old directory holds bytes that satisfy the CURRENT
///    manifest. The set is REPRODUCED at the destination (APFS clone: instant,
///    no extra space) with the source left completely intact, re-admitted there,
///    and only then is the old directory dropped. Zero re-download, and the
///    source stays a valid fallback at every instant — so a crash mid-relocation
///    can never leave both sides partial.
///
/// 2. **Trusted-legacy** — the old directory holds a PREVIOUSLY-SHIPPED layout
///    that cannot satisfy the current manifest (EG-1's monolithic
///    `eg-1-v1.gguf` vs the current 8-shard `componentSet`). These bytes are a
///    *trusted app-managed asset* — we shipped them and hold their digest — so
///    the contract's automatic-replacement clause permits replacing them
///    without asking. The migrator does NOT move, load, or delete them: it
///    records a durable pending-cleanup token and returns. The caller starts the
///    replacement fetch and deletes the legacy bytes ONLY after the new set is
///    admitted (verify-before-delete).
///
/// The migrator never deletes anything it has not proven replaceable, and it
/// never deletes an unrecognized foreign copy at all.
public struct ModelRelocationMigrator: Sendable {

  /// A layout WE shipped, identified by what it IS, not what it is called.
  ///
  /// The filename alone is not identity. A corrupt, hand-edited, or unrelated
  /// file that happens to be named `eg-1-v1.gguf` is NOT ours, and the
  /// provenance rule forbids deleting bytes we cannot prove we shipped — so the
  /// digest is the gate, and a mismatch drops the file into the untouchable
  /// `unrecognized` class.
  public struct TrustedLegacyArtifact: Sendable, Equatable {
    /// On-disk name inside the legacy directory.
    public let name: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(name: String, sizeBytes: Int64, sha256: String) {
      self.name = name
      self.sizeBytes = sizeBytes
      self.sha256 = sha256
    }
  }

  /// One model's relocation descriptor. Journaling/crash-safety is written once
  /// here and reused per family rather than reimplemented per engine.
  public struct RelocationPlan: Sendable {
    /// Delivery identity of the model being rehomed (also the token/journal key).
    public let manifest: DeliveryManifest
    /// Where the bytes used to live (checked in order; first hit wins).
    public let oldLocations: [URL]
    /// The app-owned destination — the new registration's install directory.
    public let destination: URL
    /// Where admission markers live (unchanged by relocation).
    public let metadataDirectory: URL
    /// Previously-shipped layouts this build can no longer load but DOES
    /// recognize as its own. Identity is the DIGEST, never the filename: a
    /// same-named file we did not ship is a stranger's, and strangers are never
    /// deleted (the provenance rule — Codex PR-1 review P2).
    public let trustedLegacyArtifacts: [TrustedLegacyArtifact]
    /// Filename suffixes of a retired downloader's scratch files (e.g.
    /// `[".partial", ".resume.json"]`). Swept from the old locations during
    /// migration — once the install directory moves, nothing else will ever look
    /// there again, so an interrupted multi-GB download would be stranded on the
    /// user's disk forever. NEVER a model suffix: only genuine scratch.
    public let staleSidecarSuffixes: [String]

    public init(
      manifest: DeliveryManifest,
      oldLocations: [URL],
      destination: URL,
      metadataDirectory: URL,
      trustedLegacyArtifacts: [TrustedLegacyArtifact] = [],
      staleSidecarSuffixes: [String] = []
    ) {
      self.manifest = manifest
      self.oldLocations = oldLocations
      self.destination = destination
      self.metadataDirectory = metadataDirectory
      self.trustedLegacyArtifacts = trustedLegacyArtifacts
      self.staleSidecarSuffixes = staleSidecarSuffixes
    }
  }

  public enum Outcome: Sendable, Equatable {
    /// Nothing to do: destination already holds this model, or no old copy exists.
    case noop
    /// Old bytes satisfied the current manifest and were moved into place.
    case relocated
    /// A previously-shipped layout we recognize is present at this URL. It has
    /// NOT been moved, loaded, or deleted. The caller must fetch the current
    /// manifest's bytes and, only once admitted, call `cleanUpLegacy`.
    case trustedLegacyPending(URL)
    /// Old bytes exist but match neither the current manifest nor a trusted
    /// legacy layout. Untouched, never loaded. Treated as absent.
    case unrecognized
  }

  /// `<metadata-dir>/<cache-key>.relocation.json` — the durable token. Survives
  /// relaunch so a crash mid-transition is reconcilable, and so the legacy
  /// cleanup can be retried on a later launch if it throws.
  struct Token: Codable, Equatable {
    /// Absolute path of the legacy artifact awaiting cleanup.
    let legacyPath: String
    /// Size and digest of the artifact we VERIFIED at classification time. BOTH
    /// are re-checked immediately before the delete. Size alone is not enough: a
    /// same-size corruption or a same-size manual replacement would slip through
    /// a byte-count check and we would delete bytes we can no longer prove are
    /// ours (Codex PR-1 review r2). The delete is minutes after classification —
    /// a whole model download — so the file genuinely can change in between.
    let legacySizeBytes: Int64
    let legacySHA256: String
    /// Manifest digest this token was minted against — a token from a different
    /// revision must never authorize a delete under the current one.
    let manifestDigest: String
  }

  public init() {}

  // MARK: - Migration (runs inside the migration latch, before any engine loads)

  /// Classify and, where possible, relocate. Filesystem only — never a network
  /// transfer, so the caller must NOT hold the migration latch across a
  /// download. Hashes at most one candidate (size gates first), so the common
  /// launch is a stat and nothing more.
  public func migrate(_ plan: RelocationPlan) async -> Outcome {
    let fm = FileManager.default
    let admission = CacheAdmission(
      manifest: plan.manifest,
      installDirectory: plan.destination,
      metadataDirectory: plan.metadataDirectory)

    // Destination already good — the common case on every launch after the
    // first. Cheap marker check, no rehash.
    if admission.isAdmitted() { return .noop }

    guard let oldDirectory = plan.oldLocations.first(where: { fm.fileExists(atPath: $0.path) }),
      oldDirectory.standardizedFileURL != plan.destination.standardizedFileURL
    else { return .noop }

    // Stale download sidecars from a retired downloader (an interrupted
    // multi-GB `.partial` and its resume file) are stranded the moment the
    // install directory moves: the engine only ever sweeps its CURRENT dir, so
    // nothing would ever look here again. Left behind, they silently cost the
    // user gigabytes and can fail the replacement download's disk preflight.
    // Swept before classification, because the trusted-legacy path returns
    // early and that is exactly the case where a stranded partial exists.
    // Never a model file — only the named sidecar suffixes.
    sweepStaleSidecars(in: oldDirectory, plan: plan)

    // A previously-shipped layout we recognize: do NOT move it, do NOT load it,
    // do NOT delete it. Record the token and let the caller replace it.
    if let legacy = await trustedLegacyArtifact(in: oldDirectory, plan: plan) {
      writeToken(
        Token(
          legacyPath: legacy.url.path,
          legacySizeBytes: legacy.artifact.sizeBytes,
          legacySHA256: legacy.artifact.sha256,
          manifestDigest: plan.manifest.manifestDigest),
        plan: plan)
      return .trustedLegacyPending(legacy.url)
    }

    // Does the old directory satisfy the CURRENT manifest? Validate in place
    // before moving a single byte — we relocate proven-good bytes only.
    let oldAdmission = CacheAdmission(
      manifest: plan.manifest,
      installDirectory: oldDirectory,
      metadataDirectory: plan.metadataDirectory)
    let validation = await oldAdmission.validateExistingCache()
    guard validation.failedComponents.isEmpty, !validation.verifiedComponents.isEmpty else {
      return .unrecognized
    }

    do {
      try relocate(from: oldDirectory, to: plan.destination, manifest: plan.manifest)
    } catch {
      // The old copy is untouched on any throw; next launch retries.
      return .unrecognized
    }

    // Re-stamp admission against the NEW install directory. A same-volume
    // rename preserves size+mtime, so this is the marker fast path; a
    // cross-volume copy rehashes once, which `promoteAndAdmit` handles.
    do {
      try admission.promoteAndAdmit(
        stagedComponents: [],
        stagingDirectory: plan.destination,
        untouchedComponents: validation.verifiedComponents)
    } catch {
      return .unrecognized
    }
    guard admission.isAdmitted() else { return .unrecognized }

    // Only now is the old copy provably redundant — and only the parts of it we
    // actually reproduced. Deleting the whole directory would take anything ELSE
    // in it with us: a foreign model, a user's own file, something we never
    // validated and never copied. We do not delete what we cannot account for
    // (Codex PR-1 review r3 P1).
    for root in CacheAdmission.componentRoots(of: plan.manifest).sorted() {
      try? fm.removeItem(at: oldDirectory.appendingPathComponent(root))
    }
    // The directory itself goes only if nothing of the user's remains in it.
    if let remaining = try? fm.contentsOfDirectory(atPath: oldDirectory.path), remaining.isEmpty {
      try? fm.removeItem(at: oldDirectory)
    }
    return .relocated
  }

  // MARK: - Legacy cleanup (runs ONLY after the replacement is admitted)

  /// Delete the trusted-legacy bytes and clear the token. The caller MUST have
  /// confirmed the new set is admitted and stopped any runtime holding the old
  /// file open (deleting a file an engine has mmap'd is a SIGBUS).
  ///
  /// Throws on a failed delete so the caller can retain the token and retry on a
  /// later launch — never clears the token on a failure. Idempotent: an
  /// already-absent legacy file clears the token and returns.
  public func cleanUpLegacy(_ plan: RelocationPlan) async throws {
    let fm = FileManager.default
    guard let token = readToken(plan: plan) else { return }
    // A token minted against a different revision must not authorize a delete.
    guard token.manifestDigest == plan.manifest.manifestDigest else {
      clearToken(plan: plan)
      return
    }
    let url = URL(fileURLWithPath: token.legacyPath)
    if fm.fileExists(atPath: token.legacyPath) {
      // The file must STILL be the artifact we proved was ours. Classification
      // happened before a multi-GB download, so minutes have passed and the file
      // genuinely can have changed underneath us. Re-prove identity by digest,
      // not by byte count — a same-size corruption or replacement passes a size
      // check and would otherwise cost the user bytes we cannot identify.
      // Size is the cheap gate; the hash is the proof.
      guard CacheAdmission.sizeMatches(url: url, expected: token.legacySizeBytes),
        await CacheAdmission.streamingSHA256(of: url) == token.legacySHA256
      else {
        // No longer identifiable as ours: leave the bytes alone and drop the
        // token so we never revisit them.
        clearToken(plan: plan)
        return
      }
      try fm.removeItem(at: url)
    }
    clearToken(plan: plan)
  }

  /// The pending legacy artifact, if a cleanup is still owed for THIS revision.
  /// Drives next-launch reconciliation.
  public func pendingLegacyArtifact(_ plan: RelocationPlan) -> URL? {
    guard let token = readToken(plan: plan),
      token.manifestDigest == plan.manifest.manifestDigest
    else { return nil }
    return URL(fileURLWithPath: token.legacyPath)
  }

  // MARK: - Internals

  /// Delete a retired downloader's scratch files from an old location.
  ///
  /// Strictly suffix-matched, and the suffixes are scratch-only — a model file
  /// is never a candidate. This is the one thing we DO delete from the old home
  /// without proving a digest, because a `.partial` is by definition an
  /// incomplete artifact that nothing can load, and leaving it costs the user
  /// gigabytes that no future code path will ever reclaim.
  private func sweepStaleSidecars(in directory: URL, plan: RelocationPlan) {
    guard !plan.staleSidecarSuffixes.isEmpty,
      let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return }
    for entry in entries where plan.staleSidecarSuffixes.contains(where: { entry.hasSuffix($0) }) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
    }
  }

  /// A previously-shipped artifact in `directory` that we can PROVE is ours.
  ///
  /// The filename is only the lookup key; the digest is the identity (Codex PR-1
  /// review P2). A file named `eg-1-v1.gguf` that we did not ship — corrupt,
  /// truncated, hand-replaced, or someone else's — fails the hash and falls
  /// through to `unrecognized`, where it is never moved, loaded, or deleted.
  /// Size is the cheap gate so the multi-GB hash runs only on a real candidate.
  private func trustedLegacyArtifact(in directory: URL, plan: RelocationPlan) async
    -> (url: URL, artifact: TrustedLegacyArtifact)?
  {
    for artifact in plan.trustedLegacyArtifacts {
      let url = directory.appendingPathComponent(artifact.name)
      guard CacheAdmission.sizeMatches(url: url, expected: artifact.sizeBytes),
        await CacheAdmission.streamingSHA256(of: url) == artifact.sha256
      else { continue }
      return (url, artifact)
    }
    return nil
  }

  /// Reproduce every manifest-listed component at `destination`, leaving the
  /// source COMPLETELY INTACT. The source is dropped by the caller only after
  /// the destination is admitted — verify-before-delete, applied to the move
  /// itself (Codex PR-1 review P2).
  ///
  /// This is deliberately NOT a rename. A per-component `moveItem` removes each
  /// component from the source as it goes, so a crash (or a later component's
  /// failure) leaves BOTH directories partial: the destination is unadmittable
  /// and the source no longer validates, so the next launch classifies a
  /// perfectly good model as `unrecognized` and re-downloads it. Copying keeps
  /// the source a complete, valid fallback at every instant.
  ///
  /// Copying multiple GB would normally be the expensive choice — except on
  /// APFS, where `clonefile(2)` makes a copy-on-write clone: no bytes are moved,
  /// no extra space is used, and it returns immediately. We clone when we can and
  /// fall back to a real copy (a different volume, or a non-APFS filesystem)
  /// where we cannot.
  private func relocate(from source: URL, to destination: URL, manifest: DeliveryManifest) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    // Sorted, not set-order: a deterministic sequence makes a partial-failure
    // reproducible in a test instead of depending on hash ordering.
    for root in CacheAdmission.componentRoots(of: manifest).sorted() {
      let from = source.appendingPathComponent(root)
      let to = destination.appendingPathComponent(root)
      guard fm.fileExists(atPath: from.path) else { continue }
      if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
      if clonefile(from.path, to.path, 0) == 0 { continue }
      try fm.copyItem(at: from, to: to)
    }
  }

  private func tokenURL(plan: RelocationPlan) -> URL {
    plan.metadataDirectory.appendingPathComponent(
      "\(plan.manifest.identity.cacheKey).relocation.json")
  }

  private func writeToken(_ token: Token, plan: RelocationPlan) {
    let url = tokenURL(plan: plan)
    try? FileManager.default.createDirectory(
      at: plan.metadataDirectory, withIntermediateDirectories: true)
    try? JSONEncoder().encode(token).write(to: url, options: .atomic)
  }

  private func readToken(plan: RelocationPlan) -> Token? {
    guard let data = try? Data(contentsOf: tokenURL(plan: plan)) else { return nil }
    return try? JSONDecoder().decode(Token.self, from: data)
  }

  private func clearToken(plan: RelocationPlan) {
    try? FileManager.default.removeItem(at: tokenURL(plan: plan))
  }
}
