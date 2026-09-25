import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #3105 PR 4 chunk 1: signed contract and separate admission only.
@Suite("EG-1 checker companion delivery", .tags(.driftGuard))
struct EGOneCheckerDeliveryTests {
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

  @Test func bundledContractAndAppSignaturePin() throws {
    let data = try Data(contentsOf: Self.resource("eg1-checker-delivery-manifest"))
    let checker = try DeliveryManifest.load(from: data)
    let base = try Self.manifest("eg1-delivery-manifest")
    let runtime =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: Self.resource("eg1-manifest"))) as! [String: Any]
    let contract = try #require(checker.checkerContract)

    #expect(
      checker.manifestDigest == "d0dc89505a065298ad13df38c6e34073a345e5aa6ccf8a2eace4bd732ba851c3")
    #expect(checker.identity.family == .egOneChecker)
    #expect(checker.identity.cacheKey != base.identity.cacheKey)
    #expect(checker.files.count == 1)
    #expect(
      checker.files[0].sha256 == "c36e831adb4d35ccbde46fb15567de2fe42d343859a20a78402bd1ffa6a24e83")
    #expect(checker.files[0].sizeBytes == 66_094_912)
    #expect(contract.adapterFileName == checker.files[0].resolvedInstallPath)
    #expect(contract.format == "gguf-lora")
    #expect(contract.qualifiedThreshold == "0.7")
    #expect(contract.qualifiedLanguages == ["en"])
    #expect(contract.base.revision == base.identity.revision)
    #expect(contract.base.variant == base.identity.variant)
    #expect(contract.base.shardSHA256 == base.files.map(\.sha256))
    #expect(contract.base.promptTemplateID == runtime["promptTemplateID"] as? String)
    #expect(contract.base.runtimeABI == base.identity.runtimeABI)

    let project = try String(
      contentsOf: Self.root.appendingPathComponent("Project.swift"), encoding: .utf8)
    #expect(
      project.contains("\"Sources/EnviousWispr/Resources/eg1-checker-delivery-manifest.json\","))
    var tampered = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var changedContract = tampered["checkerContract"] as! [String: Any]
    changedContract["qualifiedThreshold"] = "0.8"
    tampered["checkerContract"] = changedContract
    #expect(throws: (any Error).self) {
      try DeliveryManifest.load(from: JSONSerialization.data(withJSONObject: tampered))
    }
  }

  @Test func signedContractOwnsQualifiedLanguagesAndThreshold() throws {
    func load(threshold: String, languages: [String]) throws -> DeliveryManifest {
      try DeliveryManifest.load(
        from: Self.signedJSON(
          Self.resource("eg1-checker-delivery-manifest")
        ) { object in
          var contract = object["checkerContract"] as! [String: Any]
          contract["qualifiedThreshold"] = threshold
          contract["qualifiedLanguages"] = languages
          object["checkerContract"] = contract
        })
    }
    let widened = try #require(
      try load(threshold: "0.7", languages: ["en", "de", "fil"]).checkerContract)
    #expect(widened.qualifiedThreshold == "0.7")
    #expect(widened.qualifiedLanguages == ["en", "de", "fil"])
    for (threshold, languages) in [
      ("0", ["en"]), ("1.5", ["en"]), ("nan", ["en"]), ("high", ["en"]), ("0.9", []),
      ("0.9", ["en", "en"]), ("0.9", ["EN"]), ("0.9", ["english"]), ("0.9", ["e"]),
    ] {
      #expect(throws: (any Error).self) { try load(threshold: threshold, languages: languages) }
    }
  }

  @Test func compatibilityIsClosedAndOrderSensitive() throws {
    let checker = try Self.manifest("eg1-checker-delivery-manifest")
    let contract = try #require(checker.checkerContract)
    let base = try Self.manifest("eg1-delivery-manifest")
    func verdict(_ manifest: DeliveryManifest, prompt: String = "eg1-v2-named-language")
      -> EGOneCheckerCompatibility
    {
      compatibility(
        contract: contract,
        admittedBase: AdmittedEGOneBase(manifest: manifest, promptTemplateID: prompt))
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
