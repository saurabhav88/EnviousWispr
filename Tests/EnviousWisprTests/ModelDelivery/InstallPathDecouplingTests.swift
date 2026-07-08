import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

// MARK: - Decision F: fetch/install decoupling (schema v1.1, #1363)

/// Builds a manifest JSON where a file's fetch `path` and local `installPath`
/// may differ (the EG-1 shape). Reuses the canonical-digest computation so the
/// loaded manifest passes the trust-root check.
private enum InstallPathFixture {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// One-file manifest with an explicit `installPath` (nil ⇒ field omitted).
  static func json(
    path: String, installPath: String?, component: String, content: Data,
    extraFiles: [(path: String, installPath: String?, component: String, content: Data)] = [],
    entrypointFile: String? = nil, layout: String = "singleFile"
  ) throws -> Data {
    func fileObject(_ p: String, _ ip: String?, _ c: String, _ data: Data) -> [String: Any] {
      var obj: [String: Any] = [
        "path": p, "sizeBytes": data.count, "sha256": sha256(data), "component": c,
      ]
      if let ip { obj["installPath"] = ip }
      return obj
    }
    let all = [(path, installPath, component, content)] + extraFiles
    var admission: [String: Any] = [
      "layout": layout, "installLocation": "test",
      "diskHeadroomFactor": "2.2", "evictPreviousRevisions": false,
    ]
    if let entrypointFile { admission["entrypointFile"] = entrypointFile }
    let object: [String: Any] = [
      "schemaVersion": 1,
      "identity": [
        "family": "eg_one", "name": "eg-1", "revision": "v1", "variant": "q5km",
        "runtimeABI": "llamacpp-test",
      ],
      "files": all.map { fileObject($0.0, $0.1, $0.2, $0.3) },
      "optionalFiles": [] as [Any],
      "totalBytes": all.reduce(0) { $0 + $1.3.count },
      "sources": [["id": "our_copy", "baseURL": "https://mirror.invalid.example/eg1/"]],
      "admission": admission,
    ]
    let canonical = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    var withDigest = object
    withDigest["manifestDigest"] = sha256(canonical)
    return try JSONSerialization.data(withJSONObject: withDigest)
  }
}

@Suite struct InstallPathDecouplingTests {
  // (a) fetch uses `path`; every local op resolves to `installPath`.
  @Test func distinctPathAndInstallPathResolveIndependently() throws {
    let manifest = try DeliveryManifest.load(
      from: InstallPathFixture.json(
        path: "eg-1-v1-q5km.gguf", installPath: "eg-1-v1.gguf",
        component: "eg-1-v1.gguf", content: Data("model-bytes".utf8)))
    let file = try #require(manifest.files.first)
    #expect(file.path == "eg-1-v1-q5km.gguf")  // fetch key
    #expect(file.resolvedInstallPath == "eg-1-v1.gguf")  // local name
    // Orphan roots (a local concern) derive from the install name, never the
    // fetch key — else cleanup could delete the preserved file.
    #expect(CacheAdmission.componentRoots(of: manifest) == ["eg-1-v1.gguf"])
  }

  // MARK: - resolvedEntrypointPath (#1417, schema v1.2)

  // entrypointFile present ⇒ resolvedEntrypointPath resolves to that specific
  // file among N, not just `.first`.
  @Test func resolvedEntrypointPathHonorsExplicitEntrypoint() throws {
    let data = try InstallPathFixture.json(
      path: "eg-1-00001-of-00002.gguf", installPath: nil, component: "eg-1-00001-of-00002.gguf",
      content: Data("shard1".utf8),
      extraFiles: [
        ("eg-1-00002-of-00002.gguf", nil, "eg-1-00002-of-00002.gguf", Data("shard2".utf8))
      ],
      entrypointFile: "eg-1-00001-of-00002.gguf", layout: "componentSet")
    let manifest = try DeliveryManifest.load(from: data)
    #expect(manifest.resolvedEntrypointPath == "eg-1-00001-of-00002.gguf")
  }

  // entrypointFile ABSENT on a multi-file manifest ⇒ falls back to `.first`
  // (regression: the pre-#1417 behavior, now generalized to N files).
  @Test func resolvedEntrypointPathFallsBackToFirstWhenAbsent() throws {
    let data = try InstallPathFixture.json(
      path: "a.gguf", installPath: nil, component: "a.gguf", content: Data("a".utf8),
      extraFiles: [("b.gguf", nil, "b.gguf", Data("b".utf8))],
      layout: "componentSet")
    let manifest = try DeliveryManifest.load(from: data)
    #expect(manifest.resolvedEntrypointPath == "a.gguf")
  }

  // entrypointFile naming a non-existent files[] entry fails at manifest
  // validation (authoring/build time), never at runtime boot.
  @Test func entrypointFileNotMatchingAnyFileFailsValidation() throws {
    let data = try InstallPathFixture.json(
      path: "a.gguf", installPath: nil, component: "a.gguf", content: Data("a".utf8),
      entrypointFile: "does-not-exist.gguf", layout: "componentSet")
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: data) }
  }

  // (c) absent installPath ⇒ resolvedInstallPath == path (v1 back-compat).
  @Test func absentInstallPathDefaultsToPath() throws {
    let manifest = try DeliveryManifest.load(
      from: InstallPathFixture.json(
        path: "weights.bin", installPath: nil, component: "weights.bin",
        content: Data("w".utf8)))
    let file = try #require(manifest.files.first)
    #expect(file.installPath == nil)
    #expect(file.resolvedInstallPath == "weights.bin")
    #expect(CacheAdmission.componentRoots(of: manifest) == ["weights.bin"])
  }

  // (b) duplicate resolved install paths are a corrupt manifest (fail closed).
  @Test func duplicateResolvedInstallPathIsRefused() throws {
    // Two files with distinct fetch keys but the SAME install name → clobber.
    let data = try InstallPathFixture.json(
      path: "a-remote.gguf", installPath: "model.gguf", component: "model.gguf",
      content: Data("a".utf8),
      extraFiles: [("b-remote.gguf", "model.gguf", "model.gguf", Data("bb".utf8))])
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: data) }
  }

  // (b) component must equal the top segment of the resolved install path.
  @Test func componentRootMismatchIsRefused() throws {
    // Loose file installs as `eg-1-v1.gguf` but claims component `eg-1` →
    // promotion would move a staging/eg-1 that never exists.
    let data = try InstallPathFixture.json(
      path: "eg-1-v1-q5km.gguf", installPath: "eg-1-v1.gguf", component: "eg-1",
      content: Data("x".utf8))
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: data) }
  }

  // installPath traversal is rejected exactly like fetch-path traversal.
  @Test func unsafeInstallPathIsRefused() throws {
    let data = try InstallPathFixture.json(
      path: "ok.gguf", installPath: "../escape.gguf", component: "..",
      content: Data("x".utf8))
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: data) }
  }

  // (d) marker round-trip with a distinct install name: stage → promote →
  // isAdmitted() true, keyed by resolvedInstallPath on BOTH sides.
  @Test func markerRoundTripWithDistinctInstallName() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("installpath-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    let fm = FileManager.default
    for dir in [install, staging, metadata] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }

    let content = Data("eg1-model-bytes".utf8)
    let manifest = try DeliveryManifest.load(
      from: InstallPathFixture.json(
        path: "eg-1-v1-q5km.gguf", installPath: "eg-1-v1.gguf",
        component: "eg-1-v1.gguf", content: content))
    // Stage the file under the RESOLVED INSTALL name (what ManifestFetchTask
    // now does), then promote.
    try content.write(to: staging.appendingPathComponent("eg-1-v1.gguf"))
    let admission = CacheAdmission(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
    #expect(admission.isAdmitted() == false)
    try admission.promoteAndAdmit(
      stagedComponents: ["eg-1-v1.gguf"], stagingDirectory: staging, untouchedComponents: [])
    // The file landed at the install NAME, not the fetch key.
    #expect(fm.fileExists(atPath: install.appendingPathComponent("eg-1-v1.gguf").path))
    #expect(
      fm.fileExists(atPath: install.appendingPathComponent("eg-1-v1-q5km.gguf").path) == false)
    // Marker fast path admits (read side keys by resolvedInstallPath too).
    #expect(admission.isAdmitted())
  }

  // Migration adoption: an existing byte-correct file at the INSTALL name
  // validates in place (no fetch needed).
  @Test func existingInstallFileValidatesInPlace() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("adopt-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    let fm = FileManager.default
    for dir in [install, metadata] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }

    let content = Data("existing-user-model".utf8)
    let manifest = try DeliveryManifest.load(
      from: InstallPathFixture.json(
        path: "eg-1-v1-q5km.gguf", installPath: "eg-1-v1.gguf",
        component: "eg-1-v1.gguf", content: content))
    // Seed the existing user's file at the legacy LOCAL name.
    try content.write(to: install.appendingPathComponent("eg-1-v1.gguf"))
    let admission = CacheAdmission(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
    let result = await admission.validateExistingCache()
    #expect(result.verifiedComponents == ["eg-1-v1.gguf"])
    #expect(result.failedComponents.isEmpty)
  }
}

// MARK: - The shipped EG-1 delivery manifest (golden + agreement, #1363)

@Suite struct EGOneShippedDeliveryManifestTests {
  static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // ModelDelivery
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
  }

  static var deliveryManifestURL: URL {
    repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources/eg1-delivery-manifest.json")
  }
  static var runtimeManifestURL: URL {
    repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources/eg1-manifest.json")
  }

  // #1417: EG-1 shipped its sharded revision (v2-sharded, 8 componentSet
  // files) — golden digest updated to match. Recomputed via the real
  // DeliveryManifest.canonicalDigest algorithm against the authored manifest,
  // first cross-checked against the OLD single-file manifest's known-good
  // digest to prove the recompute technique was faithful before trusting it.
  static let goldenDigest = "07550d07e242aa660393f5e62d36106ed7916ffa8852d9fb66f5420854a6b70d"

  @Test func shippedDeliveryManifestLoadsAndMatchesGoldenDigest() throws {
    let data = try Data(contentsOf: Self.deliveryManifestURL)
    let manifest = try DeliveryManifest.load(from: data)
    #expect(manifest.manifestDigest == Self.goldenDigest)
    #expect(try DeliveryManifest.canonicalDigest(of: data) == Self.goldenDigest)
    #expect(manifest.identity.family == .egOne)
    #expect(manifest.identity.revision == "v2-sharded")
    #expect(manifest.admission.layout == "componentSet")
    #expect(manifest.files.count == 8)
    #expect(manifest.totalBytes == manifest.files.reduce(0) { $0 + $1.sizeBytes })
    for file in manifest.files {
      #expect(
        file.sizeBytes <= 450_000_000, "\(file.path) exceeds the cache-eligible shard ceiling")
    }
    let entrypointPath = try #require(manifest.resolvedEntrypointPath)
    #expect(entrypointPath == "eg-1-v1-00001-of-00008.gguf")
    let entrypointFile = try #require(
      manifest.files.first { $0.resolvedInstallPath == entrypointPath })
    #expect(entrypointFile.path == "v2-sharded/eg-1-v1-00001-of-00008.gguf")  // server object key
    #expect(entrypointFile.component == "eg-1-v1-00001-of-00008.gguf")
    #expect(manifest.sources.map(\.id) == ["our_copy"])
  }

  @Test func manifestIsDeclaredAsAppResource() throws {
    let project = try String(
      contentsOf: Self.repoRoot.appendingPathComponent("Project.swift"), encoding: .utf8)
    #expect(
      project.contains("Sources/EnviousWispr/Resources/eg1-delivery-manifest.json"),
      "eg1-delivery-manifest.json must be listed in the app target's resources")
  }

  /// Identity + fetch agreement (#1417 §3.6, revised from the #1363 3-axis
  /// version): the runtime `EGOneManifest`'s `sha256`/`sizeBytes` were
  /// removed as dead fields (no runtime reader, superseded by the delivery
  /// manifest's own per-file hash/size verification — contract invariant 1),
  /// so a 1:1 content-identity check against them no longer has a single
  /// counterpart once the delivery manifest lists N shards. What must still
  /// agree: model identity (name/version), and the runtime `downloadURL`
  /// matches the manifest's ENTRYPOINT file's fetch URL — today's single
  /// file; shard 1's URL once EG-1 ships sharded (same assertion, no rewrite
  /// needed at that point since it reads `resolvedEntrypointPath` generically).
  @Test func deliveryManifestAgreesWithRuntimeManifest() throws {
    let delivery = try DeliveryManifest.load(from: Data(contentsOf: Self.deliveryManifestURL))
    let runtime =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: Self.runtimeManifestURL)) as! [String: Any]

    // Identity axis: modelName/version must agree between the two manifests.
    let modelName = runtime["modelName"] as! String
    let version = runtime["version"] as! String
    #expect(delivery.identity.name == modelName)
    #expect(delivery.identity.revision == version)

    // Fetch axis: the runtime downloadURL matches the ENTRYPOINT file's URL.
    let entrypointPath = try #require(delivery.resolvedEntrypointPath)
    let entrypointFile = try #require(
      delivery.files.first { $0.resolvedInstallPath == entrypointPath })
    let ourCopy = try #require(delivery.sources.first { $0.id == "our_copy" })
    let reconstructed = ourCopy.baseURL.appendingPathComponent(entrypointFile.path).absoluteString
    #expect(reconstructed == (runtime["downloadURL"] as? String))
  }
}
