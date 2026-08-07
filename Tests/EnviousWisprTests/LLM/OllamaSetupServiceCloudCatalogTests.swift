import EnviousWisprCore
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

  /// A LOCAL model that happens to share a name with a hosted offering is not the
  /// hosted registration. Suppressing the suggestion on a name match alone hid an
  /// addable model from the user, which is the opposite of what this feature is for.
  @Test("a local model sharing a hosted model's name does not suppress the hosted row")
  func localNamesakeDoesNotSuppressHostedSuggestion() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("gpt-oss:20b", isRemote: false)], cloudCatalogIDs: ["gpt-oss:20b"])
    let matching = catalog.filter { OllamaSetupService.hostedCatalogKey($0.name) == "gpt-oss:20b" }
    #expect(matching.count == 2)
    #expect(matching.contains { $0.isRemote == false && $0.isDownloaded == true })
    #expect(matching.contains { $0.isRemote == true && $0.isDownloaded == false })
  }

  /// The other direction, so the fix cannot be "never dedupe". A REMOTE
  /// registration still suppresses its own advertised suggestion.
  @Test("a remote registration still suppresses its advertised suggestion")
  func remoteRegistrationStillSuppresses() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("gpt-oss:20b-cloud", isRemote: true)], cloudCatalogIDs: ["gpt-oss:20b"])
    let matching = catalog.filter { OllamaSetupService.hostedCatalogKey($0.name) == "gpt-oss:20b" }
    #expect(matching.count == 1)
    #expect(matching.first?.name == "gpt-oss:20b-cloud")
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

/// #1956 Chunk 3: the refresh state machine, its 15-minute reuse window, and its
/// single-flight commit barrier.
///
/// A separate suite from the client tests because this one is concurrency and
/// timing shaped, so it needs to be filterable and repeatable on its own.
///
/// No test here sleeps. The reuse window is driven by an injected clock
/// (swift-patterns RULE: tests-no-real-time-scheduling-precision), and every
/// wait for a concurrent condition polls actor state inside a bounded
/// `withThrowingTimeout` rather than parking on a continuation that might never
/// resume (swift-patterns RULE: tests-no-unconditional-continuation-await).
/// Every such loop also calls `try Task.checkCancellation()`, which is what
/// makes the bound real — see `waitUntil` for why omitting it turns the
/// deadline into a hang.
@MainActor
@Suite("Ollama hosted catalog refresh (#1956)")
struct OllamaSetupServiceCloudCatalogRefreshTests {

  // MARK: - Test doubles

  /// Counts transport invocations and can hold a request until released, so the
  /// single-flight barrier is observable without any timing assumption.
  ///
  /// Parking is owned HERE and nowhere else. It used to be a second switch on
  /// `client(gate:parked:)`, captured when the client was built, while
  /// `reconfigure(parked:)` moved only this actor's flag — two switches that had
  /// to agree with nothing enforcing it. `priorLoadedStaysVisibleDuringRefresh`
  /// set the one that was never read, so its second request was never actually
  /// held in flight and the assertion merely raced it: 45 of 50 repeated runs
  /// passed, and every one of those passes proved nothing. A test double whose
  /// configuration can be silently ignored is worse than no double, so the
  /// duplicate switch is gone rather than corrected.
  private actor Gate {
    private(set) var startedCount = 0
    private var released: Bool
    private var ids: [String]
    private var failure: Error?

    init(ids: [String] = ["kimi-k3"], failure: Error? = nil, parked: Bool = false) {
      self.ids = ids
      self.failure = failure
      self.released = !parked
    }

    func begin() { startedCount += 1 }
    func release() { released = true }
    func isReleased() -> Bool { released }
    func outcome() throws -> [String] {
      if let failure { throw failure }
      return ids
    }
    func reconfigure(ids: [String]? = nil, failure: Error? = nil, parked: Bool) {
      if let ids { self.ids = ids }
      self.failure = failure
      released = !parked
    }
  }

  /// A transport that records each invocation and waits for the gate to be
  /// released. An unparked gate starts released, so the wait falls straight
  /// through and a test that never parks pays nothing.
  ///
  /// The wait is deadline-bounded because a diverged test may never release it.
  /// A timeout becomes an ordinary transport failure. Success and in-flight tests
  /// assert terminal IDs and therefore catch that failure; failure-only tests use
  /// gates constructed unparked.
  private func client(gate: Gate) -> OllamaCloudCatalogClient {
    OllamaCloudCatalogClient { request, _ in
      await gate.begin()
      try await withThrowingTimeout(seconds: 5) {
        while await gate.isReleased() == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }
      let ids = try await gate.outcome()
      return try stubbedResponse(ids: ids, for: request)
    }
  }

  /// A transport that always fails, for the failure populations.
  ///
  /// It honours the gate's park for the same reason `client(gate:)` does. No
  /// test parks a failing gate today, so this is a footgun rather than a live
  /// defect — but leaving one double that silently ignores `parked` while the
  /// other honours it recreates exactly the two-switches-must-agree shape that
  /// made `priorLoadedStaysVisibleDuringRefresh` vacuous.
  private func failingClient(gate: Gate, error: Error = URLError(.notConnectedToInternet))
    -> OllamaCloudCatalogClient
  {
    OllamaCloudCatalogClient { _, _ in
      await gate.begin()
      try await withThrowingTimeout(seconds: 5) {
        while await gate.isReleased() == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }
      throw error
    }
  }

  /// A settable clock. `@MainActor` because the seam is, and a class so the test
  /// can advance it after construction.
  @MainActor private final class Clock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = start }
    func advance(_ seconds: TimeInterval) { now += seconds }
    var read: @MainActor () -> Date { { [self] in now } }
  }

  /// Polls `condition` until it holds, bounded by `seconds`.
  ///
  /// `try Task.checkCancellation()` is load-bearing, not defensive.
  /// `withThrowingTimeout` cancels the losing child and its task-group scope
  /// then AWAITS it, so an operation that ignores cancellation makes the
  /// "bounded" wait unbounded. A plain `while … { await Task.yield() }` never
  /// observes cancellation — `Task.yield()` does not throw — so a condition
  /// that never becomes true hangs the suite for the whole run instead of
  /// failing it. Found by mutation controls M6 and M10, each of which stops a
  /// second transport from starting: both wedged past 600s where the healthy
  /// suite finishes in 0.02s. That shape reaching CI would stall the required
  /// `build-debug` check rather than turning it red.
  ///
  /// The timeout carries no label, so the failure below is what names the wait
  /// that expired; without it a timeout reports only a duration. One halting
  /// requirement rather than record-then-rethrow, which would report the same
  /// timeout twice: once as the recorded issue and again as an unhandled error.
  private func waitUntil(
    _ label: String, seconds: Double = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    do {
      try await withThrowingTimeout(seconds: seconds) {
        while await condition() == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }
    } catch {
      try #require(
        false,
        "waitUntil never satisfied: \(label); underlying error: \(error)",
        sourceLocation: sourceLocation)
    }
  }

  private func loadedIDs(_ state: CloudCatalogState) -> [String]? {
    if case .loaded(let ids, _) = state { return ids }
    return nil
  }

  private func loadedAt(_ state: CloudCatalogState) -> Date? {
    if case .loaded(_, let at) = state { return at }
    return nil
  }

  // MARK: - Construction

  @Test("all three construction paths start idle, and the #1914 seam keeps its models")
  func everyInitialiserStartsIdle() {
    #expect(OllamaSetupService().cloudCatalog == .idle)

    let injected = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    #expect(injected.cloudCatalog == .idle)

    let seamed = OllamaSetupService(downloadedModelsForTesting: [
      OllamaDownloadedModel(
        exactName: "llama3.2", canonicalName: "llama3.2", parameterSize: "3B",
        parameterBillions: 3.0, fileSizeBytes: 1, displayName: "llama3.2",
        facts: OllamaModelFacts(isRemote: false, thinks: false))
    ])
    #expect(seamed.cloudCatalog == .idle)
    #expect(seamed.downloadedModels.count == 1)
  }

  // MARK: - The three transitions

  @Test("a first successful refresh goes idle to loaded and records the completion clock")
  func firstSuccessLoads() async {
    let gate = Gate(ids: ["kimi-k3", "glm-5.2"])
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)

    await service.refreshCloudCatalog()

    #expect(loadedIDs(service.cloudCatalog) == ["kimi-k3", "glm-5.2"])
    #expect(loadedAt(service.cloudCatalog) == clock.now)
  }

  @Test("fetchedAt is the clock at completion, not at request start")
  func fetchedAtIsCompletionTime() async throws {
    let gate = Gate(parked: true)
    let clock = Clock()
    let service = OllamaSetupService(
      cloudCatalogClient: client(gate: gate), now: clock.read)

    let start = clock.now
    let refresh = Task { @MainActor in await service.refreshCloudCatalog() }
    try await waitUntil("transport started") { await gate.startedCount == 1 }
    clock.advance(42)
    await gate.release()
    await refresh.value

    #expect(loadedAt(service.cloudCatalog) == start + 42)
    #expect(loadedAt(service.cloudCatalog) != start)
  }

  @Test("an initial failure becomes exactly catalog_unavailable")
  func initialFailureIsFailed() async {
    let gate = Gate()
    let service = OllamaSetupService(cloudCatalogClient: failingClient(gate: gate))
    await service.refreshCloudCatalog()
    #expect(service.cloudCatalog == .failed(reason: "catalog_unavailable"))
  }

  @Test("a transport-thrown cancellation with no prior success is an ordinary failure")
  func transportCancellationWithoutPriorSuccess() async {
    let gate = Gate()
    let service = OllamaSetupService(
      cloudCatalogClient: failingClient(gate: gate, error: CancellationError()))
    await service.refreshCloudCatalog()
    #expect(service.cloudCatalog == .failed(reason: "catalog_unavailable"))
  }

  // MARK: - Retention

  @Test("a prior loaded value stays visible while a refresh is in flight")
  func priorLoadedStaysVisibleDuringRefresh() async throws {
    let gate = Gate(ids: ["kimi-k3"])
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()
    let firstLoaded = service.cloudCatalog

    await gate.reconfigure(ids: ["glm-5.2"], parked: true)
    let refresh = Task { @MainActor in await service.refreshCloudCatalog(force: true) }
    try await waitUntil("second transport started") { await gate.startedCount == 2 }

    #expect(service.cloudCatalog == firstLoaded)
    #expect(service.cloudCatalog != .loading)

    await gate.release()
    await refresh.value

    // Anti-vacuity control. The two assertions above are satisfied by a second
    // request that was never made at all, which is precisely how this test used
    // to pass while proving nothing. Requiring the NEW ids after release proves
    // the request was real and was genuinely pending across those assertions.
    #expect(loadedIDs(service.cloudCatalog) == ["glm-5.2"])
  }

  @Test("a failure after a success retains the previous loaded value exactly")
  func failureAfterSuccessRetainsPriorLoaded() async {
    let gate = Gate(ids: ["kimi-k3"])
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()
    let priorLoaded = service.cloudCatalog

    await gate.reconfigure(failure: URLError(.timedOut), parked: false)
    clock.advance(1000)
    await service.refreshCloudCatalog()

    #expect(service.cloudCatalog == priorLoaded)
    #expect(loadedIDs(service.cloudCatalog) == ["kimi-k3"])
  }

  /// The second of the two transport-cancellation populations. Its sibling above
  /// covers the no-prior-success case; this one exists because "no
  /// `CancellationError` special case" is a claim about BOTH, and only a prior
  /// success can show that a cancellation is treated as an ordinary failure
  /// rather than as something that discards a good list.
  @Test("a transport-thrown cancellation after success retains the prior loaded value")
  func transportCancellationAfterSuccessRetainsPriorLoaded() async {
    let gate = Gate(ids: ["kimi-k3"])
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate))
    await service.refreshCloudCatalog()
    let priorLoaded = service.cloudCatalog

    await gate.reconfigure(failure: CancellationError(), parked: false)
    await service.refreshCloudCatalog(force: true)

    #expect(service.cloudCatalog == priorLoaded)
    #expect(loadedIDs(service.cloudCatalog) == ["kimi-k3"])
  }

  @Test("a later success replaces the ids and the recorded clock")
  func laterSuccessReplaces() async {
    let gate = Gate(ids: ["kimi-k3"])
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()
    let firstAt = loadedAt(service.cloudCatalog)

    await gate.reconfigure(ids: ["glm-5.2", "minimax-m3"], parked: false)
    clock.advance(1000)
    await service.refreshCloudCatalog()

    #expect(loadedIDs(service.cloudCatalog) == ["glm-5.2", "minimax-m3"])
    #expect(loadedAt(service.cloudCatalog) == clock.now)
    #expect(loadedAt(service.cloudCatalog) != firstAt)
  }

  // MARK: - The reuse window, driven by the injected clock

  @Test("at 899 seconds the result is reused and no request is made")
  func reuseUnderFifteenMinutes() async {
    let gate = Gate()
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()
    #expect(await gate.startedCount == 1)

    clock.advance(899)
    await service.refreshCloudCatalog()
    #expect(await gate.startedCount == 1)
  }

  @Test("at exactly 900 seconds the result is refreshed")
  func refreshAtExactlyFifteenMinutes() async {
    let gate = Gate()
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()

    clock.advance(900)
    await service.refreshCloudCatalog()
    #expect(await gate.startedCount == 2)
  }

  @Test("at 901 seconds the result is refreshed")
  func refreshPastFifteenMinutes() async {
    let gate = Gate()
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()

    clock.advance(901)
    await service.refreshCloudCatalog()
    #expect(await gate.startedCount == 2)
  }

  @Test("force bypasses a still-fresh result")
  func forceBypassesFreshness() async {
    let gate = Gate()
    let clock = Clock()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate), now: clock.read)
    await service.refreshCloudCatalog()

    clock.advance(899)
    await service.refreshCloudCatalog(force: true)
    #expect(await gate.startedCount == 2)
  }

  // MARK: - Task lifecycle

  @Test("the task is cleared after a success, so a later forced refresh starts a new request")
  func taskClearedAfterSuccess() async {
    let gate = Gate()
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate))
    await service.refreshCloudCatalog()
    await service.refreshCloudCatalog(force: true)
    #expect(await gate.startedCount == 2)
  }

  @Test("the task is cleared after a failure, so a retry starts a new request")
  func taskClearedAfterFailure() async {
    let gate = Gate()
    let service = OllamaSetupService(cloudCatalogClient: failingClient(gate: gate))
    await service.refreshCloudCatalog()
    await service.refreshCloudCatalog()
    #expect(await gate.startedCount == 2)
  }

  // MARK: - Single-flight commit barrier

  /// The defect this exists to catch: if the stored task owned only the
  /// transport and each caller committed separately, both become runnable when
  /// the transport finishes and the joining caller can return while the state is
  /// still `.loading`.
  ///
  /// Both callers pass `force: true` as the anti-vacuity control. If the second
  /// caller did NOT join the in-flight task, `force` guarantees it would start a
  /// second request and the exactly-once assertion would fail — so a passing
  /// result cannot be explained by the freshness guard.
  @Test("two concurrent callers share one request and both see the committed result")
  func singleFlightBarrier() async throws {
    let gate = Gate(ids: ["kimi-k3"], parked: true)
    let clock = Clock()
    let service = OllamaSetupService(
      cloudCatalogClient: client(gate: gate), now: clock.read)

    let first = Task { @MainActor () -> CloudCatalogState in
      await service.refreshCloudCatalog(force: true)
      return service.cloudCatalog
    }
    try await waitUntil("first transport started") { await gate.startedCount == 1 }

    // Queued on the MainActor, and deliberately NOT awaited here. It cannot run
    // until this turn suspends, and the next line is what suspends it — inside
    // the second refresh, at the point where that call joins the stored task.
    // So the join is reached before the transport is ever released.
    let releaser = Task { @MainActor in await gate.release() }
    await service.refreshCloudCatalog(force: true)
    let secondTerminal = service.cloudCatalog
    let firstTerminal = await first.value
    _ = await releaser.value

    #expect(await gate.startedCount == 1)
    #expect(loadedIDs(firstTerminal) == ["kimi-k3"])
    #expect(loadedIDs(secondTerminal) == ["kimi-k3"])
    #expect(firstTerminal == secondTerminal)
  }

  @Test("cancelling an awaiting caller does not cancel the service-owned refresh")
  func callerCancellationDoesNotCancelTheRefresh() async throws {
    let gate = Gate(ids: ["kimi-k3"], parked: true)
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate))

    let caller = Task { @MainActor in await service.refreshCloudCatalog(force: true) }
    try await waitUntil("transport started") { await gate.startedCount == 1 }
    caller.cancel()
    await gate.release()
    await caller.value

    #expect(loadedIDs(service.cloudCatalog) == ["kimi-k3"])
  }

  // MARK: - Instance catalog wiring

  @Test("a loaded catalog contributes hosted suggestions to the instance catalog")
  func loadedStateReachesTheInstanceCatalog() async {
    let gate = Gate(ids: ["kimi-k3"])
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate))
    await service.refreshCloudCatalog()

    let suggestion = service.dynamicCatalog.first { $0.name == "kimi-k3" }
    #expect(suggestion?.isRemote == true)
    #expect(suggestion?.isDownloaded == false)
  }

  @Test("idle, loading and failed contribute no hosted suggestion")
  func nonLoadedStatesContributeNothing() async throws {
    let idle = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    #expect(idle.dynamicCatalog.allSatisfy { $0.isRemote == false })

    let failGate = Gate()
    let failed = OllamaSetupService(cloudCatalogClient: failingClient(gate: failGate))
    await failed.refreshCloudCatalog()
    #expect(failed.cloudCatalog == .failed(reason: "catalog_unavailable"))
    #expect(failed.dynamicCatalog.allSatisfy { $0.isRemote == false })

    let loadGate = Gate(ids: ["kimi-k3"], parked: true)
    let loading = OllamaSetupService(cloudCatalogClient: client(gate: loadGate))
    let refresh = Task { @MainActor in await loading.refreshCloudCatalog() }
    try await waitUntil("transport started") { await loadGate.startedCount == 1 }
    #expect(loading.cloudCatalog == .loading)
    #expect(loading.dynamicCatalog.allSatisfy { $0.isRemote == false })
    await loadGate.release()
    await refresh.value
  }

  @Test("the existing local catalog is still present alongside hosted suggestions")
  func localCatalogSurvives() async {
    let gate = Gate(ids: ["kimi-k3"])
    let service = OllamaSetupService(cloudCatalogClient: client(gate: gate))
    await service.refreshCloudCatalog()

    let catalog = service.dynamicCatalog
    #expect(catalog.contains { $0.isRemote == false })
    #expect(catalog.contains { $0.name == "kimi-k3" })
  }
}

/// Builds the stub cloud-catalog response. A free function rather than a method
/// on the `@MainActor` suite: the transport closure is `@Sendable` and runs off
/// the MainActor, so a MainActor-isolated helper would need an actor hop there.
///
/// Throws rather than forcing, so a malformed stub reports as a test failure at
/// the call site instead of trapping inside the double.
private func stubbedResponse(ids: [String], for request: URLRequest) throws
  -> (Data, URLResponse)
{
  let rows = ids.map { ["id": $0, "object": "model"] as [String: Any] }
  let body = try JSONSerialization.data(withJSONObject: ["object": "list", "data": rows])
  guard let url = request.url,
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
  else { throw CloudCatalogError.invalidResponse }
  return (body, response)
}

/// #1956 Chunk 4: resolving a hosted model's pullable name at Add time.
///
/// Ollama advertises a hosted model under one id and pulls it under another. This
/// suite pins that we ASK the daemon which name is real rather than inferring it
/// from the id's shape, and that we refuse rather than guess whenever the answer
/// is not exactly one proven name.
///
/// Every wait here is inside a bounded `withThrowingTimeout` AND calls
/// `try Task.checkCancellation()`. Without the second, the bound cannot fire and
/// a regression hangs the required `build-debug` check instead of turning it red
/// (Chunk 3 defect A).
///
/// The script has ONE owner for parking and ONE owner for each candidate's
/// reply, and `showScript` requires both candidates to be scripted explicitly.
/// A double whose configuration can be silently ignored produced 45 vacuous
/// passes out of 50 in Chunk 3; a missing reply here is unwriteable rather than
/// defaulted. An UNEXPECTED candidate is caught by `add(...)`, which asserts it
/// for every test routed through it; the concurrent test drives the service
/// directly and asserts it itself.
@MainActor
@Suite("Ollama hosted Add (#1956)")
struct OllamaSetupServiceHostedAddTests {

  // MARK: - Test doubles

  private enum ShowReply: Sendable {
    case status(Int)
    case nonHTTP
    case thrown(ShowFailure)
  }

  /// A concrete error type rather than `any Error`, so the script stays `Sendable`
  /// without an unchecked escape hatch.
  private enum ShowFailure: Error, Sendable {
    case transport
    case cancelled

    var asError: Error {
      switch self {
      case .transport: return URLError(.notConnectedToInternet)
      case .cancelled: return CancellationError()
      }
    }
  }

  private struct RecordedShowRequest: Equatable, Sendable {
    let url: String
    let method: String
    let timeout: TimeInterval
    let contentType: String?
    let bodyJSON: [String: String]

    var candidate: String? { bodyJSON["model"] }
  }

  /// Owns the scripted replies, the record of what was asked, and whether the
  /// requests are held. Parking is owned here and nowhere else.
  private actor ShowScript {
    private let dashReply: ShowReply
    private let colonReply: ShowReply
    private let dashCandidate: String
    private let colonCandidate: String
    private var released: Bool

    private(set) var recorded: [RecordedShowRequest] = []
    /// A candidate nobody scripted. Asserted empty by every test, so a typo in a
    /// candidate name surfaces as itself rather than as an indeterminate result
    /// that several tests would happily accept.
    private(set) var unscripted: [String] = []

    init(
      advertisedID: String, dash: ShowReply, colon: ShowReply, parked: Bool = false
    ) {
      self.dashCandidate = "\(advertisedID)-cloud"
      self.colonCandidate = "\(advertisedID):cloud"
      self.dashReply = dash
      self.colonReply = colon
      self.released = !parked
    }

    func record(_ request: RecordedShowRequest) { recorded.append(request) }
    func release() { released = true }
    func isReleased() -> Bool { released }
    var requestCount: Int { recorded.count }
    var candidates: [String] { recorded.compactMap(\.candidate) }

    func reply(for candidate: String) -> ShowReply {
      if candidate == dashCandidate { return dashReply }
      if candidate == colonCandidate { return colonReply }
      unscripted.append(candidate)
      return .thrown(.transport)
    }
  }

  /// Records what the production code asked to pull, and what the Add state was
  /// at the moment it asked.
  @MainActor private final class PullLog {
    var pulled: [String] = []
    var statesWhenCalled: [HostedModelAddState] = []
  }

  private func showScript(
    advertisedID: String, dash: ShowReply, colon: ShowReply, parked: Bool = false
  ) -> ShowScript {
    ShowScript(advertisedID: advertisedID, dash: dash, colon: colon, parked: parked)
  }

  private func transport(_ script: ShowScript) -> HostedShowTransport {
    { request in
      let recorded = try Self.record(request)
      await script.record(recorded)
      guard let candidate = recorded.candidate else { throw ShowFailure.transport }

      try await withThrowingTimeout(seconds: 5) {
        while await script.isReleased() == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }

      switch await script.reply(for: candidate) {
      case .status(let code):
        guard let url = request.url,
          let response = HTTPURLResponse(
            url: url, statusCode: code, httpVersion: nil, headerFields: nil)
        else { throw ShowFailure.transport }
        return (Data(), response)
      case .nonHTTP:
        guard let url = request.url else { throw ShowFailure.transport }
        return (
          Data(),
          URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        )
      case .thrown(let failure):
        throw failure.asError
      }
    }
  }

  /// Decodes the request into a Sendable record. `throws` rather than forcing, so
  /// a malformed request fails the test that produced it.
  private nonisolated static func record(_ request: URLRequest) throws -> RecordedShowRequest {
    let json: [String: String]
    if let body = request.httpBody,
      let decoded = try? JSONSerialization.jsonObject(with: body) as? [String: String]
    {
      json = decoded
    } else {
      json = [:]
    }
    return RecordedShowRequest(
      url: request.url?.absoluteString ?? "",
      method: request.httpMethod ?? "",
      timeout: request.timeoutInterval,
      contentType: request.value(forHTTPHeaderField: "Content-Type"),
      bodyJSON: json)
  }

  private func starter(_ log: PullLog, service: @escaping @MainActor () -> OllamaSetupService)
    -> HostedPullStarter
  {
    { name in
      log.pulled.append(name)
      log.statesWhenCalled.append(service().hostedModelAddState)
    }
  }

  /// A cloud-catalog client that always serves the given ids, so a test can put
  /// the service into `.loaded` before adding.
  private func catalogClient(ids: [String]) -> OllamaCloudCatalogClient {
    OllamaCloudCatalogClient { request, _ in
      try stubbedResponse(ids: ids, for: request)
    }
  }

  private func failedMessage(_ state: HostedModelAddState) -> String? {
    if case .failed(_, let message) = state { return message }
    return nil
  }

  private func failedID(_ state: HostedModelAddState) -> String? {
    if case .failed(let id, _) = state { return id }
    return nil
  }

  /// Runs one Add against a scripted daemon and returns everything worth
  /// asserting. Both candidates must be scripted; neither has a default.
  ///
  /// The unexpected-candidate check lives HERE rather than in each test, so it
  /// cannot be forgotten. It was originally written into two tests only, while a
  /// comment claimed every test made it — and the tests it was missing from are
  /// exactly the refusal tests, where a misspelled production candidate turns
  /// into an indeterminate reply and passes as the refusal the test wanted.
  private func add(
    _ advertisedID: String, dash: ShowReply, colon: ShowReply,
    on service: OllamaSetupService? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> (service: OllamaSetupService, script: ShowScript, log: PullLog) {
    let script = showScript(advertisedID: advertisedID, dash: dash, colon: colon)
    let service = service ?? OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    let log = PullLog()
    await service.addHostedModel(
      advertisedID: advertisedID,
      show: transport(script),
      startPull: starter(log, service: { service }))

    let unscripted = await script.unscripted
    #expect(
      unscripted.isEmpty, "unexpected candidate(s): \(unscripted)",
      sourceLocation: sourceLocation)

    return (service, script, log)
  }

  /// Compares two catalogs field by field. `zip` after a count check rather than
  /// subscripting, because `#expect` does not halt and a count regression would
  /// otherwise turn a readable failure into an out-of-bounds crash.
  private func expectSameCatalog(
    _ actual: [OllamaModelCatalogEntry],
    _ expected: [OllamaModelCatalogEntry],
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.count == expected.count, sourceLocation: sourceLocation)
    for (index, pair) in zip(actual, expected).enumerated() {
      let (lhs, rhs) = pair
      #expect(lhs.name == rhs.name, "name at \(index)", sourceLocation: sourceLocation)
      #expect(
        lhs.displayName == rhs.displayName, "displayName at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.parameterCount == rhs.parameterCount, "parameterCount at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.downloadSize == rhs.downloadSize, "downloadSize at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.qualityTier == rhs.qualityTier, "qualityTier at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.isDownloaded == rhs.isDownloaded, "isDownloaded at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.isRemote == rhs.isRemote, "isRemote at \(index)", sourceLocation: sourceLocation)
    }
  }

  // MARK: - Construction

  @Test("all three construction paths start with no Add in progress")
  func everyInitialiserStartsIdle() {
    #expect(OllamaSetupService().hostedModelAddState == .idle)
    #expect(
      OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient()).hostedModelAddState
        == .idle)
    #expect(
      OllamaSetupService(downloadedModelsForTesting: []).hostedModelAddState == .idle)
  }

  // MARK: - The request itself

  @Test("both candidates are probed in dash-then-colon order, as bare localhost POSTs")
  func requestShape() async throws {
    let result = await add("glm-5.2", dash: .status(200), colon: .status(404))

    let recorded = await result.script.recorded
    #expect(recorded.count == 2)

    let expectedCandidates = ["glm-5.2-cloud", "glm-5.2:cloud"]
    #expect(await result.script.candidates == expectedCandidates)

    for (request, candidate) in zip(recorded, expectedCandidates) {
      #expect(request.url == "http://localhost:11434/api/show")
      #expect(request.method == "POST")
      #expect(request.timeout == 5)
      #expect(request.contentType == "application/json")
      #expect(request.bodyJSON == ["model": candidate])
      #expect(request.bodyJSON.count == 1)
    }
  }

  // MARK: - Exactly one proven name

  @Test("a proven dash name and an absent colon name pulls the dash name once")
  func dashProvenPullsDash() async {
    let result = await add("gpt-oss:120b", dash: .status(200), colon: .status(404))
    #expect(result.log.pulled == ["gpt-oss:120b-cloud"])
    #expect(result.service.hostedModelAddState == .idle)
  }

  @Test("an absent dash name and a proven colon name pulls the colon name once")
  func colonProvenPullsColon() async {
    let result = await add("glm-5.2", dash: .status(404), colon: .status(200))
    #expect(result.log.pulled == ["glm-5.2:cloud"])
    #expect(result.service.hostedModelAddState == .idle)
  }

  /// The anti-first-wins control. A 200 on the first candidate must not end the
  /// resolution, because stopping there would make probe ORDER the authority on
  /// which name is real.
  @Test("the second candidate is probed even after the first returns a proven name")
  func firstProvenStillProbesSecond() async {
    let result = await add("glm-5.2", dash: .status(200), colon: .status(404))
    #expect(await result.script.requestCount == 2)
    #expect(await result.script.candidates == ["glm-5.2-cloud", "glm-5.2:cloud"])
  }

  @Test("the starter sees the Add state already cleared when it is invoked")
  func starterObservesIdle() async {
    let result = await add("glm-5.2", dash: .status(200), colon: .status(404))
    #expect(result.log.statesWhenCalled == [.idle])
  }

  // MARK: - Refusals

  @Test("two proven names refuse as ambiguous and pull nothing")
  func bothProvenRefuses() async {
    let result = await add("glm-5.2", dash: .status(200), colon: .status(200))
    #expect(result.log.pulled.isEmpty)
    #expect(
      failedMessage(result.service.hostedModelAddState)
        == "Ollama returned two valid names for this model. Add it in Ollama, then refresh this list."
    )
  }

  @Test("two absent names refuse with the no-usable-name message and pull nothing")
  func bothAbsentRefuses() async {
    let result = await add("glm-5.2", dash: .status(404), colon: .status(404))
    #expect(result.log.pulled.isEmpty)
    #expect(
      failedMessage(result.service.hostedModelAddState)
        == "Ollama listed this model but did not return a name EnviousWispr can add. Try again after updating Ollama."
    )
  }

  @Test("a proven name plus an indeterminate answer refuses without pulling")
  func provenPlusIndeterminateRefuses() async {
    let result = await add("glm-5.2", dash: .status(200), colon: .status(500))
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  @Test("an indeterminate answer plus a proven name refuses without pulling")
  func indeterminatePlusProvenRefuses() async {
    let result = await add("glm-5.2", dash: .status(500), colon: .status(200))
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  @Test("an absent name plus an indeterminate answer refuses without pulling")
  func absentPlusIndeterminateRefuses() async {
    let result = await add("glm-5.2", dash: .status(404), colon: .nonHTTP)
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  @Test("a transport throw on the first probe still probes the second, and refuses")
  func throwOnFirstStillProbesSecond() async {
    let result = await add("glm-5.2", dash: .thrown(.transport), colon: .status(200))
    #expect(await result.script.candidates == ["glm-5.2-cloud", "glm-5.2:cloud"])
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  @Test("a transport throw on the second probe refuses even though the first was proven")
  func throwOnSecondRefuses() async {
    let result = await add("glm-5.2", dash: .status(200), colon: .thrown(.transport))
    #expect(await result.script.requestCount == 2)
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  @Test("a response that is not an HTTP response is indeterminate")
  func nonHTTPIsIndeterminate() async {
    let result = await add("glm-5.2", dash: .nonHTTP, colon: .nonHTTP)
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  @Test(
    "no status other than 200 or 404 is ever treated as an answer",
    arguments: [201, 202, 401, 403, 429, 500, 503])
  func otherStatusesAreIndeterminate(status: Int) async {
    let result = await add("glm-5.2", dash: .status(status), colon: .status(status))
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  /// Matches Chunk 3's contract: a transport-thrown cancellation is an ordinary
  /// failure, not a special case, and it certainly never starts a pull.
  @Test("a transport-thrown cancellation is indeterminate and starts no pull")
  func cancellationIsIndeterminate() async {
    let result = await add("glm-5.2", dash: .thrown(.cancelled), colon: .thrown(.cancelled))
    #expect(result.log.pulled.isEmpty)
    #expect(failedMessage(result.service.hostedModelAddState) == Self.unreachableMessage)
  }

  // MARK: - What a refusal must not disturb

  @Test("no refusal changes the setup state, so Manage Models cannot vanish")
  func refusalsLeaveSetupStateUntouched() async {
    let combinations: [(ShowReply, ShowReply)] = [
      (.status(200), .status(200)),
      (.status(404), .status(404)),
      (.status(200), .status(500)),
      (.status(500), .status(200)),
      (.nonHTTP, .nonHTTP),
      (.thrown(.transport), .thrown(.transport)),
      (.thrown(.cancelled), .status(404)),
    ]
    for (dash, colon) in combinations {
      let service = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
      let entry = service.setupState
      let result = await add("glm-5.2", dash: dash, colon: colon, on: service)
      #expect(result.service.setupState == entry)
      #expect(result.log.pulled.isEmpty)
    }
  }

  /// All three refusal branches, not just the one that prompted the test.
  /// Production refuses in three distinct places — both proven, both absent, and
  /// the indeterminate default — and each is its own opportunity to disturb the
  /// list. Covering one of three would have left two untested.
  @Test("every refusal preserves the loaded cloud state and the complete catalog")
  func refusalsRetainTheAdvertisedCatalog() async {
    let combinations: [(ShowReply, ShowReply)] = [
      (.status(200), .status(200)),
      (.status(404), .status(404)),
      (.status(200), .status(500)),
    ]

    for (dash, colon) in combinations {
      let service = OllamaSetupService(cloudCatalogClient: catalogClient(ids: ["glm-5.2"]))
      await service.refreshCloudCatalog()

      let beforeCloud = service.cloudCatalog
      let beforeCatalog = service.dynamicCatalog
      #expect(beforeCatalog.contains { $0.name == "glm-5.2" })

      let result = await add("glm-5.2", dash: dash, colon: colon, on: service)

      #expect(result.log.pulled.isEmpty)
      #expect(service.cloudCatalog == beforeCloud)
      expectSameCatalog(service.dynamicCatalog, beforeCatalog)
      #expect(service.dynamicCatalog.contains { $0.name == "glm-5.2" })
    }
  }

  @Test("a failure is keyed to the row that started it, never another")
  func failureIsKeyedToTheInitiatingRow() async {
    let result = await add("kimi-k3", dash: .status(404), colon: .status(404))
    #expect(failedID(result.service.hostedModelAddState) == "kimi-k3")
    #expect(failedID(result.service.hostedModelAddState) != "glm-5.2")
  }

  // MARK: - Retry

  @Test("a retry after a failure probes again and can succeed")
  func retryAfterFailureCanSucceed() async {
    let service = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    let first = await add("glm-5.2", dash: .status(404), colon: .status(404), on: service)
    #expect(failedID(service.hostedModelAddState) == "glm-5.2")
    #expect(first.log.pulled.isEmpty)

    let second = await add("glm-5.2", dash: .status(404), colon: .status(200), on: service)
    #expect(await second.script.requestCount == 2)
    #expect(second.log.pulled == ["glm-5.2:cloud"])
    #expect(service.hostedModelAddState == .idle)
  }

  // MARK: - Two clicks

  /// The defect this exists to catch: `pullModel` cancels any in-flight pull, so
  /// a second Add reaching it would cancel the first one's download.
  ///
  /// The second call is made while the first is PROVABLY parked mid-probe, and
  /// the assertions before release prove the second did nothing. The post-release
  /// half is the anti-vacuity control: without it, "no second request" would also
  /// be satisfied by a first Add that had already finished.
  @Test("a second Add during a resolution does nothing, and the first still completes")
  func secondAddDuringResolutionIsRefused() async throws {
    let script = showScript(
      advertisedID: "glm-5.2", dash: .status(404), colon: .status(200), parked: true)
    let service = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    let log = PullLog()

    let first = Task { @MainActor in
      await service.addHostedModel(
        advertisedID: "glm-5.2",
        show: transport(script),
        startPull: starter(log, service: { service }))
    }

    try await waitUntilAdd("the first probe started") { await script.requestCount == 1 }
    #expect(service.hostedModelAddState == .resolving(advertisedID: "glm-5.2"))

    let otherScript = showScript(advertisedID: "kimi-k3", dash: .status(200), colon: .status(404))
    await service.addHostedModel(
      advertisedID: "kimi-k3",
      show: transport(otherScript),
      startPull: starter(log, service: { service }))

    #expect(await otherScript.requestCount == 0)
    #expect(log.pulled.isEmpty)
    #expect(service.hostedModelAddState == .resolving(advertisedID: "glm-5.2"))

    await script.release()
    await first.value

    #expect(await script.candidates == ["glm-5.2-cloud", "glm-5.2:cloud"])
    #expect(log.pulled == ["glm-5.2:cloud"])
    #expect(service.hostedModelAddState == .idle)
    #expect(await otherScript.requestCount == 0)
    // This test drives `addHostedModel` directly, so it does not inherit the
    // unexpected-candidate check that `add(...)` performs for every other test.
    #expect(await script.unscripted.isEmpty)
    #expect(await otherScript.unscripted.isEmpty)
  }

  // MARK: - Leaving Ollama mid-resolution (#1956, whole-diff review r2)

  /// The defect: a hosted Add spends two `/api/show` round trips BEFORE any pull
  /// exists, so `cancelPull()` — which is what switching provider calls — finds
  /// `pullTask == nil` and does nothing. The resolution then started a pull for
  /// a provider the user had already left, and because `pullModel` cancels the
  /// current pull, that late arrival could kill a pull started after switching
  /// back.
  ///
  /// The Add is parked mid-probe so the cancellation provably lands INSIDE the
  /// resolution window rather than before or after it.
  @Test("leaving Ollama mid-resolution starts no pull when the probes finish")
  func hostedResolutionSupersededByLeavingOllama() async throws {
    let script = showScript(
      advertisedID: "glm-5.2", dash: .status(404), colon: .status(200), parked: true)
    let service = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    let log = PullLog()

    let add = Task { @MainActor in
      await service.addHostedModel(
        advertisedID: "glm-5.2",
        show: transport(script),
        startPull: starter(log, service: { service }))
    }

    try await waitUntilAdd("the first probe started") { await script.requestCount == 1 }
    #expect(service.hostedModelAddState == .resolving(advertisedID: "glm-5.2"))

    // What `onChange(llmProvider)` does when the user picks another provider.
    service.cancelHostedResolution()
    #expect(service.hostedModelAddState == .idle)

    await script.release()
    await add.value

    // The probes still complete — they were already in flight — but nothing acts
    // on their answer.
    #expect(log.pulled.isEmpty)
    #expect(service.hostedModelAddState == .idle)
    #expect(await script.unscripted.isEmpty)
  }

  /// Two-way control for the test above. Without it, "no pull started" would be
  /// satisfied by a resolution that never resolves anything at all — including a
  /// `cancelHostedResolution` that bumped the epoch unconditionally and broke
  /// every hosted Add.
  @Test("the same resolution, not superseded, does start its pull")
  func hostedResolutionNotSupersededStartsPull() async throws {
    let script = showScript(
      advertisedID: "glm-5.2", dash: .status(404), colon: .status(200), parked: true)
    let service = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    let log = PullLog()

    let add = Task { @MainActor in
      await service.addHostedModel(
        advertisedID: "glm-5.2",
        show: transport(script),
        startPull: starter(log, service: { service }))
    }

    try await waitUntilAdd("the first probe started") { await script.requestCount == 1 }
    await script.release()
    await add.value

    #expect(log.pulled == ["glm-5.2:cloud"])
    #expect(service.hostedModelAddState == .idle)
    #expect(await script.unscripted.isEmpty)
  }

  /// Cancelling an unrelated LOCAL download must not abandon a hosted Add.
  ///
  /// This is why the invalidation is its own method instead of living inside
  /// `cancelPull()`: local Download buttons stay enabled while a hosted row
  /// resolves, so folding the epoch bump into `cancelPull()` would let one
  /// model's Cancel silently kill a different model's Add.
  @Test("cancelPull does not abandon a hosted resolution")
  func cancelPullLeavesHostedResolutionAlone() async throws {
    let script = showScript(
      advertisedID: "glm-5.2", dash: .status(404), colon: .status(200), parked: true)
    let service = OllamaSetupService(cloudCatalogClient: OllamaCloudCatalogClient())
    let log = PullLog()

    let add = Task { @MainActor in
      await service.addHostedModel(
        advertisedID: "glm-5.2",
        show: transport(script),
        startPull: starter(log, service: { service }))
    }

    try await waitUntilAdd("the first probe started") { await script.requestCount == 1 }
    service.cancelPull()
    #expect(service.hostedModelAddState == .resolving(advertisedID: "glm-5.2"))

    await script.release()
    await add.value

    #expect(log.pulled == ["glm-5.2:cloud"])
    #expect(await script.unscripted.isEmpty)
  }

  // MARK: - Helpers

  private static let unreachableMessage =
    "EnviousWispr could not confirm this model's name with Ollama. Try again in a moment."

  /// See the suite doc: `try Task.checkCancellation()` is what makes the bound
  /// real, because `withThrowingTimeout` cancels the losing child and then awaits
  /// it, and `Task.yield()` never throws.
  private func waitUntilAdd(
    _ label: String, seconds: Double = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    do {
      try await withThrowingTimeout(seconds: seconds) {
        while await condition() == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }
    } catch {
      try #require(
        false,
        "waitUntilAdd never satisfied: \(label); underlying error: \(error)",
        sourceLocation: sourceLocation)
    }
  }
}
