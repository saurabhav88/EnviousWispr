import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprEG1Engine
@testable import EnviousWisprModelDelivery

/// #4473 P4: the bundled delivery manifests of the published EG-1 sizes on the EnviousDecode
/// engine (full and Micro; Mini is not published yet), read from the committed resources
/// through the real loader.
///
/// When this fails, a user who picks a size cannot get it or gets a broken one: the app
/// refuses its own manifest at launch (a wrong digest), the download asks an address that
/// does not hold the file, the engine is handed a folder without the draft model, or the
/// size's learned-word checker is refused (or accepted on another size's model) because its
/// pin is not the model that was published. Encounter: every download of a size and every
/// polish that checks a learned word. Owner: plan #4473 P4.
@Suite(
  "The bundled EG-1 MLX manifests are the published sizes, and each checker binds to its own model only (#4473)",
  .tags(.driftGuard))
struct EGOneMLXBundledManifestTests {
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

  /// The polish prompt contract the app pins a checker's base with: the runtime manifest's.
  private static func runtimePromptTemplateID() throws -> String {
    let object =
      try JSONSerialization.jsonObject(with: Data(contentsOf: resource("eg1-manifest")))
      as! [String: Any]
    return try #require(object["promptTemplateID"] as? String)
  }

  /// One published size, pinned by value against what was uploaded and verified.
  struct Published: Sendable, CustomTestStringConvertible {
    let size: EGOneSize
    let model, checker: String
    let revision, checkerRevision: String
    let modelDigest, checkerDigest: String
    let fileCount: Int
    let totalBytes, checkerBytes: Int64
    let adapterSHA256, threshold: String
    /// Files that travel as transport parts.
    let partedFiles: [String]
    var testDescription: String { model }
  }

  static let published = [
    Published(
      size: .full, model: "eg1-mlx-delivery-manifest",
      checker: "eg1-mlx-checker-delivery-manifest",
      revision: "eg1-1.3-intl-1c-20261109", checkerRevision: "eg1c-v3",
      modelDigest: "baabe5aa20c1a7a8c36345b4afa50df013e1e63d7db2adbbf255b2e9ad66afb7",
      checkerDigest: "509eab563212582cdcecfb90130b55634c572153e704d212de506868725b1f02",
      fileCount: 21, totalBytes: 4_707_411_269, checkerBytes: 121_947_825,
      adapterSHA256: "670a9015", threshold: "0.1824255410790286",
      partedFiles: ["model-00007-of-00008.safetensors"]),
    Published(
      size: .micro, model: "eg1-micro-delivery-manifest",
      checker: "eg1-micro-checker-delivery-manifest",
      revision: "eg1-micro-1.0-g3d", checkerRevision: "eg1c-micro-v1",
      modelDigest: "c7124d669db301629fa6e9e3a795c84ac9a178f34c258e1f263892f423856a58",
      checkerDigest: "d2b2df0f9ad736798ce927d0242c886f5b45e9ff63d40cbc0a7878c140c4070f",
      fileCount: 12, totalBytes: 805_133_748, checkerBytes: 40_932_473,
      adapterSHA256: "7247de61", threshold: "0.20181324142004287",
      partedFiles: []),
  ]

  private static let appSupport = URL(fileURLWithPath: "/tmp/eg1-mlx-bundled/app-support")

  @Test(arguments: published)
  func theModelManifestIsThePublishedSizeAndHandsTheEngineItsFolders(_ item: Published) throws {
    let manifest = try Self.manifest(item.model)
    #expect(manifest.manifestDigest == item.modelDigest)
    #expect(manifest.identity.revision == item.revision)
    #expect(manifest.identity.variant == EGOneArtifactCatalog.modelVariant)
    #expect(manifest.identity.runtimeABI == EGOneArtifactCatalog.runtimeABI)
    #expect(manifest.files.count == item.fileCount)
    #expect(manifest.totalBytes == item.totalBytes)
    #expect(manifest.admission.entrypointFile == "config.json")
    #expect(manifest.admission.evictPreviousRevisions)

    // One address: our model host (no bundled manifest names the pre-#3271 host).
    #expect(manifest.sources.map(\.id) == ["our_copy"])
    #expect(
      manifest.sources.map(\.baseURL.absoluteString) == [
        "https://models.enviouswispr.com/eg1/\(item.revision)/",
      ])

    // No single download is larger than the limit; a larger file travels as parts, and then
    // every address must serve the parts (the whole file is not uploaded).
    let parted = manifest.files.filter { $0.parts != nil }
    #expect(parted.map(\.path) == item.partedFiles)
    for file in manifest.files {
      let fetched = file.parts?.map(\.sizeBytes) ?? [file.sizeBytes]
      #expect(
        fetched.allSatisfy { $0 <= 450_000_000 }, "\(file.path) has a download over the limit")
    }
    #expect(manifest.sources.allSatisfy { ($0.servesParts == true) == !parted.isEmpty })

    // The licence and notice files travel with the model.
    #expect(manifest.files.contains { $0.path == "LICENSE" })
    #expect(manifest.files.contains { $0.path == "NOTICE" })
    // The prompt form the helper reads from the folder is part of the pinned files.
    #expect(manifest.files.contains { $0.path == "chat_template.jinja" })

    // The catalog takes it as this size and as no other.
    let registration = try EGOneArtifactCatalog.modelRegistration(
      item.size, manifest: manifest, appSupport: Self.appSupport)
    for other in [EGOneSize.full, .mini, .micro] where other != item.size {
      #expect(throws: EGOneArtifactCatalog.Refusal.self) {
        try EGOneArtifactCatalog.modelRegistration(
          other, manifest: manifest, appSupport: Self.appSupport)
      }
    }
    #expect(throws: EGOneArtifactCatalog.Refusal.self) {
      try EGOneArtifactCatalog.checkerRegistration(
        item.size, manifest: manifest, appSupport: Self.appSupport)
    }
    let folders = try #require(EGOneArtifactCatalog.launchFolders(for: registration))
    #expect(folders.model == registration.installDirectory)
    #expect(folders.draft == registration.installDirectory.appendingPathComponent("helper", isDirectory: true))
    #expect(manifest.files.contains { $0.path == "helper/config.json" && $0.component == "helper" })
    #expect(manifest.files.contains { $0.path == "config.json" })
  }

  @Test(arguments: published)
  func theCheckerManifestBindsToItsOwnPublishedModel(_ item: Published) throws {
    let checker = try Self.manifest(item.checker)
    let model = try Self.manifest(item.model)
    let contract = try #require(checker.checkerContract)
    #expect(checker.manifestDigest == item.checkerDigest)
    #expect(checker.identity.revision == item.checkerRevision)
    #expect(checker.totalBytes == item.checkerBytes)
    #expect(Set(checker.files.map(\.path)) == ["adapters.safetensors", "adapter_config.json"])
    #expect(contract.format == LearnedWordCheckerContract.mlxLoRAFormat)
    #expect(contract.adapterSHA256.hasPrefix(item.adapterSHA256))
    // The threshold is the qualified one, to the last digit: the app compares with it.
    #expect(contract.qualifiedThreshold == item.threshold)
    #expect(
      checker.sources.map(\.baseURL.absoluteString) == [
        "https://models.enviouswispr.com/eg1/checker/\(item.checkerRevision)/",
      ])

    let registration = try EGOneArtifactCatalog.checkerRegistration(
      item.size, manifest: checker, appSupport: Self.appSupport)
    #expect(EGOneArtifactCatalog.checkerFolder(for: registration) == registration.installDirectory)
    #expect(EGOneArtifactCatalog.launchFolders(for: registration) == nil)

    // The binding the app computes: the admitted model, with the runtime prompt contract.
    let prompt = try Self.runtimePromptTemplateID()
    func verdict(_ base: DeliveryManifest, prompt: String) -> LearnedWordCheckerCompatibility {
      compatibility(
        contract: contract, checkerFamily: checker.identity.family,
        admittedBase: AdmittedCheckerBase(manifest: base, promptTemplateID: prompt))
    }
    #expect(verdict(model, prompt: prompt) == .compatible)
    #expect(verdict(model, prompt: "other") == .refused(.promptTemplateMismatch))
    // Another size's model, and the llama revision of EG-1, are not this checker's model.
    for other in Self.published where other.model != item.model {
      #expect(verdict(try Self.manifest(other.model), prompt: prompt) != .compatible)
    }
    #expect(verdict(try Self.manifest("eg1-delivery-manifest"), prompt: prompt) != .compatible)
  }

  /// The shipped llama pair is untouched by the new manifests: it still binds, and the llama
  /// checker does not bind to the new full-size model.
  @Test func theShippedLlamaCheckerStillBindsToTheLlamaModelOnly() throws {
    let checker = try Self.manifest("eg1-checker-delivery-manifest")
    let contract = try #require(checker.checkerContract)
    let prompt = try Self.runtimePromptTemplateID()
    func verdict(_ name: String) throws -> LearnedWordCheckerCompatibility {
      compatibility(
        contract: contract, checkerFamily: .egOneChecker,
        admittedBase: AdmittedCheckerBase(
          manifest: try Self.manifest(name), promptTemplateID: prompt))
    }
    #expect(try verdict("eg1-delivery-manifest") == .compatible)
    #expect(try verdict("eg1-mlx-delivery-manifest") == .refused(.baseRevisionMismatch))
  }

  @Test func theFourManifestsAreAppResources() throws {
    let project = try String(
      contentsOf: Self.root.appendingPathComponent("Project.swift"), encoding: .utf8)
    for item in Self.published {
      for name in [item.model, item.checker] {
        #expect(
          project.contains("\"Sources/EnviousWispr/Resources/\(name).json\""),
          "\(name).json must be listed in the app target's resources")
      }
    }
  }
}
