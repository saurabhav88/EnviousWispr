import Foundation
import Testing

// `@testable` is required from Chunk 2 onward and was NOT needed in Chunk 1.
// `dynamicCatalog(from:cloudCatalogIDs:)` is internal, and Chunk 2's acceptance
// item 3 forbids widening it, so a plain import cannot reach it. The two
// pre-existing suites that call the same function (`OllamaModelCatalogTests`,
// `OllamaManageModelsPresentationTests`) already use `@testable` for exactly
// this reason. Every symbol Chunk 1 introduced remains `package` and would still
// be reachable on a plain import.
@testable import EnviousWisprLLM

/// #1956: the hosted-catalog transport and parser.
///
/// Scope boundary, stated rather than implied: this suite proves the CLIENT's
/// contract — the request it sends, what it accepts as a valid document, and the
/// two safety limits. It does not prove the catalog merge, the refresh state
/// machine, or anything rendered; those arrive in later chunks with their own
/// suites.
///
/// The two limits are tested against PRODUCTION functions
/// (`shouldFollowRedirect(to:)`, `accumulate(_:maximumBytes:)`), not against the
/// injected transport re-implementing them. A test that asserts a fake threw
/// `responseTooLarge` on command proves only that the fake works.
///
/// Three conventions here are load-bearing rather than stylistic.
///
/// Fixtures THROW instead of forcing, so a broken fixture reports as a failure in
/// the test that needed it rather than as a crash in the helper.
///
/// Every fixture is built OUTSIDE its `#expect(throws:)` block — a `try` inside
/// that block would let a fixture failure masquerade as the very error the test
/// claims to be proving.
///
/// Sequences are compared through `zip`, never by subscripting after a count
/// expectation. `#expect` does not halt, so a count regression would record its
/// failure and then run into an out-of-bounds crash, replacing a readable
/// failure with a dead run.
///
/// See the import above for why this file uses `@testable` from Chunk 2 onward.
@Suite("Ollama hosted catalog client (#1956)")
struct OllamaSetupServiceCloudCatalogTests {

  // MARK: - Fixtures

  /// Captured live from `https://ollama.com/v1/models` on 2026-08-05, trimmed to
  /// the fields the parser reads. Eighteen models, which is the number the plan's
  /// §2.5 measurements rest on.
  private static let liveDocumentIDs = [
    "deepseek-v4-flash:0731", "deepseek-v4-flash:preview", "deepseek-v4-pro", "gemma4:31b",
    "glm-5.1", "glm-5.2", "gpt-oss:120b", "gpt-oss:20b", "kimi-k2.6", "kimi-k2.7-code",
    "kimi-k3", "minimax-m2.7", "minimax-m3", "mistral-large-3:675b", "nemotron-3-nano:30b",
    "nemotron-3-super", "nemotron-3-ultra", "qwen3.5:397b",
  ]

  private func document(ids: [String], sourceLocation: SourceLocation = #_sourceLocation) throws
    -> Data
  {
    let rows = ids.map { ["id": $0, "object": "model", "owned_by": "ollama"] as [String: Any] }
    return try document(rawRows: rows, sourceLocation: sourceLocation)
  }

  private func document(rawRows: [Any], sourceLocation: SourceLocation = #_sourceLocation) throws
    -> Data
  {
    try #require(
      try? JSONSerialization.data(withJSONObject: ["object": "list", "data": rawRows]),
      sourceLocation: sourceLocation)
  }

  /// The endpoint the client is contractually required to call, and the URL the
  /// stub response is built from — so a response is never fabricated out of
  /// whatever the request happened to carry.
  private func endpointURL(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
    try #require(URL(string: "https://ollama.com/v1/models"), sourceLocation: sourceLocation)
  }

  private func url(_ string: String, sourceLocation: SourceLocation = #_sourceLocation) throws
    -> URL
  {
    try #require(URL(string: string), sourceLocation: sourceLocation)
  }

  private func client(
    status: Int = 200, body: Data,
    observe: (@Sendable (URLRequest, Int) -> Void)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> OllamaCloudCatalogClient {
    let stub = try #require(
      HTTPURLResponse(
        url: try endpointURL(sourceLocation: sourceLocation), statusCode: status,
        httpVersion: nil, headerFields: nil),
      sourceLocation: sourceLocation)
    return OllamaCloudCatalogClient { request, maximumBytes in
      observe?(request, maximumBytes)
      return (body, stub)
    }
  }

  private func bytes(_ values: [UInt8]) -> AsyncThrowingStream<UInt8, Error> {
    AsyncThrowingStream { continuation in
      for value in values { continuation.yield(value) }
      continuation.finish()
    }
  }

  // MARK: - The happy path and the request itself

  @Test("a captured live document yields all eighteen advertised ids")
  func liveDocumentParses() async throws {
    let sut = try client(body: try document(ids: Self.liveDocumentIDs))
    let ids = try await sut.fetchIDs()
    #expect(ids == Self.liveDocumentIDs)
    #expect(ids.count == 18)
  }

  /// The request is part of the privacy claim, so it is asserted rather than
  /// described: exact URL, GET, no body, and the byte ceiling handed to the
  /// transport so an injected one is held to the production contract.
  @Test("the request is a bare five-second GET to the exact endpoint, carrying no body")
  func requestShape() async throws {
    let captured = CapturedRequest()
    let sut = try client(body: try document(ids: ["gpt-oss:20b"])) { request, maximumBytes in
      captured.store(request: request, maximumBytes: maximumBytes)
    }
    _ = try await sut.fetchIDs()

    #expect(captured.url?.absoluteString == "https://ollama.com/v1/models")
    #expect(captured.method == "GET")
    #expect(captured.body == nil)
    #expect(captured.timeout == 5)
    #expect(captured.maximumBytes == OllamaCloudCatalogClient.maximumBytes)
    #expect(OllamaCloudCatalogClient.maximumBytes == 1_048_576)
  }

  @Test("a non-200 response is refused even when its body is a perfectly good document")
  func nonOKStatusThrows() async throws {
    let sut = try client(status: 503, body: try document(ids: Self.liveDocumentIDs))
    await #expect(throws: CloudCatalogError.invalidResponse) { _ = try await sut.fetchIDs() }
  }

  // MARK: - Invalid documents

  @Test("an object with no data array is an invalid document")
  func emptyObjectThrows() {
    let body = Data("{}".utf8)
    #expect(throws: CloudCatalogError.invalidResponse) {
      _ = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    }
  }

  @Test("an empty data array is invalid, never an empty success")
  func emptyDataArrayThrows() throws {
    let body = try document(ids: [])
    #expect(throws: CloudCatalogError.invalidResponse) {
      _ = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    }
  }

  @Test("a non-JSON body is an invalid document")
  func nonJSONThrows() {
    let body = Data("<html>nope</html>".utf8)
    #expect(throws: CloudCatalogError.invalidResponse) {
      _ = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    }
  }

  @Test("a non-empty array whose every row is malformed is invalid")
  func noSurvivingIDThrows() throws {
    let body = try document(rawRows: [["object": "model"], "a string", 7, ["id": "   "]])
    #expect(throws: CloudCatalogError.invalidResponse) {
      _ = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    }
  }

  // MARK: - Row-level tolerance

  @Test("malformed rows are dropped individually while good rows survive")
  func malformedRowsAreDropped() throws {
    let body = try document(rawRows: [
      ["id": "glm-5.2"], ["object": "model"], "a string", 7, ["id": 42], ["id": "kimi-k3"],
    ])
    let ids = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    #expect(ids == ["glm-5.2", "kimi-k3"])
  }

  @Test("ids are trimmed, and a whitespace-only id is dropped rather than kept as empty")
  func idsAreTrimmed() throws {
    let body = try document(rawRows: [
      ["id": "  glm-5.2\n"], ["id": " \t "], ["id": "kimi-k3"],
    ])
    let ids = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    #expect(ids == ["glm-5.2", "kimi-k3"])
  }

  @Test("duplicates keep their first occurrence, including after trimming")
  func duplicatesKeepFirstOccurrence() throws {
    let body = try document(rawRows: [
      ["id": "glm-5.2"], ["id": "kimi-k3"], ["id": " glm-5.2 "], ["id": "glm-5.2"],
    ])
    let ids = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    #expect(ids == ["glm-5.2", "kimi-k3"])
  }

  // MARK: - The raw-entry ceiling

  @Test("exactly two hundred raw entries are accepted")
  func exactlyMaximumEntriesAccepted() throws {
    let body = try document(ids: (0..<200).map { "model-\($0)" })
    let ids = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    #expect(ids.count == 200)
    #expect(OllamaCloudCatalogClient.maximumEntries == 200)
  }

  /// The regression this ceiling exists for: bounding the SURVIVING ids would
  /// let this document through, because only one row survives filtering.
  @Test("201 raw entries are rejected even when only one row would survive filtering")
  func rawEntryCeilingCountsRawRowsNotSurvivors() throws {
    var rows: [Any] = Array(repeating: ["object": "model"], count: 200)
    rows.append(["id": "glm-5.2"])
    let body = try document(rawRows: rows)
    #expect(throws: CloudCatalogError.invalidResponse) {
      _ = try OllamaCloudCatalogClient.parseCloudCatalog(fromModelsJSON: body)
    }
  }

  // MARK: - The byte ceiling, against the production accumulator

  @Test("the accumulator accepts exactly its ceiling")
  func accumulatorAcceptsExactlyTheCeiling() async throws {
    let data = try await OllamaCloudCatalogClient.accumulate(bytes([1, 2, 3, 4]), maximumBytes: 4)
    #expect(data.count == 4)
  }

  @Test("the accumulator throws on the byte after its ceiling")
  func accumulatorThrowsPastTheCeiling() async {
    await #expect(throws: CloudCatalogError.responseTooLarge) {
      _ = try await OllamaCloudCatalogClient.accumulate(bytes([1, 2, 3, 4, 5]), maximumBytes: 4)
    }
  }

  @Test("an empty stream accumulates to empty rather than throwing")
  func accumulatorHandlesEmptyStream() async throws {
    let data = try await OllamaCloudCatalogClient.accumulate(bytes([]), maximumBytes: 4)
    #expect(data.isEmpty)
  }

  // MARK: - The redirect policy, against the production decision

  /// Each destination is required to PARSE first. Without that, a typo making the
  /// string unparseable would hand `nil` to the policy, which refuses — so a
  /// refusal test would pass for entirely the wrong reason.
  @Test("an https redirect that stays on ollama.com is followed, case-insensitively")
  func sameHostHTTPSRedirectAllowed() throws {
    #expect(
      OllamaCloudCatalogClient.shouldFollowRedirect(to: try url("https://ollama.com/v1/models")))
    #expect(
      OllamaCloudCatalogClient.shouldFollowRedirect(to: try url("https://OLLAMA.COM/v1/models")))
  }

  @Test("a redirect to another host is refused, including a lookalike subdomain")
  func otherHostRedirectRefused() throws {
    #expect(
      OllamaCloudCatalogClient.shouldFollowRedirect(to: try url("https://evil.example/v1/models"))
        == false)
    #expect(
      OllamaCloudCatalogClient.shouldFollowRedirect(
        to: try url("https://ollama.com.evil.example/v1/models")) == false)
  }

  @Test("an https to http downgrade is refused even on the allowed host")
  func downgradeRefused() throws {
    #expect(
      OllamaCloudCatalogClient.shouldFollowRedirect(to: try url("http://ollama.com/v1/models"))
        == false)
  }

  @Test("a nil destination is refused")
  func nilDestinationRefused() {
    #expect(OllamaCloudCatalogClient.shouldFollowRedirect(to: nil) == false)
  }

  // MARK: - Transport failures propagate

  @Test("a timeout propagates rather than becoming an empty success")
  func timeoutPropagates() async {
    let sut = OllamaCloudCatalogClient { _, _ in throw URLError(.timedOut) }
    await #expect(throws: URLError.self) { _ = try await sut.fetchIDs() }
  }

  @Test("a cancellation propagates rather than becoming an empty success")
  func cancellationPropagates() async {
    let sut = OllamaCloudCatalogClient { _, _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) { _ = try await sut.fetchIDs() }
  }

  @Test("an oversized body reported by the transport propagates unchanged")
  func responseTooLargePropagates() async {
    let sut = OllamaCloudCatalogClient { _, _ in throw CloudCatalogError.responseTooLarge }
    await #expect(throws: CloudCatalogError.responseTooLarge) { _ = try await sut.fetchIDs() }
  }

  // MARK: - Chunk 2: shared hosted identity

  private func downloaded(_ exactName: String, isRemote: Bool) -> OllamaDownloadedModel {
    OllamaDownloadedModel(
      exactName: exactName,
      canonicalName: OllamaSetupService.canonicalModelName(exactName),
      parameterSize: "4B",
      parameterBillions: 4.0,
      fileSizeBytes: 2_900_000_000,
      displayName: exactName,
      facts: OllamaModelFacts(isRemote: isRemote, thinks: false))
  }

  private func entry(_ name: String, in catalog: [OllamaModelCatalogEntry])
    -> OllamaModelCatalogEntry?
  {
    catalog.first { $0.name == name }
  }

  /// The two forms Ollama uses for one model: it ADVERTISES `glm-5.2` and
  /// REGISTERS `glm-5.2:cloud`. Both must key the same or an added model renders
  /// twice.
  @Test("a colon-cloud registered name and its advertised id share one key")
  func colonCloudSharesAdvertisedIdentity() {
    #expect(OllamaSetupService.hostedCatalogKey("glm-5.2:cloud") == "glm-5.2")
    #expect(OllamaSetupService.hostedCatalogKey("glm-5.2") == "glm-5.2")
  }

  @Test("a dash-cloud registered name and its advertised id share one key")
  func dashCloudSharesAdvertisedIdentity() {
    #expect(OllamaSetupService.hostedCatalogKey("gpt-oss:120b-cloud") == "gpt-oss:120b")
    #expect(OllamaSetupService.hostedCatalogKey("gpt-oss:120b") == "gpt-oss:120b")
    #expect(
      OllamaSetupService.hostedCatalogKey("nemotron-3-nano:30b-cloud") == "nemotron-3-nano:30b")
  }

  /// Only a TRAILING suffix is stripped. A model legitimately containing the
  /// word must keep its name, or the key would collide two unrelated models.
  @Test("an ordinary local name is untouched, including one that merely contains cloud")
  func localNamesAreUntouched() {
    #expect(OllamaSetupService.hostedCatalogKey("llama3.2") == "llama3.2")
    #expect(OllamaSetupService.hostedCatalogKey("cloud-thing") == "cloud-thing")
    #expect(OllamaSetupService.hostedCatalogKey("my:cloudy") == "my:cloudy")
  }

  // MARK: - Chunk 2: the merge

  @Test("a registered colon-cloud row plus its advertised id produces exactly one row")
  func colonCloudRegisteredRowDedupes() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("glm-5.2:cloud", isRemote: true)], cloudCatalogIDs: ["glm-5.2"])
    let matching = catalog.filter { OllamaSetupService.hostedCatalogKey($0.name) == "glm-5.2" }
    #expect(matching.count == 1)
    #expect(matching.first?.name == "glm-5.2:cloud")
    #expect(matching.first?.isDownloaded == true)
    #expect(matching.first?.isRemote == true)
  }

  @Test("a registered dash-cloud row plus its advertised id produces exactly one row")
  func dashCloudRegisteredRowDedupes() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("gpt-oss:120b-cloud", isRemote: true)], cloudCatalogIDs: ["gpt-oss:120b"])
    let matching = catalog.filter { OllamaSetupService.hostedCatalogKey($0.name) == "gpt-oss:120b" }
    #expect(matching.count == 1)
    #expect(matching.first?.name == "gpt-oss:120b-cloud")
    #expect(matching.first?.isDownloaded == true)
  }

  /// The registered row wins because it carries daemon-derived facts and is the
  /// one the picker can actually select.
  @Test("a retained registered row keeps its daemon name, downloaded state and remoteness")
  func registeredRowWins() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("glm-5.2:cloud", isRemote: true), downloaded("llama3.2", isRemote: false)],
      cloudCatalogIDs: ["glm-5.2"])
    #expect(entry("glm-5.2:cloud", in: catalog)?.isRemote == true)
    #expect(entry("llama3.2", in: catalog)?.isRemote == false)
    #expect(entry("llama3.2", in: catalog)?.isDownloaded == true)
    #expect(entry("glm-5.2", in: catalog) == nil)
  }

  /// The newly reachable combination. Before #1956, remote implied downloaded.
  @Test("an unregistered advertised id becomes a remote, not-downloaded suggestion")
  func unregisteredAdvertisedIDBecomesASuggestion() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [], cloudCatalogIDs: ["kimi-k3"])
    let suggestion = entry("kimi-k3", in: catalog)
    #expect(suggestion?.isRemote == true)
    #expect(suggestion?.isDownloaded == false)
  }

  @Test("a hosted suggestion carries no size or quality claim it cannot support")
  func hostedSuggestionMetadataIsSuppressed() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [], cloudCatalogIDs: ["kimi-k3"])
    let suggestion = entry("kimi-k3", in: catalog)
    #expect(suggestion?.displayName == OllamaSetupService.inferDisplayName(from: "kimi-k3"))
    #expect(suggestion?.parameterCount == "")
    #expect(suggestion?.downloadSize == "")
    #expect(suggestion?.qualityTier == .medium)
  }

  /// Every field, not a representative one. Comparing only `name` would pass a
  /// merge that silently rewrote a retained row's metadata, tier or downloaded
  /// state — an outcome-only check where the payload is what matters.
  ///
  /// One helper so the two directions cannot drift into checking different
  /// things, which is how a "both directions covered" claim quietly becomes half
  /// a claim.
  private func expectSameEntry(
    _ actual: OllamaModelCatalogEntry, _ expected: OllamaModelCatalogEntry,
    at index: Int, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.name == expected.name, "name at \(index)", sourceLocation: sourceLocation)
    #expect(
      actual.displayName == expected.displayName, "displayName at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.parameterCount == expected.parameterCount, "parameterCount at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.downloadSize == expected.downloadSize, "downloadSize at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.qualityTier == expected.qualityTier, "qualityTier at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.isDownloaded == expected.isDownloaded, "isDownloaded at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.isRemote == expected.isRemote, "isRemote at \(index)",
      sourceLocation: sourceLocation)
  }

  /// Direction one of the two-way control. The twelve pre-existing call sites
  /// only ever exercise this direction, which is why the next test exists.
  @Test("omitting the argument and passing an empty array both reproduce the old catalog")
  func defaultPathIsUnchanged() {
    let models = [
      downloaded("llama3.2", isRemote: false), downloaded("glm-5.2:cloud", isRemote: true),
    ]
    let omitted = OllamaSetupService.dynamicCatalog(from: models)
    let explicit = OllamaSetupService.dynamicCatalog(from: models, cloudCatalogIDs: [])

    // The count is asserted, then compared through `zip` rather than by
    // subscripting. `#expect` does not halt, so a count regression would record
    // its failure and then run straight into an out-of-bounds crash on the next
    // line, replacing a readable failure with a dead test run.
    #expect(omitted.count == explicit.count)
    for (index, pair) in zip(explicit, omitted).enumerated() {
      expectSameEntry(pair.0, pair.1, at: index)
    }
  }

  /// Direction two. Together with the test above this is the actual two-way
  /// control: one proves nothing was added, the other proves the right things are.
  ///
  /// The prefix comparison is field-by-field and position-by-position, so a merge
  /// that appended correctly while corrupting a retained row fails here. That
  /// also covers the requirement that a retained registered row keeps all of its
  /// daemon-derived metadata AND its position.
  @Test("a non-empty array appends exactly the hosted suggestions, after both existing sections")
  func nonEmptyPathAppendsAfterExistingSections() {
    let models = [
      downloaded("llama3.2", isRemote: false), downloaded("glm-5.2:cloud", isRemote: true),
    ]
    let before = OllamaSetupService.dynamicCatalog(from: models)
    let after = OllamaSetupService.dynamicCatalog(
      from: models, cloudCatalogIDs: ["kimi-k3", "gemma4:31b"])

    #expect(after.count == before.count + 2)
    for (index, pair) in zip(after.prefix(before.count), before).enumerated() {
      expectSameEntry(pair.0, pair.1, at: index)
    }
    #expect(after.suffix(2).map(\.name) == ["kimi-k3", "gemma4:31b"])
    #expect(after.suffix(2).allSatisfy { $0.isRemote && $0.isDownloaded == false })
  }

  @Test("hosted suggestions preserve the order the endpoint advertised them in")
  func hostedSuggestionOrderIsPreserved() {
    let ids = ["qwen3.5:397b", "gemma4:31b", "kimi-k3", "glm-5.1"]
    let catalog = OllamaSetupService.dynamicCatalog(from: [], cloudCatalogIDs: ids)
    #expect(catalog.filter(\.isRemote).map(\.name) == ids)
  }
}

/// Captures the one request the client sends. A class rather than captured
/// locals because the transport closure is `@Sendable`.
///
/// `@unchecked Sendable` is safe because `lock` protects both mutable fields,
/// and every read and write uses a locked accessor.
private final class CapturedRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var request: URLRequest?
  private var bytes: Int?

  func store(request: URLRequest, maximumBytes: Int) {
    lock.lock()
    defer { lock.unlock() }
    self.request = request
    self.bytes = maximumBytes
  }

  private func read<T>(_ body: (URLRequest?, Int?) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(request, bytes)
  }

  var url: URL? { read { request, _ in request?.url } }
  var method: String? { read { request, _ in request?.httpMethod } }
  var body: Data? { read { request, _ in request?.httpBody } }
  var timeout: TimeInterval? { read { request, _ in request?.timeoutInterval } }
  var maximumBytes: Int? { read { _, bytes in bytes } }
}
