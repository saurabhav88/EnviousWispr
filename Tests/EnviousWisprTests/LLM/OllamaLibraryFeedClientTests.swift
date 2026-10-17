import Foundation
import Testing

@testable import EnviousWisprLLM

/// #2778: the Ollama library feed client and its production eligibility rules.
///
/// The feed names are handed to the local Ollama daemon as pull targets, so these
/// tests drive the PRODUCTION parser (`OllamaLibraryFeedClient.parseFeed`) with each
/// hostile or malformed row shape rather than a re-implementation of the rules. The
/// user-visible failure each row shape guards against is a Download button that can
/// only fail, a label that claims we tested a model we did not, or text that renders
/// as something other than what the file says.
///
/// Fixtures are built outside any `#expect(throws:)` block and sequences are compared
/// through `zip`, for the same reasons as `OllamaSetupServiceCloudCatalogTests`.
@Suite("Ollama library feed client (#2778)", .tags(.productOutcome))
struct OllamaLibraryFeedClientTests {

  // MARK: - Fixtures

  private static let goodSize = 5_493_439_296

  private func goodRow(
    name: String = "gemma4:e4b", displayName: String = "Gemma 4 (E4B)",
    parameterCount: String = "4B", sizeBytes: Any = OllamaLibraryFeedClientTests.goodSize
  ) -> [String: Any] {
    [
      "name": name, "displayName": displayName, "parameterCount": parameterCount,
      "sizeBytes": sizeBytes, "reason": "test fixture",
    ]
  }

  private func document(
    rows: [Any], schema: Any = 1, sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> Data {
    try #require(
      try? JSONSerialization.data(withJSONObject: [
        "schema": schema, "updated": "2026-10-16", "models": rows,
      ]), sourceLocation: sourceLocation)
  }

  private func parse(
    _ rows: [Any], sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> OllamaLibraryFeedClient.ParsedFeed {
    try OllamaLibraryFeedClient.parseFeed(try document(rows: rows, sourceLocation: sourceLocation))
  }

  private func endpointURL(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
    try #require(
      URL(string: "https://enviouswispr.com/ollama-library.json"), sourceLocation: sourceLocation)
  }

  private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var ceiling: Int?
    func store(_ request: URLRequest, _ ceiling: Int) {
      lock.lock()
      defer { lock.unlock() }
      self.request = request
      self.ceiling = ceiling
    }
    var captured: (request: URLRequest?, ceiling: Int?) {
      lock.lock()
      defer { lock.unlock() }
      return (request, ceiling)
    }
  }

  private func client(
    status: Int = 200, body: Data, captured: Captured? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> OllamaLibraryFeedClient {
    let stub = try #require(
      HTTPURLResponse(
        url: try endpointURL(sourceLocation: sourceLocation), statusCode: status,
        httpVersion: nil, headerFields: nil), sourceLocation: sourceLocation)
    return OllamaLibraryFeedClient { request, ceiling in
      captured?.store(request, ceiling)
      return (body, stub)
    }
  }

  // MARK: - The happy path

  @Test("a good row becomes a catalog entry with the file's name and a size string")
  func goodRowParses() throws {
    let parsed = try parse([goodRow()])
    #expect(parsed.dropped.isEmpty)
    let entry = try #require(parsed.entries.first)
    #expect(parsed.entries.count == 1)
    #expect(entry.name == "gemma4:e4b")
    #expect(entry.displayName == "Gemma 4 (E4B)")
    #expect(entry.parameterCount == "4B")
    #expect(entry.downloadSize == "~5.5 GB")
    #expect(entry.isDownloaded == false)
    #expect(entry.isRemote == false)
  }

  @Test("an empty models array is a valid document that contributes nothing")
  func emptyFeedIsValid() throws {
    let parsed = try parse([])
    #expect(parsed.entries.isEmpty)
    #expect(parsed.dropped.isEmpty)
  }

  @Test("file order is preserved")
  func orderIsPreserved() throws {
    let parsed = try parse([
      goodRow(name: "gemma4:e4b"), goodRow(name: "olmo2:7b", displayName: "OLMo 2 (7B)"),
      goodRow(name: "granite3.3:8b", displayName: "Granite 3.3 (8B)"),
    ])
    #expect(parsed.dropped.isEmpty)
    for (entry, expected) in zip(parsed.entries, ["gemma4:e4b", "olmo2:7b", "granite3.3:8b"]) {
      #expect(entry.name == expected)
    }
    #expect(parsed.entries.count == 3)
  }

  @Test("an accepted tag may use uppercase letters other than the latest alias")
  func uppercaseTagIsAccepted() throws {
    let parsed = try parse([goodRow(name: "foo:Q4_K_M")])
    #expect(parsed.dropped.isEmpty)
    #expect(parsed.entries.first?.name == "foo:Q4_K_M")
  }

  // MARK: - Row eligibility

  /// Holds the row as JSON bytes, not as `[String: Any]`: `@Test(arguments:)` needs
  /// `Sendable` values, and the bytes are exactly what the parser would receive.
  struct BadRow: CustomTestStringConvertible, Sendable {
    let label: String
    let json: Data
    let reason: OllamaLibraryFeedClient.DropReason
    var testDescription: String { label }
  }

  static func bad(
    _ label: String, name: String = "gemma4:e4b", displayName: String = "Gemma 4 (E4B)",
    parameterCount: String = "4B", sizeBytes: Any = goodSize,
    reason: OllamaLibraryFeedClient.DropReason
  ) -> BadRow {
    let row: [String: Any] = [
      "name": name, "displayName": displayName, "parameterCount": parameterCount,
      "sizeBytes": sizeBytes,
    ]
    // An empty `Data` on failure makes the test fail loudly at decode, not pass vacuously.
    let json = (try? JSONSerialization.data(withJSONObject: row)) ?? Data()
    return BadRow(label: label, json: json, reason: reason)
  }

  nonisolated private static let badRows: [BadRow] = [
    bad("trailing newline in name", name: "gemma4:e4b\n", reason: .badName),
    bad("leading hyphen", name: "-foo", reason: .badName),
    bad("uppercase repository", name: "Gemma4", reason: .badName),
    bad("path separator", name: "hf.co/foo/bar", reason: .badName),
    bad("space in name", name: "foo bar", reason: .badName),
    bad("empty tag", name: "foo:", reason: .badName),
    bad("name over 64 characters", name: String(repeating: "a", count: 65), reason: .badName),
    bad("uppercase LATEST alias", name: "foo:LATEST", reason: .caseVariantOfLatest),
    bad("mixed case Latest alias", name: "foo:Latest", reason: .caseVariantOfLatest),
    bad("cloud tag", name: "gpt-oss:120b-cloud", reason: .reservedName),
    bad("cloud repository", name: "kimi-cloud", reason: .reservedName),
    bad("s1-mini lookalike", name: "hf.co/superwhisper/s1-mini-gguf", reason: .badName),
    bad("empty display name", displayName: "", reason: .badDisplayName),
    bad(
      "display name over 60", displayName: String(repeating: "x", count: 61),
      reason: .badDisplayName),
    bad("bidi override in display name", displayName: "abc\u{202E}def", reason: .badDisplayName),
    bad("zero width space in display name", displayName: "ab\u{200B}c", reason: .badDisplayName),
    bad("newline in display name", displayName: "ab\nc", reason: .badDisplayName),
    bad("empty parameter count", parameterCount: "", reason: .badParameterCount),
    bad("parameter count over 12", parameterCount: "1234567890123", reason: .badParameterCount),
    bad("bidi in parameter count", parameterCount: "4\u{2067}B", reason: .badParameterCount),
    bad("size below floor", sizeBytes: 49_999_999, reason: .badSize),
    bad("size above ceiling", sizeBytes: 200_000_000_001, reason: .badSize),
    bad("size as string", sizeBytes: "5493439296", reason: .badSize),
    bad("size as boolean", sizeBytes: true, reason: .badSize),
    bad("fractional size", sizeBytes: 5_493_439_296.5, reason: .badSize),
    bad("shipped exact name", name: "qwen2.5:3b", reason: .shipped),
    bad("shipped via latest alias", name: "llama3.2:latest", reason: .shipped),
    bad("shipped bare name with latest", name: "gemma2:latest", reason: .shipped),
    bad("measured but not shipped", name: "deepseek-r1:1.5b", reason: .hasVerdict),
  ]

  @Test("each hostile or malformed row shape is dropped, with its reason", arguments: badRows)
  func badRowIsDropped(_ bad: BadRow) throws {
    let row = try #require(try? JSONSerialization.jsonObject(with: bad.json))
    let parsed = try parse([row])
    #expect(parsed.entries.isEmpty)
    #expect(parsed.dropped == [bad.reason])
  }

  @Test("a non-object row is dropped")
  func nonObjectRowIsDropped() throws {
    let parsed = try parse(["gemma4:e4b", 7, NSNull(), goodRow(name: "olmo2:7b")])
    #expect(parsed.dropped == [.notAnObject, .notAnObject, .notAnObject])
    #expect(parsed.entries.map(\.name) == ["olmo2:7b"])
  }

  @Test("the bare name and its latest alias are one model; the second is a duplicate")
  func latestAliasIsADuplicate() throws {
    let parsed = try parse([goodRow(name: "olmo2"), goodRow(name: "olmo2:latest")])
    #expect(parsed.entries.map(\.name) == ["olmo2"])
    #expect(parsed.dropped == [.duplicate])
  }

  @Test("a first-party variant never rides in as a Not tested row")
  func firstPartyVariantIsRejected() throws {
    let parsed = try parse([goodRow(name: "eg-1:q4")])
    #expect(parsed.entries.isEmpty)
    #expect(parsed.dropped.count == 1)
  }

  @Test("a good row after a bad one still survives")
  func goodRowSurvivesNeighbours() throws {
    let parsed = try parse([
      goodRow(name: "BAD NAME"), goodRow(name: "olmo2:7b"), goodRow(sizeBytes: 1),
    ])
    #expect(parsed.entries.map(\.name) == ["olmo2:7b"])
    #expect(parsed.dropped == [.badName, .badSize])
  }

  @Test("no feed row can carry a verdict: every parsed entry reads Not tested")
  func entriesAreNotTested() throws {
    let parsed = try parse([goodRow(), goodRow(name: "olmo2:7b")])
    #expect(parsed.entries.isEmpty == false)
    for entry in parsed.entries {
      #expect(OllamaModelVerdicts.verdict(for: entry.name) == .notTested)
    }
  }

  // MARK: - Document validity

  @Test("an invalid DOCUMENT throws; it is not read as an empty feed")
  func invalidDocumentsThrow() throws {
    let notJSON = Data("<html>502</html>".utf8)
    let wrongSchema = try document(rows: [goodRow()], schema: 2)
    let stringSchema = try document(rows: [goodRow()], schema: "1")
    let booleanSchema = try document(rows: [goodRow()], schema: true)
    let fractionalSchema = try document(rows: [goodRow()], schema: 1.5)
    let missingModels = try #require(
      try? JSONSerialization.data(withJSONObject: ["schema": 1, "updated": "x"]))
    let topLevelArray = try #require(try? JSONSerialization.data(withJSONObject: [goodRow()]))
    let tooMany = try document(rows: Array(repeating: goodRow(), count: 201))
    for body in [
      notJSON, wrongSchema, stringSchema, booleanSchema, fractionalSchema, missingModels,
      topLevelArray, tooMany,
    ] {
      #expect(throws: CloudCatalogError.invalidResponse) {
        _ = try OllamaLibraryFeedClient.parseFeed(body)
      }
    }
  }

  @Test("exactly the row ceiling is accepted")
  func rowCeilingBoundary() throws {
    let rows: [Any] = (0..<200).map { goodRow(name: "m\($0):7b") }
    let parsed = try parse(rows)
    #expect(parsed.entries.count == 200)
  }

  // MARK: - Size text

  @Test(
    "size text uses decimal units like the shipped literals",
    arguments: [
      (Int64(5_493_439_296), "~5.5 GB"), (Int64(2_000_000_000), "~2 GB"),
      (Int64(1_949_000_000), "~1.9 GB"), (Int64(522_653_277), "~523 MB"),
      (Int64(50_000_000), "~50 MB"), (Int64(999_499_999), "~999 MB"),
      (Int64(999_500_000), "~1 GB"), (Int64(200_000_000_000), "~200 GB"),
    ])
  func sizeText(bytes: Int64, expected: String) {
    #expect(OllamaLibraryFeedClient.downloadSizeText(bytes: bytes) == expected)
  }

  // MARK: - The request and the response handling

  @Test("the request is a bare five-second GET to the exact endpoint, carrying no body")
  func requestShape() async throws {
    let captured = Captured()
    let sut = try client(body: try document(rows: [goodRow()]), captured: captured)
    let entries = try await sut.fetchEntries()
    let seen = captured.captured

    #expect(entries.map(\.name) == ["gemma4:e4b"])
    #expect(seen.request?.url?.absoluteString == "https://enviouswispr.com/ollama-library.json")
    #expect(seen.request?.httpMethod == "GET")
    #expect(seen.request?.httpBody == nil)
    #expect(seen.request?.timeoutInterval == 5)
    #expect(seen.ceiling == OllamaLibraryFeedClient.maximumBytes)
    #expect(OllamaLibraryFeedClient.maximumBytes == 1_048_576)
  }

  @Test("a non-200 response is refused even when its body is a good document")
  func nonOKStatusThrows() async throws {
    let sut = try client(status: 503, body: try document(rows: [goodRow()]))
    await #expect(throws: CloudCatalogError.invalidResponse) { _ = try await sut.fetchEntries() }
  }

  @Test("a transport error propagates and is not turned into an empty feed")
  func transportErrorPropagates() async {
    struct Offline: Error, Equatable {}
    let sut = OllamaLibraryFeedClient { _, _ in throw Offline() }
    await #expect(throws: Offline()) { _ = try await sut.fetchEntries() }
  }

  @Test("redirects follow only https on the feed host")
  func redirectRule() throws {
    let host = OllamaLibraryFeedClient.allowedHost
    #expect(host == "enviouswispr.com")
    let cases: [(String, Bool)] = [
      ("https://enviouswispr.com/ollama-library.json", true),
      ("https://ENVIOUSWISPR.com/x", true),
      ("http://enviouswispr.com/x", false),
      ("https://www.enviouswispr.com/x", false),
      ("https://enviouswispr.com.evil.example/x", false),
      ("https://ollama.com/x", false),
    ]
    for (string, expected) in cases {
      let url = try #require(URL(string: string))
      #expect(
        OllamaCloudCatalogClient.shouldFollowRedirect(to: url, allowedHost: host) == expected,
        "\(string)")
    }
    #expect(OllamaCloudCatalogClient.shouldFollowRedirect(to: nil, allowedHost: host) == false)
  }
}
