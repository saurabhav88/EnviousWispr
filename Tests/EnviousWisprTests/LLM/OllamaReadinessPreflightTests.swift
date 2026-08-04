import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

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

  /// #1914: a tags body whose rows carry arbitrary extra keys, so a test can
  /// build the exact shapes the real daemon emits (`remote_host`, `capabilities`)
  /// including absent, empty, and null variants.
  private func tagsBody(rows: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["models": rows])
  }

  /// #1914: membership-only assertion. The pre-existing readiness tests are about
  /// whether the armed model was FOUND, not about the facts on its row, so they
  /// must not be rewritten into facts assertions — that would silently turn
  /// membership coverage into fact coverage and leave membership untested.
  private func isReady(_ readiness: OllamaReadiness) -> Bool {
    if case .ready = readiness { return true }
    return false
  }

  /// #1914: the facts carried by a `.ready`, or nil when not ready. Spelled with
  /// an explicit binding because Swift lets `case .ready:` ignore the payload.
  private func facts(_ readiness: OllamaReadiness) -> OllamaModelFacts? {
    if case .ready(let facts) = readiness { return facts }
    return nil
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
    #expect(isReady(readiness))
  }

  @Test("canonical matching equates llama2 and llama2:latest in BOTH directions")
  func latestCanonicalization() {
    // Installed with :latest, armed without.
    #expect(
      isReady(
        OllamaConnector.classifyReadiness(
          data: tagsBody(["llama2:latest"]), response: http(200), model: "llama2")))
    // Installed without, armed with :latest.
    #expect(
      isReady(
        OllamaConnector.classifyReadiness(
          data: tagsBody(["llama2"]), response: http(200), model: "llama2:latest")))
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

  // MARK: - Daemon-reported facts (#1914)

  @Test("remote_host present and non-empty means remote; absent means local")
  func remoteHostDiscriminatesBothWays() {
    // Measured 2026-08-01: the daemon returns remote_host for a pulled cloud
    // model and OMITS the key entirely for a local one, side by side in one
    // payload. Both directions are asserted because a decoder that always
    // answered "remote" would pass a one-way test while discriminating nothing.
    let body = tagsBody(rows: [
      ["name": "gpt-oss:120b-cloud", "remote_host": "https://ollama.com"],
      ["name": "qwen3:0.6b"],
    ])
    #expect(
      facts(
        OllamaConnector.classifyReadiness(
          data: body, response: http(200), model: "gpt-oss:120b-cloud"))?.isRemote == true)
    #expect(
      facts(
        OllamaConnector.classifyReadiness(
          data: body, response: http(200), model: "qwen3:0.6b"))?.isRemote == false)
  }

  @Test("an empty or null remote_host reads as local, never remote")
  func degenerateRemoteHostIsLocal() {
    // Fail-safe direction: an unreadable value must not promote a local model
    // to remote, which would suppress its warm-up and mislabel it in the picker.
    let empty = tagsBody(rows: [["name": "m", "remote_host": ""]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: empty, response: http(200), model: "m"))?
        .isRemote == false)

    let null = tagsBody(rows: [["name": "m", "remote_host": NSNull()]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: null, response: http(200), model: "m"))?
        .isRemote == false)

    // Wrong SHAPE (number where a string belongs) must also read as local.
    let wrongType = tagsBody(rows: [["name": "m", "remote_host": 42]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: wrongType, response: http(200), model: "m"))?
        .isRemote == false)
  }

  @Test("capabilities containing thinking discriminates in BOTH directions")
  func thinkingCapabilityDiscriminatesBothWays() {
    // The load-bearing half is the NEGATIVE: measured across 12 models, 11
    // reported thinking and tinyllama reported only ["completion"]. A field that
    // always said yes would look like it worked while telling us nothing, and
    // would hand every non-thinking model the large reasoning budget.
    let body = tagsBody(rows: [
      ["name": "qwen3:0.6b", "capabilities": ["completion", "tools", "thinking"]],
      ["name": "tinyllama:latest", "capabilities": ["completion"]],
    ])
    #expect(
      facts(
        OllamaConnector.classifyReadiness(
          data: body, response: http(200), model: "qwen3:0.6b"))?.thinks == true)
    #expect(
      facts(
        OllamaConnector.classifyReadiness(
          data: body, response: http(200), model: "tinyllama:latest"))?.thinks == false)
  }

  @Test("absent, empty, or wrong-shaped capabilities read as NOT thinking")
  func degenerateCapabilitiesAreNotThinking() {
    // Absent must match today's default for an unlisted model — the tight
    // budget — so an older daemon degrades to current behaviour, not to a
    // silently enlarged budget for every model it serves.
    let absent = tagsBody(rows: [["name": "m"]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: absent, response: http(200), model: "m"))?
        .thinks == false)

    let empty = tagsBody(rows: [["name": "m", "capabilities": [String]()]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: empty, response: http(200), model: "m"))?
        .thinks == false)

    let null = tagsBody(rows: [["name": "m", "capabilities": NSNull()]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: null, response: http(200), model: "m"))?
        .thinks == false)

    // A non-array shape must not crash or match.
    let wrongType = tagsBody(rows: [["name": "m", "capabilities": "thinking"]])
    #expect(
      facts(OllamaConnector.classifyReadiness(data: wrongType, response: http(200), model: "m"))?
        .thinks == false)
  }

  @Test("the two facts are INDEPENDENT — all four combinations decode correctly")
  func factsAreIndependent() {
    // Where a model runs does not tell you whether it reasons. A local thinking
    // model and a remote non-thinking model both exist, so neither fact may be
    // derived from the other.
    let body = tagsBody(rows: [
      ["name": "local-plain"],
      ["name": "local-thinks", "capabilities": ["thinking"]],
      ["name": "remote-plain", "remote_host": "https://ollama.com"],
      [
        "name": "remote-thinks", "remote_host": "https://ollama.com",
        "capabilities": ["completion", "thinking"],
      ],
    ])
    func f(_ model: String) -> OllamaModelFacts? {
      facts(OllamaConnector.classifyReadiness(data: body, response: http(200), model: model))
    }
    #expect(f("local-plain") == OllamaModelFacts(isRemote: false, thinks: false))
    #expect(f("local-thinks") == OllamaModelFacts(isRemote: false, thinks: true))
    #expect(f("remote-plain") == OllamaModelFacts(isRemote: true, thinks: false))
    #expect(f("remote-thinks") == OllamaModelFacts(isRemote: true, thinks: true))
  }

  @Test("facts come from the MATCHED row, not from any row in the payload")
  func factsComeFromTheMatchedRow() {
    // The defect this prevents: scanning the whole payload for facts would let
    // one installed cloud model make every local model look remote. The armed
    // model here is local and sits AFTER a remote row, so a first-row or
    // any-row implementation fails.
    let body = tagsBody(rows: [
      [
        "name": "deepseek-v4-flash", "remote_host": "https://ollama.com",
        "capabilities": ["thinking"],
      ],
      ["name": "llama3.2"],
    ])
    let armed = facts(
      OllamaConnector.classifyReadiness(data: body, response: http(200), model: "llama3.2"))
    #expect(armed == OllamaModelFacts(isRemote: false, thinks: false))
  }

  @Test("canonical :latest matching still supplies the matched row's facts")
  func canonicalMatchCarriesFacts() {
    // Membership uses canonical names, so fact extraction must resolve to the
    // same row that membership matched — including across the :latest equality.
    let body = tagsBody(rows: [
      ["name": "gemma4:latest", "remote_host": "https://ollama.com", "capabilities": ["thinking"]]
    ])
    let armed = facts(
      OllamaConnector.classifyReadiness(data: body, response: http(200), model: "gemma4"))
    #expect(armed == OllamaModelFacts(isRemote: true, thinks: true))
  }

  @Test("the probe carries facts end to end through the transport")
  func probeCarriesFactsEndToEnd() async {
    let connector = OllamaConnector()
    let body = tagsBody(rows: [
      [
        "name": "gpt-oss:20b-cloud", "remote_host": "https://ollama.com",
        "capabilities": ["thinking"],
      ]
    ])
    let readiness = await connector.preflightReadiness(
      model: "gpt-oss:20b-cloud", executor: { _ in (body, self.http(200)) })
    #expect(facts(readiness) == OllamaModelFacts(isRemote: true, thinks: true))
  }

  // MARK: - Probe wrapper

  /// #1914: was `.modelMissing`. The two states now diverge here, at the
  /// producer, because only the preflight can see the armed string and a
  /// downstream `isEmpty` check would be a second authority on one question.
  @Test("empty model is noModelSelected WITHOUT any network call")
  func emptyModelShortCircuits() async {
    let connector = OllamaConnector()
    let readiness = await connector.preflightReadiness(
      model: "",
      executor: { _ in
        Issue.record("the empty-model guard must not reach the network")
        throw URLError(.badURL)
      })
    #expect(readiness == .noModelSelected)
  }

  /// The discriminating half. A nonempty model absent from the tags list is a
  /// genuinely missing INSTALL and must keep its own state, or the split buys
  /// nothing: both would still land on one sentence.
  @Test("a nonempty model absent from tags stays modelMissing, not noModelSelected")
  func nonemptyMissingModelStaysModelMissing() async {
    let connector = OllamaConnector()
    let body = tagsBody(rows: [["name": "llama3.2"]])
    let readiness = await connector.preflightReadiness(
      model: "deleted-model",
      executor: { _ in (body, self.http(200)) })
    #expect(readiness == .modelMissing)
    #expect(readiness != .noModelSelected)
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
    #expect(isReady(ready))

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
    // #1914: was "no model is installed in Ollama", which is false whenever
    // models ARE installed and the armed one simply is not among them.
    let modelMissing = PolishFailureReason.modelUnavailable.ollamaPreflightSkipMessage
    #expect(
      modelMissing
        == "AI cleanup skipped: the selected Ollama model isn't installed. "
          + "Download it or pick another in Settings → AI Polish."
    )
    // #1914: the founder's sentence, pinned. Distinct from the one above on
    // purpose — telling a user with no selection to download something sends
    // them to fix what is not broken.
    let noSelection = PolishFailureReason.noModelSelected.ollamaPreflightSkipMessage
    #expect(
      noSelection
        == "AI cleanup skipped: no polish model selected. Pick one in Settings → AI Polish.")
    #expect(modelMissing != noSelection, "the two states must not collapse to one sentence")
    // All three must carry the skip lead-in the completion planner keys off.
    #expect(PolishFailureReason.isSkipNotice(serverDown ?? "") == true)
    #expect(PolishFailureReason.isSkipNotice(modelMissing ?? "") == true)
    #expect(PolishFailureReason.isSkipNotice(noSelection ?? "") == true)
  }

  /// Rule 6: no em or en dashes in user-facing copy. Checked on the whole
  /// preflight set rather than the one string this change added, because the
  /// rule applies to the class and a per-instance check is how the next one
  /// slips through.
  @Test("no preflight notice contains an em or en dash")
  func preflightCopyHasNoDashes() {
    for reason in PolishFailureReason.allCases {
      guard let message = reason.ollamaPreflightSkipMessage else { continue }
      #expect(!message.contains("\u{2014}"), "\(reason) has an em dash")
      #expect(!message.contains("\u{2013}"), "\(reason) has an en dash")
    }
  }

  @Test("non-preflight reasons have NO preflight copy or telemetry reason")
  func nonPreflightReasonsAreNil() {
    for reason in PolishFailureReason.allCases
    where reason != .providerUnreachable && reason != .modelUnavailable
      && reason != .noModelSelected {
      #expect(reason.ollamaPreflightSkipMessage == nil)
      #expect(PolishSkipReason(ollamaPreflight: reason) == nil)
    }
  }

  @Test("preflight telemetry reasons join the local_polish_ family")
  func telemetryReasons() {
    #expect(
      PolishSkipReason(ollamaPreflight: .providerUnreachable)?.telemetryTag
        == "local_polish_ollama_server_down")
    #expect(
      PolishSkipReason(ollamaPreflight: .noModelSelected)?.telemetryTag
        == "local_polish_ollama_no_model_selected")
    #expect(
      PolishSkipReason(ollamaPreflight: .modelUnavailable)?.telemetryTag
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
