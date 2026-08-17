import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The EG-1 limb adapter's pure mapping: every delivery state/failure resolves
/// to an EG-1 UI vocabulary value, and EVERY `DeliveryFailureClass` maps to a
/// retry-able RED (the limb never blocks dictation — #1363 §7).
@Suite struct EGOneDeliveryAdapterMappingTests {
  /// #2109 changed this signature: mapping a not-serving state now depends on
  /// DISK truth (is a working older revision present, are there partials), so
  /// the registration is required. This fixture has an empty install and
  /// metadata dir, so every not-serving state resolves to `.notInstalled` —
  /// the pre-#2109 behaviour, asserted here so the OTHER cases stay unchanged.
  @Test func deliveryStateMapsToInstallState() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let reg = try Self.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)

    #expect(EGOneDeliveryAdapter.map(.notReady, version: "1.1", registration: reg) == .notInstalled)
    #expect(
      EGOneDeliveryAdapter.map(
        .preparing(validatingExistingCache: true), version: "1.1", registration: reg)
        == .verifying)
    #expect(
      EGOneDeliveryAdapter.map(
        .downloading(fractionCompleted: 0.5, bytesWritten: 5, totalBytes: 10), version: "1.1",
        registration: reg)
        == .downloading(fractionCompleted: 0.5, upgrade: nil))
    #expect(EGOneDeliveryAdapter.map(.verifying, version: "1.1", registration: reg) == .verifying)
    #expect(
      EGOneDeliveryAdapter.map(.admitted, version: "1.1", registration: reg)
        == .installed(version: "1.1"))
    // Changed by #2109: a cancel with nothing on disk is a first-install that
    // never started, NOT a failure. With partials it is `.paused`; with a
    // surviving older revision it is `.updatePaused`. See
    // `notServingStateSeparatesTheFourDiskSituations`.
    #expect(
      EGOneDeliveryAdapter.map(.cancelled(resumable: true), version: "1.1", registration: reg)
        == .notInstalled)
  }

  @Test func everyFailureClassMapsToARetryableInstallFailure() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let reg = try Self.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    let all: [DeliveryFailureClass] = [
      .sourceUnreachable, .sourceTimeout, .source5xx, .source4xx, .integrityMismatch,
      .insufficientDisk, .permissionDenied, .cacheRepairFailed, .cancelled, .unknown,
    ]
    for reason in all {
      let mapped = EGOneDeliveryAdapter.map(
        .failed(DeliveryFailure(reason: reason)), version: "1.1", registration: reg)
      guard case .failed = mapped else {
        Issue.record("\(reason) did not map to a .failed install state")
        continue
      }
    }
  }

  private func makeTempDirs() throws -> (install: URL, metadata: URL, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-adapter-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("PolishModels", isDirectory: true)
    let metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    return (install, metadata, { try? FileManager.default.removeItem(at: root) })
  }

  /// A synthetic componentSet manifest (2 shards + `entrypointFile`),
  /// independent of the real shipped manifest — tiny bytes so tests can stage
  /// a REAL admissible cache (zeros, 1000 + 2000 bytes) with no network.
  static func shardedFixtureRegistration(install: URL, metadata: URL) throws
    -> DeliveryRegistration
  {
    func sha256(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func fileObject(_ path: String, _ data: Data) -> [String: Any] {
      ["path": path, "sizeBytes": data.count, "sha256": sha256(data), "component": path]
    }
    let shard1 = Data(count: 1000)
    let shard2 = Data(count: 2000)
    var object: [String: Any] = [
      "schemaVersion": 1,
      "identity": [
        "family": "eg_one", "name": "eg-1", "revision": "v2-sharded", "variant": "q5km",
        "runtimeABI": "llamacpp-test",
      ],
      "files": [
        fileObject("eg-1-00001-of-00002.gguf", shard1),
        fileObject("eg-1-00002-of-00002.gguf", shard2),
      ],
      "optionalFiles": [] as [Any],
      "totalBytes": shard1.count + shard2.count,
      "sources": [["id": "our_copy", "baseURL": "https://mirror.invalid.example/eg1/"]],
      "admission": [
        "layout": "componentSet", "installLocation": "test",
        "diskHeadroomFactor": "2.2", "evictPreviousRevisions": false,
        "entrypointFile": "eg-1-00001-of-00002.gguf",
      ] as [String: Any],
    ]
    let canonical = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    object["manifestDigest"] = sha256(canonical)
    let manifest = try DeliveryManifest.load(
      from: try JSONSerialization.data(withJSONObject: object))
    return DeliveryRegistration(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
  }

  @MainActor
  @Test func installedArtifactURLResolvesToEntrypointShardForComponentSetManifest() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try Self.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v2-sharded")
    #expect(adapter.installedArtifactURL.lastPathComponent == "eg-1-00001-of-00002.gguf")
  }

  // MARK: - Not-serving state decision (#2109)

  /// Write a prior-revision admission marker recording files that EXIST, which
  /// is what `supersededInstallSurvives` requires: a marker alone proves an
  /// install once completed, never that its bytes survive.
  private static func seedSurvivingOlderRevision(
    _ registration: DeliveryRegistration
  ) throws {
    let identity = registration.manifest.identity
    let older = "\(identity.family.rawValue)-\(identity.name)-v1-legacy-\(identity.variant)"
    let fileName = "eg-1-v1-legacy.gguf"

    try FileManager.default.createDirectory(
      at: registration.installDirectory, withIntermediateDirectories: true)
    let installed = registration.installDirectory.appendingPathComponent(fileName)
    try Data([0xAB, 0xCD]).write(to: installed)

    let attrs = try FileManager.default.attributesOfItem(atPath: installed.path)
    let marker: [String: Any] = [
      "manifestDigest": "older-revision-digest",
      "admittedAt": 0,
      "files": [
        [
          "path": fileName,
          "sizeBytes": attrs[.size] as? Int64 ?? 2,
          "mtime": (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ]
      ],
    ]
    try FileManager.default.createDirectory(
      at: registration.metadataDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: marker).write(
      to: registration.metadataDirectory.appendingPathComponent("\(older).admission.json"))
  }

  private static func seedStagedPartials(_ registration: DeliveryRegistration) throws {
    let staging = ModelDeliveryController.stagingDirectoryURL(for: registration)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data([0x01, 0x02, 0x03]).write(to: staging.appendingPathComponent("partial.bin"))
  }

  /// The four-way decision that determines what a user actually sees. All four
  /// arms are asserted TOGETHER, because each one is the other three's control:
  /// a stub returning any single value would pass one row and fail the rest.
  ///
  /// The `notInstalled` row is the one that used to swallow the other two —
  /// before #2109 every not-serving case rendered identically to a user who
  /// had never installed EG-1 at all.
  @Test func notServingStateSeparatesTheFourDiskSituations() throws {
    // 1. Nothing on disk: a genuine first-time user.
    let cold = try makeTempDirs()
    defer { cold.cleanup() }
    let coldReg = try Self.shardedFixtureRegistration(
      install: cold.install, metadata: cold.metadata)
    #expect(EGOneDeliveryAdapter.notServingState(for: coldReg, version: "1.1") == .notInstalled)

    // 2. Partials only: an interrupted FIRST install. Resume, not a failure.
    let interrupted = try makeTempDirs()
    defer { interrupted.cleanup() }
    let interruptedReg = try Self.shardedFixtureRegistration(
      install: interrupted.install, metadata: interrupted.metadata)
    try Self.seedStagedPartials(interruptedReg)
    #expect(EGOneDeliveryAdapter.notServingState(for: interruptedReg, version: "1.1") == .paused)

    // 3. A surviving older revision, upgrade not started: cleanup is off and
    //    the user has never pressed anything.
    let owed = try makeTempDirs()
    defer { owed.cleanup() }
    let owedReg = try Self.shardedFixtureRegistration(
      install: owed.install, metadata: owed.metadata)
    try Self.seedSurvivingOlderRevision(owedReg)
    #expect(EGOneDeliveryAdapter.notServingState(for: owedReg, version: "1.1") == .updatePaused(resumable: false, targetVersion: "1.1"))

    // 4. A surviving older revision AND partials: they started the upgrade and
    //    stopped. This is the Resume-upgrade row.
    let started = try makeTempDirs()
    defer { started.cleanup() }
    let startedReg = try Self.shardedFixtureRegistration(
      install: started.install, metadata: started.metadata)
    try Self.seedSurvivingOlderRevision(startedReg)
    try Self.seedStagedPartials(startedReg)
    #expect(EGOneDeliveryAdapter.notServingState(for: startedReg, version: "1.1") == .updatePaused(resumable: true, targetVersion: "1.1"))
  }

  /// A cancel is a DECISION, not a failure. It used to map to
  /// `.failed(.cancelled)`, which painted a red row with a Try Again button
  /// for something the user chose deliberately.
  @Test func cancelNoLongerMapsToAFailure() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try Self.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    try Self.seedStagedPartials(registration)

    let mapped = EGOneDeliveryAdapter.map(
      .cancelled(resumable: true), version: "1.1", registration: registration)
    #expect(mapped == .paused)

    // Two-way control: a REAL failure must still be a failure. If cancel and
    // failure both became paused, the red row would be unreachable.
    let failed = EGOneDeliveryAdapter.map(
      .failed(DeliveryFailure(reason: .sourceUnreachable)), version: "1.1",
      registration: registration)
    #expect(failed == .failed(.network))
  }

  /// The display version reaches the installed state verbatim, and nil stays
  /// nil rather than becoming a placeholder.
  @Test func installedCarriesTheDisplayVersionOrNothing() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try Self.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)

    #expect(
      EGOneDeliveryAdapter.map(.admitted, version: "1.1", registration: registration)
        == .installed(version: "1.1"))
    #expect(
      EGOneDeliveryAdapter.map(.admitted, version: nil, registration: registration)
        == .installed(version: nil))
  }

  @Test func failureClassBucketsMatchExistingCopy() {
    #expect(EGOneDeliveryAdapter.mapFailure(.sourceUnreachable) == .network)
    #expect(EGOneDeliveryAdapter.mapFailure(.sourceTimeout) == .network)
    #expect(EGOneDeliveryAdapter.mapFailure(.source4xx) == .http)
    #expect(EGOneDeliveryAdapter.mapFailure(.source5xx) == .http)
    #expect(EGOneDeliveryAdapter.mapFailure(.integrityMismatch) == .checksum)
    #expect(EGOneDeliveryAdapter.mapFailure(.cacheRepairFailed) == .checksum)
    #expect(EGOneDeliveryAdapter.mapFailure(.insufficientDisk) == .disk)
    #expect(EGOneDeliveryAdapter.mapFailure(.cancelled) == .cancelled)
    #expect(EGOneDeliveryAdapter.mapFailure(.permissionDenied) == .http)
    #expect(EGOneDeliveryAdapter.mapFailure(.unknown) == .http)
  }
}

/// Integration of the adapter's decline/admission hooks with the REAL
/// coordinator and REAL controller (#1386 PR-1): Cancel/Remove persist the
/// user's decline into the owed marker before any controller work, and
/// admission through any door clears it. Tiny fixture manifest, zero network.
@Suite struct EGOneLegacyUpgradeIntegrationTests {
  private struct Harness {
    let root: URL
    let store: UserDefaults
    let suite: String
    let adapter: EGOneDeliveryAdapter
    let coordinator: EGOneUpgradeCoordinator
    let controller: ModelDeliveryController
    let registration: DeliveryRegistration
    let events: EventBox

    func cleanup() {
      store.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  @MainActor
  final class EventBox {
    var events: [EGOneUpgradeCoordinator.Event] = []
  }

  private func markerURL(_ root: URL) -> URL {
    root.appendingPathComponent("EnviousWispr/ModelDelivery/eg1-v1-replacement-owed")
  }

  @MainActor
  private func makeHarness() throws -> Harness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-integration-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("EnviousWispr/Models/eg-1", isDirectory: true)
    let metadata = root.appendingPathComponent("EnviousWispr/ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

    let suite = "eg1-integration-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))

    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)
    // The actor gets its OWN suite instance (region-moved), never the test
    // body's — the ModelDeliveryControllerTests isolation pattern.
    let controller = ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!)
    let adapter = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: "v2-sharded",
      defaults: store)
    let coordinator = EGOneUpgradeCoordinator(
      adapter: adapter, appSupportDirectory: root,
      identity: registration.manifest.identity,
      installDirectory: registration.installDirectory,
      isOnboardingComplete: { true },
      defaults: store)
    let events = EventBox()
    coordinator.onEvent = { [events] event in
      events.events.append(event)
    }
    return Harness(
      root: root, store: store, suite: suite, adapter: adapter,
      coordinator: coordinator, controller: controller, registration: registration,
      events: events)
  }

  private func stageMarker(_ root: URL) throws {
    let url = markerURL(root)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
  }

  /// Stage byte-valid shard files so `admitIfComplete` can admit offline.
  private func stageValidShards(_ registration: DeliveryRegistration) throws {
    try Data(count: 1000).write(
      to: registration.installDirectory.appendingPathComponent("eg-1-00001-of-00002.gguf"))
    try Data(count: 2000).write(
      to: registration.installDirectory.appendingPathComponent("eg-1-00002-of-00002.gguf"))
  }

  @MainActor
  @Test func cancelClearsMarkerBeforeControllerCancel() async throws {
    let h = try makeHarness()
    defer { h.cleanup() }
    try stageMarker(h.root)

    await h.adapter.cancel()

    #expect(!FileManager.default.fileExists(atPath: markerURL(h.root).path))
    #expect(h.events.events == [.replacementDeclined])
  }

  @MainActor
  @Test func cancelWhileKillSwitchOffClearsOwedMarkerAndDoesNotResume() async throws {
    let h = try makeHarness()
    defer { h.cleanup() }
    try stageMarker(h.root)

    h.store.set(false, forKey: DeliveryFlags.key("enabled", family: .egOne))
    await h.adapter.cancel()

    #expect(
      !FileManager.default.fileExists(atPath: markerURL(h.root).path),
      "contract §5c.10: the switch never silences an explicit decline")
    #expect(h.events.events == [.replacementDeclined])

    // Switch back on: the launch table finds no marker and starts nothing.
    h.store.set(true, forKey: DeliveryFlags.key("enabled", family: .egOne))
    await h.coordinator.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: markerURL(h.root).path))
    #expect(await h.controller.isAdmitted(h.registration) == false)
    #expect(
      h.events.events == [.replacementDeclined],
      "no detection, retirement, or completion after the decline")
  }

  @MainActor
  @Test func cancelLosingAdmissionRaceLeavesAdmittedModelInstalledAndMarkerCleared()
    async throws
  {
    let h = try makeHarness()
    defer { h.cleanup() }
    try stageMarker(h.root)
    try stageValidShards(h.registration)

    // Admission wins the race first...
    #expect(await h.adapter.adoptIfPresent())
    #expect(!FileManager.default.fileExists(atPath: markerURL(h.root).path))

    // ...then the user's Cancel lands late. The verified model stays.
    await h.adapter.cancel()

    #expect(await h.controller.isAdmitted(h.registration))
    #expect(!FileManager.default.fileExists(atPath: markerURL(h.root).path))
  }

  @MainActor
  @Test func removeClearsMarkerBeforeControllerRemoval() async throws {
    let h = try makeHarness()
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    #expect(await h.adapter.adoptIfPresent())
    try stageMarker(h.root)

    let outcome = await h.adapter.remove()

    #expect(outcome == .removed)
    #expect(!FileManager.default.fileExists(atPath: markerURL(h.root).path))
    #expect(await h.controller.isAdmitted(h.registration) == false)
    #expect(h.events.events.contains(.replacementDeclined))
  }

  @MainActor
  @Test func manualDownloadAdmissionClearsMarker() async throws {
    // A user's own Try Again/adoption completing the replacement counts: the
    // marker clears through the same admission hook, no coordinator launch
    // pass required.
    let h = try makeHarness()
    defer { h.cleanup() }
    try stageMarker(h.root)
    try stageValidShards(h.registration)

    #expect(await h.adapter.adoptIfPresent())

    #expect(!FileManager.default.fileExists(atPath: markerURL(h.root).path))
    #expect(h.events.events.contains(.replacementCompleted))
  }
}
