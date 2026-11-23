import EnviousWisprASR
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline

/// #4578 §3.2: once the person removes Parakeet, no route brings its bytes back until an
/// explicit install. When this fails, a removed engine downloads (or is copied back) on its own
/// and the disk space the person freed is gone again. Each blocked door has a permitted control
/// in the same rig, so a door that was never reached cannot pass.
@MainActor
@Suite(.tags(.productOutcome), .serialized)
struct ParakeetInstallIntentTests {
  private typealias Policy = ParakeetUpgradePolicyTests

  /// The shared upgrade rig with a coordinator that reads `intent`.
  private func rig(
    v3: Bool, ultra: Bool, enabled: Bool = true, state: ParakeetUpgradeState? = nil,
    v3Donor: Bool = false, onboarding: Bool = false, removed: Bool
  ) async throws -> (Policy.Rig, ParakeetInstallIntentStore) {
    var rig = try await Policy.rig(
      v3: v3, ultra: ultra, enabled: enabled, state: state, v3Donor: v3Donor,
      onboarding: onboarding)
    let intent = ParakeetInstallIntentStore(metadataDirectory: rig.metadata)
    if removed { try intent.write(removedByUser: true) }
    rig.coordinator = ParakeetUpgradeCoordinator(
      parakeetSelection: rig.selection, delivery: rig.v3,
      target: .init(delivery: rig.ultra, store: rig.store, ownedModelsRoot: rig.models),
      installIntent: intent,
      isOnboardingComplete: { [onboarding = rig.onboarding] in onboarding.value })
    rig.coordinator.markSelectionPoint()
    return (rig, intent)
  }

  // MARK: The record

  @Test("the record: absent is wanted, a Remove persists across a new reader, install clears it")
  func recordRoundTrip() throws {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4578-intent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ParakeetInstallIntentStore(metadataDirectory: dir)
    #expect(store.read() == .wanted)
    try store.write(removedByUser: true)
    #expect(ParakeetInstallIntentStore(metadataDirectory: dir).read() == .removedByUser)
    try store.write(removedByUser: false)
    #expect(ParakeetInstallIntentStore(metadataDirectory: dir).read() == .wanted)
  }

  @Test("an unreadable record (not a file) permits no bytes")
  func unreadableRecordFailsClosed() async throws {
    let (rig, intent) = try await rig(v3: false, ultra: false, removed: false)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try FileManager.default.createDirectory(at: intent.url, withIntermediateDirectories: true)
    #expect(intent.read() == .unreadable(reason: "not_a_file"))
    Policy.enqueueUltra(rig)
    await #expect(throws: ParakeetRemovedByUserError.self) {
      _ = try await rig.coordinator.prepareLoad()
    }
    #expect(Policy.ultraRequests(rig) == 0)
  }

  // MARK: Doors, each with its permitted control

  @Test("a load with nothing installed: removed fetches nothing, wanted downloads Ultra")
  func foregroundLoadDoor() async throws {
    let (removed, _) = try await rig(v3: false, ultra: false, removed: true)
    defer { try? FileManager.default.removeItem(at: removed.root) }
    Policy.enqueueUltra(removed)
    await #expect(throws: ParakeetRemovedByUserError.self) {
      _ = try await removed.coordinator.prepareLoad()
    }
    #expect(Policy.ultraRequests(removed) == 0)
    #expect(removed.selection.current == nil, "no request is left for a direct load to reuse")

    let (wanted, _) = try await rig(v3: false, ultra: false, removed: false)
    defer { try? FileManager.default.removeItem(at: wanted.root) }
    Policy.enqueueUltra(wanted)
    let prepared = try await wanted.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .ultra)
    #expect(Policy.ultraRequests(wanted) > 0, "control: the wanted rig reached the fetch")
  }

  @Test("delivery off: removed selects no vendor download, wanted selects the vendor branch")
  func vendorLoadDoor() async throws {
    let (removed, _) = try await rig(v3: false, ultra: false, enabled: false, removed: true)
    defer { try? FileManager.default.removeItem(at: removed.root) }
    await #expect(throws: ParakeetRemovedByUserError.self) {
      _ = try await removed.coordinator.prepareLoad()
    }
    #expect(removed.selection.current == nil)

    let (wanted, _) = try await rig(v3: false, ultra: false, enabled: false, removed: false)
    defer { try? FileManager.default.removeItem(at: wanted.root) }
    let prepared = try await wanted.coordinator.prepareLoad()
    #expect(prepared.selection?.cacheOnly == false, "control: the vendor branch was reached")
  }

  @Test("Resume: removed is refused and fetches nothing; wanted downloads")
  func resumeDoor() async throws {
    let (removed, _) = try await rig(v3: false, ultra: false, removed: true)
    defer { try? FileManager.default.removeItem(at: removed.root) }
    Policy.enqueueUltra(removed)
    #expect(await removed.coordinator.resumeDownloadInForeground() == nil)
    #expect(Policy.ultraRequests(removed) == 0)

    let (wanted, _) = try await rig(v3: false, ultra: false, removed: false)
    defer { try? FileManager.default.removeItem(at: wanted.root) }
    Policy.enqueueUltra(wanted)
    #expect(await wanted.coordinator.resumeDownloadInForeground() != nil)
    #expect(Policy.ultraRequests(wanted) > 0)
  }

  @Test("the background upgrade: removed schedules nothing; wanted downloads and admits Ultra")
  func backgroundDoor() async throws {
    for removedLater in [true, false] {
      // v3 serves (row B) and the background fetch waits for Setup to finish.
      let (rig, intent) = try await rig(v3: true, ultra: false, onboarding: false, removed: false)
      defer { try? FileManager.default.removeItem(at: rig.root) }
      _ = try await rig.coordinator.prepareLoad()
      #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
      if removedLater { try intent.write(removedByUser: true) }
      Policy.enqueueUltra(rig)
      let admitted = BoundedWait.Signal()
      rig.coordinator.onOutcome = { if $0 == .backgroundAdmitted { admitted.fire() } }
      rig.onboarding.value = true
      rig.coordinator.onboardingDidComplete()
      if removedLater {
        #expect(rig.coordinator.hasBackgroundFetchForTesting == false)
        #expect(Policy.ultraRequests(rig) == 0)
      } else {
        // Control: the scheduled upgrade really downloads; teardown waits for its end.
        try await BoundedWait.until(admitted)
        #expect(Policy.ultraRequests(rig) > 0)
        #expect(await rig.controller.isAdmitted(rig.ultraRegistration))
      }
    }
  }

  @Test("a failed load: removed gets no repair or fallback; wanted gets the bounded repair")
  func failurePlanDoor() async throws {
    for removedLater in [true, false] {
      let (rig, intent) = try await rig(v3: false, ultra: true, removed: false)
      defer { try? FileManager.default.removeItem(at: rig.root) }
      let prepared = try await rig.coordinator.prepareLoad()
      #expect(prepared.selection?.model == .ultra)
      #expect(Policy.physicalLoad(rig, succeeds: false) == .loaded)
      if removedLater { try intent.write(removedByUser: true) }
      let plan = await rig.coordinator.handleLoadFailure(prepared, error: Policy.VendorLoadFailed())
      #expect(plan == (removedLater ? .fail : .reload))
    }
  }

  @Test("install cancels a queued removal of the target's bytes from the replaced cycle")
  func explicitInstallCancelsQueuedCleanup() async throws {
    let (rig, _) = try await rig(
      v3: true, ultra: true,
      state: .init(attempts: 0, refetchSpent: true, exhausted: true, declined: false),
      removed: false)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let ended = BoundedWait.Signal()
    rig.coordinator.onCleanupEndedForTesting = { _ in ended.fire() }
    let prepared = try await rig.coordinator.prepareLoad()
    #expect(prepared.selection?.model == .v3, "row V queued the removal")
    _ = try await rig.coordinator.installExplicitly()
    try await BoundedWait.until(ended)
    #expect(await rig.controller.isAdmitted(rig.ultraRegistration), "the queued removal was cancelled")
  }

  @Test("the launch copy of a donor v3: removed copies nothing back; wanted copies it")
  func donorMigrationDoor() async throws {
    let (removed, _) = try await rig(v3: false, ultra: false, v3Donor: true, removed: true)
    defer { try? FileManager.default.removeItem(at: removed.root) }
    try Policy.install(
      Policy.v3Files, into: try #require(removed.v3Registration.legacyDonorDirectory))
    await removed.coordinator.runLaunchMigration()
    #expect(
      FileManager.default.fileExists(atPath: removed.v3Registration.installDirectory.path) == false)

    let (wanted, _) = try await rig(v3: false, ultra: false, v3Donor: true, removed: false)
    defer { try? FileManager.default.removeItem(at: wanted.root) }
    try Policy.install(
      Policy.v3Files, into: try #require(wanted.v3Registration.legacyDonorDirectory))
    await wanted.coordinator.runLaunchMigration()
    #expect(FileManager.default.fileExists(atPath: wanted.v3Registration.installDirectory.path))
  }

  @Test("a relaunch keeps the removal: the next coordinator over the same disk fetches nothing")
  func removalSurvivesRelaunch() async throws {
    let (first, _) = try await rig(v3: false, ultra: false, removed: true)
    defer { try? FileManager.default.removeItem(at: first.root) }
    let again = ParakeetUpgradeCoordinator(
      parakeetSelection: first.selection, delivery: first.v3,
      target: .init(delivery: first.ultra, store: first.store, ownedModelsRoot: first.models),
      installIntent: ParakeetInstallIntentStore(metadataDirectory: first.metadata))
    again.markSelectionPoint()
    Policy.enqueueUltra(first)
    await #expect(throws: ParakeetRemovedByUserError.self) { _ = try await again.prepareLoad() }
    #expect(Policy.ultraRequests(first) == 0)
  }

  // MARK: Explicit install

  /// #4578 (r2 N2): Remove and Set up model in one session, no relaunch. When this fails, the
  /// person cannot get Parakeet back until they restart the app.
  @Test("Remove then Set up model in the same session: Resume stays refused, install fetches")
  func removeThenReinstallSameSession() async throws {
    let (rig, intent) = try await rig(
      v3: false, ultra: false,
      state: .init(attempts: 2, refetchSpent: true, exhausted: true, declined: false),
      removed: false)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try await rig.coordinator.recordRemovalByUser()
    #expect(intent.read() == .removedByUser)
    #expect(await rig.coordinator.resumeDownloadInForeground() == nil, "Resume is no install")
    Policy.enqueueUltra(rig)
    let outcome = try await rig.coordinator.installExplicitly()
    #expect(outcome != nil)
    #expect(intent.read() == .wanted)
    #expect(
      Policy.state(rig)
        == .init(attempts: 0, refetchSpent: false, exhausted: false, declined: false))
    #expect(Policy.ultraRequests(rig) > 0)
  }

  /// #4578: what Settings' "Remove leftover files" reads. When this fails, an interrupted
  /// removal leaves hundreds of megabytes with no way to remove them, or an installed model is
  /// offered as leftovers.
  @Test("leftover bytes: unadmitted files are leftovers; nothing, or an install, is not")
  func leftoverBytes() async throws {
    let (bare, _) = try await rig(v3: false, ultra: false, removed: false)
    defer { try? FileManager.default.removeItem(at: bare.root) }
    #expect(await bare.controller.hasLeftoverBytes(bare.v3Registration) == false)
    try Policy.install(Policy.v3Files, into: bare.v3Registration.installDirectory)
    #expect(await bare.controller.hasLeftoverBytes(bare.v3Registration))
    #expect(await bare.controller.remove(bare.v3Registration) == .removed)
    #expect(await bare.controller.hasLeftoverBytes(bare.v3Registration) == false)
    let (installed, _) = try await rig(v3: true, ultra: false, removed: false)
    defer { try? FileManager.default.removeItem(at: installed.root) }
    #expect(await installed.controller.hasLeftoverBytes(installed.v3Registration) == false)
  }

  @Test(
    "install after a removal with a spent cycle: clears the removal, grants a fresh cycle, fetches")
  func explicitInstallResetsTheCycle() async throws {
    let (rig, intent) = try await rig(
      v3: false, ultra: false,
      state: .init(attempts: 2, refetchSpent: true, exhausted: true, declined: false),
      removed: true)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    Policy.enqueueUltra(rig)

    let outcome = try await rig.coordinator.installExplicitly()

    #expect(outcome != nil)
    #expect(intent.read() == .wanted)
    #expect(
      Policy.state(rig)
        == .init(attempts: 0, refetchSpent: false, exhausted: false, declined: false))
    #expect(rig.coordinator.needsExplicitRetry == false)
    #expect(
      rig.coordinator.hasPendingSelectionPoint, "the next load re-decides, never a frozen choice")
    #expect(Policy.ultraRequests(rig) > 0)
  }
}

/// #4578 §3.2 (r2 N1): the transcription Whisper cache is adopted only with consent. When this
/// fails, a Whisper model the person removed comes back when Settings re-reads it or at the next
/// launch, from files a failed removal left behind.
@MainActor
@Suite(.tags(.productOutcome))
struct WhisperAdoptionConsentTests {
  private struct Fixture {
    let root: URL
    let metadata: URL
    let registration: DeliveryRegistration
    let controller: ModelDeliveryController
    let handle: DeliveredModelHandle
  }

  /// A complete transcription payload on disk with NO admission marker: what a removal that
  /// deleted the marker and then failed leaves behind.
  private func makeFixture() throws -> Fixture {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4578-whisper-\(UUID().uuidString)", isDirectory: true)
    let metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
    let registration = DeliveryRegistration(
      manifest: try ManifestFixture.manifest(files: ManifestFixture.smallFiles),
      installDirectory: root.appendingPathComponent("Models/whisper-gguf", isDirectory: true),
      metadataDirectory: metadata, legacyDonorDirectory: nil)
    try ParakeetUpgradePolicyTests.install(
      ManifestFixture.smallFiles, into: registration.installDirectory)
    let suite = "test.4578.whisper.\(UUID().uuidString)"
    let controller = ModelDeliveryController(defaults: TestDefaults.suite(suite)!)
    let handle = DeliveredModelHandle(
      controller: controller, registration: registration,
      defaults: TestDefaults.suite(suite)!)
    return Fixture(
      root: root, metadata: metadata, registration: registration, controller: controller,
      handle: handle)
  }

  private func migration(_ f: Fixture) -> WhisperModelMigration {
    WhisperModelMigration(
      metadataDirectory: f.metadata, ports: [:], isDeliveryEnabled: { true }, log: { _ in })
  }

  private func consent(_ migration: WhisperModelMigration) -> WhisperAdoptionConsent {
    let consent = WhisperAdoptionConsent()
    consent.migration = migration
    return consent
  }

  @Test("removed: the leftover payload stays unadmitted through a re-read and a relaunch")
  func declinedLeftoversStayUnadmitted() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let first = migration(f)
    #expect(first.decline(.dictation) == .done)

    #expect(await WhisperDeliveryWiring.adoptTranscriptionCache(f.handle, consent: consent(first)) == false)
    #expect(await f.handle.isAdmitted() == false)

    let relaunched = migration(f)
    #expect(
      await WhisperDeliveryWiring.adoptTranscriptionCache(f.handle, consent: consent(relaunched))
        == false)
    #expect(await f.handle.isAdmitted() == false)
  }

  @Test("an explicit Download records consent, and the same payload is adopted without a fetch")
  func explicitDownloadRecovers() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let migration = migration(f)
    #expect(migration.decline(.dictation) == .done)
    #expect(await migration.download(.dictation) == .done)
    #expect(await WhisperDeliveryWiring.adoptTranscriptionCache(f.handle, consent: consent(migration)))
    #expect(await f.handle.isAdmitted())
  }

  @Test("no record yet (a fresh install) adopts; an unreadable record does not")
  func freshAndUnreadable() async throws {
    let fresh = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fresh.root) }
    // Held strongly: the consent holder keeps its migration weakly, as production does.
    let freshMigration = migration(fresh)
    #expect(
      await WhisperDeliveryWiring.adoptTranscriptionCache(fresh.handle, consent: consent(freshMigration)),
      "control: the payload is adoptable")

    let broken = try makeFixture()
    defer { try? FileManager.default.removeItem(at: broken.root) }
    try FileManager.default.createDirectory(at: broken.metadata, withIntermediateDirectories: true)
    try Data("not json".utf8).write(
      to: broken.metadata.appendingPathComponent("whisper-replacement.json"))
    let brokenMigration = migration(broken)
    #expect(
      await WhisperDeliveryWiring.adoptTranscriptionCache(broken.handle, consent: consent(brokenMigration))
        == false)
  }

  @Test("the preview's own decline never blocks the transcription model")
  func previewIsIndependent() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let migration = migration(f)
    #expect(migration.decline(.preview) == .done)
    #expect(await WhisperDeliveryWiring.adoptTranscriptionCache(f.handle, consent: consent(migration)))
  }

  @Test("before the migration exists, nothing is adopted")
  func noMigrationRefuses() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(
      await WhisperDeliveryWiring.adoptTranscriptionCache(f.handle, consent: WhisperAdoptionConsent())
        == false)
  }
}
