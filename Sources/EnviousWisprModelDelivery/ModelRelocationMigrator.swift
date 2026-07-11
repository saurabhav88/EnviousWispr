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

  /// What the pending legacy artifact is waiting FOR. A path alone is not enough:
  /// the same stranded file means "replace me" before the user asks for the model
  /// to be removed, and "just delete me" afterwards. Without this, a Remove whose
  /// legacy delete failed would be resurrected on the next launch — we would see
  /// the old file, conclude a replacement was owed, and silently re-download
  /// gigabytes of a model the user explicitly deleted.
  public enum LegacyIntent: String, Codable, Sendable {
    /// Fetch the current manifest's bytes, then delete this.
    case replace
    /// The user removed the model. Delete this; fetch NOTHING.
    case remove
  }

  /// `<metadata-dir>/<cache-key>.relocation.json` — the durable token. Survives
  /// relaunch so a crash mid-transition is reconcilable, and so the legacy cleanup
  /// can be retried on a later launch if it throws.
  struct Token: Codable, Equatable {
    /// Absolute path of the legacy artifact awaiting cleanup.
    let legacyPath: String
    /// Defaults to `.replace` for a token written before intent existed.
    var intent: LegacyIntent = .replace
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

  /// The first candidate directory that currently holds an ADMITTED copy of this
  /// manifest — or nil when none does.
  ///
  /// Existence is not validity. A relocation that failed partway leaves a
  /// half-populated destination directory sitting next to a perfectly good source,
  /// and a caller that picks by "does the folder exist" would choose the broken one
  /// (Codex PR-1 review r10). This is what the delivery kill switch consults to
  /// decide where a no-mutation build should READ from, so it has to be the real
  /// admission check — cheap (marker + size + mtime, no rehash) and synchronous.
  public static func admittedLocation(
    manifest: DeliveryManifest,
    candidates: [URL],
    metadataDirectory: URL
  ) -> URL? {
    candidates.first { candidate in
      CacheAdmission(
        manifest: manifest,
        installDirectory: candidate,
        metadataDirectory: metadataDirectory
      ).isAdmitted()
    }
  }

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
    //
    // NOT a bare early-return: a crash between `promoteAndAdmit` (which writes the
    // destination marker) and the old-copy cleanup below would land here forever
    // after, leaving a duplicate multi-GB model in the old home that nothing ever
    // revisits. Because the destination IS admitted, any of OUR components still
    // sitting in an old location are provably redundant, so finish the job that
    // crash interrupted (Codex PR-1 review r7).
    if admission.isAdmitted() {
      await reconcileOldLocations(plan)
      return .noop
    }

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
      // Re-classification must NOT overwrite a decision the user already made.
      //
      // If a previous launch recorded `.remove` and the delete then failed, the
      // artifact is still here — so we land here again, and writing a fresh token
      // would reset the intent to its `.replace` default and re-download the 2.9 GB
      // model the user threw away. That is the resurrection bug (r6) sneaking back
      // in through classification (Codex PR-1 review r16). Carry a current-revision
      // token's intent forward; only a token from another revision, or no token at
      // all, starts fresh.
      let intent = pendingLegacyIntent(plan) ?? .replace
      writeToken(
        Token(
          legacyPath: legacy.url.path,
          intent: intent,
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

    // Only now is the old copy provably redundant — and we just proved which
    // components are byte-exact, so pass them rather than re-hashing multiple GB.
    await reconcileOldLocations(
      plan, provenSource: (url: oldDirectory, components: validation.verifiedComponents))
    return .relocated
  }

  /// Drop the parts of an old location that the ADMITTED destination has made
  /// redundant. Safe to run at any time once the destination is admitted, which is
  /// exactly why it is also the crash-recovery path: a process that died between
  /// admitting the destination and cleaning the source resumes here on its next
  /// launch instead of leaving a duplicate multi-GB model behind forever.
  ///
  /// Removes ONLY the component roots we reproduced. Deleting the whole directory
  /// would take anything else in it with us — a foreign model, a user's own file,
  /// something we never validated and never copied — and we do not delete what we
  /// cannot account for. The directory itself goes only when nothing of the user's
  /// remains in it. A trusted-legacy artifact is deliberately NOT touched here: its
  /// deletion is governed by the durable token, never by this sweep.
  /// - Parameter provenSource: the ONE directory whose components were just proven
  ///   byte-exact (the relocation source), so we do not re-hash multiple GB to
  ///   delete what we literally just validated. Every OTHER old location earns its
  ///   deletion independently — a proof about one directory says nothing about the
  ///   bytes in another, and reusing it there would delete unverified files under a
  ///   matching name (Codex PR-1 review r12). Nil on the crash-recovery path, where
  ///   nothing has been proven at all.
  private func reconcileOldLocations(
    _ plan: RelocationPlan, provenSource: (url: URL, components: Set<String>)? = nil
  ) async {
    let fm = FileManager.default
    for oldDirectory in plan.oldLocations {
      guard oldDirectory.standardizedFileURL != plan.destination.standardizedFileURL,
        fm.fileExists(atPath: oldDirectory.path)
      else { continue }

      sweepStaleSidecars(in: oldDirectory, plan: plan)

      // Delete ONLY components we have proven are the copy we reproduced. A
      // filename match is not proof: an old directory could hold corrupt,
      // truncated, or hand-replaced bytes under a shard's name, and deleting those
      // because the name lines up is the provenance rule broken by the very code
      // that enforces it (Codex PR-1 review r11). Whatever fails the hash is left
      // exactly where it is.
      let verified: Set<String>
      if let provenSource,
        provenSource.url.standardizedFileURL == oldDirectory.standardizedFileURL
      {
        verified = provenSource.components
      } else {
        let gate = CacheAdmission(
          manifest: plan.manifest,
          installDirectory: oldDirectory,
          metadataDirectory: plan.metadataDirectory)
        verified = await gate.validateExistingCache().verifiedComponents
      }

      let roots = componentRoots(of: verified, in: plan.manifest)
      for root in roots.sorted() {
        try? fm.removeItem(at: oldDirectory.appendingPathComponent(root))
      }
      if let remaining = try? fm.contentsOfDirectory(atPath: oldDirectory.path),
        remaining.isEmpty
      {
        try? fm.removeItem(at: oldDirectory)
      }
    }
  }

  /// Top-level on-disk roots belonging to the given (verified) components only.
  private func componentRoots(of components: Set<String>, in manifest: DeliveryManifest) -> Set<
    String
  > {
    Set(
      manifest.files
        .filter { components.contains($0.component) }
        .map { file in
          let p = file.resolvedInstallPath
          return p.contains("/") ? String(p.split(separator: "/")[0]) : p
        })
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

  /// What the pending artifact is waiting for — `nil` when nothing is pending.
  public func pendingLegacyIntent(_ plan: RelocationPlan) -> LegacyIntent? {
    guard let token = readToken(plan: plan),
      token.manifestDigest == plan.manifest.manifestDigest
    else { return nil }
    return token.intent
  }

  /// The user removed this model. The stranded legacy artifact is now owed a
  /// plain DELETE, not a replacement — so if its delete fails and we retry on a
  /// later launch, we delete it and fetch nothing, instead of resurrecting a
  /// model the user threw away.
  ///
  /// No-op when nothing is pending (an ordinary Remove with no legacy artifact).
  public func markLegacyForRemoval(_ plan: RelocationPlan) {
    setIntent(.remove, plan: plan)
  }

  /// The user took the removal back (they re-selected the model). The stranded
  /// artifact is owed a REPLACEMENT again, not a delete.
  ///
  /// Without this, `removalPending` is cleared in memory but the durable token still
  /// reads `.remove` — so a failed replacement download followed by a relaunch would
  /// delete the model the user had just re-chosen (Codex PR-1 review r13). The
  /// in-memory flag and the durable intent must move together or they will disagree
  /// exactly when a crash makes it matter.
  public func markLegacyForReplacement(_ plan: RelocationPlan) {
    setIntent(.replace, plan: plan)
  }

  /// No-op when nothing is pending, when the token belongs to another revision, or
  /// when the intent already matches.
  private func setIntent(_ intent: LegacyIntent, plan: RelocationPlan) {
    guard var token = readToken(plan: plan),
      token.manifestDigest == plan.manifest.manifestDigest,
      token.intent != intent
    else { return }
    token.intent = intent
    writeToken(token, plan: plan)
  }

  // MARK: - Internals

  /// Delete a retired downloader's scratch files from an old location.
  ///
  /// The scratch we reclaim must belong to an artifact WE know: a sidecar is only
  /// a candidate when its name is `<known artifact><suffix>` — where the known
  /// artifacts are this manifest's own install names and the trusted legacy
  /// layouts we shipped. A bare suffix match would reach `custom-model.partial`,
  /// which belongs to someone else's model and is not ours to reclaim (Codex PR-1
  /// review r4).
  ///
  /// This is the one thing we delete from the old home without proving a digest,
  /// and that is defensible only because a `.partial` of a KNOWN artifact is by
  /// construction an incomplete file nothing can load — while leaving it costs the
  /// user gigabytes that no future code path will ever look for again.
  private func sweepStaleSidecars(in directory: URL, plan: RelocationPlan) {
    guard !plan.staleSidecarSuffixes.isEmpty else { return }
    let fm = FileManager.default
    let knownArtifacts =
      plan.manifest.files.map(\.resolvedInstallPath) + plan.trustedLegacyArtifacts.map(\.name)
    for artifact in knownArtifacts {
      for suffix in plan.staleSidecarSuffixes {
        let sidecar = directory.appendingPathComponent(artifact + suffix)
        guard fm.fileExists(atPath: sidecar.path) else { continue }
        try? fm.removeItem(at: sidecar)
      }
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
