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

  // MARK: - Legacy store partial migration (cloud-review P2, PR #1384)

  private func makeTempDirs() throws -> (install: URL, metadata: URL, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-migrate-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("PolishModels", isDirectory: true)
    let metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    return (install, metadata, { try? FileManager.default.removeItem(at: root) })
  }

  /// Build the shipped EG-1 delivery manifest so the adapter's install name +
  /// expected size are real (`eg-1-v1.gguf`, 2_889_511_680).
  private func eg1Registration(install: URL, metadata: URL) throws -> DeliveryRegistration {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/EnviousWispr/Resources/eg1-delivery-manifest.json")
    let manifest = try DeliveryManifest.load(from: Data(contentsOf: url))
    return DeliveryRegistration(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
  }

  /// A synthetic componentSet manifest (2 shards + `entrypointFile`),
  /// independent of the real shipped manifest (still single-file until the
  /// shard-authoring step, #1417 §3.5) — proves `installedArtifactURL` and
  /// `migrateLegacyStoreArtifacts`'s size check against an ACTUALLY sharded
  /// manifest, not just the current single-file one.
  private func shardedFixtureRegistration(install: URL, metadata: URL) throws
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
    let registration = try shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v2-sharded")
    #expect(adapter.installedArtifactURL.lastPathComponent == "eg-1-00001-of-00002.gguf")
  }

  @MainActor
  @Test func migrateLegacyStoreArtifactsSizeCheckUsesEntrypointSizeNotSum() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    let entrypointPath = try #require(registration.manifest.resolvedEntrypointPath)
    // Entrypoint shard (shard 1) is 1000 bytes; shard 2 is 2000; sum is 3000.
    // A `.partial` sized to the SUM would be wrong — it can only ever contain
    // shard 1's own bytes. Size it to 1000 (shard 1's own size) and confirm
    // the migration recognizes it as complete and promotes.
    let partial = dirs.install.appendingPathComponent("\(entrypointPath).partial")
    #expect(FileManager.default.createFile(atPath: partial.path, contents: nil))
    let handle = try FileHandle(forWritingTo: partial)
    try handle.truncate(atOffset: 1000)
    try handle.close()

    _ = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v2-sharded")

    #expect(
      FileManager.default.fileExists(
        atPath: dirs.install.appendingPathComponent(entrypointPath).path),
      "the entrypoint-sized (not sum-sized) partial was promoted")
    #expect(!FileManager.default.fileExists(atPath: partial.path))
  }

  @MainActor
  @Test func completeLegacyPartialIsPromotedNotDeleted() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try eg1Registration(install: dirs.install, metadata: dirs.metadata)
    // #1417: derive the expected install name and size from
    // `resolvedEntrypointPath` — never a hardcoded legacy literal — so this
    // test stays correct once the shipped manifest becomes N shards (the
    // entrypoint's own name/size then, same as today's single file now).
    let entrypointPath = try #require(registration.manifest.resolvedEntrypointPath)
    let expectedSize = try #require(
      registration.manifest.files.first(where: { $0.resolvedInstallPath == entrypointPath })?
        .sizeBytes)
    // A completed-but-not-installed download: full-size .partial, no install
    // file. The .partial must REPORT the manifest's expected size (~2.9 GB) so
    // the migration's size-match promote branch fires — but as a SPARSE file
    // (truncate, no allocation) so the test never materializes gigabytes of RAM
    // or disk on CI (cloud-review P1). The migration promotes via rename (O(1)),
    // never a byte copy, so a sparse source is faithful.
    let partial = dirs.install.appendingPathComponent("\(entrypointPath).partial")
    let resume = dirs.install.appendingPathComponent("\(entrypointPath).resume.json")
    #expect(FileManager.default.createFile(atPath: partial.path, contents: nil))
    let handle = try FileHandle(forWritingTo: partial)
    try handle.truncate(atOffset: UInt64(expectedSize))
    try handle.close()
    try Data("{}".utf8).write(to: resume)

    _ = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v1")

    let fm = FileManager.default
    // Promoted to the install name (so adoption can verify + admit offline).
    #expect(fm.fileExists(atPath: dirs.install.appendingPathComponent(entrypointPath).path))
    #expect(!fm.fileExists(atPath: partial.path))
    #expect(!fm.fileExists(atPath: resume.path), "stale resume sidecar removed")
  }

  @MainActor
  @Test func incompleteLegacyPartialIsReclaimed() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try eg1Registration(install: dirs.install, metadata: dirs.metadata)
    let entrypointPath = try #require(registration.manifest.resolvedEntrypointPath)
    // An interrupted download: short .partial, no install file.
    let partial = dirs.install.appendingPathComponent("\(entrypointPath).partial")
    try Data(count: 4096).write(to: partial)

    _ = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v1")

    let fm = FileManager.default
    // Reclaimed (no partial install file left behind); no bogus install created.
    #expect(!fm.fileExists(atPath: partial.path))
    #expect(!fm.fileExists(atPath: dirs.install.appendingPathComponent(entrypointPath).path))
  }

  @MainActor
  @Test func staleOtherVersionSidecarsSweptButModelsKept() throws {
    // Cloud-review P2 (#1363): a version bump (e.g. EG-2/EG-3 hot-swap) must not
    // orphan an OLD version's download sidecars forever. The migration sweeps
    // every .partial/.resume.json in the install dir regardless of version, but
    // NEVER deletes a completed .gguf model (a superseded model is the user's
    // working polish until the new one downloads; the founder's real install must
    // survive).
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try eg1Registration(install: dirs.install, metadata: dirs.metadata)
    let fm = FileManager.default
    // An interrupted download from a DIFFERENT version + a completed model of
    // that older version (neither matches the current manifest's v1 name).
    let staleModel = dirs.install.appendingPathComponent("eg-1-v0.gguf")
    let stalePartial = dirs.install.appendingPathComponent("eg-1-v0.gguf.partial")
    let staleResume = dirs.install.appendingPathComponent("eg-1-v0.gguf.resume.json")
    try Data("old-model-bytes".utf8).write(to: staleModel)
    try Data(count: 4096).write(to: stalePartial)
    try Data("{}".utf8).write(to: staleResume)

    _ = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v1")

    #expect(!fm.fileExists(atPath: stalePartial.path), "stale partial swept (any version)")
    #expect(!fm.fileExists(atPath: staleResume.path), "stale resume sidecar swept (any version)")
    #expect(
      fm.fileExists(atPath: staleModel.path),
      "a completed .gguf model is never deleted by migration")
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

  /// The kill switch is the operational rollback control: with it off, NOTHING may
  /// mutate model bytes. #1386's relocation runs before every other delivery call,
  /// so the composition root has to be able to read the flag BEFORE it starts —
  /// otherwise the migrator would move and delete files precisely when someone had
  /// reached for the lever to stop exactly that. (Codex PR-1 review r8.)
  @Test func killSwitchIsReadableBeforeAnyRelocationRuns() throws {
    let suite = "eg1-killswitch-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = DeliveryFlags.key("enabled", family: .egOne)

    // Default (unset) is enabled — a fresh install migrates.
    #expect(EGOneDeliveryAdapter.isDeliveryEnabled(defaults: defaults))

    defaults.set(false, forKey: key)
    #expect(
      EGOneDeliveryAdapter.isDeliveryEnabled(defaults: defaults) == false,
      "with delivery disabled the relocation must not run at all")

    defaults.set(true, forKey: key)
    #expect(EGOneDeliveryAdapter.isDeliveryEnabled(defaults: defaults))
  }
}
