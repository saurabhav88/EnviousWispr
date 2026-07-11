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

  private func plan(
    files: [(path: String, content: Data, component: String)],
    dirs: (old: URL, new: URL, metadata: URL),
    legacy: [String] = ["eg-1-v1.gguf"]
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
    try write(Data("shipped-model-bytes".utf8), under: dirs.old, path: "eg-1-v1.gguf")
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
    try write(Data("shipped-model-bytes".utf8), under: dirs.old, path: "eg-1-v1.gguf")
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
    try write(Data("shipped-model-bytes".utf8), under: dirs.old, path: "eg-1-v1.gguf")
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
    try write(Data("shipped-model-bytes".utf8), under: dirs.old, path: "eg-1-v1.gguf")
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

  // MARK: - Relocatable (a dev machine whose shards already sit in the old home)

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
