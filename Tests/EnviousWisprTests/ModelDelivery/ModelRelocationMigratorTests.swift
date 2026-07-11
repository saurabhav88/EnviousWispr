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

    try await migrator.cleanUpLegacy(p)
    #expect(!exists(monolith))
    #expect(migrator.pendingLegacyArtifact(p) == nil)

    // Second run: already-absent artifact, already-cleared token. No throw.
    try await migrator.cleanUpLegacy(p)
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
    try await migrator.cleanUpLegacy(otherRevision)

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
    try await migrator.cleanUpLegacy(p)
    #expect(exists(impostor), "bytes we cannot prove are ours are never deleted")
  }

  /// If the legacy file CHANGES between classification and cleanup, it is no
  /// longer the artifact we proved was ours — so we leave it alone rather than
  /// delete something we can no longer identify.
  ///
  /// The replacement is deliberately the SAME BYTE COUNT as the original. A
  /// size-only guard passes here and deletes the file; only re-hashing catches
  /// it. That is the whole finding (Codex PR-1 review r2), and classification
  /// happens a whole model-download before the delete, so the window is real.
  @Test func sameSizeMutationBetweenClassificationAndCleanupIsNotDeleted() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)
    #expect(migrator.pendingLegacyArtifact(p) != nil)

    // Same length, different bytes — invisible to a byte-count check.
    let impostor = Data(repeating: 0x41, count: Self.legacyBytes.count)
    #expect(impostor.count == Self.legacyBytes.count)
    try write(impostor, under: dirs.old, path: "eg-1-v1.gguf")

    try await migrator.cleanUpLegacy(p)

    #expect(exists(monolith), "a same-size swap is still not the artifact we proved was ours")
    #expect(try Data(contentsOf: monolith) == impostor, "and its bytes are untouched")
    #expect(migrator.pendingLegacyArtifact(p) == nil, "the stale token is dropped")
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

  /// The crash window that would cost a user gigabytes forever: the process dies
  /// AFTER the destination is admitted but BEFORE the old copy is cleaned up. The
  /// next launch sees an admitted destination — and must still finish the cleanup
  /// rather than early-returning and leaving a duplicate multi-GB model on disk
  /// that nothing will ever look at again. (Codex PR-1 review r7.)
  @Test func admittedDestinationStillReconcilesALeftoverOldCopy() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    // Simulate the interrupted state directly: destination admitted, source still
    // fully populated — exactly what a crash between the two steps leaves behind.
    for f in files {
      try write(f.content, under: dirs.new, path: f.path)
      try write(f.content, under: dirs.old, path: f.path)
    }
    let p = try plan(files: files, dirs: dirs)
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    let validation = await gate.validateExistingCache()
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: dirs.new,
      untouchedComponents: validation.verifiedComponents)
    #expect(gate.isAdmitted())

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .noop)
    #expect(gate.isAdmitted(), "the admitted destination is untouched")
    for f in files {
      #expect(
        !exists(dirs.old.appendingPathComponent(f.path)),
        "the duplicate left by the crash must be reclaimed, not stranded forever")
    }
  }

  /// Crash-recovery cleanup must still EARN its deletions. If the old directory
  /// holds corrupt or hand-replaced bytes under a name the manifest happens to use,
  /// deleting them because the name lines up is the provenance rule broken by the
  /// very code that enforces it. (Codex PR-1 review r11.)
  @Test func recoveryCleanupNeverDeletesUnverifiedBytesUnderAMatchingName() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    // Destination: the real, admitted model.
    for f in files { try write(f.content, under: dirs.new, path: f.path) }
    let p = try plan(files: files, dirs: dirs)
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    let validation = await gate.validateExistingCache()
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: dirs.new,
      untouchedComponents: validation.verifiedComponents)
    #expect(gate.isAdmitted())

    // Old home: bytes that are NOT ours, wearing a manifest filename.
    let victim = files[0]
    try write(Data("not the bytes we shipped".utf8), under: dirs.old, path: victim.path)
    let impostor = dirs.old.appendingPathComponent(victim.path)

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .noop)
    #expect(
      exists(impostor),
      "unverified bytes must survive cleanup even when their filename matches ours")
  }

  /// A proof about ONE directory says nothing about the bytes in another. When a
  /// plan lists several old locations, the relocation source's validation must not
  /// authorize deletions in the others — those earn their own. EG-1 ships one old
  /// location today, so this is the API being made safe BEFORE the remaining engines
  /// add a second. (Codex PR-1 review r12.)
  @Test func proofForOneOldLocationNeverAuthorizesDeletionInAnother() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    // Old location A: the genuine copy (this becomes the relocation source).
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    // Old location B: same filenames, bytes we never shipped.
    let otherOld = dirs.old.deletingLastPathComponent()
      .appendingPathComponent("PolishModels-2", isDirectory: true)
    try FileManager.default.createDirectory(at: otherOld, withIntermediateDirectories: true)
    for f in files {
      try write(Data("not the bytes we shipped".utf8), under: otherOld, path: f.path)
    }

    let p = ModelRelocationMigrator.RelocationPlan(
      manifest: try ManifestFixture.manifest(files: files),
      oldLocations: [dirs.old, otherOld],
      destination: dirs.new,
      metadataDirectory: dirs.metadata,
      trustedLegacyArtifacts: [Self.legacyArtifact])

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .relocated)
    // The proven source is cleaned up...
    for f in files { #expect(!exists(dirs.old.appendingPathComponent(f.path))) }
    // ...while the OTHER location's unverified bytes survive untouched.
    for f in files {
      #expect(
        exists(otherOld.appendingPathComponent(f.path)),
        "a proof about one directory must never authorize deleting another's bytes")
    }
  }

  /// A failed promotion must not silently un-admit an intact source.
  ///
  /// There is one admission marker per model, and promotion deletes it before doing
  /// work that can throw. If that work fails, the source's bytes are still perfect —
  /// but nothing that picks by ADMISSION (including the kill-switch fallback) can
  /// find them any more, so EG-1 would report unavailable with a flawless copy
  /// sitting right there. (Codex PR-1 review r17.)
  @Test func failedPromotionRestoresTheSourceAdmission() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    let p = try plan(files: files, dirs: dirs)

    // The source starts out admitted (a machine that downloaded before this change).
    let sourceGate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.old, metadataDirectory: dirs.metadata)
    let validation = await sourceGate.validateExistingCache()
    try sourceGate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: dirs.old,
      untouchedComponents: validation.verifiedComponents)
    #expect(sourceGate.isAdmitted())

    // Make PROMOTION fail — not the copy. Promotion prunes orphans (anything in the
    // destination the manifest does not name), so an orphan directory we cannot
    // delete throws from inside promoteAndAdmit, AFTER it has already dropped the
    // shared admission marker. That is precisely the window this test exists for.
    try FileManager.default.createDirectory(at: dirs.new, withIntermediateDirectories: true)
    let orphan = dirs.new.appendingPathComponent("not-in-the-manifest", isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try write(Data("x".utf8), under: orphan, path: "stuck.bin")
    // No write permission on the orphan dir: its contents cannot be removed.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: orphan.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: orphan.path)
    }

    // Something of the user's, in the legacy directory. The RECOVERY path must not
    // touch it: re-admitting the source by running a full promotion would prune every
    // unlisted entry and delete this (Codex PR-1 review r18) — the recovery breaking
    // the preservation guarantee the rest of the migrator enforces.
    let bystander = dirs.old.appendingPathComponent("users-own-file.bin")
    try write(Data("mine".utf8), under: dirs.old, path: "users-own-file.bin")

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome != .relocated)
    #expect(
      sourceGate.isAdmitted(),
      "an intact source must remain ADMITTED when promotion fails, or the fallback cannot find it")
    #expect(
      exists(bystander),
      "restoring admission must not delete unrelated files from the legacy directory")
    // The invariant that actually matters: SOME usable copy is still findable by
    // admission. (The destination may also validate here — the clone succeeded and
    // only the orphan prune failed — and loading from it is perfectly fine. What must
    // never happen is BOTH going un-admitted, which is what leaves EG-1 unavailable
    // with a flawless model on disk.)
    #expect(
      ModelRelocationMigrator.admittedLocation(
        manifest: p.manifest, candidates: [dirs.new, dirs.old],
        metadataDirectory: dirs.metadata) != nil,
      "the fallback must still find a usable copy after a failed promotion")
  }

  /// The replacement can complete without a note ever being written (journalling is
  /// allowed to fail — r17). If the admitted fast path then just returned, every later
  /// launch would take it, and the 2.9 GB legacy model would sit on the user's disk
  /// forever with nothing left that would ever look for it. The fast path must
  /// re-journal a stranded artifact. (Codex PR-1 review r19.)
  @Test func admittedDestinationStillJournalsAStrandedLegacyArtifact() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    // The replacement landed and is admitted...
    for f in files { try write(f.content, under: dirs.new, path: f.path) }
    let p = try plan(files: files, dirs: dirs)
    let gate = CacheAdmission(
      manifest: p.manifest, installDirectory: dirs.new, metadataDirectory: dirs.metadata)
    let validation = await gate.validateExistingCache()
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: dirs.new,
      untouchedComponents: validation.verifiedComponents)
    #expect(gate.isAdmitted())

    // ...but the legacy model is still there and NO token was ever written.
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let migrator = ModelRelocationMigrator()
    #expect(migrator.pendingLegacyArtifact(p) == nil, "precondition: nothing journaled")

    let outcome = await migrator.migrate(p)

    #expect(outcome == .trustedLegacyPending(monolith))
    #expect(
      migrator.pendingLegacyArtifact(p) == monolith,
      "a stranded artifact must be re-journaled, or it is stranded forever")
    #expect(exists(monolith), "and it is still not deleted before its cleanup runs")
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

  /// Relocation must remove only what it actually reproduced. The old directory
  /// can hold things that are not ours — a foreign model, a user's own file —
  /// and deleting the whole directory would take them with it. (Codex PR-1
  /// review r3 P1.)
  @Test func relocationNeverDeletesUnrelatedFilesInTheOldDirectory() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    // Something of the user's, sitting in the same folder. Not ours, never
    // validated, never copied.
    let bystander = dirs.old.appendingPathComponent("someone-elses-model.gguf")
    try write(Data("not ours".utf8), under: dirs.old, path: "someone-elses-model.gguf")
    let p = try plan(files: files, dirs: dirs)

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .relocated)
    #expect(exists(bystander), "a file we never validated must survive relocation")
    // What we DID reproduce is gone from the old home.
    for f in files {
      #expect(!exists(dirs.old.appendingPathComponent(f.path)))
    }
    // The directory itself survives precisely because the bystander is still in it.
    #expect(exists(dirs.old))
  }

  /// A retired downloader's scratch files are stranded the moment the install
  /// directory moves — nothing will ever look in the old home again. They must be
  /// swept, including on the trusted-legacy path, which is exactly the case where
  /// an interrupted multi-GB `.partial` exists. (Codex PR-1 review r3 P2 / #1363.)
  @Test func staleDownloadSidecarsAreSweptFromTheOldHome() async throws {
    let dirs = try makeDirs()
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    // An interrupted download from the retired store, plus its resume file.
    try write(Data(repeating: 0x7, count: 4096), under: dirs.old, path: "eg-1-v1.gguf.partial")
    try write(Data("{}".utf8), under: dirs.old, path: "eg-1-v1.gguf.resume.json")
    let p = ModelRelocationMigrator.RelocationPlan(
      manifest: try ManifestFixture.manifest(files: ManifestFixture.smallFiles),
      oldLocations: [dirs.old],
      destination: dirs.new,
      metadataDirectory: dirs.metadata,
      trustedLegacyArtifacts: [Self.legacyArtifact],
      staleSidecarSuffixes: [".partial", ".resume.json"])

    let outcome = await ModelRelocationMigrator().migrate(p)

    #expect(outcome == .trustedLegacyPending(dirs.old.appendingPathComponent("eg-1-v1.gguf")))
    #expect(!exists(dirs.old.appendingPathComponent("eg-1-v1.gguf.partial")), "partial reclaimed")
    #expect(
      !exists(dirs.old.appendingPathComponent("eg-1-v1.gguf.resume.json")), "resume reclaimed")
    // The MODEL is not scratch: it survives, awaiting its verified replacement.
    #expect(exists(dirs.old.appendingPathComponent("eg-1-v1.gguf")))
  }

  /// The sweep may only reclaim scratch belonging to an artifact WE know. Someone
  /// else's interrupted download happens to end in `.partial` too — it is not ours
  /// to delete, and a bare suffix match would have taken it. (Codex PR-1 review r4.)
  @Test func sidecarSweepNeverReclaimsAnotherModelsScratch() async throws {
    let dirs = try makeDirs()
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    try write(Data(repeating: 0x7, count: 64), under: dirs.old, path: "eg-1-v1.gguf.partial")
    // Not ours: a different model's interrupted download, same suffix.
    let stranger = dirs.old.appendingPathComponent("custom-model.gguf.partial")
    try write(Data(repeating: 0x9, count: 64), under: dirs.old, path: "custom-model.gguf.partial")
    let p = ModelRelocationMigrator.RelocationPlan(
      manifest: try ManifestFixture.manifest(files: ManifestFixture.smallFiles),
      oldLocations: [dirs.old],
      destination: dirs.new,
      metadataDirectory: dirs.metadata,
      trustedLegacyArtifacts: [Self.legacyArtifact],
      staleSidecarSuffixes: [".partial", ".resume.json"])

    _ = await ModelRelocationMigrator().migrate(p)

    #expect(!exists(dirs.old.appendingPathComponent("eg-1-v1.gguf.partial")), "ours is reclaimed")
    #expect(exists(stranger), "another model's scratch is not ours to delete")
  }

  /// A Remove during the transition retires the pending REPLACEMENT. If the legacy
  /// delete then fails, the next launch must finish the DELETE and fetch nothing —
  /// otherwise we would see the stranded file, conclude a replacement was owed, and
  /// silently re-download gigabytes of a model the user explicitly threw away.
  /// (Found while fixing Codex PR-1 review r6.)
  @Test func removeRetiresThePendingReplacementSoNothingIsResurrected() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)
    #expect(migrator.pendingLegacyIntent(p) == .replace)

    // The user hits Remove.
    migrator.markLegacyForRemoval(p)

    #expect(
      migrator.pendingLegacyIntent(p) == .remove,
      "a Remove must retire the replacement, not merely defer it")
    // The next launch honors the delete...
    try await migrator.cleanUpLegacy(p)
    #expect(!exists(monolith))
    #expect(migrator.pendingLegacyIntent(p) == nil, "and nothing remains pending to re-fetch")
  }

  /// The user removes the model, then takes it back by re-selecting it. The durable
  /// intent must follow: leaving it at `.remove` would delete the model on the next
  /// launch after they had explicitly re-chosen it. (Codex PR-1 review r13.)
  @Test func takingTheRemovalBackRestoresTheReplacementIntent() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)

    migrator.markLegacyForRemoval(p)
    #expect(migrator.pendingLegacyIntent(p) == .remove)

    // They re-select EG-1: the removal is taken back.
    migrator.markLegacyForReplacement(p)

    #expect(
      migrator.pendingLegacyIntent(p) == .replace,
      "a cancelled removal must not survive as a durable delete")
    #expect(exists(monolith), "and the model they re-chose is still there to replace")
  }

  /// A Remove that could not finish must SURVIVE re-classification. The next launch
  /// re-runs migrate() before anything reads the token; if classification rewrote the
  /// token from scratch it would reset the intent to `.replace` and re-download the
  /// model the user deleted — the resurrection bug climbing back in through the
  /// classifier. (Codex PR-1 review r16.)
  @Test func reclassificationPreservesAnUnfinishedRemoval() async throws {
    let dirs = try makeDirs()
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)
    migrator.markLegacyForRemoval(p)
    #expect(migrator.pendingLegacyIntent(p) == .remove)

    // The delete failed; the artifact is still here. Next launch re-classifies it.
    let nextLaunch = ModelRelocationMigrator()
    _ = await nextLaunch.migrate(p)

    #expect(
      nextLaunch.pendingLegacyIntent(p) == .remove,
      "re-classification must not resurrect a model the user removed")
  }

  /// The delete itself can FAIL — a read-only parent directory, a permissions problem.
  /// When it does, the token MUST survive: it is the only record that a cleanup is
  /// still owed, and without it the legacy model is stranded forever. The next launch
  /// retries from it.
  ///
  /// This is the migrator half of the runtime's cleanup-failure branch (which is not
  /// unit-testable — see the PR's named gap).
  @Test func aFailedDeleteRetainsTheTokenForRetry() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()
    _ = await migrator.migrate(p)
    #expect(migrator.pendingLegacyArtifact(p) == monolith)

    // Unlinking a file needs write permission on its PARENT — deny it.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dirs.old.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dirs.old.path)
    }

    await #expect(throws: (any Error).self) {
      try await migrator.cleanUpLegacy(p)
    }

    #expect(exists(monolith), "the artifact survives a failed delete")
    #expect(
      migrator.pendingLegacyArtifact(p) == monolith,
      "and the token MUST survive it too, or the model is stranded forever")

    // Permissions restored: the retry succeeds and clears the token.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirs.old.path)
    try await migrator.cleanUpLegacy(p)
    #expect(!exists(monolith))
    #expect(migrator.pendingLegacyArtifact(p) == nil)
  }

  /// If the token cannot be PERSISTED, the classification must start nothing.
  ///
  /// An unjournaled replacement could never be admitted anyway — the token and the
  /// admission marker share one metadata directory — and if it somehow did land, a later
  /// Remove would have no token to flip, so the next launch would reclassify the monolith
  /// as `.replace` and re-download a model the user deleted. Treated as absent: nothing
  /// moved, nothing deleted, retry next launch. (GitHub cloud review, PR #1497.)
  @Test func aClassificationThatCannotBeJournaledStartsNothing() async throws {
    let dirs = try makeDirs()
    let monolith = dirs.old.appendingPathComponent("eg-1-v1.gguf")
    try write(Self.legacyBytes, under: dirs.old, path: "eg-1-v1.gguf")
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)

    // The metadata directory refuses writes — the token cannot be persisted.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: dirs.metadata.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dirs.metadata.path)
    }

    let migrator = ModelRelocationMigrator()
    let outcome = await migrator.migrate(p)

    #expect(
      outcome == .unrecognized,
      "an unjournaled classification must not drive a replacement")
    #expect(migrator.pendingLegacyArtifact(p) == nil, "and nothing is pending")
    #expect(exists(monolith), "the model is untouched — nothing moved, nothing deleted")
  }

  /// Marking a removal when nothing is pending is a plain no-op — an ordinary
  /// Remove on a machine with no legacy artifact must not invent one.
  @Test func markingRemovalWithNoPendingArtifactIsANoop() async throws {
    let dirs = try makeDirs()
    let p = try plan(files: ManifestFixture.smallFiles, dirs: dirs)
    let migrator = ModelRelocationMigrator()

    migrator.markLegacyForRemoval(p)

    #expect(migrator.pendingLegacyIntent(p) == nil)
    #expect(migrator.pendingLegacyArtifact(p) == nil)
  }

  /// Existence is not validity. A relocation that failed partway leaves a
  /// half-populated destination beside an intact source; a disabled (kill-switched)
  /// build must read from the ADMITTED one, not from whichever directory happens to
  /// exist — otherwise the rollback breaks EG-1 in exactly the scenario it exists to
  /// rescue. (Codex PR-1 review r10.)
  @Test func admittedLocationIgnoresAHalfPopulatedDirectory() async throws {
    let dirs = try makeDirs()
    let files = ManifestFixture.smallFiles
    // Intact, admitted copy in the OLD home.
    for f in files { try write(f.content, under: dirs.old, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)
    let oldGate = CacheAdmission(
      manifest: manifest, installDirectory: dirs.old, metadataDirectory: dirs.metadata)
    let validation = await oldGate.validateExistingCache()
    try oldGate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: dirs.old,
      untouchedComponents: validation.verifiedComponents)
    #expect(oldGate.isAdmitted())

    // The new home EXISTS but holds only part of the model — what a relocation that
    // died halfway leaves behind.
    try write(files[0].content, under: dirs.new, path: files[0].path)
    #expect(exists(dirs.new))

    let chosen = ModelRelocationMigrator.admittedLocation(
      manifest: manifest,
      candidates: [dirs.new, dirs.old],
      metadataDirectory: dirs.metadata)

    #expect(
      chosen == dirs.old,
      "must choose the admitted copy, not the directory that merely exists")
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
