import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// Admission-gate tests (contract invariants 1-4; D2 §§3-5): the marker is
/// the only door, presence is never truth, promotion is crash-ordered, and
/// the #1339 poison classes are caught at component grain.
@Suite struct CacheAdmissionTests {
  private func makeDirs() throws -> (install: URL, metadata: URL, staging: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("admission-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    for dir in [install, metadata, staging] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return (install, metadata, staging)
  }

  private func write(_ content: Data, under root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url)
  }

  private func admission(
    files: [(path: String, content: Data, component: String)], dirs: (URL, URL)
  ) throws -> CacheAdmission {
    CacheAdmission(
      manifest: try ManifestFixture.manifest(files: files),
      installDirectory: dirs.0, metadataDirectory: dirs.1)
  }

  // MARK: Legacy-cache validation (D2 §4)

  @Test func completeValidLegacyCachePassesValidation() async throws {
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents.isEmpty)
    #expect(result.verifiedComponents == ["Encoder.mlmodelc", "vocab.json"])
  }

  @Test func truncatedLooseVocabIsCaught() async throws {
    // The #1339 gap D1 documented: a truncated loose file FluidAudio's own
    // recovery never catches. Size fast-gate flags it at component grain.
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    try write(Data("{".utf8), under: install, path: "vocab.json")
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["vocab.json"])
    #expect(result.verifiedComponents == ["Encoder.mlmodelc"])
  }

  @Test func staleInnerFileForcesComponentToFail() async throws {
    // #1372: a manifest revision that removes or renames a file INSIDE an
    // existing component leaves the stale file on disk. Every MANIFEST-listed
    // file here still hashes correctly, but a file the manifest no longer
    // names survives beside them, inside Encoder.mlmodelc.
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    try write(
      Data("leftover-from-a-prior-revision".utf8), under: install,
      path: "Encoder.mlmodelc/stale_leftover.bin")
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["Encoder.mlmodelc"])
    #expect(result.verifiedComponents == ["vocab.json"])
  }

  @Test func symlinkedComponentRootForcesComponentToFail() async throws {
    // Cloud review P2: when the COMPONENT ROOT itself (Encoder.mlmodelc) is
    // a symlink to a directory holding all expected files plus stale ones,
    // `fileExists(atPath:isDirectory:)` follows it and the OLD code's
    // enumerator could return zero descendants for a symlink root, so the
    // stale contents were never examined and the component was admitted.
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    let realTarget = install.deletingLastPathComponent().appendingPathComponent(
      "real-encoder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: realTarget, withIntermediateDirectories: true)
    for f in files where f.component == "Encoder.mlmodelc" {
      let relative = String(f.path.dropFirst("Encoder.mlmodelc/".count))
      let dest = realTarget.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      try f.content.write(to: dest)
    }
    try Data("stale-outside-the-manifest".utf8).write(
      to: realTarget.appendingPathComponent("stale.bin"))
    try write(
      files.first { $0.component == "vocab.json" }!.content, under: install, path: "vocab.json")
    try FileManager.default.createSymbolicLink(
      atPath: install.appendingPathComponent("Encoder.mlmodelc").path,
      withDestinationPath: realTarget.path)

    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["Encoder.mlmodelc"])
  }

  @Test func unlistedSymlinkForcesComponentToFail() async throws {
    // Cloud review P2: a symlink is neither a regular file nor a directory,
    // so an `isRegularFile`-only check silently skipped an unlisted
    // dangling link left by manual cache manipulation, and the component
    // could be admitted despite containing it.
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    try FileManager.default.createSymbolicLink(
      atPath: install.appendingPathComponent("Encoder.mlmodelc/dangling.bin").path,
      withDestinationPath: "/nonexistent-target")
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["Encoder.mlmodelc"])
  }

  @Test func unreadableSubdirectoryFailsClosed() async throws {
    // Whole-diff review P2: `FileManager.enumerator` silently STOPS
    // traversal on an unreadable subdirectory rather than throwing, so a
    // stale file hidden behind that failure would never be seen. An
    // unverified traversal must never read as "nothing extra found."
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let lockedDir = install.appendingPathComponent("Encoder.mlmodelc/locked", isDirectory: true)
    try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
    }
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["Encoder.mlmodelc"])
  }

  @Test func exactComponentContentsStayVerified() async throws {
    // Two-way control for the test above: EXACTLY the manifest-listed files,
    // nothing extra — the new check must not false-positive on the common case.
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents.isEmpty)
    #expect(result.verifiedComponents.contains("Encoder.mlmodelc"))
  }

  @Test func looseComponentHasNoExtraFilesCheck() {
    // A loose (non-directory) component has nothing to recurse into.
    let (path:path, content:_, component:component) = ManifestFixture.smallFiles[2]
    let installDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("admission-loose-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: installDirectory, withIntermediateDirectories: true)
    try? Data("{}".utf8).write(to: installDirectory.appendingPathComponent(path))
    let manifest = try! ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    let expected = manifest.filesByComponent.first { $0.component == component }!.files
    #expect(
      !CacheAdmission.hasExtraFiles(
        component: component, expectedFiles: expected, installDirectory: installDirectory))
  }

  @Test func corruptComponentMemberWithCorrectSizeIsCaughtByHash() async throws {
    // Same-size, different-bytes corruption: only the hash gate sees it —
    // this is exactly what presence/size checks (the old world) admit.
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    try write(Data("weightX".utf8), under: install, path: "Encoder.mlmodelc/weights/weight.bin")
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["Encoder.mlmodelc"])
  }

  @Test func missingComponentFails() async throws {
    let (install, metadata, _) = try makeDirs()
    let files = ManifestFixture.smallFiles
    try write(files[2].content, under: install, path: files[2].path)  // vocab only
    let gate = try admission(files: files, dirs: (install, metadata))
    let result = await gate.validateExistingCache()
    #expect(result.failedComponents == ["Encoder.mlmodelc"])
    #expect(result.verifiedComponents == ["vocab.json"])
  }

  // MARK: Marker semantics (D2 §3)

  @Test func admissionRequiresMarkerNotPresence() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let gate = try admission(files: files, dirs: (install, metadata))
    // Files complete and valid — still NOT admitted without the marker.
    #expect(!gate.isAdmitted())
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging,
      untouchedComponents: ["Encoder.mlmodelc", "vocab.json"])
    #expect(gate.isAdmitted())
  }

  // MARK: Superseded-marker cleanup (#2096 §3.3)

  /// A manifest whose files live in this install dir gets its previous revision's FILES swept by
  /// orphan cleanup, but its previous revision's MARKER lives in the metadata directory, which
  /// every family shares. Nothing swept those until now, which is the half `evictPreviousRevisions`
  /// named and never delivered.
  private func manifest(
    files: [(path: String, content: Data, component: String)],
    revision: String,
    evictPreviousRevisions: Bool
  ) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(files: files) { object in
        var identity = object["identity"] as! [String: Any]
        identity["revision"] = revision
        object["identity"] = identity
        var admission = object["admission"] as! [String: Any]
        admission["evictPreviousRevisions"] = evictPreviousRevisions
        object["admission"] = admission
      })
  }

  private func stageForeignMarker(metadata: URL, cacheKey: String) throws -> URL {
    let url = metadata.appendingPathComponent("\(cacheKey).admission.json")
    try Data("{}".utf8).write(to: url)
    return url
  }

  @Test func supersededMarkersAreRemovedOnAdmission() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }

    // A marker left behind by the revision this app supersedes, and one belonging to an entirely
    // different model. Only the first may be swept.
    let priorRevision = try stageForeignMarker(
      metadata: metadata, cacheKey: "parakeet-fixture-model-rev0-int8")
    let otherFamily = try stageForeignMarker(
      metadata: metadata, cacheKey: "eg_one-eg-1-v3-eg2-q5km")

    let gate = CacheAdmission(
      manifest: try manifest(files: files, revision: "rev1", evictPreviousRevisions: true),
      installDirectory: install, metadataDirectory: metadata)
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])

    #expect(gate.isAdmitted(), "the current revision is admitted")
    #expect(
      !FileManager.default.fileExists(atPath: priorRevision.path),
      "the superseded revision's marker is swept")
    #expect(
      FileManager.default.fileExists(atPath: otherFamily.path),
      "a different model's marker in the shared metadata dir is untouched")
  }

  /// The control that ARMS the flag. `evictPreviousRevisions` shipped decoded and unread for
  /// months; without this case the cleanup could ignore it entirely and still pass the test above,
  /// and Parakeet and WhisperKit — which both set it `false` — would silently change behaviour.
  @Test func supersededCleanupRespectsTheManifestFlag() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }

    let priorRevision = try stageForeignMarker(
      metadata: metadata, cacheKey: "parakeet-fixture-model-rev0-int8")

    let gate = CacheAdmission(
      manifest: try manifest(files: files, revision: "rev1", evictPreviousRevisions: false),
      installDirectory: install, metadataDirectory: metadata)
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])

    #expect(gate.isAdmitted())
    #expect(
      FileManager.default.fileExists(atPath: priorRevision.path),
      "a family that did not opt in keeps its previous markers")
  }

  /// Cleanup must never take the marker it just wrote. The current revision's own marker matches
  /// the same family and name, and differs only by revision.
  @Test func supersededCleanupNeverRemovesTheCurrentMarker() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }

    let gate = CacheAdmission(
      manifest: try manifest(files: files, revision: "rev1", evictPreviousRevisions: true),
      installDirectory: install, metadataDirectory: metadata)
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])

    #expect(FileManager.default.fileExists(atPath: gate.markerURL.path))
    #expect(gate.isAdmitted())
  }

  @Test func markerFastPathRejectsSizeDrift() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let gate = try admission(files: files, dirs: (install, metadata))
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])
    #expect(gate.isAdmitted())
    // Damage a file AFTER admission: size/mtime stamp catches it without a
    // rehash (the "manually deleted/damaged" row of D2 §4).
    try write(Data("longer-than-before".utf8), under: install, path: "vocab.json")
    #expect(!gate.isAdmitted())
  }

  @Test func markerBoundToManifestDigest() async throws {
    // A revision bump = new digest = old marker invalid (the marker carries
    // the revision binding the shared FluidAudio path cannot).
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let gate = try admission(files: files, dirs: (install, metadata))
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])

    var newFiles = files
    newFiles[2].content = Data("{\"b\":2}".utf8)
    let bumped = CacheAdmission(
      manifest: try ManifestFixture.manifest(files: newFiles),
      installDirectory: install, metadataDirectory: metadata)
    #expect(!bumped.isAdmitted())
  }

  // MARK: Promotion (grounded r1 revision 4 — crash ordering + orphans)

  @Test func promoteMovesStagedComponentsAndWritesMarker() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    // vocab valid in place; encoder staged fresh.
    try write(files[2].content, under: install, path: files[2].path)
    try write(files[0].content, under: staging, path: files[0].path)
    try write(files[1].content, under: staging, path: files[1].path)
    let gate = try admission(files: files, dirs: (install, metadata))
    try gate.promoteAndAdmit(
      stagedComponents: ["Encoder.mlmodelc"], stagingDirectory: staging,
      untouchedComponents: ["vocab.json"])
    #expect(gate.isAdmitted())
    let moved = install.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
    #expect(FileManager.default.fileExists(atPath: moved.path))
  }

  @Test func promotionFailureLeavesUnadmittedNeverMixedBlessed() async throws {
    // Crash-point table: marker dies FIRST; a failure mid-promote (staged
    // component missing) leaves NO marker → unadmitted → next launch
    // revalidates. Old marker can never bless the mixed state.
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    let gate = try admission(files: files, dirs: (install, metadata))
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])
    #expect(gate.isAdmitted())

    // Now a repair promote whose staged dir is MISSING throws mid-sequence.
    #expect(throws: (any Error).self) {
      try gate.promoteAndAdmit(
        stagedComponents: ["Encoder.mlmodelc"], stagingDirectory: staging,
        untouchedComponents: ["vocab.json"])
    }
    #expect(!gate.isAdmitted(), "a failed promote must leave the cache unadmitted")
  }

  @Test func orphanCleanupPrunesUnlistedSparesListed() async throws {
    let (install, metadata, staging) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: install, path: f.path) }
    // A stale revision's leftover + foreign debris.
    try write(Data("old".utf8), under: install, path: "ObsoleteDecoder.mlmodelc/coremldata.bin")
    try write(Data("junk".utf8), under: install, path: "stray.tmp")
    let gate = try admission(files: files, dirs: (install, metadata))
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [])
    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: install.appendingPathComponent("ObsoleteDecoder.mlmodelc").path))
    #expect(!fm.fileExists(atPath: install.appendingPathComponent("stray.tmp").path))
    #expect(fm.fileExists(atPath: install.appendingPathComponent("vocab.json").path))
    #expect(gate.isAdmitted())
  }

  @Test func componentRootsCoverDirsAndLooseFiles() throws {
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    #expect(CacheAdmission.componentRoots(of: manifest) == ["Encoder.mlmodelc", "vocab.json"])
  }
}
