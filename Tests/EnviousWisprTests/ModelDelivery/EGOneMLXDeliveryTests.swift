import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprEG1Engine
@testable import EnviousWisprModelDelivery

/// #4473 P4: the delivery of an EG-1 size as an MLX model FOLDER (polish model files plus the
/// draft model under `helper`), and the one rule that lets the new full-size revision replace
/// the installed llama revision.
///
/// When this fails, a user who picks a size gets a model that cannot start or an update that
/// never comes: the polish model is admitted without its draft model, a damaged draft model is
/// not repaired, the file that travels in two parts is not put back together, the installed
/// EG-1 is never seen as the revision the new one replaces (so no update is offered and
/// gigabytes of old files stay), or another size's or model's files are deleted as if they
/// were an old revision. Encounter: every download, repair, cancel and update of a size.
/// Owner: plan #4473 P4. Rig: tiny hash-pinned files served by the delivery suites' URL stub;
/// no public address is used.
@Suite(
  "An EG-1 size is delivered as its folder with its draft model, and only the approved old revision is replaced (#4473)",
  .serialized, .tags(.productOutcome))
struct EGOneMLXDeliveryTests {
  init() {
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
  }

  typealias File = (path: String, content: Data, component: String)

  // MARK: - The rig

  static let config = Data(#"{"model_type":"qwen3_5"}"#.utf8)
  static let shardOne = Data("0123456789".utf8)
  static let shardTwo = Data("abcdefgh".utf8)
  static let draftConfig = Data(#"{"draft":true}"#.utf8)
  static let draftWeights = Data("draft-weights-v1".utf8)
  /// A model's files: three at the top level and the draft model's two under `helper`.
  static let modelFiles: [File] = [
    ("config.json", config, "config.json"),
    ("model-00001-of-00002.safetensors", shardOne, "model-00001-of-00002.safetensors"),
    ("model-00002-of-00002.safetensors", shardTwo, "model-00002-of-00002.safetensors"),
    ("helper/config.json", draftConfig, "helper"),
    ("helper/model.safetensors", draftWeights, "helper"),
  ]
  /// The first shard travels as two parts.
  static let parts = [Data("01234".utf8), Data("56789".utf8)]

  struct Rig {
    let root: URL
    let scope: String
    let base: String
    var appSupport: URL { root.appendingPathComponent("app-support", isDirectory: true) }

    init() throws {
      root = TestTemporaryDirectory.url
        .appendingPathComponent("eg1-mlx-\(UUID().uuidString)", isDirectory: true)
      scope = "/eg1-mlx-\(UUID().uuidString)/"
      base = "https://mirror.invalid.example\(scope)"
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      DeliveryStubProtocol.beginScope(pathPrefix: scope)
    }

    func serve(_ path: String, _ body: Data) {
      DeliveryStubProtocol.enqueue(
        url: base + path,
        .init(status: 200, headers: ["Content-Length": String(body.count)], body: body))
    }

    var requests: [String] {
      DeliveryStubProtocol.requests(in: scope).map {
        String($0.dropFirst("GET ".count + base.count))
      }
    }

    func controller() -> ModelDeliveryController {
      let suite = "test.eg1mlx.\(UUID().uuidString)"
      TestDefaults.suite(suite)!.removePersistentDomain(forName: suite)
      return ModelDeliveryController(
        defaults: TestDefaults.suite(suite)!, availableDiskBytes: { _ in .max })
    }
  }

  /// A signed model manifest for a size. `mutate` changes it before it is signed.
  static func modelManifest(
    _ size: EGOneSize, base: String, revision: String = "rev-b", files: [File] = modelFiles,
    mutate: ((inout [String: Any]) -> Void)? = nil
  ) throws -> DeliveryManifest {
    let artifact = EGOneArtifactCatalog.model(size)
    return try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: files, sources: [["id": "our_copy", "baseURL": base]],
        family: artifact.family.rawValue
      ) { object in
        object["identity"] = [
          "family": artifact.family.rawValue, "name": artifact.name, "revision": revision,
          "variant": artifact.variant, "runtimeABI": EGOneArtifactCatalog.runtimeABI,
        ]
        var sources = object["sources"] as! [[String: Any]]
        sources[0]["servesParts"] = true
        object["sources"] = sources
        var entries = object["files"] as! [[String: Any]]
        for index in entries.indices
        where entries[index]["path"] as? String == "model-00001-of-00002.safetensors" {
          entries[index]["parts"] = parts.enumerated().map { number, data in
            [
              "path": "model-00001-of-00002.safetensors.part\(number + 1)",
              "sizeBytes": data.count, "sha256": ManifestFixture.sha256(data),
            ] as [String: Any]
          }
        }
        object["files"] = entries
        var admission = object["admission"] as! [String: Any]
        admission["entrypointFile"] = "config.json"
        admission["evictPreviousRevisions"] = true
        object["admission"] = admission
        mutate?(&object)
      })
  }

  func serveModel(_ rig: Rig) {
    rig.serve("config.json", Self.config)
    rig.serve("model-00001-of-00002.safetensors.part1", Self.parts[0])
    rig.serve("model-00001-of-00002.safetensors.part2", Self.parts[1])
    rig.serve("model-00002-of-00002.safetensors", Self.shardTwo)
    rig.serve("helper/config.json", Self.draftConfig)
    rig.serve("helper/model.safetensors", Self.draftWeights)
  }

  static func identity(
    _ family: ModelFamily, _ name: String, _ revision: String, _ variant: String
  ) -> ModelIdentity {
    ModelIdentity(
      family: family, name: name, revision: revision, variant: variant, runtimeABI: "any")
  }

  /// An admitted install of `identity` in `registration`'s folders: the files on disk and the
  /// marker that records them, written by the real admission code.
  static func seedAdmitted(
    _ identity: ModelIdentity, files: [File], install: URL, metadata: URL
  ) throws {
    let manifest = try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(files: files, family: identity.family.rawValue) {
        object in
        object["identity"] = [
          "family": identity.family.rawValue, "name": identity.name,
          "revision": identity.revision, "variant": identity.variant, "runtimeABI": "llama-test",
        ]
      })
    let staging = metadata.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
    for file in files {
      let url = staging.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try file.content.write(to: url)
    }
    let gate = CacheAdmission(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
    try gate.promoteAndAdmit(
      stagedComponents: Set(files.map(\.component)), stagingDirectory: staging,
      untouchedComponents: [])
    try? FileManager.default.removeItem(at: staging)
    #expect(gate.isAdmitted())
  }

  // MARK: - 1. The folder is admitted whole, and handed to the engine as folders

  @Test(
    "a size's folder is downloaded with its draft model and its two-part file, admitted as one, handed to the engine as two folders, and a manifest that is not that size's is refused"
  )
  func theFolderIsAdmittedWholeAndHandedOverAsFolders() async throws {
    let rig = try Rig()
    let manifest = try Self.modelManifest(.mini, base: rig.base)
    let registration = try EGOneArtifactCatalog.modelRegistration(
      .mini, manifest: manifest, appSupport: rig.appSupport)
    #expect(
      registration.installDirectory.path.hasSuffix("/EnviousWispr/Models/eg-1-mini")
        && registration.metadataDirectory.path.hasSuffix("/EnviousWispr/ModelDelivery"))
    serveModel(rig)
    let controller = rig.controller()
    #expect(await controller.ensureModelAvailable(registration) == .admitted)
    #expect(await controller.isAdmitted(registration))

    // Every file is where the engine reads it; the two-part file is the whole file again and
    // no part is left in the install folder.
    let install = registration.installDirectory
    for file in Self.modelFiles {
      #expect(try Data(contentsOf: install.appendingPathComponent(file.path)) == file.content)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: install.path).sorted() == [
        "config.json", "helper", "model-00001-of-00002.safetensors",
        "model-00002-of-00002.safetensors",
      ])
    #expect(
      Set(rig.requests) == [
        "config.json", "model-00001-of-00002.safetensors.part1",
        "model-00001-of-00002.safetensors.part2", "model-00002-of-00002.safetensors",
        "helper/config.json", "helper/model.safetensors",
      ])

    // The hand-off: two folders, decided by the runtime ABI. The manifest's entrypoint stays
    // a real file.
    let folders = try #require(EGOneArtifactCatalog.launchFolders(for: registration))
    #expect(folders.model == install && folders.draft == install.appendingPathComponent("helper"))
    #expect(manifest.resolvedEntrypointPath == "config.json")
    #expect(EGOneArtifactCatalog.checkerFolder(for: registration) == nil)
    let llama = DeliveryRegistration(
      manifest: try DeliveryManifest.load(
        from: ManifestFixture.manifestJSON(
          files: [("eg-1.gguf", Self.shardOne, "eg-1.gguf")], family: "eg_one")),
      installDirectory: install, metadataDirectory: registration.metadataDirectory)
    #expect(EGOneArtifactCatalog.launchFolders(for: llama) == nil)

    // The six artifacts, written out.
    typealias Catalog = EGOneArtifactCatalog
    #expect(
      EGOneSize.allCases.map { Catalog.model($0) } == [
        .init(family: .egOne, name: "eg-1", variant: "mlx-q6", installFolder: "eg-1"),
        .init(family: .egOneMini, name: "eg-1-mini", variant: "mlx-q6", installFolder: "eg-1-mini"),
        .init(
          family: .egOneMicro, name: "eg-1-micro", variant: "mlx-q6", installFolder: "eg-1-micro"),
      ])
    #expect(
      EGOneSize.allCases.map { Catalog.checker($0) } == [
        .init(
          family: .egOneChecker, name: "eg1c", variant: "mlx-f32", installFolder: "eg-1-checker"),
        .init(
          family: .egOneMiniChecker, name: "eg1c-mini", variant: "mlx-f32",
          installFolder: "eg-1-mini-checker"),
        .init(
          family: .egOneMicroChecker, name: "eg1c-micro", variant: "mlx-f32",
          installFolder: "eg-1-micro-checker"),
      ])
    #expect(Catalog.runtimeABI == "enviousdecode-v1" && Catalog.draftComponent == "helper")

    // Refused: another size's manifest, a manifest with no draft model, one with nothing else,
    // and a manifest of another runtime.
    func refusal(_ size: EGOneSize, _ manifest: DeliveryManifest) -> Catalog.Refusal? {
      do {
        _ = try Catalog.modelRegistration(size, manifest: manifest, appSupport: rig.appSupport)
        return nil
      } catch { return error as? Catalog.Refusal }
    }
    #expect(
      refusal(.micro, manifest)
        == .identityMismatch(
          expected: "eg_one_micro/eg-1-micro/mlx-q6/enviousdecode-v1",
          found: "eg_one_mini/eg-1-mini/mlx-q6/enviousdecode-v1"))
    #expect(refusal(.mini, manifest) == nil)
    let noDraft = try Self.modelManifest(
      .mini, base: rig.base, files: Array(Self.modelFiles.prefix(3)))
    #expect(refusal(.mini, noDraft) == .draftModelMissing)
    let onlyDraft = try Self.modelManifest(
      .mini, base: rig.base, files: Array(Self.modelFiles.suffix(2))
    ) { object in
      var admission = object["admission"] as! [String: Any]
      admission["entrypointFile"] = "helper/config.json"
      object["admission"] = admission
    }
    #expect(refusal(.mini, onlyDraft) == .polishModelMissing)
    let otherRuntime = try Self.modelManifest(.mini, base: rig.base) { object in
      var identity = object["identity"] as! [String: Any]
      identity["runtimeABI"] = "llamacpp-eg1-v1"
      object["identity"] = identity
    }
    #expect(
      refusal(.mini, otherRuntime)
        == .identityMismatch(
          expected: "eg_one_mini/eg-1-mini/mlx-q6/enviousdecode-v1",
          found: "eg_one_mini/eg-1-mini/mlx-q6/llamacpp-eg1-v1"))
  }

  // MARK: - 2. Repair and resume

  @Test(
    "a damaged draft model is repaired by fetching the draft folder again and nothing else, and a download cancelled with bytes already staged can be resumed to an admitted folder"
  )
  func aDamagedDraftModelIsRepairedAndACancelledDownloadResumes() async throws {
    let rig = try Rig()
    let registration = try EGOneArtifactCatalog.modelRegistration(
      .micro, manifest: try Self.modelManifest(.micro, base: rig.base), appSupport: rig.appSupport)
    let controller = rig.controller()
    await controller.setBackoffSleepForTesting { _ in }
    serveModel(rig)
    #expect(await controller.ensureModelAvailable(registration) == .admitted)
    let first = rig.requests.count
    #expect(first == 6)

    // The draft model's weights are damaged on disk. The next check finds it, fetches the
    // `helper` component again (both of its files) and no polish model file.
    let draft = registration.installDirectory.appendingPathComponent("helper/model.safetensors")
    try Data("damaged".utf8).write(to: draft)
    rig.serve("helper/config.json", Self.draftConfig)
    rig.serve("helper/model.safetensors", Self.draftWeights)
    #expect(await controller.ensureModelAvailable(registration) == .admitted)
    #expect(try Data(contentsOf: draft) == Self.draftWeights)
    #expect(
      Set(rig.requests.dropFirst(first)) == ["helper/config.json", "helper/model.safetensors"])

    // Cancel with bytes already staged: the answer is "resumable", and the next download
    // ends admitted. (Second registration, fresh folders: the full size.)
    let other = try Rig()
    let full = try EGOneArtifactCatalog.modelRegistration(
      .full, manifest: try Self.modelManifest(.full, base: other.base),
      appSupport: other.appSupport)
    let staging = ModelDeliveryController.stagingDirectoryURL(for: full)
    try FileManager.default.createDirectory(
      at: staging.appendingPathComponent("helper"), withIntermediateDirectories: true)
    // The first six bytes of the draft model's weights, with the record that lets the next
    // download continue from them.
    let stagedDraft = staging.appendingPathComponent("helper/model.safetensors")
    try Self.draftWeights.prefix(6).write(to: stagedDraft)
    try JSONSerialization.data(withJSONObject: [
      "etag": "\"d\"", "contentLength": Self.draftWeights.count,
    ] as [String: Any]).write(to: URL(fileURLWithPath: stagedDraft.path + ".resume.json"))
    let second = other.controller()
    await second.setBackoffSleepForTesting { _ in }
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    await second.setBeforeExistingCacheValidationForTesting {
      entered.continuation.yield()
      entered.continuation.finish()
      var iterator = release.stream.makeAsyncIterator()
      _ = await iterator.next()
    }
    async let attempt = second.ensureModelAvailable(full)
    let didEnter = await withDeadline(seconds: 5) {
      var iterator = entered.stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(didEnter == true, "the attempt never reached the validation window")
    let deadlineRelease = Task {
      try? await Task.sleep(for: .seconds(5))  // deadline-fallback: frees a wedged cancel path
      release.continuation.yield()
      release.continuation.finish()
    }
    let cancelled = await second.cancel(full.manifest.identity)
    deadlineRelease.cancel()
    release.continuation.yield()
    release.continuation.finish()
    _ = await attempt
    #expect(cancelled == .cancelled(resumable: true))
    #expect(!(await second.isAdmitted(full)))
    await second.setBeforeExistingCacheValidationForTesting(nil)
    // The resumed download: every other file whole; for the draft weights the server first
    // confirms it is the same object, then sends only the bytes after the six on disk.
    other.serve("config.json", Self.config)
    other.serve("model-00001-of-00002.safetensors.part1", Self.parts[0])
    other.serve("model-00001-of-00002.safetensors.part2", Self.parts[1])
    other.serve("model-00002-of-00002.safetensors", Self.shardTwo)
    other.serve("helper/config.json", Self.draftConfig)
    DeliveryStubProtocol.enqueue(
      url: other.base + "helper/model.safetensors",
      .init(
        status: 200,
        headers: ["Content-Length": String(Self.draftWeights.count), "ETag": "\"d\""],
        body: Data()))
    DeliveryStubProtocol.enqueue(
      url: other.base + "helper/model.safetensors",
      .init(
        status: 206, headers: ["Content-Length": String(Self.draftWeights.count - 6)],
        body: Self.draftWeights.suffix(from: 6)))
    #expect(await second.ensureModelAvailable(full) == .admitted)
    #expect(
      try Data(contentsOf: full.installDirectory.appendingPathComponent("helper/model.safetensors"))
        == Self.draftWeights)
  }

  // MARK: - 3. Only the approved old revision is replaced

  @Test(
    "the installed llama EG-1 is the revision the new full size replaces: it is seen, its files and marker go at admission, its staged bytes are swept; another variant, name, family or size is never touched"
  )
  func onlyTheApprovedPredecessorIsReplaced() async throws {
    // The table, written out, and every variant in it is a registered shipped variant.
    #expect(
      PriorRevisionAdmission.approvedPredecessorVariants == [
        "eg_one|eg-1": ["mlx-q6": ["q5km"]],
        "eg_one_checker|eg1c": ["mlx-f32": ["f16"]],
      ])
    for (model, pairs) in PriorRevisionAdmission.approvedPredecessorVariants {
      let registered = try #require(ShippedModelNames.variants[model], "\(model)")
      for (successor, predecessors) in pairs {
        #expect(registered.contains(successor) && predecessors.isSubset(of: registered), "\(model)")
        #expect(!predecessors.contains(successor) && !predecessors.contains(""), "\(model)")
      }
    }
    typealias Prior = PriorRevisionAdmission
    #expect(
      Prior.supersededVariants(of: Self.identity(.egOne, "eg-1", "r", "mlx-q6")) == [
        "mlx-q6", "q5km",
      ])
    #expect(Prior.supersededVariants(of: Self.identity(.egOne, "eg-1", "r", "q5km")) == ["q5km"])
    #expect(
      Prior.supersededVariants(of: Self.identity(.egOneMini, "eg-1-mini", "r", "mlx-q6")) == [
        "mlx-q6"
      ])
    #expect(
      Prior.supersededVariants(of: Self.identity(.s1Mini, "s1-mini", "r", "q4km")) == ["q4km"])

    // An installed llama EG-1 (two shard files) in EG-1's folder.
    let rig = try Rig()
    let manifest = try Self.modelManifest(.full, base: rig.base, revision: "eg1-1.3-x")
    let registration = try EGOneArtifactCatalog.modelRegistration(
      .full, manifest: manifest, appSupport: rig.appSupport)
    let install = registration.installDirectory
    let metadata = registration.metadataDirectory
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let old = Self.identity(.egOne, "eg-1", "eg1-1.2-c003", "q5km")
    let shards: [File] = [
      ("old-00001-of-00002.gguf", Data("gguf-1".utf8), "old-00001-of-00002.gguf"),
      ("old-00002-of-00002.gguf", Data("gguf-2".utf8), "old-00002-of-00002.gguf"),
    ]
    try Self.seedAdmitted(old, files: shards, install: install, metadata: metadata)
    let oldMarker = metadata.appendingPathComponent("\(old.cacheKey).admission.json")
    #expect(FileManager.default.fileExists(atPath: oldMarker.path))

    // Seen by the new full size (so an update is owed), by nothing else.
    func survives(_ identity: ModelIdentity) -> Bool {
      Prior.supersededInstallSurvives(
        identity: identity, metadataDirectory: metadata, installDirectory: install)
    }
    #expect(survives(manifest.identity))
    #expect(
      survives(Self.identity(.egOne, "eg-1", "eg1-1.2-c004", "q5km")), "same format, as before")
    for stranger in [
      Self.identity(.egOne, "eg-1", "eg1-1.3-x", "mlx-q8"),  // a variant that is not in the table
      Self.identity(.egOne, "eg-2", "eg1-1.3-x", "mlx-q6"),  // another name
      Self.identity(.egOneMini, "eg-1-mini", "eg1-mini-x", "mlx-q6"),  // another size
      Self.identity(.egOneChecker, "eg1c", "eg1c-x", "mlx-f32"),  // the checker
      Self.identity(.s1Mini, "s1-mini", "s1-x", "q4km"),  // S-1
    ] {
      #expect(!survives(stranger), "\(stranger.cacheKey)")
    }
    // The old revision does not see the new one as ITS predecessor.
    try Self.seedAdmitted(
      Self.identity(.egOneMini, "eg-1-mini", "mini-a", "mlx-q6"),
      files: [("m.bin", Data("m".utf8), "m.bin")],
      install: rig.appSupport.appendingPathComponent("EnviousWispr/Models/eg-1-mini"),
      metadata: metadata)
    let miniMarker = metadata.appendingPathComponent(
      "eg_one_mini-eg-1-mini-mini-a-mlx-q6.admission.json")
    #expect(FileManager.default.fileExists(atPath: miniMarker.path))

    // Staged bytes: the old llama revision's, an unlisted variant's, and Mini's.
    let staging = metadata.appendingPathComponent("staging", isDirectory: true)
    let stagedOld = staging.appendingPathComponent(
      "eg_one-eg-1-eg1-1.2-c002-q5km", isDirectory: true)
    let stagedStranger = staging.appendingPathComponent(
      "eg_one-eg-1-eg1-1.3-x-mlx-q8", isDirectory: true)
    let stagedMini = staging.appendingPathComponent(
      "eg_one_mini-eg-1-mini-mini-b-mlx-q6", isDirectory: true)
    for folder in [stagedOld, stagedStranger, stagedMini] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: folder.appendingPathComponent("part.bin"))
    }
    #expect(
      Prior.supersededStagingURLs(for: manifest.identity, metadataDirectory: metadata)
        .map(\.lastPathComponent) == ["eg_one-eg-1-eg1-1.2-c002-q5km"])
    #expect(
      Prior.supersededStagingURLs(
        for: Self.identity(.egOneMini, "eg-1-mini", "mini-c", "mlx-q6"), metadataDirectory: metadata
      ).map(\.lastPathComponent) == ["eg_one_mini-eg-1-mini-mini-b-mlx-q6"])

    // The new full size is downloaded and admitted into the same folder.
    serveModel(rig)
    let controller = rig.controller()
    #expect(await controller.ensureModelAvailable(registration) == .admitted)
    // The llama shards and marker are gone; the new folder is complete.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: install.path).sorted() == [
        "config.json", "helper", "model-00001-of-00002.safetensors",
        "model-00002-of-00002.safetensors",
      ])
    #expect(!FileManager.default.fileExists(atPath: oldMarker.path))
    #expect(!survives(manifest.identity), "nothing is left to replace")
    // The old revision's staged bytes were swept; the stranger's and Mini's, and Mini's
    // install and marker, were not touched.
    #expect(!FileManager.default.fileExists(atPath: stagedOld.path))
    #expect(
      FileManager.default.fileExists(atPath: stagedStranger.appendingPathComponent("part.bin").path)
    )
    #expect(
      FileManager.default.fileExists(atPath: stagedMini.appendingPathComponent("part.bin").path))
    #expect(FileManager.default.fileExists(atPath: miniMarker.path))
    #expect(
      FileManager.default.fileExists(
        atPath: rig.appSupport.appendingPathComponent("EnviousWispr/Models/eg-1-mini/m.bin").path))
  }
}
