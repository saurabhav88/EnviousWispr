import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Stage 1 harness item 2): the weekly cloud model routine reads each
/// provider's COMPLETE catalog without availability probes. Every request here goes through a
/// scripted transport that refuses anything it was not told to expect, so no test request can
/// reach a provider and a stray probe (a POST) fails the test instead of spending money.
@Suite("Cloud model routine catalog (#4353 PR 5)", .tags(.harnessContract))
struct CloudModelRoutineCatalogTests {

  static let fakeKey = "fake-routine-key-7f3a"

  // MARK: - Scripted transport

  /// Replies keyed by `"<METHOD> <absolute URL>"`, each consumed once in order. Records every
  /// request it receives, including refused ones.
  final class ScriptedTransport: @unchecked Sendable {
    struct Unexpected: Error, CustomStringConvertible {
      let key: String
      var description: String { "unexpected request \(key)" }
    }

    private let lock = NSLock()
    private var replies: [String: [(status: Int, body: Data)]] = [:]
    private var received: [URLRequest] = []

    func expect(_ method: String, _ url: String, status: Int = 200, json: String) {
      lock.withLock { replies["\(method) \(url)", default: []].append((status, Data(json.utf8))) }
    }

    var requests: [URLRequest] { lock.withLock { received } }
    var requestKeys: [String] { requests.map(Self.key) }
    var unconsumed: Int { lock.withLock { replies.values.reduce(0) { $0 + $1.count } } }

    static func key(_ request: URLRequest) -> String {
      "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")"
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
      let key = Self.key(request)
      let reply: (status: Int, body: Data)? = lock.withLock {
        received.append(request)
        guard var queue = replies[key], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        replies[key] = queue
        return first
      }
      guard let reply, let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)
      else { throw Unexpected(key: key) }
      return (reply.body, response)
    }

    func discovery(list: CloudModelList? = CloudModelListSeed.current) -> LLMModelDiscovery {
      LLMModelDiscovery(cloudModelList: list, transport: { try self.send($0) })
    }
  }

  static let openAIURL = "https://api.openai.com/v1/models"
  static let claudeURL = "https://api.anthropic.com/v1/models?limit=1000"
  static let geminiURL = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"

  static func reasons(_ catalog: LLMModelDiscovery.CloudCatalog) -> [String: String] {
    Dictionary(uniqueKeysWithValues: catalog.excluded.map { ($0.id, $0.reason.rawValue) })
  }

  // MARK: - Complete catalogs

  @Test("OpenAI: every id is in the population; each exclusion names its shipped rule")
  func openAICatalog() async throws {
    let transport = ScriptedTransport()
    transport.expect(
      "GET", Self.openAIURL,
      json: """
        {"object":"list","data":[
          {"id":"gpt-9-zeta","created":1767225600},
          {"id":"gpt-9-zeta-pro","created":1767225600},
          {"id":"gpt-9-realtime"},
          {"id":"dall-e-9"},
          {"id":"gpt-9-tts"},
          {"id":"gpt-9-latest"},
          {"id":"gpt-9-001"},
          {"id":"gpt-6-luna","created":1760000000},
          {"id":"gpt-9-zeta"}
        ]}
        """)
    let catalog = try await transport.discovery().fetchCatalog(
      provider: .openAI, apiKey: Self.fakeKey)

    #expect(
      catalog.identities == [
        "gpt-9-zeta", "gpt-9-zeta-pro", "gpt-9-realtime", "dall-e-9", "gpt-9-tts",
        "gpt-9-latest", "gpt-9-001", "gpt-6-luna",
      ])
    #expect(catalog.eligible.map(\.id) == ["gpt-9-zeta", "gpt-6-luna"])
    #expect(
      Self.reasons(catalog) == [
        "gpt-9-zeta-pro": "noChatCompletions", "gpt-9-realtime": "nonTextModality",
        "dall-e-9": "notChatTextFamily", "gpt-9-tts": "excludedPattern",
        "gpt-9-latest": "alias", "gpt-9-001": "versionedDuplicate",
      ])
    // The provider's date survives (publication-date conversion is a later step).
    #expect(catalog.eligible.first?.releaseDate == Date(timeIntervalSince1970: 1_767_225_600))
    #expect(transport.requestKeys == ["GET \(Self.openAIURL)"])
    #expect(
      transport.requests.first?.value(forHTTPHeaderField: "Authorization")
        == "Bearer \(Self.fakeKey)")
  }

  @Test("Claude: follows the cursor to the last page and keeps the provider's date")
  func claudeCatalogFollowsCursor() async throws {
    let transport = ScriptedTransport()
    transport.expect(
      "GET", Self.claudeURL,
      json: """
        {"data":[{"id":"claude-sonnet-9","display_name":"Claude Sonnet 9",
                  "created_at":"2026-10-01T00:00:00Z"}],
         "has_more":true,"last_id":"claude-sonnet-9"}
        """)
    transport.expect(
      "GET", "\(Self.claudeURL)&after_id=claude-sonnet-9",
      json: """
        {"data":[{"id":"claude-haiku-9","display_name":"Claude Haiku 9"},
                 {"id":"claude-latest"}],
         "has_more":false,"last_id":"claude-latest"}
        """)
    let catalog = try await transport.discovery().fetchCatalog(
      provider: .claude, apiKey: Self.fakeKey)

    #expect(catalog.identities == ["claude-sonnet-9", "claude-haiku-9", "claude-latest"])
    #expect(catalog.eligible.map(\.id) == ["claude-sonnet-9", "claude-haiku-9"])
    #expect(Self.reasons(catalog) == ["claude-latest": "alias"])
    #expect(catalog.eligible.first?.releaseDate == Date(timeIntervalSince1970: 1_790_812_800))
    #expect(transport.requestKeys.count == 2)
    #expect(transport.unconsumed == 0)
  }

  @Test("Gemini: follows nextPageToken; excluded rows stay in the population")
  func geminiCatalogFollowsPageToken() async throws {
    let transport = ScriptedTransport()
    transport.expect(
      "GET", Self.geminiURL,
      json: """
        {"models":[
          {"name":"models/gemini-9-flash","displayName":"Gemini 9 Flash",
           "supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/text-embedding-9","displayName":"Embedding 9",
           "supportedGenerationMethods":["embedContent"]}],
         "nextPageToken":"tok-2"}
        """)
    transport.expect(
      "GET", "\(Self.geminiURL)&pageToken=tok-2",
      json: """
        {"models":[
          {"name":"models/gemini-9-pro","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-9-flash-image","displayName":"Gemini 9 Flash Image",
           "supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-9-lite","displayName":"Gemini 9 Lite",
           "supportedGenerationMethods":["generateContent"]}]}
        """)
    let catalog = try await transport.discovery().fetchCatalog(
      provider: .gemini, apiKey: Self.fakeKey)

    #expect(
      catalog.identities == [
        "gemini-9-flash", "text-embedding-9", "gemini-9-pro", "gemini-9-flash-image",
        "gemini-9-lite",
      ])
    #expect(catalog.eligible.map(\.id) == ["gemini-9-flash", "gemini-9-lite"])
    #expect(
      Self.reasons(catalog) == [
        "text-embedding-9": "noGenerateContent", "gemini-9-pro": "incompleteMetadata",
        "gemini-9-flash-image": "excludedPattern",
      ])
    #expect(transport.requests.first?.value(forHTTPHeaderField: "x-goog-api-key") == Self.fakeKey)
    #expect(transport.unconsumed == 0)
  }

  @Test("the eligible rows are exactly what the picker's parser and filter keep")
  func eligibleMatchesPickerDecision() throws {
    let rows: [[String: Any]] = [
      ["id": "gpt-9-zeta"], ["id": "gpt-9-zeta-pro"], ["id": "gpt-9-tts"],
      ["id": "o4-mini"], ["id": "whisper-9"], ["id": "gpt-9-search-preview"],
    ]
    let list = CloudModelListSeed.current
    let picker = LLMModelDiscovery(cloudModelList: list).filterModels(
      LLMModelDiscovery.openAICandidates(fromModels: rows, list: list))
    let catalog = try LLMModelDiscovery.catalog(provider: .openAI, rows: rows, list: list)
    #expect(catalog.eligible == picker)
    #expect(catalog.eligible.map(\.id) == ["gpt-9-zeta", "o4-mini"])
    #expect(catalog.identities.count == rows.count)
    #expect(catalog.eligible.count + catalog.excluded.count == catalog.identities.count)
  }

  // MARK: - Empty and broken catalogs

  @Test("a valid empty catalog is an empty catalog, for each provider")
  func emptyCatalogsSucceed() async throws {
    let transport = ScriptedTransport()
    transport.expect("GET", Self.openAIURL, json: #"{"object":"list","data":[]}"#)
    transport.expect("GET", Self.claudeURL, json: #"{"data":[],"has_more":false}"#)
    transport.expect("GET", Self.geminiURL, json: "{}")
    let discovery = transport.discovery()
    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let catalog = try await discovery.fetchCatalog(provider: provider, apiKey: Self.fakeKey)
      #expect(catalog.identities.isEmpty, "\(provider)")
      #expect(catalog.eligible.isEmpty, "\(provider)")
    }
    #expect(transport.unconsumed == 0)
  }

  enum Broken: String, CaseIterable {
    case openAIMissingData, openAIRowWithoutID, claudeMissingHasMore, claudeRepeatedCursor
    case geminiModelsNotList, geminiTokenNotText, geminiRepeatedToken, geminiLaterPageFails
    case openAINotJSONObject
  }

  /// Scripts one broken catalog and returns the provider to read.
  static func script(_ broken: Broken, _ transport: ScriptedTransport) -> LLMProvider {
    switch broken {
    case .openAIMissingData:
      transport.expect("GET", openAIURL, json: #"{"object":"list"}"#)
      return .openAI
    case .openAINotJSONObject:
      transport.expect("GET", openAIURL, json: #"["gpt-9-zeta"]"#)
      return .openAI
    case .openAIRowWithoutID:
      transport.expect("GET", openAIURL, json: #"{"data":[{"id":"gpt-9-zeta"},{"created":1}]}"#)
      return .openAI
    case .claudeMissingHasMore:
      transport.expect("GET", claudeURL, json: #"{"data":[{"id":"claude-sonnet-9"}]}"#)
      return .claude
    case .claudeRepeatedCursor:
      transport.expect(
        "GET", claudeURL, json: #"{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}"#)
      transport.expect(
        "GET", "\(claudeURL)&after_id=a",
        json: #"{"data":[{"id":"b"}],"has_more":true,"last_id":"a"}"#)
      return .claude
    case .geminiModelsNotList:
      transport.expect("GET", geminiURL, json: #"{"models":{"name":"models/x"}}"#)
      return .gemini
    case .geminiTokenNotText:
      transport.expect("GET", geminiURL, json: #"{"models":[],"nextPageToken":7}"#)
      return .gemini
    case .geminiRepeatedToken:
      transport.expect("GET", geminiURL, json: #"{"models":[],"nextPageToken":"t"}"#)
      transport.expect(
        "GET", "\(geminiURL)&pageToken=t", json: #"{"models":[],"nextPageToken":"t"}"#)
      return .gemini
    case .geminiLaterPageFails:
      transport.expect("GET", geminiURL, json: #"{"models":[],"nextPageToken":"t"}"#)
      transport.expect("GET", "\(geminiURL)&pageToken=t", status: 500, json: "{}")
      return .gemini
    }
  }

  static func expectedFailure(_ broken: Broken) -> String {
    switch broken {
    case .openAIMissingData, .openAIRowWithoutID, .claudeMissingHasMore, .geminiModelsNotList,
      .openAINotJSONObject:
      return "\(LLMModelDiscovery.CatalogFailure.malformedResponse)"
    case .claudeRepeatedCursor: return "\(ModelDiscoveryFailure.malformedPagination)"
    case .geminiTokenNotText, .geminiRepeatedToken:
      return "\(LLMModelDiscovery.CatalogFailure.malformedPagination)"
    case .geminiLaterPageFails: return "\(ModelDiscoveryFailure.httpStatus(500))"
    }
  }

  @Test(
    "a broken or incomplete catalog throws; it never reads as a complete one",
    arguments: Broken.allCases)
  func brokenCatalogThrows(_ broken: Broken) async {
    let transport = ScriptedTransport()
    let provider = Self.script(broken, transport)
    do {
      let catalog = try await transport.discovery().fetchCatalog(
        provider: provider, apiKey: Self.fakeKey)
      Issue.record("\(broken) returned a catalog of \(catalog.identities.count) ids")
    } catch {
      #expect("\(error)" == Self.expectedFailure(broken), "\(broken)")
      // The key must never surface in what a failure prints.
      #expect("\(error)".contains(Self.fakeKey) == false)
      #expect(error.localizedDescription.contains(Self.fakeKey) == false)
    }
    #expect(transport.unconsumed == 0, "\(broken) left a scripted page unread")
  }

  @Test("Claude refuses numeric has_more", arguments: [0, 1])
  func claudeRejectsNumericHasMore(_ value: Int) async {
    let transport = ScriptedTransport()
    transport.expect(
      "GET", Self.claudeURL,
      json: """
        {"data":[{"id":"claude-sonnet-9"}],"has_more":\(value),"last_id":"a"}
        """)

    await #expect(throws: LLMModelDiscovery.CatalogFailure.malformedResponse) {
      _ = try await transport.discovery().fetchCatalog(
        provider: .claude, apiKey: Self.fakeKey)
    }
    #expect(transport.requestKeys == ["GET \(Self.claudeURL)"])
  }

  @Test("an unexpected request is refused, never sent anywhere")
  func unexpectedRequestRefused() async {
    let transport = ScriptedTransport()
    await #expect(throws: ScriptedTransport.Unexpected.self) {
      _ = try await transport.discovery().fetchCatalog(provider: .openAI, apiKey: Self.fakeKey)
    }
    #expect(transport.requestKeys == ["GET \(Self.openAIURL)"])
  }

  @Test("local and fixed providers have no routine catalog")
  func unsupportedProviders() async {
    let transport = ScriptedTransport()
    for provider in [LLMProvider.ollama, .appleIntelligence, .egOne, .s1Mini, .none] {
      await #expect(throws: LLMModelDiscovery.CatalogFailure.unsupportedProvider) {
        _ = try await transport.discovery().fetchCatalog(provider: provider, apiKey: Self.fakeKey)
      }
    }
    #expect(transport.requests.isEmpty)
  }

  // MARK: - No generation requests

  @Test("a large catalog of listed and excluded models sends only catalog reads")
  func largeCatalogSendsNoProbe() async throws {
    let list = try #require(CloudModelListSeed.current)
    let listed = list.models.filter { $0.provider == .openAI }.map(\.id)
    #expect(listed.count >= 20)
    let extra = (1...30).map { "gpt-9-filler-\($0)-tts" }
    let ids = listed + extra
    let rows = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
    let transport = ScriptedTransport()
    transport.expect("GET", Self.openAIURL, json: #"{"data":[\#(rows)]}"#)
    let catalog = try await transport.discovery(list: list).fetchCatalog(
      provider: .openAI, apiKey: Self.fakeKey)

    #expect(catalog.identities.count == ids.count)
    #expect(catalog.eligible.count > 10)
    #expect(transport.requestKeys == ["GET \(Self.openAIURL)"])
    #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
  }

  // MARK: - Ordinary discovery keeps its requests

  @Test("ordinary discovery still sends its single-page reads and one probe per model")
  func ordinaryDiscoveryUnchanged() async throws {
    let transport = ScriptedTransport()
    // Gemini: the picker reads one page with no query, even when another page is offered.
    transport.expect(
      "GET", "https://generativelanguage.googleapis.com/v1beta/models",
      json: """
        {"models":[{"name":"models/gemini-9-flash","displayName":"Gemini 9 Flash",
                    "supportedGenerationMethods":["generateContent"]}],
         "nextPageToken":"ignored"}
        """)
    transport.expect(
      "POST",
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-9-flash:generateContent",
      json: "{}")
    transport.expect("GET", Self.openAIURL, json: #"{"data":[{"id":"gpt-9-zeta"}]}"#)
    transport.expect("POST", "https://api.openai.com/v1/chat/completions", json: "{}")
    let discovery = transport.discovery()

    let gemini = try await discovery.discoverModels(provider: .gemini, apiKey: Self.fakeKey)
    let openAI = try await discovery.discoverModels(provider: .openAI, apiKey: Self.fakeKey)

    #expect(gemini.map(\.id) == ["gemini-9-flash"])
    #expect(openAI.map(\.id) == ["gpt-9-zeta"])
    #expect(gemini.first?.availability == .available)
    #expect(openAI.first?.availability == .available)
    #expect(
      transport.requestKeys == [
        "GET https://generativelanguage.googleapis.com/v1beta/models",
        "POST https://generativelanguage.googleapis.com/v1beta/models/gemini-9-flash:generateContent",
        "GET \(Self.openAIURL)",
        "POST https://api.openai.com/v1/chat/completions",
      ])
    #expect(transport.unconsumed == 0)
  }

  // MARK: - Gemini page decision

  @Test("Gemini page decision: missing or empty stops; text continues; repeats and non-text refuse")
  func geminiPageDecision() {
    typealias D = LLMModelDiscovery
    #expect(D.geminiPageDecision(nextPageToken: nil, seenTokens: []) == .stop)
    #expect(D.geminiPageDecision(nextPageToken: "", seenTokens: []) == .stop)
    #expect(D.geminiPageDecision(nextPageToken: "t1", seenTokens: []) == .next("t1"))
    #expect(D.geminiPageDecision(nextPageToken: "t1", seenTokens: ["t1"]) == .malformed)
    #expect(D.geminiPageDecision(nextPageToken: 3, seenTokens: []) == .malformed)
  }
}
