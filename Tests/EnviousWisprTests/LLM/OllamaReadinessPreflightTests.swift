import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1305: the `OllamaConnector.preflightReadiness` probe — response
/// classification (pure), transport-failure mapping, the empty-model
/// short-circuit, the absolute deadline net, and the surfaced-skip catalog
/// entries (pinned copy + telemetry reasons + retry policy).
@Suite("Ollama readiness preflight (#1305)")
struct OllamaReadinessPreflightTests {

  // MARK: - Fixtures

  private func tagsBody(_ names: [String]) -> Data {
    let payload: [String: Any] = ["models": names.map { ["name": $0] }]
    return try! JSONSerialization.data(withJSONObject: payload)
  }

  private func http(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "http://localhost:11434/api/tags")!,
      statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  // MARK: - Pure classification

  @Test("2xx with an exact tags match is ready")
  func exactMatchReady() {
    let readiness = OllamaConnector.classifyReadiness(
      data: tagsBody(["llama3.2", "mistral"]), response: http(200), model: "llama3.2")
    #expect(readiness == .ready)
  }

  @Test("canonical matching equates llama2 and llama2:latest in BOTH directions")
  func latestCanonicalization() {
    // Installed with :latest, armed without.
    #expect(
      OllamaConnector.classifyReadiness(
        data: tagsBody(["llama2:latest"]), response: http(200), model: "llama2") == .ready)
    // Installed without, armed with :latest.
    #expect(
      OllamaConnector.classifyReadiness(
        data: tagsBody(["llama2"]), response: http(200), model: "llama2:latest") == .ready)
    // A NON-latest tag is a different model — must not loosely match.
    #expect(
      OllamaConnector.classifyReadiness(
        data: tagsBody(["llama3.2:1b"]), response: http(200), model: "llama3.2") == .modelMissing)
  }

  @Test("2xx with a parsed list and no match is modelMissing")
  func noMatchIsModelMissing() {
    let readiness = OllamaConnector.classifyReadiness(
      data: tagsBody(["mistral"]), response: http(200), model: "llama3.2")
    #expect(readiness == .modelMissing)
  }

  @Test("2xx with an EMPTY installed list is modelMissing")
  func emptyListIsModelMissing() {
    let readiness = OllamaConnector.classifyReadiness(
      data: tagsBody([]), response: http(200), model: "llama3.2")
    #expect(readiness == .modelMissing)
  }

  @Test("non-2xx is serverDown, even with a valid-looking body")
  func non2xxIsServerDown() {
    let readiness = OllamaConnector.classifyReadiness(
      data: tagsBody(["llama3.2"]), response: http(500), model: "llama3.2")
    #expect(readiness == .serverDown)
  }

  @Test("unparseable JSON is serverDown, not modelMissing")
  func invalidJSONIsServerDown() {
    let readiness = OllamaConnector.classifyReadiness(
      data: Data("not json".utf8), response: http(200), model: "llama3.2")
    #expect(readiness == .serverDown)
  }

  @Test("a 2xx body without a models array is serverDown")
  func missingModelsKeyIsServerDown() {
    let body = try! JSONSerialization.data(withJSONObject: ["error": "weird"])
    let readiness = OllamaConnector.classifyReadiness(
      data: body, response: http(200), model: "llama3.2")
    #expect(readiness == .serverDown)
  }

  // MARK: - Probe wrapper

  @Test("empty model is modelMissing WITHOUT any network call")
  func emptyModelShortCircuits() async {
    let connector = OllamaConnector()
    let readiness = await connector.preflightReadiness(
      model: "",
      executor: { _ in
        Issue.record("the empty-model guard must not reach the network")
        throw URLError(.badURL)
      })
    #expect(readiness == .modelMissing)
  }

  @Test("a transport error (connection refused) maps to serverDown")
  func transportErrorIsServerDown() async {
    let connector = OllamaConnector()
    let readiness = await connector.preflightReadiness(
      model: "llama3.2",
      executor: { _ in throw URLError(.cannotConnectToHost) })
    #expect(readiness == .serverDown)
  }

  @Test("a request timeout maps to serverDown")
  func timeoutErrorIsServerDown() async {
    let connector = OllamaConnector()
    let readiness = await connector.preflightReadiness(
      model: "llama3.2",
      executor: { _ in throw URLError(.timedOut) })
    #expect(readiness == .serverDown)
  }

  @Test("the absolute deadline abandons a wedged transport and reports serverDown")
  func deadlineNetCatchesWedge() async {
    let connector = OllamaConnector()
    // The transport hangs far past the (shrunk) deadline: the probe must
    // answer serverDown at the deadline instead of waiting the transport out.
    // The test awaits the probe's RETURN — the deadline firing is the signal;
    // the sleep below is the simulated wedge it must abandon, never awaited.
    let readiness = await connector.preflightReadiness(
      model: "llama3.2",
      executor: { _ in
        // settle: simulated wedged socket the deadline under test must abandon
        try await Task.sleep(for: .seconds(30))
        throw URLError(.timedOut)
      },
      deadlineSeconds: 0.05)
    #expect(readiness == .serverDown)
  }

  @Test("the probe answers from the transport's data, end to end")
  func probeEndToEnd() async {
    let connector = OllamaConnector()
    let body = tagsBody(["gemma3n:e4b"])
    let response = http(200)
    let ready = await connector.preflightReadiness(
      model: "gemma3n:e4b", executor: { _ in (body, response) })
    #expect(ready == .ready)

    let missing = await connector.preflightReadiness(
      model: "llama3.2", executor: { _ in (body, response) })
    #expect(missing == .modelMissing)
  }

  // MARK: - Surfaced-skip catalog entries

  @Test("the pinned preflight skip copy is exact and reads as a skip notice")
  func pinnedCopy() {
    let serverDown = PolishFailureReason.providerUnreachable.ollamaPreflightSkipMessage
    #expect(
      serverDown == "AI cleanup skipped: Ollama isn't running. Start it in Settings → AI Polish.")
    let modelMissing = PolishFailureReason.modelUnavailable.ollamaPreflightSkipMessage
    #expect(
      modelMissing
        == "AI cleanup skipped: no model is installed in Ollama. Download one in Settings → AI Polish."
    )
    // Both must carry the skip lead-in the completion planner keys off.
    #expect(PolishFailureReason.isSkipNotice(serverDown ?? "") == true)
    #expect(PolishFailureReason.isSkipNotice(modelMissing ?? "") == true)
  }

  @Test("non-preflight reasons have NO preflight copy or telemetry reason")
  func nonPreflightReasonsAreNil() {
    for reason in PolishFailureReason.allCases
    where reason != .providerUnreachable && reason != .modelUnavailable {
      #expect(reason.ollamaPreflightSkipMessage == nil)
      #expect(reason.ollamaPreflightSkipTelemetryReason == nil)
    }
  }

  @Test("preflight telemetry reasons join the local_polish_ family")
  func telemetryReasons() {
    #expect(
      PolishFailureReason.providerUnreachable.ollamaPreflightSkipTelemetryReason
        == "local_polish_ollama_server_down")
    #expect(
      PolishFailureReason.modelUnavailable.ollamaPreflightSkipTelemetryReason
        == "local_polish_ollama_model_missing")
  }

  @Test("localPolishNotReady is explicitly non-retryable")
  func notReadyIsNotRetryable() {
    #expect(!LLMRetryPolicy.isRetryable(LLMError.localPolishNotReady(.providerUnreachable)))
    #expect(!LLMRetryPolicy.isRetryable(LLMError.localPolishNotReady(.modelUnavailable)))
  }

  @Test("localPolishNotReady equality compares the carried reason")
  func notReadyEquatable() {
    #expect(
      LLMError.localPolishNotReady(.providerUnreachable)
        == LLMError.localPolishNotReady(.providerUnreachable))
    #expect(
      LLMError.localPolishNotReady(.providerUnreachable)
        != LLMError.localPolishNotReady(.modelUnavailable))
  }

  @Test("PolishFailureReason.from unwraps localPolishNotReady defensively")
  func fromUnwrapsNotReady() {
    #expect(
      PolishFailureReason.from(LLMError.localPolishNotReady(.providerUnreachable))
        == .providerUnreachable)
    #expect(
      PolishFailureReason.from(LLMError.localPolishNotReady(.modelUnavailable))
        == .modelUnavailable)
  }
}
