import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit

/// #3735 plan §3.6: every row of the migration state matrix, against real temporary folders.
/// When one of these fails, an updated user loses their Whisper model without a replacement,
/// gets a download they did not ask for, or has a cancel silently undone.
@MainActor
@Suite("Whisper model migration (#3735 §3.6)", .tags(.productOutcome))
struct WhisperModelMigrationTests {

  /// A fake delivery door: counts fetches and answers with a scripted outcome.
  @MainActor final class FakeDoor {
    var selected: Bool
    var admitted = false
    var fetches = 0
    var fetchSucceeds = true
    /// When set, the next fetch fires `held` and suspends until `release` fires.
    var holdNextFetch = false
    let held = BoundedWait.Signal()
    let release = BoundedWait.Signal()

    init(selected: Bool) { self.selected = selected }

    func port(legacy: URL) -> WhisperModelMigration.ArtifactPort {
      .init(
        isSelected: { [unowned self] in selected },
        isAdmittedOrAdoptable: { [unowned self] in admitted },
        ensureAvailable: { [unowned self] in
          fetches += 1
          if holdNextFetch {
            holdNextFetch = false
            held.fire()
            // Bounded: a test that never releases fails here instead of hanging the lane.
            try? await BoundedWait.until(release)
          }
          if fetchSucceeds { admitted = true }
          return fetchSucceeds
        },
        legacyInstallDirectory: legacy)
    }
  }

  @MainActor struct Rig {
    let root: URL
    let metadata: URL
    let legacyDictation: URL
    let legacyPreview: URL
    let dictation: FakeDoor
    let preview: FakeDoor
    var deliveryEnabled = true
    var failDeleting: Set<String> = []
    var events: [WhisperModelMigration.Event] = []
    var stateAtFirstDeletion: WhisperModelMigration.ReplacementState?

    init(dictationSelected: Bool, previewSelected: Bool = false) throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-3735-migration-\(UUID().uuidString)", isDirectory: true)
      metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
      legacyDictation = root.appendingPathComponent("Models/whisper", isDirectory: true)
      legacyPreview = root.appendingPathComponent("Models/whisper-preview", isDirectory: true)
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
      dictation = FakeDoor(selected: dictationSelected)
      preview = FakeDoor(selected: previewSelected)
    }

    func makeOldModels(dictation: Bool = true, preview: Bool = true) throws {
      let fm = FileManager.default
      for (make, dir) in [(dictation, legacyDictation), (preview, legacyPreview)] where make {
        let inner = dir.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: inner.appendingPathComponent("weight.bin"))
      }
    }

    func touch(_ relative: String) throws {
      let url = metadata.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  }

  private func makeMigration(_ rig: inout Rig) -> (WhisperModelMigration, () -> Rig) {
    // A class box so the closures below can record into the rig the test reads back.
    final class Box {
      var rig: Rig
      init(_ rig: Rig) { self.rig = rig }
    }
    let box = Box(rig)
    var migrationRef: WhisperModelMigration?
    let migration = WhisperModelMigration(
      metadataDirectory: rig.metadata,
      ports: [
        .dictation: rig.dictation.port(legacy: rig.legacyDictation),
        .preview: rig.preview.port(legacy: rig.legacyPreview),
      ],
      isDeliveryEnabled: { box.rig.deliveryEnabled },
      removeItem: { url in
        if box.rig.stateAtFirstDeletion == nil {
          box.rig.stateAtFirstDeletion = MainActor.assumeIsolated {
            migrationRef?.state(of: .dictation)
          }
        }
        if box.rig.failDeleting.contains(url.lastPathComponent) {
          throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
      },
      log: { _ in })
    migrationRef = migration
    migration.onEvent = { box.rig.events.append($0) }
    return (migration, { box.rig })
  }

  // MARK: - Launch rows

  @Test("updated Whisper user: debt recorded before deletion, old model deleted, new one fetched")
  func selectedUserWithOldModel() async throws {
    var rig = try Rig(dictationSelected: true)
    try rig.makeOldModels()
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    let after = read()
    #expect(after.stateAtFirstDeletion == .owed)
    #expect(!after.exists(after.legacyDictation))
    #expect(!after.exists(after.legacyPreview))
    #expect(after.dictation.fetches == 1)
    #expect(after.preview.fetches == 0)
    #expect(migration.state(of: .dictation) == .admitted)
    #expect(migration.state(of: .preview) == .owed)
    #expect(after.events == [.legacyRetired, .replacementCompleted(.dictation)])
  }

  @Test("user who never selected Whisper: old folders deleted, nothing downloaded")
  func unselectedUserWithOldModel() async throws {
    var rig = try Rig(dictationSelected: false)
    try rig.makeOldModels()
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    let after = read()
    #expect(!after.exists(after.legacyDictation))
    #expect(!after.exists(after.legacyPreview))
    #expect(after.dictation.fetches == 0)
    #expect(after.preview.fetches == 0)
    #expect(after.events == [.legacyRetired])
  }

  @Test("Universal preview selected: the preview replacement is fetched, dictation is not")
  func previewSelectedUser() async throws {
    var rig = try Rig(dictationSelected: false, previewSelected: true)
    try rig.makeOldModels()
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    #expect(read().preview.fetches == 1)
    #expect(read().dictation.fetches == 0)
    #expect(migration.state(of: .preview) == .admitted)
  }

  @Test("a new install with nothing old and nothing selected owes nothing, even after selecting")
  func freshInstall() async throws {
    var rig = try Rig(dictationSelected: false)
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()
    #expect(migration.state(of: .dictation) == .notOwed)
    read().dictation.selected = true
    await migration.runLaunch()

    #expect(read().dictation.fetches == 0)
    #expect(read().events.isEmpty)
  }

  @Test("Whisper selected but never downloaded: the replacement is fetched")
  func selectedWithoutOldModel() async throws {
    var rig = try Rig(dictationSelected: true)
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    #expect(read().dictation.fetches == 1)
    #expect(migration.state(of: .dictation) == .admitted)
  }

  @Test("quit after the deletion and before the download: the next launch fetches")
  func quitBeforeDownload() async throws {
    var rig = try Rig(dictationSelected: true)
    try rig.makeOldModels()
    rig.dictation.fetchSucceeds = false  // the first run ends without a model
    let (first, read) = makeMigration(&rig)
    await first.runLaunch()
    #expect(first.state(of: .dictation) == .owed)
    #expect(!read().exists(read().legacyDictation))

    // A new process: a fresh migration over the same disk.
    var next = read()
    next.dictation.fetchSucceeds = true
    let (second, readNext) = makeMigration(&next)
    await second.runLaunch()

    #expect(readNext().dictation.fetches == 2)
    #expect(second.state(of: .dictation) == .admitted)
  }

  @Test("a download failure stays owed and is retried on the next launch")
  func downloadFailureRetries() async throws {
    var rig = try Rig(dictationSelected: true)
    rig.dictation.fetchSucceeds = false
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()
    await migration.runLaunch()

    #expect(read().dictation.fetches == 2)
    #expect(migration.state(of: .dictation) == .owed)
  }

  @Test("a failed deletion is reported, never blocks the download, and is retried next launch")
  func deletionFailure() async throws {
    var rig = try Rig(dictationSelected: true)
    try rig.makeOldModels(preview: false)
    rig.failDeleting = ["whisper"]
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()
    #expect(read().exists(read().legacyDictation))
    #expect(read().dictation.fetches == 1)
    #expect(read().events.first == .legacyRetirementFailed)

    var retry = read()
    retry.failDeleting = []
    let (again, readAgain) = makeMigration(&retry)
    await again.runLaunch()
    #expect(!readAgain().exists(readAgain().legacyDictation))
  }

  @Test("the kill switch refuses the whole run: no record, no deletion, no download")
  func killSwitchOff() async throws {
    var rig = try Rig(dictationSelected: true)
    try rig.makeOldModels()
    rig.deliveryEnabled = false
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    #expect(read().exists(read().legacyDictation))
    #expect(read().dictation.fetches == 0)
    #expect(migration.state(of: .dictation) == nil)
  }

  @Test("an unwritable record deletes nothing")
  func recordWriteFailure() async throws {
    var rig = try Rig(dictationSelected: true)
    try rig.makeOldModels()
    // A read-only metadata folder lets the record read as absent (the code reaches its write) and
    // makes the atomic write fail. A directory at the record path reads as unusable instead and
    // returns before the write, so it would not reach the line this test guards.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.metadata.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: rig.metadata.path)
    }
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    #expect(!read().exists(read().metadata.appendingPathComponent("whisper-replacement.json")))
    #expect(read().exists(read().legacyDictation))
    #expect(read().dictation.fetches == 0)
  }

  @Test("an already installed replacement is recorded without a download")
  func alreadyAdmitted() async throws {
    var rig = try Rig(dictationSelected: true)
    rig.dictation.admitted = true
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()

    #expect(read().dictation.fetches == 0)
    #expect(migration.state(of: .dictation) == .admitted)
  }

  // MARK: - User commands

  @Test("Cancel is remembered: no automatic download on later launches")
  func cancelIsRemembered() async throws {
    var rig = try Rig(dictationSelected: true)
    rig.dictation.fetchSucceeds = false
    let (migration, read) = makeMigration(&rig)
    await migration.runLaunch()

    #expect(migration.decline(.dictation) == .done)
    await migration.runLaunch()

    #expect(read().dictation.fetches == 1)
    #expect(migration.state(of: .dictation) == .declined)
  }

  @Test("an explicit Download clears the decline and fetches")
  func downloadClearsDecline() async throws {
    var rig = try Rig(dictationSelected: true)
    let (migration, read) = makeMigration(&rig)
    _ = migration.decline(.dictation)

    #expect(await migration.download(.dictation) == .done)

    #expect(read().dictation.fetches == 1)
    #expect(migration.state(of: .dictation) == .admitted)
  }

  @Test("a Cancel during the launch download wins: the late result does not undo it")
  func cancelOvertakesLaunchFetch() async throws {
    var rig = try Rig(dictationSelected: true)
    rig.dictation.holdNextFetch = true
    let (migration, read) = makeMigration(&rig)

    let launch = Task { await migration.runLaunch() }
    try await BoundedWait.until(read().dictation.held)
    #expect(migration.decline(.dictation) == .done)
    let release = read().dictation.release
    release.fire()
    _ = try await BoundedWait.result(of: launch, onExpiry: { release.fire() })

    #expect(migration.state(of: .dictation) == .declined)
  }

  @Test("a Cancel on dictation during its launch fetch does not stop the owed preview fetch")
  func cancelIsPerArtifact() async throws {
    var rig = try Rig(dictationSelected: true, previewSelected: true)
    rig.dictation.holdNextFetch = true
    let (migration, read) = makeMigration(&rig)

    let launch = Task { await migration.runLaunch() }
    try await BoundedWait.until(read().dictation.held)
    #expect(migration.decline(.dictation) == .done)
    let release = read().dictation.release
    release.fire()
    _ = try await BoundedWait.result(of: launch, onExpiry: { release.fire() })

    #expect(migration.state(of: .dictation) == .declined)
    #expect(read().preview.fetches == 1)
    #expect(migration.state(of: .preview) == .admitted)
  }

  // MARK: - A record this build cannot read

  @Test(
    "an unreadable or unknown-version record changes nothing: no deletion, no download, no overwrite",
    arguments: ["{not json", #"{"version":2,"artifacts":{"dictation":"declined"}}"#])
  func unusableRecordChangesNothing(contents: String) async throws {
    var rig = try Rig(dictationSelected: true, previewSelected: true)
    try rig.makeOldModels()
    let recordURL = rig.metadata.appendingPathComponent("whisper-replacement.json")
    try Data(contents.utf8).write(to: recordURL)
    let (migration, read) = makeMigration(&rig)

    await migration.runLaunch()
    #expect(migration.decline(.preview) == .refusedRecord)
    #expect(await migration.download(.dictation) == .refusedRecord)

    let after = read()
    #expect(after.exists(after.legacyDictation))
    #expect(after.exists(after.legacyPreview))
    #expect(after.dictation.fetches == 0)
    #expect(after.preview.fetches == 0)
    #expect(try String(contentsOf: recordURL, encoding: .utf8) == contents)
  }

  // MARK: - What counts as a leftover

  @Test("only the retired family's files are deleted; other models and links are untouched")
  func leftoverIdentification() async throws {
    var rig = try Rig(dictationSelected: false)
    try rig.touch(
      "whisper_kit-whisperkit-coreml-97a5bf9b-openai_whisper-large-v3-v20240930_turbo.admission.json"
    )
    try rig.touch("staging/whisper_kit-whisperkit-coreml-97a5bf9b-openai_whisper-small_216MB/p")
    try rig.touch("whisperkit-replacement-owed")
    try rig.touch("whisperkit-foreign-declined.json")
    let keep = [
      "whisper-whisper-large-v3-turbo-gguf-5eaf945c-q8_0.admission.json",
      "parakeet-parakeet-ultra-coreml-95eaa59a-int8.admission.json",
      "staging/whisper-whisper-small-gguf-a2073177-q8_0/p",
    ]
    for name in keep { try rig.touch(name) }
    // A symlink where the old folder was is never followed or deleted.
    let elsewhere = rig.root.appendingPathComponent("someone-else", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: rig.legacyDictation.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: rig.legacyDictation, withDestinationURL: elsewhere)
    let (migration, read) = makeMigration(&rig)

    #expect(migration.legacyLeftovers().count == 4)
    await migration.runLaunch()

    let after = read()
    for name in keep { #expect(after.exists(after.metadata.appendingPathComponent(name))) }
    #expect(after.exists(elsewhere))
    #expect(migration.legacyLeftovers().isEmpty)
    #expect(after.exists(after.metadata))
    // The old coordinator's owed marker means this user was mid-replacement: still owed,
    // but not selected, so nothing downloads. The symlink alone would not have counted.
    #expect(migration.state(of: .dictation) == .owed)
    #expect(migration.state(of: .preview) == .notOwed)
    #expect(after.dictation.fetches == 0)
  }
}

/// #3735 §3.6 through the preview's real Settings doors (`ModelDeliveryHome`'s Download, Cancel
/// and Remove), bound to a real `WhisperModelMigration` exactly as production binds it. When this
/// fails, a user who cancelled or removed the preview model gets it downloaded again at the next
/// launch, or a press does something while the record cannot be kept.
@MainActor
@Suite("Preview Settings commands keep the replacement record (#3735)", .serialized, .tags(.productOutcome))
struct WhisperPreviewCommandRecordTests {
  typealias FakeDoor = WhisperModelMigrationTests.FakeDoor

  @MainActor struct Fixture {
    let root: URL
    let home: ModelDeliveryHome
    let metadata: URL
    let door: FakeDoor

    func migration() -> WhisperModelMigration {
      WhisperModelMigration(
        metadataDirectory: metadata,
        ports: [.preview: door.port(legacy: root.appendingPathComponent("old-preview"))],
        isDeliveryEnabled: { true }, log: { _ in })
    }

    /// A launch: a fresh migration over the same disk, bound to the doors.
    func launch() async -> WhisperModelMigration {
      let migration = migration()
      WhisperDeliveryWiring.bindPreviewCommands(of: home, to: migration)
      await migration.runLaunch()
      return migration
    }
  }

  private func makeFixture() throws -> Fixture {
    let repoRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3735-preview-doors-\(UUID().uuidString)", isDirectory: true)
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting,
      manifestBundle: try #require(
        Bundle(url: repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources"))),
      appSupportOverride: root,
      deliveryFlagDefaults: try #require(TestDefaults.suite("ew-3735-doors-\(UUID().uuidString)")))
    let metadata = try #require(home.whisperPreviewRegistration).metadataDirectory
    // Never the real delete: the doors' ordering is under test, not the controller's removal.
    home.deletePreviewModelOverrideForTests = {}
    let door = FakeDoor(selected: true)
    door.fetchSucceeds = false  // the launch fetch ends with the preview still owed
    return Fixture(root: root, home: home, metadata: metadata, door: door)
  }

  @Test("Cancel records the decline, so the next launch does not download again")
  func cancelSurvivesRelaunch() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = await f.launch()
    #expect(first.state(of: .preview) == .owed)
    #expect(f.door.fetches == 1)

    f.home.cancelPreviewDownload()
    #expect(first.state(of: .preview) == .declined)

    _ = await f.launch()
    #expect(f.door.fetches == 1, "a cancelled preview download restarted at the next launch")
  }

  @Test("Remove records the decline before it drains anything, and the next launch keeps it")
  func removeSurvivesRelaunch() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = await f.launch()
    var stateAtDrain: WhisperModelMigration.ReplacementState?
    f.home.drainPreviewHoldersBeforeRemoval = { stateAtDrain = first.state(of: .preview) }
    let finished = BoundedWait.Signal()
    f.home.previewRemovalDidFinish = { finished.fire() }

    f.home.removePreviewModel()
    try await BoundedWait.until(finished)
    #expect(stateAtDrain == .declined)
    #expect(f.home.removalStepsForTests == ["drain", "delete", "finish"])

    _ = await f.launch()
    #expect(f.door.fetches == 1, "a removed preview model was downloaded again at the next launch")
  }

  @Test("Download after a Cancel clears the decline and fetches")
  func downloadClearsDecline() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = await f.launch()
    f.home.cancelPreviewDownload()
    f.door.fetchSucceeds = true

    f.home.startPreviewDownload()
    let press = try #require(f.home.previewDownloadTaskForTests)
    _ = try await BoundedWait.result(of: press)

    #expect(f.door.fetches == 2)
    #expect(first.state(of: .preview) == .admitted)
  }

  @Test("Download then Cancel with no suspension between: nothing fetches, the decline survives")
  func downloadThenCancelImmediately() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = await f.launch()
    let fetchesBefore = f.door.fetches
    f.door.fetchSucceeds = true

    f.home.startPreviewDownload()
    f.home.cancelPreviewDownload()
    let press = try #require(f.home.previewDownloadTaskForTests)
    _ = try await BoundedWait.result(of: press)

    #expect(f.door.fetches == fetchesBefore)
    #expect(first.state(of: .preview) == .declined)
    _ = await f.launch()
    #expect(f.door.fetches == fetchesBefore)
  }

  @Test("Download then Remove with no suspension between: nothing fetches, the decline survives")
  func downloadThenRemoveImmediately() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = await f.launch()
    let fetchesBefore = f.door.fetches
    f.door.fetchSucceeds = true
    let finished = BoundedWait.Signal()
    f.home.previewRemovalDidFinish = { finished.fire() }

    f.home.startPreviewDownload()
    f.home.removePreviewModel()
    let press = try #require(f.home.previewDownloadTaskForTests)
    _ = try await BoundedWait.result(of: press)
    try await BoundedWait.until(finished)

    #expect(f.door.fetches == fetchesBefore)
    #expect(first.state(of: .preview) == .declined)
    _ = await f.launch()
    #expect(f.door.fetches == fetchesBefore)
  }

  @Test("with an unusable record, Cancel, Remove and Download touch nothing")
  func unusableRecordRefusesEveryDoor() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.createDirectory(at: f.metadata, withIntermediateDirectories: true)
    let recordURL = f.metadata.appendingPathComponent("whisper-replacement.json")
    try Data("{not json".utf8).write(to: recordURL)
    let migration = f.migration()
    WhisperDeliveryWiring.bindPreviewCommands(of: f.home, to: migration)
    var drained = false
    f.home.drainPreviewHoldersBeforeRemoval = { drained = true }

    f.home.cancelPreviewDownload()
    f.home.removePreviewModel()
    f.home.startPreviewDownload()
    let press = try #require(f.home.previewDownloadTaskForTests)
    _ = try await BoundedWait.result(of: press)

    #expect(!drained)
    #expect(f.home.removalStepsForTests.isEmpty)
    #expect(f.door.fetches == 0)
    #expect(try String(contentsOf: recordURL, encoding: .utf8) == "{not json")
  }

  @Test("an unbound record refuses every door")
  func unboundRefuses() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var drained = false
    f.home.drainPreviewHoldersBeforeRemoval = { drained = true }
    f.home.removePreviewModel()
    f.home.startPreviewDownload()
    #expect(!drained)
    #expect(f.home.previewDownloadTaskForTests == nil)
  }
}
