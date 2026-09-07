import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #2483. The promise a user feels: the model files another app put on their Mac
/// are still there afterwards, byte for byte, and they do not pay for a download
/// they have already done.
///
/// The donor directory here stands in for
/// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`,
/// which EnviousWispr shared with every other FluidAudio app until this change.
@Suite("Legacy donor import (#2483)", .tags(.productOutcome))
struct LegacyDonorImportTests {

  /// `root` doubles as the app-owned trusted root the import requires staging to
  /// resolve inside. In production that is the delivery metadata directory.
  private func makeDirs() throws -> (donor: URL, staging: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("donor-\(UUID().uuidString)", isDirectory: true)
    let donor = root.appendingPathComponent("donor", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    for dir in [donor, staging] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return (donor, staging, root)
  }

  private func write(_ content: Data, under root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url)
  }

  /// Path → (bytes, inode). Inode as well as bytes, because a move or a
  /// replace-with-identical-content would leave the bytes equal and is exactly
  /// the outcome this change exists to prevent.
  private func fingerprint(of root: URL) throws -> [String: (Data, UInt64)] {
    let fm = FileManager.default
    var result: [String: (Data, UInt64)] = [:]
    guard
      let walker = fm.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey],
        errorHandler: { _, _ in false })
    else { return result }
    for case let url as URL in walker {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
      else { continue }
      let attrs = try fm.attributesOfItem(atPath: url.path)
      let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      result[url.path] = (try Data(contentsOf: url), inode)
    }
    return result
  }

  @Test("the donor keeps every file, its bytes and its inode")
  func donorIsUntouched() throws {
    let (donor, staging, root) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: donor, path: f.path) }
    // A file no manifest of ours names. Under the pre-#2483 behaviour this is
    // precisely what promotion's orphan cleanup deleted, and what #2690's
    // reporter could not get past.
    try write(Data("another app put this here".utf8), under: donor, path: "CtcHead.mlmodelc/x.bin")
    let manifest = try ManifestFixture.manifest(files: files)
    let before = try fingerprint(of: donor)
    #expect(before.count == files.count + 1)

    let outcome = LegacyDonorImport.reproduce(
      manifest: manifest, components: Set(files.map(\.component)), donor: donor, staging: staging, trustedRoot: root)

    #expect(outcome.filesReproduced == files.count)
    let after = try fingerprint(of: donor)
    #expect(after.count == before.count)
    for (path, expected) in before {
      let actual = after[path]
      #expect(actual?.0 == expected.0, "donor bytes changed at \(path)")
      #expect(actual?.1 == expected.1, "donor inode changed at \(path)")
    }
  }

  @Test("every manifest file lands in staging with the donor's bytes")
  func filesReachStaging() throws {
    let (donor, staging, root) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)

    let outcome = LegacyDonorImport.reproduce(
      manifest: manifest, components: Set(files.map(\.component)), donor: donor, staging: staging, trustedRoot: root)

    #expect(outcome.filesReproduced == files.count)
    #expect(outcome.bytesReproduced == files.reduce(Int64(0)) { $0 + Int64($1.content.count) })
    for f in files {
      let staged = staging.appendingPathComponent(f.path)
      #expect(try Data(contentsOf: staged) == f.content, "staged bytes differ at \(f.path)")
    }
  }

  @Test("a donor file of the wrong size is left behind, not copied")
  func wrongSizeIsSkipped() throws {
    let (donor, staging, root) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: donor, path: f.path) }
    // A truncated or different-revision copy. It must not reach staging, where
    // a size match would let the fetch path skip it and then fail its hash —
    // a slower, more confusing route to the same download.
    try write(Data("{".utf8), under: donor, path: files[0].path)
    let manifest = try ManifestFixture.manifest(files: files)

    let outcome = LegacyDonorImport.reproduce(
      manifest: manifest, components: Set(files.map(\.component)), donor: donor, staging: staging, trustedRoot: root)

    #expect(outcome.filesReproduced == files.count - 1)
    #expect(
      !FileManager.default.fileExists(
        atPath: staging.appendingPathComponent(files[0].path).path))
  }

  @Test("a staging directory outside the trusted root is refused outright")
  func stagingMustResolveInsideTheTrustedRoot() throws {
    // Cloud round P2: proving the destination sits under `staging` says nothing
    // if `staging` itself resolves into the donor's tree. Here staging IS a
    // symlink into the donor, which is the shape that would have turned every
    // copy into a write inside the directory this type promises never to touch.
    let (donor, _, root) = try makeDirs()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)
    let aliased = root.appendingPathComponent("aliased-staging", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: aliased, withDestinationURL: donor)
    let before = try fingerprint(of: donor)

    let outcome = LegacyDonorImport.reproduce(
      manifest: manifest, components: Set(files.map(\.component)), donor: donor,
      staging: aliased, trustedRoot: donor)

    #expect(outcome == .none)
    let after = try fingerprint(of: donor)
    #expect(after.count == before.count)
    for (path, expected) in before {
      #expect(after[path]?.1 == expected.1, "donor inode changed at \(path)")
    }
  }

  @Test("a donor that is not there costs nothing and reports nothing")
  func absentDonorIsNotAFailure() throws {
    let (donor, staging, root) = try makeDirs()
    let files = ManifestFixture.smallFiles
    let manifest = try ManifestFixture.manifest(files: files)
    let missing = donor.appendingPathComponent("never-existed", isDirectory: true)

    let outcome = LegacyDonorImport.reproduce(
      manifest: manifest, components: Set(files.map(\.component)), donor: missing,
      staging: staging, trustedRoot: root)

    #expect(outcome == .none)
    #expect(try fingerprint(of: staging).isEmpty)
  }
}

/// The naming rule is load-bearing, not cosmetic, so it gets a test rather than
/// a comment: FluidAudio rebuilds a repo directory from whatever parent it is
/// handed, dropping the last component and re-appending its own folder name. A
/// directory named anything else would make our install location and the
/// runtime's lookup location disagree while each looked right on its own.
@Suite("Parakeet install location (#2483)", .tags(.driftGuard))
struct ParakeetInstallLocationTests {

  @Test("we install under our own directory, never under FluidAudio")
  func installDirectoryIsOurs() {
    let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
    let install = ParakeetInstallLocation.directory(appSupport: root)
    // Literal on purpose, not derived from `repoFolderName`: this pins the
    // SHAPE of the path independently, so a change to that constant has to be
    // deliberate here too. The constant's agreement with FluidAudio is the
    // separate test below.
    #expect(install.path == "/tmp/appsupport/EnviousWispr/Models/parakeet-tdt-0.6b-v3")
    #expect(!install.path.contains("FluidAudio"))
  }

  @Test("our folder name is the one FluidAudio itself reconstructs")
  func lastComponentSurvivesVendorReconstruction() {
    // Second-pass finding 10: the ORACLE is FluidAudio, not our own constant.
    // Reconstructing the expected value from `repoFolderName` compared that
    // constant with itself, so the one drift worth catching — the vendor
    // renaming its repo folder while our constant stands still — passed.
    // `ParakeetBackend.vendorSharedDirectory` is `AsrModels.defaultCacheDirectory`,
    // whose last component IS the vendor's own `repo.folderName`.
    let vendorFolderName = ParakeetBackend.vendorSharedDirectory.lastPathComponent
    // One literal, not a concatenation: `#expect`'s second argument is a
    // `Comment`, which a `+` expression cannot convert to.
    #expect(
      ParakeetInstallLocation.repoFolderName == vendorFolderName,
      "FluidAudio's repo folder is now \(vendorFolderName); our install directory is no longer the one its loader reconstructs")

    let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
    let install = ParakeetInstallLocation.directory(appSupport: root)
    // What AsrModels.repoPath(from:) does: drop the last component, re-append
    // the vendor's folder name. A location that does not survive that round
    // trip is one the runtime would look for somewhere else.
    let reconstructed = install.deletingLastPathComponent()
      .appendingPathComponent(vendorFolderName, isDirectory: true)
    #expect(reconstructed.standardizedFileURL == install.standardizedFileURL)
  }

  @Test("the donor points at the shared FluidAudio directory and is a different place")
  func donorIsTheOldSharedDirectory() {
    let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
    let donor = ParakeetInstallLocation.legacySharedDonor(appSupport: root)
    #expect(donor.path == "/tmp/appsupport/FluidAudio/Models/parakeet-tdt-0.6b-v3")
    #expect(donor != ParakeetInstallLocation.directory(appSupport: root))
  }
}
