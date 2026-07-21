import EnviousWisprCore
import Foundation
import Security
import Testing
import os

@testable import EnviousWisprLLM

/// #1330: the unsupported-param strip-and-retry. The parser fixtures pin the
/// qualification rules (allowlisted param, actually sent, structured error
/// does not contradict); the scripted transport tests prove the CONNECTOR
/// actually re-issues a rebuilt request, bounds the strips, memoizes per
/// model, and preflights Responses-only models without touching transport.
///
/// Every scripted test uses a UNIQUE model id: the memo is process-global
/// mutable state, and sharing fixture models across parallel tests is the
/// flake class of swift-patterns RULE: tests-no-process-global-mutable-delegate.
@Suite("OpenAI unsupported-param strip-retry")
struct OpenAIParamStripTests {

  // MARK: - Parser fixtures

  /// Reconstructed from the exact recorded #1330 message, type, and param.
  /// (The issue does not preserve a complete verbatim JSON body with `code`;
  /// the code variants below cover present, missing, null, contradictory.)
  private static let recordedTemperatureRejection = """
    {"error": {"message": "Unsupported value: 'temperature' does not support 0 with this model. \
    Only the default (1) value is supported.", "type": "invalid_request_error", \
    "param": "temperature", "code": "unsupported_value"}}
    """

  @Test func recordedRejectionYieldsTemperature() {
    let param = OpenAIConnector.strippableParam(
      fromErrorBody: Self.recordedTemperatureRejection, sentParams: ["temperature"])
    #expect(param == "temperature")
  }

  @Test func unsupportedParameterCodeQualifies() {
    let body = """
      {"error": {"message": "Unsupported parameter: 'reasoning_effort'.", \
      "type": "invalid_request_error", "param": "reasoning_effort", \
      "code": "unsupported_parameter"}}
      """
    #expect(
      OpenAIConnector.strippableParam(fromErrorBody: body, sentParams: ["reasoning_effort"])
        == "reasoning_effort")
  }

  @Test func missingCodeStillQualifies() {
    // The public API reference does not document the 400 schema; fail open
    // on an absent code when param + type agree.
    let body = """
      {"error": {"message": "'temperature' is not supported.", \
      "type": "invalid_request_error", "param": "temperature"}}
      """
    #expect(
      OpenAIConnector.strippableParam(fromErrorBody: body, sentParams: ["temperature"])
        == "temperature")
  }

  @Test func nullCodeStillQualifies() {
    let body = """
      {"error": {"message": "'temperature' is not supported.", \
      "type": "invalid_request_error", "param": "temperature", "code": null}}
      """
    #expect(
      OpenAIConnector.strippableParam(fromErrorBody: body, sentParams: ["temperature"])
        == "temperature")
  }

  @Test func contradictingCodeDisqualifies() {
    let body = """
      {"error": {"message": "too long", "type": "invalid_request_error", \
      "param": "temperature", "code": "context_length_exceeded"}}
      """
    #expect(
      OpenAIConnector.strippableParam(fromErrorBody: body, sentParams: ["temperature"]) == nil)
  }

  @Test func contradictingTypeDisqualifies() {
    let body = """
      {"error": {"message": "nope", "type": "server_error", "param": "temperature", \
      "code": "unsupported_value"}}
      """
    #expect(
      OpenAIConnector.strippableParam(fromErrorBody: body, sentParams: ["temperature"]) == nil)
  }

  @Test func paramNotSentDisqualifies() {
    #expect(
      OpenAIConnector.strippableParam(
        fromErrorBody: Self.recordedTemperatureRejection, sentParams: []) == nil)
  }

  @Test func nonAllowlistedParamDisqualifies() {
    let body = """
      {"error": {"message": "bad messages", "type": "invalid_request_error", \
      "param": "messages", "code": "unsupported_value"}}
      """
    #expect(
      OpenAIConnector.strippableParam(fromErrorBody: body, sentParams: ["messages"]) == nil)
  }

  @Test func malformedJSONDisqualifies() {
    #expect(
      OpenAIConnector.strippableParam(
        fromErrorBody: "<html>Bad gateway</html>", sentParams: ["temperature"]) == nil)
  }

  // MARK: - Memo

  @Test func memoRecordsOnceAndPreOmits() {
    let model = "gpt-4o-memo-test-\(UUID().uuidString)"
    #expect(OpenAIConnector.memoizedOmissions(model: model).isEmpty)
    #expect(OpenAIConnector.recordOmission(model: model, param: "temperature"))
    // Idempotent double-insert: second record is NOT newly learned.
    #expect(!OpenAIConnector.recordOmission(model: model, param: "temperature"))
    #expect(OpenAIConnector.memoizedOmissions(model: model) == ["temperature"])
    OpenAIConnector.resetOmissions(model: model)
    #expect(OpenAIConnector.memoizedOmissions(model: model).isEmpty)
  }

  // MARK: - Scripted transport

  private struct PopulatedKeyStore: LegacyKeyFileStorage {
    func store(key: String, value: String) throws {}
    func retrieve(key: String) throws -> String { "sk-test-not-a-real-key" }
    func delete(key: String) throws {}
  }

  private struct EmptyKeyStore: LegacyKeyFileStorage {
    func store(key: String, value: String) throws {}
    func retrieve(key: String) throws -> String {
      throw KeyStoreError.retrieveFailed(errSecItemNotFound)
    }
    func delete(key: String) throws {}
  }

  private func populatedKeychain() -> KeychainManager {
    KeychainManager(backend: .legacyFiles, legacyStore: PopulatedKeyStore())
  }

  private func config(model: String, reasoningEffort: String? = nil) -> LLMProviderConfig {
    LLMProviderConfig(
      model: model, apiKeyKeychainId: "openai-api-key", maxTokens: 512,
      temperature: 0, thinkingBudget: nil, reasoningEffort: reasoningEffort)
  }

  private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

  private static func response(_ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: endpoint, statusCode: code, httpVersion: nil, headerFields: nil)!
  }

  private static let successBody = Data(
    #"{"choices": [{"message": {"content": "Polished."}, "finish_reason": "stop"}]}"#.utf8)

  // The raw content is non-empty ("   \n  "), so a check against the
  // UNTRIMMED string would incorrectly treat this as success (#1710 Gap 2).
  private static let whitespaceOnlyBody = Data(
    #"{"choices": [{"message": {"content": "   \n  "}, "finish_reason": "stop"}]}"#.utf8)

  private static func rejection(param: String) -> Data {
    Data(
      """
      {"error": {"message": "Unsupported value: '\(param)'.", \
      "type": "invalid_request_error", "param": "\(param)", "code": "unsupported_value"}}
      """.utf8)
  }

  /// Scripted executor: pops one result per physical request, records each
  /// request body. The yield before returning satisfies
  /// swift-patterns RULE: fake-executor-must-yield-before-throw (the fake
  /// completes synchronously; production transport always suspends).
  private final class ScriptedTransport: Sendable {
    private let state: OSAllocatedUnfairLock<(script: [(Data, HTTPURLResponse)], bodies: [Data])>

    init(script: [(Data, HTTPURLResponse)]) {
      state = OSAllocatedUnfairLock(initialState: (script: script, bodies: []))
    }

    var requestCount: Int { state.withLock { $0.bodies.count } }

    func sentBody(_ index: Int) -> [String: Any] {
      let data = state.withLock { $0.bodies[index] }
      return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func executor() -> OpenAIConnector.RequestExecutor {
      { request, _ in
        await Task.yield()
        return try self.state.withLock { state in
          state.bodies.append(request.httpBody ?? Data())
          guard !state.script.isEmpty else {
            throw URLError(.badServerResponse)
          }
          let (data, response) = state.script.removeFirst()
          return (data, response)
        }
      }
    }
  }

  private func connector(_ transport: ScriptedTransport) -> OpenAIConnector {
    OpenAIConnector(keychainManager: populatedKeychain(), requestExecutor: transport.executor())
  }

  @Test func temperatureRejectionStripsAndSucceedsInTwoRequests() async throws {
    let model = "gpt-4o-strip-a-\(UUID().uuidString)"
    defer { OpenAIConnector.resetOmissions(model: model) }
    let transport = ScriptedTransport(script: [
      (Self.rejection(param: "temperature"), Self.response(400)),
      (Self.successBody, Self.response(200)),
    ])

    let result = try await connector(transport).polish(
      text: "hello", instructions: .default, config: config(model: model), onToken: nil)

    #expect(result.polishedText == "Polished.")
    #expect(transport.requestCount == 2)
    #expect(transport.sentBody(0)["temperature"] as? Double == 0)
    #expect(transport.sentBody(1)["temperature"] == nil)
  }

  @Test func doubleRejectionStripsBothParamsInThreeRequests() async throws {
    let model = "gpt-4o-strip-b-\(UUID().uuidString)"
    defer { OpenAIConnector.resetOmissions(model: model) }
    let transport = ScriptedTransport(script: [
      (Self.rejection(param: "reasoning_effort"), Self.response(400)),
      (Self.rejection(param: "temperature"), Self.response(400)),
      (Self.successBody, Self.response(200)),
    ])

    let result = try await connector(transport).polish(
      text: "hello", instructions: .default,
      config: config(model: model, reasoningEffort: "low"), onToken: nil)

    #expect(result.polishedText == "Polished.")
    #expect(transport.requestCount == 3)
    #expect(transport.sentBody(2)["temperature"] == nil)
    #expect(transport.sentBody(2)["reasoning_effort"] == nil)
  }

  @Test func nonQualifying400ThrowsClassifiedAfterOneRequest() async {
    let model = "gpt-4o-strip-c-\(UUID().uuidString)"
    defer { OpenAIConnector.resetOmissions(model: model) }
    let transport = ScriptedTransport(script: [
      (Data(#"{"error": {"message": "malformed request"}}"#.utf8), Self.response(400))
    ])

    do {
      _ = try await connector(transport).polish(
        text: "hello", instructions: .default, config: config(model: model), onToken: nil)
      Issue.record("expected classified badRequest")
    } catch let LLMError.classified(reason) {
      #expect(reason == .badRequest)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(transport.requestCount == 1)
  }

  @Test func secondPolishPreOmitsViaMemoWithoutA400() async throws {
    let model = "gpt-4o-strip-d-\(UUID().uuidString)"
    defer { OpenAIConnector.resetOmissions(model: model) }
    let firstTransport = ScriptedTransport(script: [
      (Self.rejection(param: "temperature"), Self.response(400)),
      (Self.successBody, Self.response(200)),
    ])
    _ = try await connector(firstTransport).polish(
      text: "hello", instructions: .default, config: config(model: model), onToken: nil)
    #expect(firstTransport.requestCount == 2)

    let secondTransport = ScriptedTransport(script: [
      (Self.successBody, Self.response(200))
    ])
    let result = try await connector(secondTransport).polish(
      text: "again", instructions: .default, config: config(model: model), onToken: nil)

    #expect(result.polishedText == "Polished.")
    #expect(secondTransport.requestCount == 1)
    #expect(secondTransport.sentBody(0)["temperature"] == nil)
  }

  // MARK: - Responses-only preflight (key precedence preserved)

  @Test func responsesOnlyModelWithValidKeyFailsLocallyWithZeroRequests() async {
    let transport = ScriptedTransport(script: [])

    do {
      _ = try await connector(transport).polish(
        text: "hello", instructions: .default, config: config(model: "gpt-5-pro"), onToken: nil)
      Issue.record("expected classified modelUnavailable")
    } catch let LLMError.classified(reason) {
      #expect(reason == .modelUnavailable)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(transport.requestCount == 0)
  }

  @Test func responsesOnlyModelWithMissingKeyReportsKeyFirst() async {
    let transport = ScriptedTransport(script: [])
    let connector = OpenAIConnector(
      keychainManager: KeychainManager(backend: .legacyFiles, legacyStore: EmptyKeyStore()),
      requestExecutor: transport.executor())

    do {
      _ = try await connector.polish(
        text: "hello", instructions: .default, config: config(model: "gpt-5-pro"), onToken: nil)
      Issue.record("expected classified apiKeyMissing")
    } catch let LLMError.classified(reason) {
      #expect(reason == .apiKeyMissing)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(transport.requestCount == 0)
  }

  // MARK: - Empty/whitespace response (#1710 Gap 2)

  @Test func whitespaceOnlyContentThrowsEmptyResponse() async {
    let model = "gpt-4o-whitespace-\(UUID().uuidString)"
    defer { OpenAIConnector.resetOmissions(model: model) }
    let transport = ScriptedTransport(script: [
      (Self.whitespaceOnlyBody, Self.response(200))
    ])

    do {
      _ = try await connector(transport).polish(
        text: "hello", instructions: .default, config: config(model: model), onToken: nil)
      Issue.record("expected LLMError.emptyResponse")
    } catch LLMError.emptyResponse {
      // expected
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(transport.requestCount == 1)
  }
}
