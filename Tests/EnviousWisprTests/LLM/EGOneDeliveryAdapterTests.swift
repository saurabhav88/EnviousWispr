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

  @MainActor
  @Test func completeLegacyPartialIsPromotedNotDeleted() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try eg1Registration(install: dirs.install, metadata: dirs.metadata)
    let expectedSize = try #require(registration.manifest.files.first?.sizeBytes)
    // A completed-but-not-installed download: full-size .partial, no install
    // file. The .partial must REPORT the manifest's expected size (~2.9 GB) so
    // the migration's size-match promote branch fires — but as a SPARSE file
    // (truncate, no allocation) so the test never materializes gigabytes of RAM
    // or disk on CI (cloud-review P1). The migration promotes via rename (O(1)),
    // never a byte copy, so a sparse source is faithful.
    let partial = dirs.install.appendingPathComponent("eg-1-v1.gguf.partial")
    let resume = dirs.install.appendingPathComponent("eg-1-v1.gguf.resume.json")
    #expect(FileManager.default.createFile(atPath: partial.path, contents: nil))
    let handle = try FileHandle(forWritingTo: partial)
    try handle.truncate(atOffset: UInt64(expectedSize))
    try handle.close()
    try Data("{}".utf8).write(to: resume)

    _ = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v1")

    let fm = FileManager.default
    // Promoted to the install name (so adoption can verify + admit offline).
    #expect(fm.fileExists(atPath: dirs.install.appendingPathComponent("eg-1-v1.gguf").path))
    #expect(!fm.fileExists(atPath: partial.path))
    #expect(!fm.fileExists(atPath: resume.path), "stale resume sidecar removed")
  }

  @MainActor
  @Test func incompleteLegacyPartialIsReclaimed() throws {
    let dirs = try makeTempDirs()
    defer { dirs.cleanup() }
    let registration = try eg1Registration(install: dirs.install, metadata: dirs.metadata)
    // An interrupted download: short .partial, no install file.
    let partial = dirs.install.appendingPathComponent("eg-1-v1.gguf.partial")
    try Data(count: 4096).write(to: partial)

    _ = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(), registration: registration, version: "v1")

    let fm = FileManager.default
    // Reclaimed (no partial install file left behind); no bogus install created.
    #expect(!fm.fileExists(atPath: partial.path))
    #expect(!fm.fileExists(atPath: dirs.install.appendingPathComponent("eg-1-v1.gguf").path))
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
