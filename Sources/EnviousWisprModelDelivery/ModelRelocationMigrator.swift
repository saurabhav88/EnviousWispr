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
///    manifest. Same-volume rename into the destination, then validate the
///    admission marker against the new registration before the old directory is
///    dropped. Zero re-download. (Marker stamps store RELATIVE install paths +
///    size + mtime, and a rename preserves mtimes, so the marker survives the
///    move — `CacheAdmission.isAdmitted`.)
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
    /// Relative filenames of previously-shipped layouts that this build can no
    /// longer load but DOES recognize as its own (e.g. `["eg-1-v1.gguf"]`).
    /// Presence of one of these in an old location ⇒ trusted-legacy outcome.
    public let trustedLegacyArtifacts: [String]

    public init(
      manifest: DeliveryManifest,
      oldLocations: [URL],
      destination: URL,
      metadataDirectory: URL,
      trustedLegacyArtifacts: [String] = []
    ) {
      self.manifest = manifest
      self.oldLocations = oldLocations
      self.destination = destination
      self.metadataDirectory = metadataDirectory
      self.trustedLegacyArtifacts = trustedLegacyArtifacts
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
    /// Manifest digest this token was minted against — a token from a different
    /// revision must never authorize a delete under the current one.
    let manifestDigest: String
  }

  public init() {}

  // MARK: - Migration (runs inside the migration latch, before any engine loads)

  /// Classify and, where possible, relocate. Filesystem only: fast (stat +
  /// rename), never a network transfer — the caller must NOT hold the migration
  /// latch across a download.
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

    // A previously-shipped layout we recognize: do NOT move it, do NOT load it,
    // do NOT delete it. Record the token and let the caller replace it.
    if let legacy = trustedLegacyArtifact(in: oldDirectory, plan: plan) {
      writeToken(
        Token(legacyPath: legacy.path, manifestDigest: plan.manifest.manifestDigest),
        plan: plan)
      return .trustedLegacyPending(legacy)
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

    // Only now is the old home provably redundant.
    try? fm.removeItem(at: oldDirectory)
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
  public func cleanUpLegacy(_ plan: RelocationPlan) throws {
    let fm = FileManager.default
    guard let token = readToken(plan: plan) else { return }
    // A token minted against a different revision must not authorize a delete.
    guard token.manifestDigest == plan.manifest.manifestDigest else {
      clearToken(plan: plan)
      return
    }
    if fm.fileExists(atPath: token.legacyPath) {
      try fm.removeItem(atPath: token.legacyPath)
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

  /// A recognized previously-shipped artifact in `directory`, if any. Only the
  /// exact filenames this build ships as `trustedLegacyArtifacts` qualify — an
  /// unrecognized file is never treated as ours.
  private func trustedLegacyArtifact(in directory: URL, plan: RelocationPlan) -> URL? {
    let fm = FileManager.default
    for name in plan.trustedLegacyArtifacts {
      let url = directory.appendingPathComponent(name)
      if fm.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  /// Move every manifest-listed file from `source` into `destination`. Same
  /// volume ⇒ rename (instant, mtime preserved). Cross-volume ⇒ copy, leaving
  /// the source intact for the caller to drop after admission.
  ///
  /// Journal-free by construction: nothing is deleted here, so a crash mid-move
  /// leaves the old copy intact and a partially-populated destination that the
  /// next launch's admission check rejects and rebuilds.
  private func relocate(from source: URL, to destination: URL, manifest: DeliveryManifest) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    for root in CacheAdmission.componentRoots(of: manifest) {
      let from = source.appendingPathComponent(root)
      let to = destination.appendingPathComponent(root)
      guard fm.fileExists(atPath: from.path) else { continue }
      if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
      do {
        try fm.moveItem(at: from, to: to)
      } catch {
        // Cross-volume (or any rename refusal): copy instead. The source stays
        // put; the caller drops it only after the destination is admitted.
        try fm.copyItem(at: from, to: to)
      }
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
