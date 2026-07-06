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
