import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4721: the launch key check. When it is wrong, the person is warned about a key that works,
/// or never warned about one the provider refuses. Every request goes through a scripted
/// transport that refuses anything unexpected, so no test request reaches a provider.
@Suite("Launch key check (#4721)", .tags(.productOutcome))
struct SavedKeyCheckTests {
  typealias Transport = CloudModelRoutineCatalogTests.ScriptedTransport

  static let key = "fake-launch-key-41c9"
  static let openAIList = "https://api.openai.com/v1/models"
  static let openAIProbe = "https://api.openai.com/v1/chat/completions"
  static let claudeList = "https://api.anthropic.com/v1/models?limit=1000"
  static let claudeProbe = "https://api.anthropic.com/v1/messages"
  static let geminiList = "https://generativelanguage.googleapis.com/v1beta/models"

  static func geminiProbe(_ id: String) -> String {
    "https://generativelanguage.googleapis.com/v1beta/models/\(id):generateContent"
  }

  /// The thrown error, or nil when the call returned.
  static func checkError(
    _ transport: Transport, _ provider: LLMProvider, chosen: [String] = []
  ) async -> (any Error)? {
    do {
      _ = try await transport.discovery().checkSavedKey(
        provider: provider, apiKey: key, chosenModels: chosen)
      return nil
    } catch {
      return error
    }
  }

  static func failure(_ error: (any Error)?) -> LLMModelDiscovery.SavedKeyCheckFailure? {
    error as? LLMModelDiscovery.SavedKeyCheckFailure
  }

  static func isRejected(_ error: (any Error)?) -> Bool {
    guard let failure = failure(error) else { return false }
    return failure.isRejection && failure.listAnsweredAt != nil
      && (failure.error as? LLMError) == .invalidAPIKey
  }

  /// nil when not an inconclusive failure; otherwise whether it carried an answer time.
  static func inconclusiveHasTime(_ error: (any Error)?) -> Bool? {
    guard let failure = failure(error), !failure.isRejection else { return nil }
    return failure.listAnsweredAt != nil
  }

  /// The `model` field of each POST body, in order.
  static func probedModelIDs(_ transport: Transport) -> [String] {
    transport.requests.filter { $0.httpMethod == "POST" }.compactMap { request in
      guard let body = request.httpBody,
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
      else { return nil }
      return json["model"] as? String
    }
  }

  // MARK: - Accepted

  @Test("OpenAI 200: one list request, then one probe of the chosen model only")
  func openAIAcceptedProbesOnlyChosen() async throws {
    let transport = Transport()
    transport.expect(
      "GET", Self.openAIList,
      json: #"{"data":[{"id":"gpt-9-zeta"},{"id":"gpt-9-mini"},{"id":"gpt-9-nano"}]}"#)
    transport.expect("POST", Self.openAIProbe, json: #"{"choices":[]}"#)
    let before = ContinuousClock.now

    let result = try await transport.discovery().checkSavedKey(
      provider: .openAI, apiKey: Self.key, chosenModels: ["gpt-9-zeta"])

    #expect(transport.requestKeys == ["GET \(Self.openAIList)", "POST \(Self.openAIProbe)"])
    #expect(transport.unconsumed == 0)
    #expect(result.listAnsweredAt >= before)
    #expect(result.chosenModels.map(\.id) == ["gpt-9-zeta"])
    #expect(result.chosenModels.first?.availability == .available)
    let observed = try #require(result.chosenModels.first?.availabilityObservedAt)
    #expect(observed >= result.listAnsweredAt)
  }

  @Test(
    "Claude: a page that says more pages exist is still one request; an unlisted chosen id is probed"
  )
  func claudeOneRequestAndUnlistedChosenProbed() async throws {
    let transport = Transport()
    transport.expect(
      "GET", Self.claudeList,
      json:
        #"{"data":[{"id":"claude-sonnet-9","display_name":"Claude Sonnet 9"}],"has_more":true,"last_id":"claude-sonnet-9"}"#
    )
    transport.expect("POST", Self.claudeProbe, json: #"{"content":[]}"#)
    transport.expect(
      "POST", Self.claudeProbe, status: 404,
      json: #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-sonnet-9"}}"#)

    let result = try await transport.discovery().checkSavedKey(
      provider: .claude, apiKey: Self.key, chosenModels: ["claude-opus-9", "claude-sonnet-9"])

    #expect(
      transport.requestKeys == [
        "GET \(Self.claudeList)", "POST \(Self.claudeProbe)", "POST \(Self.claudeProbe)",
      ])
    // Each probe asks for its own model, in order, and each answer lands on that model.
    #expect(Self.probedModelIDs(transport) == ["claude-opus-9", "claude-sonnet-9"])
    #expect(result.chosenModels.map(\.id) == ["claude-opus-9", "claude-sonnet-9"])
    #expect(result.chosenModels.map(\.availability) == [.available, .confirmedUnavailable])
    #expect(result.chosenModels.map(\.displayName) == ["claude-opus-9", "Claude Sonnet 9"])
  }

  @Test(
    "Two engines on one model: probed once; an empty choice is skipped; 404 confirms unavailable")
  func duplicateAndEmptyChoices() async throws {
    let transport = Transport()
    transport.expect("GET", Self.openAIList, json: #"{"data":[{"id":"gpt-9-zeta"}]}"#)
    transport.expect(
      "POST", Self.openAIProbe, status: 404,
      json: #"{"error":{"code":"model_not_found","message":"The model does not exist"}}"#)

    let result = try await transport.discovery().checkSavedKey(
      provider: .openAI, apiKey: Self.key, chosenModels: ["gpt-9-zeta", "", "gpt-9-zeta"])

    #expect(transport.requestKeys.filter { $0.hasPrefix("POST") }.count == 1)
    #expect(result.chosenModels.map(\.id) == ["gpt-9-zeta"])
    #expect(result.chosenModels.first?.availability == .confirmedUnavailable)
  }

  @Test("A 200 whose body is not the list shape still accepts the key and probes nothing")
  func malformedOKAcceptsWithoutProbes() async throws {
    let transport = Transport()
    transport.expect("GET", Self.claudeList, json: "not json at all")

    let result = try await transport.discovery().checkSavedKey(
      provider: .claude, apiKey: Self.key, chosenModels: ["claude-sonnet-9"])

    #expect(result.chosenModels.isEmpty)
    #expect(transport.requestKeys == ["GET \(Self.claudeList)"])
  }

  @Test("Gemini 200 with no models listed: accepted, chosen model probed")
  func geminiEmptyPage() async throws {
    let transport = Transport()
    transport.expect("GET", Self.geminiList, json: "{}")
    transport.expect("POST", Self.geminiProbe("gemini-9-flash"), json: #"{"candidates":[]}"#)

    let result = try await transport.discovery().checkSavedKey(
      provider: .gemini, apiKey: Self.key, chosenModels: ["gemini-9-flash"])

    #expect(result.chosenModels.map(\.availability) == [.available])
  }

  // MARK: - Rejected

  @Test("OpenAI and Claude 401 reject the key and probe nothing")
  func unauthorizedRejects() async {
    for (provider, url) in [(LLMProvider.openAI, Self.openAIList), (.claude, Self.claudeList)] {
      let transport = Transport()
      transport.expect("GET", url, status: 401, json: #"{"error":{"type":"authentication_error"}}"#)
      let error = await Self.checkError(transport, provider, chosen: ["any-model"])
      #expect(Self.isRejected(error), "\(provider)")
      #expect(transport.requestKeys == ["GET \(url)"], "\(provider)")
    }
  }

  @Test("Gemini structured API_KEY_INVALID rejects the key")
  func geminiStructuredRejects() async {
    let transport = Transport()
    transport.expect(
      "GET", Self.geminiList, status: 400,
      json:
        #"{"error":{"status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}"#
    )
    #expect(Self.isRejected(await Self.checkError(transport, .gemini)))
  }

  // MARK: - Inconclusive

  @Test("Gemini 403 and a text-only invalid-key 400 say nothing about the key")
  func geminiAmbiguousIsInconclusive() async {
    for (status, body) in [
      (403, #"{"error":{"status":"PERMISSION_DENIED"}}"#),
      (400, #"{"error":{"message":"API_KEY_INVALID mentioned in text only"}}"#),
    ] {
      let transport = Transport()
      transport.expect("GET", Self.geminiList, status: status, json: body)
      let error = await Self.checkError(transport, .gemini, chosen: ["gemini-9-flash"])
      #expect(Self.inconclusiveHasTime(error) == true, "status \(status)")
      // The list read's own typed error survives, so each case stays distinguishable.
      let expected: ModelDiscoveryFailure =
        status == 403 ? .permissionDenied : .invalidKeyUnconfirmed
      #expect(Self.failure(error)?.error as? ModelDiscoveryFailure == expected, "status \(status)")
      #expect(transport.requestKeys == ["GET \(Self.geminiList)"], "status \(status)")
    }
  }

  @Test("A server error is inconclusive with an answer time")
  func serverErrorIsInconclusive() async {
    let transport = Transport()
    transport.expect("GET", Self.openAIList, status: 503, json: "{}")
    let error = await Self.checkError(transport, .openAI)
    #expect(Self.inconclusiveHasTime(error) == true)
    #expect(Self.failure(error)?.error as? ModelDiscoveryFailure == .httpStatus(503))
  }

  @Test("No HTTP answer (offline) is inconclusive with no answer time")
  func transportFailureHasNoTime() async {
    let transport = Transport()  // nothing expected: the request throws
    #expect(Self.inconclusiveHasTime(await Self.checkError(transport, .claude)) == false)
  }

  @Test("A provider without a cloud key is refused before any request")
  func unsupportedProviderSendsNothing() async {
    for provider in [LLMProvider.ollama, .appleIntelligence, .egOne, .s1Mini, .none] {
      let transport = Transport()
      let error = await Self.checkError(transport, provider)
      #expect(
        error as? LLMModelDiscovery.CatalogFailure == .unsupportedProvider, "\(provider)")
      #expect(transport.requests.isEmpty, "\(provider)")
    }
  }
}
