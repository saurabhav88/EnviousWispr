import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// Relocation tests (#1386 PR-1). The migrator's whole contract is about what
/// SURVIVES a failure, so that is what these assert: old bytes are never
/// deleted before a verified replacement is admitted, and bytes we cannot
/// identify are never touched at all.
@Suite struct ModelRelocationMigratorTests {

  private func makeDirs() throws -> (old: URL, new: URL, metadata: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("reloc-\(UUID().uuidString)", isDirectory: true)
    let old = root.appendingPathComponent("PolishModels", isDirectory: true)
    let new = root.appendingPathComponent("Models/eg-1", isDirectory: true)
    let metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
    for dir in [old, new, metadata] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return (old, new, metadata)
  }

  private func write(_ content: Data, under root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url)
  }

  /// The bytes of the previously-shipped layout, and the descriptor that proves
  /// they are ours. Identity is the DIGEST — the filename is only a lookup key.
  private static let legacyBytes = Data("the-model-we-actually-shipped".utf8)

  private static var legacyArtifact: ModelRelocationMigrator.TrustedLegacyArtifact {
    .init(
      name: "eg-1-v1.gguf",
      sizeBytes: Int64(legacyBytes.count),
      sha256: SHA256.hash(data: legacyBytes).map { String(format: "%02x", $0) }.joined())
  }

  private func plan(
    files: [(path: String, content: Data, component: String)],
    dirs: (old: URL, new: URL, metadata: URL),
    legacy: [ModelRelocationMigrator.TrustedLegacyArtifact] = [legacyArtifact]
  ) throws -> ModelRelocationMigrator.RelocationPlan {
    ModelRelocationMigrator.RelocationPlan(
      manifest: try ManifestFixture.manifest(files: files),
      oldLocations: [dirs.old],
      destination: dirs.new,
      metadataDirectory: dirs.metadata,
      trustedLegacyArtifacts: legacy)
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  // MARK: - Trusted legacy (every shipped EG-1 user: a monolith, not the shards)

  /// The founder-critical case. A previously-shipped monolith is OURS, but this
  /// build cannot load it. It must be left exactly where it is — not moved, not
  /// deleted — and a durable token must record that a replacement is owed.
  @Test func trustedLegacyMonolithIsRecordedAndLeftUntouched() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()

    let outcome = await migrator.migrate(p)

    #expect(outcome == .trustedLegacyPending(monolith))
    #expect(exists(monolith), "the legacy model must survive classification")
    #expect(migrator.pendingLegacyArtifact(p) == monolith)
    // Nothing was fetched or admitted, so nothing may have been promoted.
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    #expect(gate.isAdmitted() == false)
  }

  /// Verify-before-delete, stated as a test: cleanup must be a no-op until the
  /// replacement is actually admitted... and the caller is what enforces that.
  /// Here we prove the token SURVIVES a migrate that admitted nothing, so the
  /// next launch can retry rather than losing the only copy.
  @Test func pendingTokenSurvivesRelaunchWhenReplacementNeverArrives() async throws {
    let dirs = try makeDirs()
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)

    _ = await ModelRelocationMigrator().migrate(p)
    // A fresh migrator == a fresh process. The token is durable, not in-memory.
    let afterRelaunch = ModelRelocationMigrator()
    #expect(afterRelaunch.pendingLegacyArtifact(p) != nil)
    #expect(exists(dirs.old.appendingPathComponent("eg-1-v1.gguf")))
  }

  /// Cleanup deletes the legacy bytes and clears the token. Idempotent: running
  /// it again (a crash between delete and token-clear) must not throw.
  @Test func cleanUpLegacyDeletesTheArtifactAndIsIdempotent() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)

    try migrator.cleanUpLegacy(p)
    #expect(!exists(monolith))
    #expect(migrator.pendingLegacyArtifact(p) == nil)

    // Second run: already-absent artifact, already-cleared token. No throw.
    try migrator.cleanUpLegacy(p)
    #expect(migrator.pendingLegacyArtifact(p) == nil)
  }

  /// A token minted against a DIFFERENT revision must never authorize a delete
  /// under the current one — otherwise an EG-2 build could drop EG-1's bytes.
  @Test func tokenFromAnotherRevisionNeverAuthorizesADelete() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)

    // Same cache key, different manifest digest (one file's bytes differ).
    let otherRevision = try plan(
      files: [(path: "vocab.json", content: Data("different".utf8), component: "vocab.json")],
      dirs: dirs)
    try migrator.cleanUpLegacy(otherRevision)

    #expect(exists(monolith), "a foreign-revision token must not delete our bytes")
  }

  /// The filename is NOT identity. A file sitting at the legacy path with the
  /// legacy NAME but bytes we never shipped — corrupt, truncated, hand-swapped,
  /// or someone else's — must fail the digest and be treated as a stranger:
  /// never tokenized, never deleted. (Codex PR-1 review P2.)
  @Test func sameNamedFileWeDidNotShipIsNeverTrustedAndNeverDeleted() async throws {
    let dirs = try makeDirs()
    let impostor = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Data("NOT the bytes we shipped".utf8), under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()

    let outcome = await migrator.migrate(p)

    #expect(outcome == .unrecognized, "a same-named file we did not ship is not ours")
    #expect(migrator.pendingLegacyArtifact(p) == nil, "and must never be marked for deletion")
    // Even if a caller ignored the outcome and ran cleanup anyway, the absent
    // token means nothing is deleted.
    try migrator.cleanUpLegacy(p)
    #expect(exists(impostor), "bytes we cannot prove are ours are never deleted")
  }

  /// If the legacy file CHANGES between classification and cleanup, it is no
  /// longer the artifact we proved was ours — so we leave it alone rather than
  /// delete something we can no longer identify.
  @Test func legacyArtifactMutatedAfterClassificationIsNotDeleted() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)
    #expect(migrator.pendingLegacyArtifact(p) != nil)

    // Something replaced the file after we classified it.
    try write(Data("swapped out from under us".utf8), under: dirs.old, path: "eg-1-v1.gguf")
    try migrator.cleanUpLegacy(p)

    #expect(exists(monolith), "a changed artifact is no longer identifiable as ours")
    #expect(migrator.pendingLegacyArtifact(p) == nil, "and the stale token is dropped")
  }

  // MARK: - Relocatable (a dev machine whose shards already sit in the old home)

  /// The source must remain a COMPLETE, valid fallback until the destination is
  /// admitted. A relocation that removed components from the source as it went
  /// would leave both sides partial on a crash, turning a good model into an
  /// `unrecognized` one and forcing a re-download. (Codex PR-1 review P2.)
  ///
  /// Proven by interrupting: pre-create a DIRECTORY at one component's
  /// destination path so its copy fails, then assert the source is still whole.
  @Test func interruptedRelocationLeavesTheSourceComplete() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    let p = try plan(files: files, dirs: dirs)

    // Block the LAST component in the (deterministic, sorted) relocation order,
    // so at least one component has already been reproduced at the destination
    // when the failure hits. Blocking the FIRST would prove nothing: a
    // move-based relocation that fails immediately never touches the source, so
    // the test would pass against the very bug it exists to catch.
    let victimRoot = CacheAdmission.componentRoots(of: p.manifest).sorted().last!
    let blocker = dirs.new.appendingPathComponent(victimRoot, isDirectory: true)
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
    try write(Data("blocker".utf8), under: blocker, path: "occupied/blocker.bin")
    // Deny writes so removeItem/copy into it fails.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: blocker.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: blocker.path)
    }

    let outcome = await ModelRelocationMigrator().migrate(p)

    // Whatever the outcome, the invariant is absolute: the source still holds a
    // complete, valid copy, so the next launch can retry from it.
    #expect(outcome != .relocated)
    for f in files {
      #expect(
        exists(dirs.old.appendingPathComponent(f.path)),
        "source must stay complete when relocation cannot finish")
    }
    let sourceGate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.old, metadataDirectory: dirs.metadata)
    let validation = await sourceGate.validateExistingCache()
    #expect(
      validation.failedComponents.isEmpty,
      "the source must still validate against the manifest — it is the fallback")
  }

  /// Bytes that satisfy the CURRENT manifest are moved, re-admitted at the new
  /// home, and the old home is dropped — with zero fetch.
  @Test func currentManifestBytesAreRelocatedAndReadmitted() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    let p = try plan(files: files, dirs: dirs)

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .relocated)
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    #expect(gate.isAdmitted(), "relocated bytes must be admitted at the new home")
    for f in files { #expect(exists(dirs.new.appendingPathComponent(f.path))) }
    #expect(!exists(dirs.old), "the old home is redundant once the new one is admitted")
  }

  /// An already-admitted destination is the common case on every launch after
  /// the first: cheap no-op, no rehash, nothing touched.
  @Test func admittedDestinationIsANoop() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: dirs.new, path: f.path) }
    let p = try plan(files: files, dirs: dirs)
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    let validation = await gate.validateExistingCache()
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: dirs.new,
      untouchedComponents: validation.verifiedComponents)

    let outcome = await ModelRelocationMigrator().migrate(p)
    #expect(outcome == .noop)
    #expect(gate.isAdmitted())
  }

  // MARK: - Unrecognized (never ours, never touched)

  /// Bytes that match neither the current manifest nor a layout we shipped are
  /// foreign. We cannot prove what they are, so we never move, load, or delete
  /// them — the provenance rule, in one test.
  @Test func unrecognizedBytesAreLeftStrictlyAlone() async throws {
    let dirs = try makeDirs()
    let stranger = dirs.old.appendingPathComponent("somebody-elses-model.gguf")
    try write(Data("not ours".utf8), under: dirs.old, path: "somebody-elses-model.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()

    let outcome = await migrator.migrate(p)

    #expect(outcome == .unrecognized)
    #expect(exists(stranger), "foreign bytes must never be deleted")
    #expect(migrator.pendingLegacyArtifact(p) == nil, "and never marked for cleanup")
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    #expect(gate.isAdmitted() == false)
  }

  /// A corrupt/partial copy of the current manifest is not relocatable and is
  /// not a trusted legacy layout: treated as absent, left in place, never
  /// admitted (the #1339 poison class).
  @Test func corruptCurrentManifestCopyIsNotRelocated() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    // Corrupt one file's bytes: size may match, hash will not.
    let victim = files[0]
    try write(
      Data(repeating: 0xFF, count: victim.content.count), under: dirs.old, path: victim.path)
    let p = try plan(files: files, dirs: dirs)

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .unrecognized)
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    #expect(gate.isAdmitted() == false, "corrupt bytes must never be admitted")
  }
}
