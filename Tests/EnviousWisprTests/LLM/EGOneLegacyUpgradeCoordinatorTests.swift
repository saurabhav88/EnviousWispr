import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The one-time EG-1 monolith retirement (#1386 PR-1): exact-fingerprint
/// recognition, the owed marker's lifecycle (born once, cleared only by
/// admission or explicit decline), the containment gate, and crash recovery
/// from disk truth alone. Every destructive path is proven against its
/// negative twin: same-size wrong bytes, renamed files, symlinked stores.
@Suite struct EGOneLegacyUpgradeCoordinatorTests {
  @MainActor
  private final class Probe {
    var admitted = false
    var ensureCount = 0
    var ensureOutcome: ModelDeliveryController.DeliveryOutcome =
      .failed(DeliveryFailure(reason: .sourceUnreachable))
    var markerExistedAtDelete = false
    var hashCount = 0
    var events: [EGOneLegacyUpgradeCoordinator.Event] = []
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-legacy-upgrade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true)
    return root
  }

  private func oldStore(_ root: URL) -> URL {
    root.appendingPathComponent("EnviousWispr/PolishModels", isDirectory: true)
  }

  private func marker(_ root: URL) -> URL {
    root.appendingPathComponent("EnviousWispr/ModelDelivery/eg1-v1-replacement-owed")
  }

  private func defaults() throws -> (UserDefaults, String) {
    let suite = "eg1-legacy-test-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  @discardableResult
  private func stageLegacy(
    root: URL,
    name: String = "eg-1-v1.gguf",
    bytes: Data
  ) throws -> URL {
    let directory = oldStore(root)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
  }

  private func stageMarker(_ root: URL) throws {
    let url = marker(root)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
  }

  @MainActor
  private func coordinator(
    root: URL,
    defaults: UserDefaults,
    bytes: Data,
    probe: Probe,
    writeMarker: (@MainActor @Sendable (URL) -> Bool)? = nil,
    removeItem: (@MainActor @Sendable (URL) throws -> Void)? = nil,
    hashError: Bool = false
  ) -> EGOneLegacyUpgradeCoordinator {
    let subject = EGOneLegacyUpgradeCoordinator(
      appSupportDirectory: root,
      defaults: defaults,
      trustedArtifact: .init(
        name: "eg-1-v1.gguf",
        sizeBytes: Int64(bytes.count),
        sha256: digest(bytes)
      ),
      ensureCurrentModel: {
        probe.ensureCount += 1
        return probe.ensureOutcome
      },
      currentModelIsAdmitted: {
        probe.admitted
      },
      hashFile: { url in
        await MainActor.run { probe.hashCount += 1 }
        if hashError { throw CocoaError(.fileReadUnknown) }
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined()
      },
      writeMarker: writeMarker,
      removeItem: removeItem
    )
    subject.onEvent = { event in
      probe.events.append(event)
    }
    return subject
  }

  // MARK: - Retirement happy path and its failure twins

  @MainActor
  @Test func matchingMonolithWritesMarkerBeforeDeleteAndStartsReplacement() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted-legacy".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    let markerURL = marker(root)

    let subject = coordinator(
      root: root,
      defaults: store,
      bytes: bytes,
      probe: probe,
      removeItem: { url in
        if url == artifact {
          probe.markerExistedAtDelete =
            FileManager.default.fileExists(atPath: markerURL.path)
        }
        try FileManager.default.removeItem(at: url)
      }
    )

    await subject.runLaunch()

    #expect(probe.markerExistedAtDelete, "marker persistence precedes unlink")
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(FileManager.default.fileExists(atPath: markerURL.path))
    #expect(probe.ensureCount == 1)
    #expect(probe.events == [.legacyDetected, .legacyRetired])
  }

  @MainActor
  @Test func markerWriteFailurePreservesMonolithAndBlocksDownload() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted-legacy".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()

    let subject = coordinator(
      root: root,
      defaults: store,
      bytes: bytes,
      probe: probe,
      writeMarker: { _ in false }
    )

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: artifact.path))
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
    #expect(probe.events.contains(.legacyRetirementFailed(reason: .markerWrite)))
  }

  @MainActor
  @Test func matchingMonolithDeleteFailureKeepsMarkerAndBlocksDownload() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    struct Denied: Error {}

    let bytes = Data("trusted-legacy".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()

    let subject = coordinator(
      root: root,
      defaults: store,
      bytes: bytes,
      probe: probe,
      removeItem: { url in
        if url == artifact { throw Denied() }
        try FileManager.default.removeItem(at: url)
      }
    )

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: artifact.path))
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
    #expect(probe.events.contains(.legacyRetirementFailed(reason: .delete)))
  }

  // MARK: - Fingerprint negative controls

  @MainActor
  @Test func sameSizeWrongBytesAreUntouched() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let trusted = Data("trusted".utf8)
    let wrong = Data("strange".utf8)
    #expect(trusted.count == wrong.count)

    let artifact = try stageLegacy(root: root, bytes: wrong)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: trusted, probe: probe)

    await subject.runLaunch()

    #expect(try Data(contentsOf: artifact) == wrong)
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
    #expect(probe.events.isEmpty)
  }

  @MainActor
  @Test func correctBytesUnderRenamedFileAreUntouched() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let renamed = try stageLegacy(
      root: root, name: "renamed-eg-1.gguf", bytes: bytes)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: renamed.path))
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
  }

  @MainActor
  @Test func absentMonolithDoesNotCreateMarkerOrAutoDownload() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
    #expect(probe.hashCount == 0)
    #expect(probe.events.isEmpty)
  }

  @MainActor
  @Test func unreadableMonolithIsPreservedAndDoesNotBlockManualDownload() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: bytes, probe: probe, hashError: true)

    let prepared = await subject.prepareForDownload()

    #expect(prepared, "an unclassifiable file must not brick manual downloads")
    #expect(FileManager.default.fileExists(atPath: artifact.path))
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.events.contains(.legacyRetirementFailed(reason: .unreadable)))
  }

  // MARK: - Marker lifecycle and crash recovery (disk truth alone)

  @MainActor
  @Test func markerWithoutMonolithResumesReplacement() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 1)
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
  }

  @MainActor
  @Test func failedReplacementKeepsMarker() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 1)
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
    #expect(!probe.events.contains(.replacementCompleted))
  }

  @MainActor
  @Test func admittedReplacementClearsMarker() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    probe.admitted = true
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
    #expect(probe.events.contains(.replacementCompleted))
  }

  @MainActor
  @Test func missedAdmissionClearIsRepairedAtLaunch() async throws {
    // A prior session admitted the shards but quit before clearing the marker.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    probe.admitted = true
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.events == [.replacementCompleted])
  }

  @MainActor
  @Test func crashRecoveryBeforeMarker() async throws {
    // Crash before the marker write: disk shows only the monolith, and a fresh
    // launch simply retries the whole classification.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 1)
  }

  @MainActor
  @Test func crashRecoveryAfterMarkerBeforeDelete() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    try stageMarker(root)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 1)
  }

  @MainActor
  @Test func crashRecoveryAfterDeleteBeforeEnsure() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 1)
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
  }

  @MainActor
  @Test func crashRecoveryMidDownload() async throws {
    // The controller owns staged-byte resume; the coordinator's whole job on
    // relaunch is to call the same ensure door again.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 1)
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
  }

  @MainActor
  @Test func crashRecoveryAfterAdmissionBeforeClear() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    probe.admitted = true
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 0)
  }

  @MainActor
  @Test func admittedReplacementStillRetiresReintroducedExactMonolith() async throws {
    // An old production build re-downloaded the monolith after the shards were
    // already admitted. Launch must still classify and retire it.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    probe.admitted = true
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(
      !FileManager.default.fileExists(atPath: marker(root).path),
      "admission immediately settles the freshly written marker")
    #expect(probe.ensureCount == 0)
    #expect(probe.events.contains(.legacyRetired))
  }

  @MainActor
  @Test func markerPlusChangedMonolithPreservesUnknownBytesButContinuesReplacement()
    async throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let trusted = Data("trusted".utf8)
    let changed = Data("strange".utf8)
    let artifact = try stageLegacy(root: root, bytes: changed)
    try stageMarker(root)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: trusted, probe: probe)

    await subject.runLaunch()

    #expect(try Data(contentsOf: artifact) == changed)
    #expect(probe.ensureCount == 1)
  }

  // MARK: - Kill switch

  @MainActor
  @Test func killSwitchOffPerformsNoHashWriteDeleteOrEnsure() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    store.set(false, forKey: DeliveryFlags.key("enabled", family: .egOne))

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: artifact.path))
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.hashCount == 0)
    #expect(probe.ensureCount == 0)
    #expect(probe.events.isEmpty)
  }

  @MainActor
  @Test func killSwitchBackOnResumesClassification() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    store.set(false, forKey: DeliveryFlags.key("enabled", family: .egOne))

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)
    await subject.runLaunch()
    #expect(FileManager.default.fileExists(atPath: artifact.path))

    store.set(true, forKey: DeliveryFlags.key("enabled", family: .egOne))
    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.ensureCount == 1)
  }

  // MARK: - Retired-store sidecars

  @MainActor
  @Test func exactRetiredSidecarsAreSweptButLookalikesRemain() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let directory = oldStore(root)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let exactPartial = directory.appendingPathComponent("eg-1-v1.gguf.partial")
    let exactResume = directory.appendingPathComponent("eg-1-v1.gguf.resume.json")
    let lookalike = directory.appendingPathComponent("eg-1-v1.gguf.partial.bak")
    let foreign = directory.appendingPathComponent("other.partial")
    for url in [exactPartial, exactResume, lookalike, foreign] {
      try Data("x".utf8).write(to: url)
    }

    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    _ = await subject.prepareForDownload()

    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: exactPartial.path))
    #expect(!fm.fileExists(atPath: exactResume.path))
    #expect(fm.fileExists(atPath: lookalike.path))
    #expect(fm.fileExists(atPath: foreign.path))
  }

  @MainActor
  @Test func installedManifestIsRemovedOnlyAfterOwnershipProof() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let trusted = Data("trusted".utf8)
    let wrong = Data("strange".utf8)
    let directory = oldStore(root)
    let installedManifest = directory.appendingPathComponent("installed-manifest.json")

    // Unproven: wrong bytes under the exact name. The retired store's own
    // metadata must survive alongside the unrecognized file.
    try stageLegacy(root: root, bytes: wrong)
    try Data("{}".utf8).write(to: installedManifest)

    let probe = Probe()
    let unproven = coordinator(root: root, defaults: store, bytes: trusted, probe: probe)
    await unproven.runLaunch()
    #expect(FileManager.default.fileExists(atPath: installedManifest.path))

    // Proven: exact bytes. Retirement takes the metadata with it.
    try stageLegacy(root: root, bytes: trusted)
    let proven = coordinator(root: root, defaults: store, bytes: trusted, probe: probe)
    await proven.runLaunch()
    #expect(!FileManager.default.fileExists(atPath: installedManifest.path))
  }

  // MARK: - Single-flight preparation

  @MainActor
  @Test func concurrentPrepareCallsJoinOneFingerprint() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    async let first = subject.prepareForDownload()
    async let second = subject.prepareForDownload()
    let results = await [first, second]

    #expect(results == [true, true])
    #expect(probe.hashCount == 1, "both callers join one fingerprint pass")
  }

  // MARK: - Containment gate

  @MainActor
  @Test func normalOldStorePassesContainmentGate() async throws {
    // The /var -> /private/var regression oracle: the test root itself sits
    // behind a system symlink, so a naive unresolved-prefix comparison would
    // false-refuse this store and silently kill state C for every normal Mac.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)
    let artifact = try stageLegacy(root: root, bytes: bytes)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(!FileManager.default.fileExists(atPath: artifact.path), "retirement ran")
    #expect(
      !probe.events.contains(.legacyRetirementFailed(reason: .containment)),
      "a normal store must never trip the containment gate")
  }

  @MainActor
  @Test func symlinkedPolishModelsDirectoryIsUntouched() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)

    // The trusted artifact lives in an EXTERNAL directory; PolishModels is a
    // symlink pointing at it.
    let external = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-external-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: external) }
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let externalArtifact = external.appendingPathComponent("eg-1-v1.gguf")
    try bytes.write(to: externalArtifact)

    let enviousTree = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    try FileManager.default.createDirectory(at: enviousTree, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: enviousTree.appendingPathComponent("PolishModels"),
      withDestinationURL: external)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: externalArtifact.path))
    #expect(probe.ensureCount == 0)
    #expect(probe.hashCount == 0)
    #expect(probe.events.contains(.legacyRetirementFailed(reason: .containment)))
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
  }

  @MainActor
  @Test func legacyArtifactEscapingAppSupportIsUntouched() async throws {
    // The EnviousWispr component itself is a symlink to an external tree.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let bytes = Data("trusted".utf8)

    let external = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-external-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: external) }
    let externalStore = external.appendingPathComponent("PolishModels", isDirectory: true)
    try FileManager.default.createDirectory(
      at: externalStore, withIntermediateDirectories: true)
    let externalArtifact = externalStore.appendingPathComponent("eg-1-v1.gguf")
    try bytes.write(to: externalArtifact)

    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("EnviousWispr"),
      withDestinationURL: external)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, bytes: bytes, probe: probe)

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: externalArtifact.path))
    #expect(probe.ensureCount == 0)
    #expect(probe.events.contains(.legacyRetirementFailed(reason: .containment)))
  }

  @MainActor
  @Test func sidecarsBehindSymlinkedOldStoreAreUntouched() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let external = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-external-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: external) }
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let partial = external.appendingPathComponent("eg-1-v1.gguf.partial")
    let resume = external.appendingPathComponent("eg-1-v1.gguf.resume.json")
    let partialBytes = Data("partial-bytes".utf8)
    let resumeBytes = Data("{}".utf8)
    try partialBytes.write(to: partial)
    try resumeBytes.write(to: resume)

    let enviousTree = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    try FileManager.default.createDirectory(at: enviousTree, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: enviousTree.appendingPathComponent("PolishModels"),
      withDestinationURL: external)

    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    _ = await subject.prepareForDownload()

    #expect(try Data(contentsOf: partial) == partialBytes)
    #expect(try Data(contentsOf: resume) == resumeBytes)
    #expect(probe.events.contains(.legacyRetirementFailed(reason: .containment)))
  }

  // MARK: - Decline

  @MainActor
  @Test func recordUserDeclineClearsMarkerAndEmitsOnce() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    #expect(subject.recordUserDecline())
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.events == [.replacementDeclined])

    // Idempotent: a second decline with no marker succeeds and stays silent.
    #expect(subject.recordUserDecline())
    #expect(probe.events == [.replacementDeclined])
  }

  @MainActor
  @Test func declineWhileKillSwitchOffStillClearsMarker() async throws {
    // Contract §5c.10: the switch guards model bytes, never the user's
    // recorded decision.
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stageMarker(root)
    store.set(false, forKey: DeliveryFlags.key("enabled", family: .egOne))

    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, bytes: Data("trusted".utf8), probe: probe)

    #expect(subject.recordUserDecline())
    #expect(!FileManager.default.fileExists(atPath: marker(root).path))
    #expect(probe.events == [.replacementDeclined])
  }
}
