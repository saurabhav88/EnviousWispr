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
    extraFiles: [(path: String, installPath: String?, component: String, content: Data)] = []
  ) throws -> Data {
    func fileObject(_ p: String, _ ip: String?, _ c: String, _ data: Data) -> [String: Any] {
      var obj: [String: Any] = [
        "path": p, "sizeBytes": data.count, "sha256": sha256(data), "component": c,
      ]
      if let ip { obj["installPath"] = ip }
      return obj
    }
    let all = [(path, installPath, component, content)] + extraFiles
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
      "admission": [
        "layout": "singleFile", "installLocation": "test",
        "diskHeadroomFactor": "2.2", "evictPreviousRevisions": false,
      ] as [String: Any],
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

  static let goldenDigest = "e3776d8863b791b120c58a1831b6e90474277753e8e0e78a6b62eac4816133c6"

  @Test func shippedDeliveryManifestLoadsAndMatchesGoldenDigest() throws {
    let data = try Data(contentsOf: Self.deliveryManifestURL)
    let manifest = try DeliveryManifest.load(from: data)
    #expect(manifest.manifestDigest == Self.goldenDigest)
    #expect(try DeliveryManifest.canonicalDigest(of: data) == Self.goldenDigest)
    #expect(manifest.identity.family == .egOne)
    #expect(manifest.files.count == 1)
    let file = try #require(manifest.files.first)
    #expect(file.path == "eg-1-v1-q5km.gguf")  // server object key
    #expect(file.resolvedInstallPath == "eg-1-v1.gguf")  // local runtime name
    #expect(file.component == "eg-1-v1.gguf")
    #expect(manifest.sources.map(\.id) == ["our_copy"])
  }

  @Test func manifestIsDeclaredAsAppResource() throws {
    let project = try String(
      contentsOf: Self.repoRoot.appendingPathComponent("Project.swift"), encoding: .utf8)
    #expect(
      project.contains("Sources/EnviousWispr/Resources/eg1-delivery-manifest.json"),
      "eg1-delivery-manifest.json must be listed in the app target's resources")
  }

  /// 3-axis agreement (#1363 §16.7): the delivery manifest and the runtime
  /// `EGOneManifest` must never drift on fetch, install, or content identity.
  @Test func deliveryManifestAgreesWithRuntimeManifest() throws {
    let delivery = try DeliveryManifest.load(from: Data(contentsOf: Self.deliveryManifestURL))
    let runtime =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: Self.runtimeManifestURL)) as! [String: Any]
    let file = try #require(delivery.files.first)
    let ourCopy = try #require(delivery.sources.first { $0.id == "our_copy" })

    // Fetch axis: baseURL + path reconstructs the runtime downloadURL.
    let reconstructed = ourCopy.baseURL.appendingPathComponent(file.path).absoluteString
    #expect(reconstructed == (runtime["downloadURL"] as? String))
    // Install axis: resolvedInstallPath == runtime artifactFileName
    // (modelName-version.gguf).
    let modelName = runtime["modelName"] as! String
    let version = runtime["version"] as! String
    #expect(file.resolvedInstallPath == "\(modelName)-\(version).gguf")
    // Content axis: sha256 + sizeBytes are identical.
    #expect(file.sha256 == (runtime["sha256"] as? String))
    #expect(file.sizeBytes == Int64(runtime["sizeBytes"] as! Int))
  }
}
