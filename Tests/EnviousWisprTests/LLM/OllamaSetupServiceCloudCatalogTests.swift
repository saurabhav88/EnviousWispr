import EnviousWisprLLM
import Foundation
import Testing

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
/// A plain `import` is deliberate: every new symbol is `package`, which the test
/// target can see without `@testable`, so the seam is not coupled to a
/// compilation mode (swift-patterns RULE:
/// package-visibility-avoids-cross-module-unknown-default).
///
/// Two conventions here are load-bearing rather than stylistic. Fixtures THROW
/// instead of forcing, so a broken fixture reports as a failure in the test that
/// needed it. And every fixture is built OUTSIDE its `#expect(throws:)` block —
/// a `try` inside that block would let a fixture failure masquerade as the very
/// error the test claims to be proving.
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
