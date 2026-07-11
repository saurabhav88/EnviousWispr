import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The EG-1 limb adapter's pure mapping: every delivery state/failure resolves
/// to an EG-1 UI vocabulary value, and EVERY `DeliveryFailureClass` maps to a
/// retry-able RED (the limb never blocks dictation — #1363 §7).
@Suite struct EGOneDeliveryAdapterMappingTests {
  @Test func deliveryStateMapsToInstallState() {
    #expect(EGOneDeliveryAdapter.map(.notReady, version: "v1") == .notInstalled)
    #expect(
      EGOneDeliveryAdapter.map(.preparing(validatingExistingCache: true), version: "v1")
        == .verifying)
    #expect(
      EGOneDeliveryAdapter.map(
        .downloading(fractionCompleted: 0.5, bytesWritten: 5, totalBytes: 10), version: "v1")
        == .downloading(fractionCompleted: 0.5))
    #expect(EGOneDeliveryAdapter.map(.verifying, version: "v1") == .verifying)
    #expect(EGOneDeliveryAdapter.map(.admitted, version: "v1") == .installed(version: "v1"))
    #expect(
      EGOneDeliveryAdapter.map(.cancelled(resumable: true), version: "v1") == .failed(.cancelled))
  }

  @Test func everyFailureClassMapsToARetryableInstallFailure() {
    let all: [DeliveryFailureClass] = [
      .sourceUnreachable, .sourceTimeout, .source5xx, .source4xx, .integrityMismatch,
      .insufficientDisk, .permissionDenied, .cacheRepairFailed, .cancelled, .unknown,
    ]
    for reason in all {
      let mapped = EGOneDeliveryAdapter.map(
        .failed(DeliveryFailure(reason: reason)), version: "v1")
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
    let coordinator: EGOneLegacyUpgradeCoordinator
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
    var events: [EGOneLegacyUpgradeCoordinator.Event] = []
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
    let coordinator = EGOneLegacyUpgradeCoordinator(
      adapter: adapter, appSupportDirectory: root, defaults: store)
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
