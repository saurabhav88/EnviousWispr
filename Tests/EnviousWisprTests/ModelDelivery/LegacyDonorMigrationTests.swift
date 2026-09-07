import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #2697. The promise a user feels: the model files another app put on their Mac
/// are still there afterwards, byte for byte; they do not pay for a download they
/// have already done; and a model they deleted stays deleted.
///
/// The donor directory stands in for
/// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`, which
/// EnviousWispr shared with every other FluidAudio app until #2483.
@Suite("Legacy donor migration (#2697)", .tags(.productOutcome))
struct LegacyDonorMigrationTests {

  private struct World {
    let donor: URL
    let install: URL
    let metadata: URL
    let root: URL
  }

  /// Creates the DONOR only. Nothing else is pre-created, deliberately: two
  /// first-install regressions during #2483 were both hidden by a fixture that
  /// made every directory in advance, so the code could require one to pre-exist
  /// and the suite could not tell.
  private func makeWorld(withDonor: Bool = true) throws -> World {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mig-\(UUID().uuidString)", isDirectory: true)
    let world = World(
      donor: root.appendingPathComponent("FluidAudio/Models/model", isDirectory: true),
      install: root.appendingPathComponent("EnviousWispr/Models/model", isDirectory: true),
      metadata: root.appendingPathComponent("EnviousWispr/ModelDelivery", isDirectory: true),
      root: root)
    if withDonor {
      try FileManager.default.createDirectory(at: world.donor, withIntermediateDirectories: true)
    } else {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    return world
  }

  private func write(_ content: Data, under root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url)
  }

  /// Path → (bytes, inode). Inode as well as bytes, because a move, or a replace
  /// with identical content, leaves the bytes equal and is exactly the outcome
  /// this change exists to prevent.
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

  private func registration(_ world: World, manifest: DeliveryManifest, donor: Bool = true)
    -> DeliveryRegistration
  {
    DeliveryRegistration(
      manifest: manifest, installDirectory: world.install, metadataDirectory: world.metadata,
      legacyDonorDirectory: donor ? world.donor : nil)
  }

  // MARK: - What the user gets

  @Test("an existing user's model reaches our directory and the donor is untouched")
  func migratesWithoutTouchingTheDonor() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    // A file no manifest of ours names. Under the pre-#2483 behaviour this is
    // precisely what promotion's orphan cleanup deleted.
    try write(Data("another app put this here".utf8), under: world.donor, path: "CtcHead/x.bin")
    let manifest = try ManifestFixture.manifest(files: files)
    let before = try fingerprint(of: world.donor)

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    #expect(outcome.componentsPublished == 2)
    for f in files {
      let landed = world.install.appendingPathComponent(f.path)
      #expect(try Data(contentsOf: landed) == f.content)
    }
    let after = try fingerprint(of: world.donor)
    #expect(before.keys.sorted() == after.keys.sorted())
    for (path, value) in before {
      #expect(after[path]?.0 == value.0, "donor bytes changed at \(path)")
      #expect(after[path]?.1 == value.1, "donor inode changed at \(path)")
    }
  }

  @Test("a partially complete installation is repaired from the donor, with no network")
  func repairsAPartialInstallOffline() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    // One component already ours and valid; the other missing entirely. This is
    // the offline user an earlier design would have stranded by refusing to
    // publish into a non-empty installation.
    try write(files[2].content, under: world.install, path: files[2].path)
    let manifest = try ManifestFixture.manifest(files: files)

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    #expect(outcome.componentsPublished >= 1)
    for f in files {
      #expect(try Data(contentsOf: world.install.appendingPathComponent(f.path)) == f.content)
    }
  }

  @Test("a fresh install with no donor does nothing and never asks again")
  func freshInstallIsAnswered() async throws {
    let world = try makeWorld(withDonor: false)
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    #expect(outcome == .none)
    #expect(!FileManager.default.fileExists(atPath: world.install.path))
    #expect(
      LegacyDonorMigration.recordedState(
        metadataDirectory: world.metadata, manifest: manifest) == .completed)
  }

  @Test("a model the user deleted is never resurrected")
  func declinedIsHonoured() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)
    LegacyDonorMigration.record(
      .declined, metadataDirectory: world.metadata, manifest: manifest)

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    #expect(outcome == .none)
    #expect(!FileManager.default.fileExists(atPath: world.install.path))
  }

  @Test("an UNREADABLE donor is never recorded as \"nothing to migrate\"")
  func unreadableDonorIsNotRecorded() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)
    // Root-owned 700 is the same class of misconfiguration that produced
    // #2690's root-owned 755. The user HAS the bytes; this process cannot see
    // them. Recording completion here would tell them there is nothing to
    // migrate forever, including after their machine is repaired.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: world.donor.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: world.donor.path)
    }

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    #expect(outcome.componentsPublished == 0)
    #expect(
      LegacyDonorMigration.recordedState(
        metadataDirectory: world.metadata, manifest: manifest) == nil,
      "an unreadable donor must leave the question open for the next launch")
  }

  // MARK: - What must never reach the user

  @Test("a donor file of the RIGHT SIZE but the wrong bytes is never published")
  func wrongBytesAtMatchingSizeAreRejected() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    // Same length, different content. A size check cannot see this, which is
    // why the candidate is hashed rather than trusted, and why "wrong bytes
    // always fail to load" was never a safe thing to depend on.
    let poisoned = Data(String(repeating: "x", count: files[0].content.count).utf8)
    try write(poisoned, under: world.donor, path: files[0].path)
    let manifest = try ManifestFixture.manifest(files: files)

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    let landed = world.install.appendingPathComponent(files[0].path)
    #expect(!FileManager.default.fileExists(atPath: landed.path))
    #expect(
      LegacyDonorMigration.recordedState(
        metadataDirectory: world.metadata, manifest: manifest) == nil,
      "an incomplete migration must not record completion")
    #expect(outcome.componentsPublished <= 1)
  }

  @Test("an interruption after cloning leaves nothing half-installed")
  func interruptionPublishesNothing() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)

    final class Box: @unchecked Sendable { var task: Task<Void, Never>? }
    let box = Box()
    LegacyDonorMigration.stallHook = { point in
      if point == "after_clone" { box.task?.cancel() }
    }
    defer { LegacyDonorMigration.stallHook = nil }

    let reg = registration(world, manifest: manifest)
    box.task = Task { _ = await LegacyDonorMigration.migrate(registration: reg) }
    await box.task?.value

    #expect(
      LegacyDonorMigration.recordedState(
        metadataDirectory: world.metadata, manifest: manifest) == nil,
      "a cancelled migration must not record completion")
    // Whatever was published is COMPLETE and correct. Nothing partial is visible.
    for (component, componentFiles) in manifest.filesByComponent {
      let root = world.install.appendingPathComponent(component)
      guard FileManager.default.fileExists(atPath: root.path) else { continue }
      for f in componentFiles {
        let landed = world.install.appendingPathComponent(f.resolvedInstallPath)
        let expected = world.donor.appendingPathComponent(f.resolvedInstallPath)
        #expect(
          try Data(contentsOf: landed) == (try Data(contentsOf: expected)),
          "a published component must be complete and correct at \(f.resolvedInstallPath)")
      }
    }
  }

  @Test("a cancel between verifying and publishing publishes nothing")
  func cancelAfterVerifyPublishesNothing() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)

    // The tightest window there is: the bytes are cloned AND proven, and the
    // only thing left is the write that leaves the candidate directory. This is
    // the instant `remove()` has to win, or a user who deleted the model gets a
    // component put back moments later.
    final class Box: @unchecked Sendable { var task: Task<Void, Never>? }
    let box = Box()
    LegacyDonorMigration.stallHook = { point in
      if point == "after_verify" { box.task?.cancel() }
    }
    defer { LegacyDonorMigration.stallHook = nil }

    let reg = registration(world, manifest: manifest)
    box.task = Task { _ = await LegacyDonorMigration.migrate(registration: reg) }
    await box.task?.value

    #expect(
      !FileManager.default.fileExists(atPath: world.install.path),
      "nothing may be published after the caller has cancelled")
    #expect(
      LegacyDonorMigration.recordedState(
        metadataDirectory: world.metadata, manifest: manifest) == nil)
  }

  @Test("an install directory resolving inside the donor is refused")
  func installInsideDonorIsRefused() async throws {
    let world = try makeWorld()
    let files = ManifestFixture.smallFiles
    for f in files { try write(f.content, under: world.donor, path: f.path) }
    let manifest = try ManifestFixture.manifest(files: files)
    // The install directory is a symlink INTO the donor. Nothing may be created,
    // moved or deleted on the far side of it.
    try FileManager.default.createDirectory(
      at: world.install.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: world.install, withDestinationURL: world.donor)
    let before = try fingerprint(of: world.donor)

    let outcome = await LegacyDonorMigration.migrate(
      registration: registration(world, manifest: manifest))

    #expect(outcome == .none)
    let after = try fingerprint(of: world.donor)
    #expect(before.keys.sorted() == after.keys.sorted())
    for (path, value) in before { #expect(after[path]?.1 == value.1) }
  }
}

/// Structural facts about WHERE the model lives. Separate suite and separate tag:
/// these do not describe an outcome a user feels, they stop the install location
/// drifting back into somebody else's directory.
@Suite("Parakeet install location (#2697)", .tags(.driftGuard))
struct ParakeetInstallLocationTests {

  @Test("the install path names no other vendor")
  func installPathIsOurs() {
    let root = URL(filePath: "/tmp/appsupport-fixture")
    let install = ParakeetInstallLocation.directory(appSupport: root)
    #expect(!install.path.contains("FluidAudio"))
    #expect(install.path.contains("EnviousWispr"))
  }

  /// Reads the vendor's answer at RUNTIME rather than restating it here. The
  /// constant is not the Hugging Face slug — `Repo.name` carries `-coreml` and
  /// `Repo.folderName` strips it — and taking it from our own manifest produced a
  /// directory the loader would never look in. This test is what caught that.
  @Test("the last path component survives the vendor's own reconstruction")
  func lastComponentSurvivesVendorReconstruction() {
    let vendorFolderName = ParakeetBackend.vendorSharedDirectory.lastPathComponent
    #expect(
      ParakeetInstallLocation.repoFolderName == vendorFolderName,
      "install directory name must equal the vendor's repo folder name")
  }

  @Test("the donor is a sibling of our directory, never inside it")
  func donorIsASibling() {
    let root = URL(filePath: "/tmp/appsupport-fixture")
    let donor = ParakeetInstallLocation.legacySharedDonor(appSupport: root)
    let install = ParakeetInstallLocation.directory(appSupport: root)
    #expect(donor != install)
    #expect(!donor.path.hasPrefix(install.path))
    #expect(!install.path.hasPrefix(donor.path))
  }
}
