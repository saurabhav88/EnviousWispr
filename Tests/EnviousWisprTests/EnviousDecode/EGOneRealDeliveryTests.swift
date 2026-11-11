import CryptoKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation
import Testing

@testable import EnviousWisprEG1Engine
@testable import EnviousWisprModelDelivery

/// #4473 P4: the published EG-1 sizes, fetched from the PUBLIC address by the app's own
/// download code with the BUNDLED manifests, into a scratch folder, and then served by the
/// helper the build puts in the Dev app.
///
/// When this fails, a user who picks a size in Settings does not get a working model: the
/// download cannot finish from the real address, a cancelled download starts again from zero
/// (or cannot continue), the one file that travels in two parts is not put back together, a
/// damaged draft model is not repaired, the old EG-1 files stay beside the new ones, or the
/// downloaded folders do not start the helper. Encounter: every first use of a size.
/// Owner: plan #4473 P4.
///
/// This suite uses the network (5.5 GB) and the GPU, so it runs only in the real-world run and
/// only when it is given a scratch folder:
/// `TEST_RUNNER_EG1_REAL_DELIVERY_DIR=<an empty scratch folder>`
/// `scripts/xcode-test.sh --real-boundary --filter EnviousWisprTests/EGOneRealDeliveryTests`
/// It must run alone: it sets the process-wide download protocol list.
@Suite(
  "The published EG-1 sizes download from the public address, resume, repair, replace the old revision and start the helper (#4473)",
  .serialized, .tags(.productOutcome, .realBoundary), .realBoundaryRun)
struct EGOneRealDeliveryTests {
  typealias HelperTests = EnviousDecodeHelperIntegrationTests

  static var scratch: URL? {
    guard let path = ProcessInfo.processInfo.environment["EG1_REAL_DELIVERY_DIR"], !path.isEmpty
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static var canRun: Bool { scratch != nil && HelperTests.helperCandidates.count == 1 }

  init() {
    // The real network, seen through the recorder. No stub.
    ChunkAppendDelegate.protocolClassesForTesting = [RequestRecorder.self]
  }

  // MARK: - The recorder

  /// Passes every request to the real network unchanged and writes down what was asked and
  /// what the server answered. It serves nothing itself.
  final class RequestRecorder: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    struct Entry: Sendable, Equatable {
      let method, path: String
      let range: String?
      let status: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    nonisolated(unsafe) private static var bodyBytes: [String: Int] = [:]

    static var log: [Entry] { lock.withLock { entries } }
    /// Body bytes received so far for GET requests of `path`.
    static func received(_ path: String) -> Int { lock.withLock { bodyBytes[path] ?? 0 } }
    static func reset() {
      lock.withLock {
        entries = []
        bodyBytes = [:]
      }
    }

    private var session: URLSession?
    private var inner: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
      request.url?.host == "models.enviouswispr.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
      self.session = session
      inner = session.dataTask(with: request)
      inner?.resume()
    }

    override func stopLoading() {
      inner?.cancel()
      session?.invalidateAndCancel()
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      Self.lock.withLock {
        Self.entries.append(
          Entry(
            method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
            range: request.value(forHTTPHeaderField: "Range"),
            status: (response as? HTTPURLResponse)?.statusCode ?? 0))
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      if request.httpMethod ?? "GET" == "GET", let path = request.url?.path {
        Self.lock.withLock { Self.bodyBytes[path, default: 0] += data.count }
      }
      client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      if let error {
        client?.urlProtocol(self, didFailWithError: error)
      } else {
        client?.urlProtocolDidFinishLoading(self)
      }
      session.finishTasksAndInvalidate()
    }
  }

  // MARK: - Helpers

  static func manifest(_ name: String) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: Data(
        contentsOf: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/\(name).json")))
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty {
      hasher.update(data: block)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func controller() -> ModelDeliveryController {
    let suite = "test.eg1real.\(UUID().uuidString)"
    TestDefaults.suite(suite)!.removePersistentDomain(forName: suite)
    return ModelDeliveryController(
      defaults: TestDefaults.suite(suite)!, availableDiskBytes: { _ in .max })
  }

  /// Every file of the manifest is in the install folder with the manifest's size and hash,
  /// and the folder holds nothing else at its top level.
  static func expectInstalled(_ registration: DeliveryRegistration) throws -> [String: String] {
    var hashes: [String: String] = [:]
    for file in registration.manifest.files {
      let url = registration.installDirectory.appendingPathComponent(file.resolvedInstallPath)
      let digest = try sha256(of: url)
      hashes[file.resolvedInstallPath] = digest
      #expect(digest == file.sha256, "\(file.resolvedInstallPath) is not the published file")
    }
    let top = Set(registration.manifest.files.map(\.component))
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: registration.installDirectory.path))
        == top, "the install folder holds something the manifest does not list")
    return hashes
  }

  static func write(_ report: [String: Any], _ name: String, in scratch: URL) throws {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: scratch.appendingPathComponent(name))
  }

  static func lines(_ entries: ArraySlice<RequestRecorder.Entry>) -> [String] {
    entries.map { "\($0.method) \($0.path) range=\($0.range ?? "-") -> \($0.status)" }
  }

  /// Starts the helper from the admitted folders with the admitted checker, and asks for one
  /// polish and one word check the way the app does. Returns what it saw.
  static func serve(
    model: DeliveryRegistration, checker: DeliveryRegistration
  ) async throws -> [String: Any] {
    let folders = try #require(EGOneArtifactCatalog.launchFolders(for: model))
    let adapter = try #require(EGOneArtifactCatalog.checkerFolder(for: checker))
    let contract = try #require(checker.manifest.checkerContract)
    let helper = try HelperTests.Helper(
      model: folders.model.path, draft: folders.draft.path, wordCheckAdapter: adapter.path)
    defer { helper.stop() }
    try await helper.untilReady()
    let ready = try #require(helper.lines.first { $0.contains("ready port=") })
    #expect(ready.contains("wordcheck=on"))
    #expect(try await helper.request("/health", bearer: helper.token).status == 200)

    let body = try EnviousDecodeRequestMapperTests.data(
      try EnviousDecodeRequestMapperTests.polishBody(
        system: "Clean up the dictated text. Return only the cleaned text.",
        user: "um so i think we should uh meet on tuesday at three"))
    let answer = try HelperTests.fields(
      try await LocalPolishTransport.send(endpoint: helper.endpoint, body: body))
    #expect(answer.finish == "stop")
    #expect(!answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    let threshold = try #require(Double(contract.qualifiedThreshold))
    let endpoint = helper.endpoint
    let wordChecker = EnviousDecodeWordChecker(threshold: threshold) {
      EnviousDecodeWordChecker.Hold(endpoint: endpoint) {}
    }
    let decisions = try await wordChecker.decide(try EnviousDecodeWordCheckerTests.questions(2))
    #expect(decisions.count == 2)
    let scores = decisions.compactMap(\.score)
    #expect(scores.count == 2 && scores.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })

    helper.stop()
    #expect(!helper.process.isRunning, "the helper is still running after it was stopped")
    return [
      "ready": ready, "polish_finish": answer.finish, "polish_content": answer.content,
      "wordcheck_scores": scores, "threshold": contract.qualifiedThreshold,
      "helper_running_after_stop": helper.process.isRunning,
      "helper_exit_status": Int(helper.process.terminationStatus),
    ]
  }

  // MARK: - Full size: cancel and resume inside the two-part file, replace the llama revision

  @Test(
    "the full size downloads from the public address, a cancel inside the two-part file resumes from the bytes already there, the installed llama EG-1 and its checker are replaced, another size is not touched, and the helper serves from the folders",
    .enabled(if: EGOneRealDeliveryTests.canRun), .timeLimit(.minutes(60)))
  func theFullSizeDownloadsResumesReplacesAndServes() async throws {
    let scratch = try #require(Self.scratch).appendingPathComponent("full", isDirectory: true)
    try? FileManager.default.removeItem(at: scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let appSupport = scratch.appendingPathComponent("app-support", isDirectory: true)
    RequestRecorder.reset()

    let manifest = try Self.manifest("eg1-mlx-delivery-manifest")
    let model = try EGOneArtifactCatalog.modelRegistration(
      .full, manifest: manifest, appSupport: appSupport)
    let checker = try EGOneArtifactCatalog.checkerRegistration(
      .full, manifest: try Self.manifest("eg1-mlx-checker-delivery-manifest"),
      appSupport: appSupport)
    let metadata = model.metadataDirectory
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

    // What is installed before: the llama EG-1, its checker, and another size.
    typealias Seed = EGOneMLXDeliveryTests
    let oldModel = Seed.identity(.egOne, "eg-1", "eg1-1.2-c003", "q5km")
    // The shipped llama checker's own manifest, with a tiny file in place of its 66 MB.
    let oldCheckerManifest = try LearnedWordCheckerDeliveryTests.tinyChecker(Data("lora".utf8))
    let oldChecker = oldCheckerManifest.identity
    let otherSize = Seed.identity(.egOneMini, "eg-1-mini", "mini-a", "mlx-q6")
    let otherInstall = appSupport.appendingPathComponent("EnviousWispr/Models/eg-1-mini")
    try Seed.seedAdmitted(
      oldModel,
      files: [("old-00001-of-00001.gguf", Data("gguf".utf8), "old-00001-of-00001.gguf")],
      install: model.installDirectory, metadata: metadata)
    let oldCheckerFile = try #require(oldCheckerManifest.resolvedEntrypointPath)
    let seedStaging = metadata.appendingPathComponent("seed-checker", isDirectory: true)
    try FileManager.default.createDirectory(at: seedStaging, withIntermediateDirectories: true)
    try Data("lora".utf8).write(to: seedStaging.appendingPathComponent(oldCheckerFile))
    try CacheAdmission(
      manifest: oldCheckerManifest, installDirectory: checker.installDirectory,
      metadataDirectory: metadata
    ).promoteAndAdmit(
      stagedComponents: [oldCheckerFile], stagingDirectory: seedStaging, untouchedComponents: [])
    try? FileManager.default.removeItem(at: seedStaging)
    try Seed.seedAdmitted(
      otherSize, files: [("m.bin", Data("m".utf8), "m.bin")], install: otherInstall,
      metadata: metadata)
    func marker(_ identity: ModelIdentity) -> Bool {
      FileManager.default.fileExists(
        atPath: metadata.appendingPathComponent("\(identity.cacheKey).admission.json").path)
    }
    #expect(marker(oldModel) && marker(oldChecker) && marker(otherSize))

    // First attempt: cancelled when the first part of the two-part file has bytes.
    let parted = try #require(manifest.files.first { $0.parts != nil })
    let part = try #require(parted.parts?.first)
    let partPath = "/eg1/\(manifest.identity.revision)/\(part.path)"
    let delivery = Self.controller()
    async let first = delivery.ensureModelAvailable(model)
    let deadline = ContinuousClock.now + .seconds(40 * 60)
    while RequestRecorder.received(partPath) < 32 << 20 {
      try #require(ContinuousClock.now < deadline, "the two-part file was never reached")
      try await Task.sleep(for: .milliseconds(50))  // deadline-fallback: the signal is the recorder's byte count for the part; 40 min bounds the files before it
    }
    let cancelOutcome = await delivery.cancel(manifest.identity)
    let firstOutcome = await first
    #expect(cancelOutcome == .cancelled(resumable: true))
    #expect(firstOutcome == .cancelled(resumable: true))
    #expect(!(await delivery.isAdmitted(model)))

    // What the cancel left: the part's bytes and its resume record, in the staging folder.
    let staging = ModelDeliveryController.stagingDirectoryURL(for: model)
    let transport = staging.appendingPathComponent(".ew-transport", isDirectory: true)
    let staged = try FileManager.default.contentsOfDirectory(atPath: transport.path)
    let partFile = try #require(staged.first { $0.hasSuffix(".part1") })
    let partBytes =
      try FileManager.default.attributesOfItem(
        atPath: transport.appendingPathComponent(partFile).path)[.size] as! Int64
    #expect(partBytes > 0 && partBytes < part.sizeBytes)
    #expect(staged.contains(partFile + ".resume.json"))
    let beforeResume = RequestRecorder.log.count
    // The old revision is still installed while the new one is not admitted.
    #expect(marker(oldModel))

    // Second attempt: continues, and ends admitted.
    #expect(await delivery.ensureModelAvailable(model) == .admitted)
    #expect(await delivery.isAdmitted(model))
    let resumed = RequestRecorder.log.dropFirst(beforeResume)
    let partResume = try #require(
      resumed.first { $0.method == "GET" && $0.path == partPath })
    #expect(partResume.range == "bytes=\(partBytes)-", "the part did not continue from its bytes")
    #expect(partResume.status == 206)
    // No file was asked for from its first byte twice.
    let fromZero = RequestRecorder.log.filter { $0.method == "GET" && $0.range == nil }
    #expect(Set(fromZero.map(\.path)).count == fromZero.count, "a file was downloaded twice")
    #expect(RequestRecorder.log.allSatisfy { [200, 206].contains($0.status) })

    // The folder is the published model; the two parts are one file again; staging is gone.
    let hashes = try Self.expectInstalled(model)
    #expect(hashes[parted.resolvedInstallPath] == parted.sha256)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    // The llama EG-1 is replaced; the checker and the other size are not touched yet.
    #expect(!marker(oldModel) && marker(manifest.identity))
    #expect(marker(oldChecker) && marker(otherSize))
    #expect(try Data(contentsOf: otherInstall.appendingPathComponent("m.bin")) == Data("m".utf8))

    // The checker: downloaded, and the llama checker replaced.
    let beforeChecker = RequestRecorder.log.count
    #expect(await delivery.ensureModelAvailable(checker) == .admitted)
    _ = try Self.expectInstalled(checker)
    #expect(!marker(oldChecker) && marker(checker.manifest.identity) && marker(otherSize))

    let served = try await Self.serve(model: model, checker: checker)
    try Self.write(
      [
        "manifest_digest": manifest.manifestDigest,
        "first_attempt": "\(firstOutcome)", "cancel": "\(cancelOutcome)",
        "part_bytes_at_cancel": partBytes, "part_size": part.sizeBytes,
        "requests_first_attempt": Self.lines(RequestRecorder.log.prefix(beforeResume)),
        "requests_resume": Self.lines(RequestRecorder.log[beforeResume..<beforeChecker]),
        "requests_checker": Self.lines(RequestRecorder.log.dropFirst(beforeChecker)),
        "installed_sha256": hashes, "staging_removed": true,
        "old_llama_model_marker_removed": !marker(oldModel),
        "old_llama_checker_marker_removed": !marker(oldChecker),
        "other_size_kept": marker(otherSize), "helper": served,
      ], "report-full.json", in: try #require(Self.scratch))
    try FileManager.default.removeItem(at: scratch)
  }

  // MARK: - Micro: a damaged draft model is repaired from the public address

  @Test(
    "the Micro size downloads from the public address, a damaged draft model is repaired by fetching the draft folder again and nothing else, and the helper serves from the folders",
    .enabled(if: EGOneRealDeliveryTests.canRun), .timeLimit(.minutes(30)))
  func theMicroSizeDownloadsRepairsAndServes() async throws {
    try await Self.downloadRepairAndServe(
      .micro, model: "eg1-micro-delivery-manifest",
      checker: "eg1-micro-checker-delivery-manifest", label: "micro")
  }

  @Test(
    "the Mini size downloads from the public address, a damaged draft model is repaired by fetching the draft folder again and nothing else, and the helper serves from the folders",
    .enabled(if: EGOneRealDeliveryTests.canRun), .timeLimit(.minutes(30)))
  func theMiniSizeDownloadsRepairsAndServes() async throws {
    try await Self.downloadRepairAndServe(
      .mini, model: "eg1-mini-delivery-manifest",
      checker: "eg1-mini-checker-delivery-manifest", label: "mini")
  }

  /// One size whose files all travel whole: download, damage the draft model, repair, serve.
  private static func downloadRepairAndServe(
    _ size: EGOneSize, model modelName: String, checker checkerName: String, label: String
  ) async throws {
    let scratch = try #require(Self.scratch).appendingPathComponent(label, isDirectory: true)
    try? FileManager.default.removeItem(at: scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let appSupport = scratch.appendingPathComponent("app-support", isDirectory: true)
    RequestRecorder.reset()

    let manifest = try Self.manifest(modelName)
    let model = try EGOneArtifactCatalog.modelRegistration(
      size, manifest: manifest, appSupport: appSupport)
    let checker = try EGOneArtifactCatalog.checkerRegistration(
      size, manifest: try Self.manifest(checkerName), appSupport: appSupport)
    let delivery = Self.controller()
    #expect(await delivery.ensureModelAvailable(model) == .admitted)
    let prefix = "/eg1/\(manifest.identity.revision)/"
    let firstRequests = RequestRecorder.log
    #expect(
      Set(firstRequests.filter { $0.method == "GET" }.map(\.path))
        == Set(manifest.files.map { prefix + $0.path }))
    _ = try Self.expectInstalled(model)

    // The draft model's weights are damaged on disk.
    let draftFiles = manifest.files.filter { $0.component == EGOneArtifactCatalog.draftComponent }
    let weights = try #require(draftFiles.max { $0.sizeBytes < $1.sizeBytes })
    let damaged = model.installDirectory.appendingPathComponent(weights.resolvedInstallPath)
    try Data("damaged".utf8).write(to: damaged)
    #expect(await delivery.ensureModelAvailable(model) == .admitted)
    let repair = RequestRecorder.log.dropFirst(firstRequests.count)
    #expect(
      Set(repair.filter { $0.method == "GET" }.map(\.path))
        == Set(draftFiles.map { prefix + $0.path }),
      "the repair fetched something other than the draft model's files")
    let hashes = try Self.expectInstalled(model)
    #expect(
      !FileManager.default.fileExists(
        atPath: ModelDeliveryController.stagingDirectoryURL(for: model).path))

    let beforeChecker = RequestRecorder.log.count
    #expect(await delivery.ensureModelAvailable(checker) == .admitted)
    _ = try Self.expectInstalled(checker)
    #expect(RequestRecorder.log.allSatisfy { [200, 206].contains($0.status) })

    let served = try await Self.serve(model: model, checker: checker)
    try Self.write(
      [
        "manifest_digest": manifest.manifestDigest,
        "requests_first": Self.lines(firstRequests[...]),
        "requests_repair": Self.lines(repair),
        "requests_checker": Self.lines(RequestRecorder.log.dropFirst(beforeChecker)),
        "damaged_file": weights.resolvedInstallPath, "installed_sha256": hashes,
        "staging_removed": true, "helper": served,
      ], "report-\(label).json", in: try #require(Self.scratch))
    try FileManager.default.removeItem(at: scratch)
  }
}
