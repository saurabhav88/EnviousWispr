import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

// MARK: - Fixture support

/// Builds a structurally-valid schema-v1 manifest JSON with a CORRECT
/// canonical digest using the same canonicalization the Swift loader recomputes
/// (sorted keys, compact separators — there is no Python authoring tool).
/// Fixture files carry REAL SHA-256s of their content so admission tests can
/// verify end to end.
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
    family: String = "parakeet",
    schemaVersion: Int = 1,
    mutate: ((inout [String: Any]) -> Void)? = nil
  ) throws -> Data {
    var object: [String: Any] = [
      "schemaVersion": schemaVersion,
      "identity": [
        "family": family, "name": "fixture-model", "revision": "rev1",
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

  @Test func whisperKitCarveOutForNonOurCopyPrimarySource() throws {
    // #1386 PR-2: the multilingual (WhisperKit) engine is the ONE licensed
    // exception to mirror-first — its single source is HF-pinned, not our_copy.
    let hfOnly = [["id": "hugging_face", "baseURL": "https://hf.invalid.example/base/"]]

    // WhisperKit ACCEPTS a non-our_copy primary source.
    let whisper = try ManifestFixture.manifestJSON(
      files: ManifestFixture.smallFiles, sources: hfOnly, family: "whisper_kit")
    #expect(throws: Never.self) { try DeliveryManifest.load(from: whisper) }

    // The carve-out MUST NOT leak: every other family still hard-requires
    // our_copy first (a non-our_copy primary is refused).
    for family in ["parakeet", "eg_one"] {
      let leaky = try ManifestFixture.manifestJSON(
        files: ManifestFixture.smallFiles, sources: hfOnly, family: family)
      #expect(throws: (any Error).self) { try DeliveryManifest.load(from: leaky) }
    }

    // WhisperKit still enforces every OTHER source rule (https + trailing slash).
    let badScheme = try ManifestFixture.manifestJSON(
      files: ManifestFixture.smallFiles,
      sources: [["id": "hugging_face", "baseURL": "http://hf.invalid.example/base/"]],
      family: "whisper_kit")
    #expect(throws: (any Error).self) { try DeliveryManifest.load(from: badScheme) }
  }

  @Test func missingBundleResourceThrowsTyped() {
    #expect(throws: DeliveryManifest.ManifestError.resourceMissing("nope")) {
      _ = try DeliveryManifest.loadBundled(resource: "nope", bundle: .main)
    }
  }
}

// MARK: - The shipped Parakeet manifest (golden fixture, grounded r1 rev 8/9)

/// The shipped multilingual (WhisperKit) manifest (#1386 PR-2). This is the ONE
/// family fetched from a source we do not host — we are not licensed to re-host
/// Argmax's CoreML weights — so the safety property is entirely in this file:
/// an immutable pinned commit, an exhaustive file list, and a SHA-256 per byte
/// range that must verify before anything is admitted. There is no runtime
/// listing call and no moving branch to drift under us.
@Suite struct WhisperKitShippedManifestTests {
  static var shippedManifestURL: URL {
    ParakeetShippedManifestTests.repoRoot.appendingPathComponent(
      "Sources/EnviousWispr/Resources/whisperkit-delivery-manifest.json")
  }

  /// Golden digest: the authoring script and the Swift loader must agree, or a
  /// valid manifest gets rejected at runtime. Not copied from the authoring
  /// script — `DeliveryManifest.load` recomputes the digest and THROWS on a
  /// mismatch, so a manifest that loads at all has already had this value
  /// confirmed by the shipped Swift canonicalization, independently.
  static let goldenDigest = "3759d7401b2a0f4c4808a006e1edf04495ddfeed4dc9e9cab479bf3c5f1f140b"

  @Test func shippedManifestLoadsAndMatchesGoldenDigest() throws {
    let data = try Data(contentsOf: Self.shippedManifestURL)
    let manifest = try DeliveryManifest.load(from: data)
    #expect(manifest.manifestDigest == Self.goldenDigest)
    #expect(try DeliveryManifest.canonicalDigest(of: data) == Self.goldenDigest)
    #expect(manifest.identity.family == .whisperKit)
    #expect(manifest.identity.variant == "openai_whisper-large-v3-v20240930_turbo")
    #expect(manifest.files.count == 24)
    #expect(manifest.totalBytes == 1_638_464_446)

    // Every component the loader needs; a partial set would admit a cache that
    // cannot actually transcribe.
    let components = Set(manifest.files.map(\.component))
    for required in [
      "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
      "TextDecoderContextPrefill.mlmodelc", "config.json",
    ] {
      #expect(components.contains(required), "missing component \(required)")
    }
  }

  /// The pin is the whole point: a `/resolve/<40-hex-commit>/` URL cannot move
  /// under us the way `/resolve/main/` can. Ship criterion 1.
  @Test func sourceIsPinnedToAnImmutableCommitNotABranch() throws {
    let manifest = try DeliveryManifest.load(from: Data(contentsOf: Self.shippedManifestURL))
    #expect(manifest.sources.count == 1)
    let baseURL = try #require(manifest.sources.first?.baseURL.absoluteString)
    #expect(baseURL.hasPrefix("https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/"))
    #expect(!baseURL.contains("/resolve/main/"), "a branch ref would let the bytes change")

    let revision = manifest.identity.revision
    #expect(revision.count == 40, "revision must be a full commit SHA, never a short ref or tag")
    #expect(revision.allSatisfy { $0.isHexDigit })
    #expect(baseURL.contains(revision), "the fetch URL must pin the SAME commit the identity names")
    // No embedded token: the pinned URL is publicly resolvable.
    #expect(!baseURL.contains("@") && !baseURL.contains("token"))
  }

  @Test func manifestIsDeclaredAsAppResource() throws {
    let project = try String(
      contentsOf: ParakeetShippedManifestTests.repoRoot.appendingPathComponent("Project.swift"),
      encoding: .utf8)
    #expect(
      project.contains("Sources/EnviousWispr/Resources/whisperkit-delivery-manifest.json"),
      "whisperkit-delivery-manifest.json must be listed in the app target's resources")
  }
}

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
  // Updated 2026-07-07 (#1405 Phase 2): `our_copy` baseURL repointed to the
  // edge-cached `/parakeet/` path; digest recomputed via the same canonicalization.
  static let goldenDigest = "edbd8592cc8316b5aa3a82de81c0855af9d0463a7e2bf8a5a1fe8569af497676"

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
