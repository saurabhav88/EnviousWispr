import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

// MARK: - Fixture support

/// Builds a structurally-valid schema-v1 manifest JSON with a CORRECT
/// canonical digest, mirroring `scripts/validate-delivery-manifest.py`'s
/// canonicalization (sorted keys, compact separators). Fixture files carry
/// REAL SHA-256s of their content so admission tests can verify end to end.
enum ManifestFixture {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func manifestJSON(
    files: [(path: String, content: Data, component: String)],
    sources: [[String: String]] = [
      ["id": "our_copy", "baseURL": "https://mirror.invalid.example/base/"],
      ["id": "backup", "baseURL": "https://upstream.invalid.example/base/"],
    ],
    schemaVersion: Int = 1,
    mutate: ((inout [String: Any]) -> Void)? = nil
  ) throws -> Data {
    var object: [String: Any] = [
      "schemaVersion": schemaVersion,
      "identity": [
        "family": "parakeet", "name": "fixture-model", "revision": "rev1",
        "variant": "int8", "runtimeABI": "fluidAudio-test",
      ],
      "files": files.map {
        [
          "path": $0.path, "sizeBytes": $0.content.count,
          "sha256": sha256($0.content), "component": $0.component,
        ] as [String: Any]
      },
      "optionalFiles": [] as [Any],
      "totalBytes": files.reduce(0) { $0 + $1.content.count },
      "sources": sources,
      "admission": [
        "layout": "componentSet", "installLocation": "fixture",
        "diskHeadroomFactor": "2.2", "evictPreviousRevisions": false,
      ] as [String: Any],
    ]
    mutate?(&object)
    let canonical = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    object["manifestDigest"] = sha256(canonical)
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func manifest(
    files: [(path: String, content: Data, component: String)]
  ) throws -> DeliveryManifest {
    try DeliveryManifest.load(from: manifestJSON(files: files))
  }

  static let smallFiles: [(path: String, content: Data, component: String)] = [
    ("Encoder.mlmodelc/coremldata.bin", Data("encoder-bytes".utf8), "Encoder.mlmodelc"),
    ("Encoder.mlmodelc/weights/weight.bin", Data("weights".utf8), "Encoder.mlmodelc"),
    ("vocab.json", Data("{\"a\":1}".utf8), "vocab.json"),
  ]
}

@Suite struct DeliveryManifestTests {
  @Test func validManifestLoadsAndGroupsComponents() throws {
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    #expect(manifest.identity.family == .parakeet)
    #expect(manifest.files.count == 3)
    #expect(manifest.totalBytes == 27)
    let components = manifest.filesByComponent
    #expect(components.map(\.component) == ["Encoder.mlmodelc", "vocab.json"])
    #expect(components[0].files.count == 2)
  }

  @Test func unknownSchemaVersionIsRefused() throws {
    let data = try ManifestFixture.manifestJSON(files: ManifestFixture.smallFiles, schemaVersion: 2)
    #expect(throws: DeliveryManifest.ManifestError.unsupportedSchemaVersion(2)) {
      try DeliveryManifest.load(from: data)
    }
  }

  @Test func tamperedDigestIsRefused() throws {
    var data = try ManifestFixture.manifestJSON(files: ManifestFixture.smallFiles)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["manifestDigest"] = String(repeating: "0", count: 64)
    data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: data) }
  }

  @Test func tamperedHashIsRefusedByDigest() throws {
    // The trust root: mutating any byte of files[] after digest computation
    // fails the load — hashes are immutable outside a trusted app update.
    var data = try ManifestFixture.manifestJSON(files: ManifestFixture.smallFiles)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var files = object["files"] as! [[String: Any]]
    files[0]["sha256"] = String(repeating: "a", count: 64)
    object["files"] = files
    data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: data) }
  }

  @Test func structuralRefusals() throws {
    // sources[0] must be our_copy (source POLICY is manifest-authored).
    let badFirstSource = try ManifestFixture.manifestJSON(
      files: ManifestFixture.smallFiles,
      sources: [["id": "backup", "baseURL": "https://upstream.invalid.example/base/"]])
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: badFirstSource) }

    // Path traversal never loads.
    let traversal = try ManifestFixture.manifestJSON(
      files: [("../escape", Data("x".utf8), "c")])
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: traversal) }

    // totalBytes arithmetic is enforced.
    let badTotal = try ManifestFixture.manifestJSON(files: ManifestFixture.smallFiles) { object in
      object["totalBytes"] = 999
    }
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: badTotal) }
  }

  @Test func missingBundleResourceThrowsTyped() {
    #expect(throws: DeliveryManifest.ManifestError.resourceMissing("nope")) {
      _ = try DeliveryManifest.loadBundled(resource: "nope", bundle: .main)
    }
  }
}

// MARK: - The shipped Parakeet manifest (golden fixture, grounded r1 rev 8/9)

@Suite struct ParakeetShippedManifestTests {
  /// Repo-relative path via #filePath — the ceilings-test house pattern for
  /// reading source-tree files from unit tests.
  static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // ModelDelivery
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
  }

  static var shippedManifestURL: URL {
    repoRoot.appendingPathComponent(
      "Sources/EnviousWispr/Resources/parakeet-delivery-manifest.json")
  }

  /// The committed golden digest: the Python authoring validator and the
  /// Swift loader MUST both reproduce it (one canonicalization, two
  /// implementations — a drift here would reject a valid manifest at
  /// runtime).
  static let goldenDigest = "9b2ac8f4a96845506f75e653605be369fd2762ba9f7ae60a27ab8991000e4581"

  @Test func shippedManifestLoadsAndMatchesGoldenDigest() throws {
    let data = try Data(contentsOf: Self.shippedManifestURL)
    let manifest = try DeliveryManifest.load(from: data)
    #expect(manifest.manifestDigest == Self.goldenDigest)
    #expect(try DeliveryManifest.canonicalDigest(of: data) == Self.goldenDigest)
    #expect(manifest.identity.name == "parakeet-tdt-0.6b-v3-coreml")
    #expect(manifest.identity.revision == "aed02740059203c4a87495924f685de3722ae9ce")
    #expect(manifest.files.count == 23)
    #expect(manifest.totalBytes == 483_256_769)
    #expect(manifest.sources.map(\.id) == ["our_copy", "backup"])
    // The no-network handoff requires the full required set (D1 §12).
    let components = Set(manifest.files.map(\.component))
    for required in [
      "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
      "Preprocessor.mlmodelc", "parakeet_vocab.json",
    ] {
      #expect(components.contains(required), "missing component \(required)")
    }
  }

  /// Presence gate at test time (grounded r1 revision 9): the manifest must
  /// ride the APP target's resource list — a unit test cannot inspect the
  /// built .app, so assert the build declaration (ceilings-test style).
  @Test func manifestIsDeclaredAsAppResource() throws {
    let project = try String(
      contentsOf: Self.repoRoot.appendingPathComponent("Project.swift"), encoding: .utf8)
    #expect(
      project.contains("Sources/EnviousWispr/Resources/parakeet-delivery-manifest.json"),
      "parakeet-delivery-manifest.json must be listed in the app target's resources")
  }

  /// Cross-artifact gate (PR-2a/PR-2b): every (path, size, sha256) in the
  /// shipped manifest matches the mirror Worker's byte-verified seed.
  @Test func shippedManifestMatchesWorkerSeed() throws {
    let manifest = try DeliveryManifest.load(from: Data(contentsOf: Self.shippedManifestURL))
    let seedData = try Data(
      contentsOf: Self.repoRoot.appendingPathComponent(
        "workers/parakeet-mirror/expected-manifest.json"))
    let seed = try JSONSerialization.jsonObject(with: seedData) as! [String: Any]
    let seedFiles = (seed["files"] as! [[String: Any]]).reduce(into: [String: (Int64, String)]()) {
      $0[$1["path"] as! String] = (Int64($1["size"] as! Int), $1["sha256"] as! String)
    }
    #expect(seedFiles.count == manifest.files.count)
    for file in manifest.files {
      let entry = seedFiles[file.path]
      #expect(entry != nil, "seed missing \(file.path)")
      #expect(entry?.0 == file.sizeBytes, "size drift for \(file.path)")
      #expect(entry?.1 == file.sha256, "sha drift for \(file.path)")
    }
    #expect(seed["revision"] as? String == manifest.identity.revision)
  }
}

// MARK: - Flags (D5)

@Suite struct DeliveryFlagsTests {
  private func defaults() -> UserDefaults {
    let suite = "test.modelDelivery.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
  }

  /// Key-spelling constants test (grounded r1 revision 9): the exact strings
  /// support will type into `defaults write`.
  @Test func flagKeySpellings() {
    #expect(DeliveryFlags.key("enabled", family: .parakeet) == "modelDelivery.parakeet.enabled")
    #expect(
      DeliveryFlags.key("sourceOrder", family: .parakeet) == "modelDelivery.parakeet.sourceOrder")
    #expect(
      DeliveryFlags.key("forceRevalidate", family: .parakeet)
        == "modelDelivery.parakeet.forceRevalidate")
    #expect(DeliveryFlags.key("mirrorDisabled", family: nil) == "modelDelivery.mirrorDisabled")
    #expect(DeliveryFlags.key("backupDisabled", family: nil) == "modelDelivery.backupDisabled")
  }

  @Test func defaultSnapshotHasNoOverrides() {
    let flags = DeliveryFlags.snapshot(family: .parakeet, defaults: defaults())
    #expect(flags.familyEnabled)
    #expect(flags.activeOverrides.isEmpty)
  }

  @Test func sourceOrderOverrideReordersAndRestricts() throws {
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    let d = defaults()
    d.set("backup,our_copy", forKey: "modelDelivery.parakeet.sourceOrder")
    var flags = DeliveryFlags.snapshot(family: .parakeet, defaults: d)
    #expect(flags.orderedSources(from: manifest).map(\.id) == ["backup", "our_copy"])

    d.set("backup", forKey: "modelDelivery.parakeet.sourceOrder")
    flags = DeliveryFlags.snapshot(family: .parakeet, defaults: d)
    #expect(flags.orderedSources(from: manifest).map(\.id) == ["backup"])

    // Adversarial (matcher-set rule): garbage never empties the list.
    d.set("nonsense,alsobad", forKey: "modelDelivery.parakeet.sourceOrder")
    flags = DeliveryFlags.snapshot(family: .parakeet, defaults: d)
    #expect(flags.orderedSources(from: manifest).map(\.id) == ["our_copy", "backup"])
  }

  @Test func mirrorAndBackupKillSwitches() throws {
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    let d = defaults()
    d.set(true, forKey: "modelDelivery.mirrorDisabled")
    var flags = DeliveryFlags.snapshot(family: .parakeet, defaults: d)
    #expect(flags.orderedSources(from: manifest).map(\.id) == ["backup"])
    #expect(flags.activeOverrides.map(\.flag) == ["mirrorDisabled"])

    // Both kill switches on would brick delivery — fall back to manifest
    // order (support flags must not be able to zero the source list).
    d.set(true, forKey: "modelDelivery.backupDisabled")
    flags = DeliveryFlags.snapshot(family: .parakeet, defaults: d)
    #expect(flags.orderedSources(from: manifest).map(\.id) == ["our_copy", "backup"])
  }
}
