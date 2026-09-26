import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #3105: each engine's signed checker contract and its separate admission.
@Suite("Learned-word checker delivery (#3105)", .tags(.driftGuard))
struct LearnedWordCheckerDeliveryTests {
  private static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private static func resource(_ name: String) -> URL {
    root.appendingPathComponent("Sources/EnviousWispr/Resources/\(name).json")
  }

  private static func manifest(_ name: String) throws -> DeliveryManifest {
    try DeliveryManifest.load(from: Data(contentsOf: resource(name)))
  }

  private static func signedJSON(
    _ source: URL, mutate: (inout [String: Any]) -> Void
  ) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
    mutate(&object)
    object.removeValue(forKey: "manifestDigest")
    let canonical = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    object["manifestDigest"] = SHA256.hash(data: canonical)
      .map { String(format: "%02x", $0) }.joined()
    return try JSONSerialization.data(withJSONObject: object)
  }

  private static func alteredBase(
    _ mutate: (inout [String: Any]) -> Void
  ) throws -> DeliveryManifest {
    let data = try signedJSON(resource("eg1-delivery-manifest"), mutate: mutate)
    return try DeliveryManifest.load(from: data)
  }

  /// Each engine's shipped checker, pinned by value: the engine's own base,
  /// runtime manifest, hosted object and qualified threshold.
  struct Shipped: Sendable, CustomTestStringConvertible {
    let checker, base, runtime: String
    let family: ModelFamily
    let digest, sha256: String
    let size: Int64
    let threshold: String
    var testDescription: String { checker }
  }

  static let shipped = [
    Shipped(
      checker: "eg1-checker-delivery-manifest", base: "eg1-delivery-manifest",
      runtime: "eg1-manifest", family: .egOneChecker,
      digest: "d513891ad8724243dce3d139410a97bb44f7104aac57cea3f19c80fe0e3f6fb0",
      sha256: "c36e831adb4d35ccbde46fb15567de2fe42d343859a20a78402bd1ffa6a24e83",
      size: 66_094_912, threshold: "0.481"),
    Shipped(
      checker: "s1-checker-delivery-manifest", base: "s1-delivery-manifest",
      runtime: "s1-manifest", family: .s1MiniChecker,
      digest: "e8c33bc88ee58300731f2143f8708de6eca4f6d6750b2bee5c617e90ab984cb4",
      sha256: "43da0f1ceda643a26a20898e3577476d4eedace5ff8b0f1ab03e9ff84f54f825",
      size: 80_767_264, threshold: "0.858"),
  ]

  @Test(arguments: shipped)
  func bundledContractAndAppSignaturePin(_ pin: Shipped) throws {
    let data = try Data(contentsOf: Self.resource(pin.checker))
    let checker = try DeliveryManifest.load(from: data)
    let base = try Self.manifest(pin.base)
    let runtime =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: Self.resource(pin.runtime))) as! [String: Any]
    let contract = try #require(checker.checkerContract)

    #expect(checker.manifestDigest == pin.digest)
    #expect(checker.identity.family == pin.family)
    #expect(pin.family.checkerBaseFamily == base.identity.family)
    #expect(checker.identity.cacheKey != base.identity.cacheKey)
    #expect(checker.files.count == 1)
    #expect(checker.files[0].sha256 == pin.sha256)
    #expect(checker.files[0].sizeBytes == pin.size)
    #expect(contract.adapterFileName == checker.files[0].resolvedInstallPath)
    #expect(contract.format == "gguf-lora")
    #expect(contract.qualifiedThreshold == pin.threshold)
    #expect(contract.base.revision == base.identity.revision)
    #expect(contract.base.variant == base.identity.variant)
    #expect(contract.base.shardSHA256 == base.files.map(\.sha256))
    #expect(contract.base.promptTemplateID == runtime["promptTemplateID"] as? String)
    #expect(contract.base.runtimeABI == base.identity.runtimeABI)
    // Hosted beside the base on our own mirror; the digest pins the URL too.
    #expect(checker.sources.map(\.id) == ["our_copy"])
    #expect(checker.sources[0].baseURL.host == "models.enviouslabs.co")
    #expect(
      checker.sources[0].baseURL.path.hasPrefix(
        base.sources[0].baseURL.path.split(separator: "/").first.map { "/\($0)/" } ?? "?"))

    let project = try String(
      contentsOf: Self.root.appendingPathComponent("Project.swift"), encoding: .utf8)
    #expect(project.contains("\"Sources/EnviousWispr/Resources/\(pin.checker).json\","))
    var tampered = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var changedContract = tampered["checkerContract"] as! [String: Any]
    changedContract["qualifiedThreshold"] = "0.8"
    tampered["checkerContract"] = changedContract
    #expect(throws: (any Error).self) {
      try DeliveryManifest.load(from: JSONSerialization.data(withJSONObject: tampered))
    }
  }

  @Test func signedContractOwnsThreshold() throws {
    func load(threshold: String) throws -> DeliveryManifest {
      try DeliveryManifest.load(
        from: Self.signedJSON(
          Self.resource("s1-checker-delivery-manifest")
        ) { object in
          var contract = object["checkerContract"] as! [String: Any]
          contract["qualifiedThreshold"] = threshold
          object["checkerContract"] = contract
        })
    }
    #expect(try #require(try load(threshold: "0.7").checkerContract).qualifiedThreshold == "0.7")
    for threshold in ["0", "1.5", "nan", "high", "-0.2"] {
      #expect(throws: (any Error).self) { try load(threshold: threshold) }
    }
  }

  /// Founder 2026-09-26: every language. The contract no longer carries a
  /// language list, and a manifest signed before that change (it still names
  /// `qualifiedLanguages`) decodes; its admitted bytes re-admit under the new
  /// manifest's digest without a download or a deletion.
  @Test func checkerAdmittedBeforeTheLanguageListReAdmitsWithoutDownload() async throws {
    let fixture = Self.root.appendingPathComponent(
      "Tests/EnviousWisprTests/ModelDelivery/Fixtures/eg1-checker-delivery-manifest-before-3105-pr2.json")
    let before = try DeliveryManifest.load(from: Data(contentsOf: fixture))
    let after = try Self.manifest("eg1-checker-delivery-manifest")
    #expect(before.identity == after.identity)
    #expect(before.files == after.files)
    #expect(before.manifestDigest != after.manifestDigest)
    #expect(
      try String(contentsOf: fixture, encoding: .utf8).contains("qualifiedLanguages"),
      "the fixture is the pre-change manifest")

    // Tiny stand-in bytes under both manifests, so the test needs no 66 MB file.
    let bytes = Data("adapter".utf8)
    func tiny(_ source: URL) throws -> DeliveryManifest {
      try DeliveryManifest.load(
        from: Self.signedJSON(source) { object in
          var files = object["files"] as! [[String: Any]]
          let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
          files[0]["sizeBytes"] = bytes.count
          files[0]["sha256"] = hash
          object["files"] = files
          object["totalBytes"] = bytes.count
          var contract = object["checkerContract"] as! [String: Any]
          contract["adapterSizeBytes"] = bytes.count
          contract["adapterSHA256"] = hash
          object["checkerContract"] = contract
        })
    }
    let old = try tiny(fixture)
    let new = try tiny(Self.resource("eg1-checker-delivery-manifest"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let install = root.appendingPathComponent("Models/eg-1-checker")
    let metadata = root.appendingPathComponent("ModelDelivery")
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let filename = try #require(new.resolvedEntrypointPath)
    let artifact = install.appendingPathComponent(filename)
    try bytes.write(to: artifact)
    let oldGate = CacheAdmission(manifest: old, installDirectory: install, metadataDirectory: metadata)
    #expect((await oldGate.validateExistingCache()).verifiedComponents == [filename])
    try oldGate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [filename])
    #expect(oldGate.isAdmitted())

    let newGate = CacheAdmission(manifest: new, installDirectory: install, metadataDirectory: metadata)
    #expect(newGate.isAdmitted() == false, "a new digest is not admitted by an old marker")
    #expect((await newGate.validateExistingCache()).verifiedComponents == [filename])
    try newGate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [filename])
    #expect(newGate.isAdmitted())
    #expect(try Data(contentsOf: artifact) == bytes, "the admitted bytes were kept, not refetched")
  }

  @Test func compatibilityIsClosedAndOrderSensitive() throws {
    let checker = try Self.manifest("eg1-checker-delivery-manifest")
    let contract = try #require(checker.checkerContract)
    let base = try Self.manifest("eg1-delivery-manifest")
    func verdict(_ manifest: DeliveryManifest, prompt: String = "eg1-v2-named-language")
      -> LearnedWordCheckerCompatibility
    {
      compatibility(
        contract: contract, checkerFamily: .egOneChecker,
        admittedBase: AdmittedCheckerBase(manifest: manifest, promptTemplateID: prompt))
    }
    #expect(verdict(base) == .compatible)
    #expect(verdict(base, prompt: "other") == .refused(.promptTemplateMismatch))
    #expect(
      verdict(
        try Self.alteredBase {
          $0["identity"] = [
            "family": "s1_mini", "name": "eg-1", "revision": "eg1-1.2-c003",
            "variant": "q5km", "runtimeABI": "llamacpp-eg1-v1",
          ]
        }) == .refused(.baseFamilyMismatch))
    #expect(
      verdict(
        try Self.alteredBase { object in
          var identity = object["identity"] as! [String: Any]
          identity["revision"] = "next"
          object["identity"] = identity
        }) == .refused(.baseRevisionMismatch))
    #expect(
      verdict(
        try Self.alteredBase { object in
          var identity = object["identity"] as! [String: Any]
          identity["variant"] = "q4km"
          object["identity"] = identity
        }) == .refused(.baseVariantMismatch))
    #expect(
      verdict(
        try Self.alteredBase { object in
          var files = object["files"] as! [[String: Any]]
          files.swapAt(0, 1)
          object["files"] = files
        }) == .refused(.shardHashMismatch))
    #expect(
      verdict(
        try Self.alteredBase { object in
          var identity = object["identity"] as! [String: Any]
          identity["runtimeABI"] = "next-binary"
          object["identity"] = identity
        }) == .refused(.runtimeMismatch))
  }

  static func tinyChecker(_ bytes: Data) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: signedJSON(resource("eg1-checker-delivery-manifest")) { object in
        var files = object["files"] as! [[String: Any]]
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        files[0]["sizeBytes"] = bytes.count
        files[0]["sha256"] = hash
        object["files"] = files
        object["totalBytes"] = bytes.count
        var contract = object["checkerContract"] as! [String: Any]
        contract["adapterSizeBytes"] = bytes.count
        contract["adapterSHA256"] = hash
        object["checkerContract"] = contract
      })
  }

  @Test func corruptWrongSizeAndStaleMarkerRefuseCheckerAdmission() async throws {
    let good = Data("adapter".utf8)
    let checker = try Self.tinyChecker(good)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let install = root.appendingPathComponent("Models/eg-1-checker")
    let metadata = root.appendingPathComponent("ModelDelivery")
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let gate = CacheAdmission(
      manifest: checker, installDirectory: install, metadataDirectory: metadata)
    let filename = try #require(checker.resolvedEntrypointPath)
    let artifact = install.appendingPathComponent(filename)
    try Data("adapteX".utf8).write(to: artifact)
    #expect((await gate.validateExistingCache()).failedComponents == [filename])
    #expect(gate.isAdmitted() == false)
    try Data("short".utf8).write(to: artifact)
    #expect((await gate.validateExistingCache()).failedComponents == [filename])
    #expect(gate.isAdmitted() == false)
    try good.write(to: artifact)
    #expect((await gate.validateExistingCache()).verifiedComponents == [filename])
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [filename])
    #expect(gate.isAdmitted())
    var marker =
      try JSONSerialization.jsonObject(with: Data(contentsOf: gate.markerURL)) as! [String: Any]
    marker["manifestDigest"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: marker).write(to: gate.markerURL)
    #expect(gate.isAdmitted() == false)
    #expect((await gate.validateExistingCache()).verifiedComponents == [filename])
    try gate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: [filename])
    #expect(gate.isAdmitted())
  }

  @Test func baseAdmissionAndCleanupLeaveCheckerSiblingIntact() async throws {
    let bytes = Data("base".utf8)
    let base = try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: [("base-shard.gguf", bytes, "base-shard.gguf")], family: "eg_one"))
    let checker = try Self.tinyChecker(Data("adapter".utf8))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let models = root.appendingPathComponent("Models")
    let baseDir = models.appendingPathComponent("eg-1")
    let checkerDir = models.appendingPathComponent("eg-1-checker")
    let metadata = root.appendingPathComponent("ModelDelivery")
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: checkerDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try bytes.write(to: baseDir.appendingPathComponent("base-shard.gguf"))
    try Data("stale".utf8).write(to: baseDir.appendingPathComponent("old-shard.gguf"))
    try Data("adapter".utf8).write(to: checkerDir.appendingPathComponent("eg1c-v2-f16.gguf"))
    let baseGate = CacheAdmission(
      manifest: base, installDirectory: baseDir, metadataDirectory: metadata)
    let checkerGate = CacheAdmission(
      manifest: checker, installDirectory: checkerDir, metadataDirectory: metadata)
    #expect((await baseGate.validateExistingCache()).verifiedComponents == ["base-shard.gguf"])
    #expect((await checkerGate.validateExistingCache()).verifiedComponents == ["eg1c-v2-f16.gguf"])
    try checkerGate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: ["eg1c-v2-f16.gguf"])
    try baseGate.promoteAndAdmit(
      stagedComponents: [], stagingDirectory: staging, untouchedComponents: ["base-shard.gguf"])
    #expect(baseGate.isAdmitted())
    #expect(checkerGate.isAdmitted())
    #expect(
      FileManager.default.fileExists(
        atPath: baseDir.appendingPathComponent("old-shard.gguf").path) == false)
    #expect(
      FileManager.default.fileExists(
        atPath: checkerDir.appendingPathComponent("eg1c-v2-f16.gguf").path))
  }
}
