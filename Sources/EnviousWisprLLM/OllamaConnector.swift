import EnviousWisprCore
import Foundation

/// #1177 (Telemetry Bible Phase 8): the result of an Ollama model eviction. Returned
/// by `evictModel` (which never throws) so the Pipeline caller can observe a quiet
/// eviction failure. Content-free metadata only.
public struct OllamaEvictOutcome: Sendable {
  /// `"unloaded"` (2xx), `"failed"` (non-2xx or transport error), or `"skipped"`
  /// (empty model / bad URL — nothing to evict).
  public let result: String
  public let durationMs: Int
  /// `"http_<status>"`, a `URLError` code, or `"invalid_url_or_empty"`.
  public let reason: String

  public init(result: String, durationMs: Int, reason: String) {
    self.result = result
    self.durationMs = durationMs
    self.reason = reason
  }
}

/// #1914: the two per-model facts the daemon reports about the armed model, read
/// from its own `/api/tags` row rather than guessed from its name.
///
/// The two are INDEPENDENT and govern different decisions — where a model runs
/// does not tell you whether it reasons before answering, which is why a single
/// flag could not serve both. Ownership table: plan §3d.
/// - `isRemote` → Manage Models presentation, warm-up skip, eviction skip, completed telemetry.
/// - `thinks` → output-token budget and the thinking level sent on the request.
///
/// Deliberately CLOSED at two fields. Add a third only when the daemon reports
/// an observed fact with a named consumer; this is not a metadata bag.
public struct OllamaModelFacts: Sendable, Equatable {
  /// True iff the daemon reported a non-empty `remote_host` for this model,
  /// meaning Ollama proxies it to its own servers rather than running it here.
  /// Never derived from a `-cloud` name suffix: the production sighting that
  /// opened #1914 was `deepseek-v4-flash:latest`, which carries no suffix.
  public let isRemote: Bool
  /// Whether the daemon listed `thinking` among this model's `capabilities`.
  /// This is the SOLE authority for the question — it replaced a hand-authored
  /// four-name family list, which was a prediction about which models other
  /// people install and mis-budgeted every thinking model outside it. Reported
  /// for local and remote models alike. Do not reintroduce a name-based
  /// fallback beside it.
  ///
  /// THREE-STATE, and the third state is load-bearing. `nil` means the daemon
  /// did not report `capabilities` AT ALL for this row, which is different from
  /// reporting a capability list that omits `thinking`:
  ///
  /// | value | meaning | budget | `think` key |
  /// |---|---|---|---|
  /// | `true` | reported, thinks | 2048 | `"low"` |
  /// | `false` | reported, does NOT think | 256 | absent |
  /// | `nil` | not reported | 2048 | absent |
  ///
  /// `nil` reproduces PRE-#1914 `main` exactly for the four families that the
  /// retired prefix list covered (`qwen3`, `deepseek-r1`, `gpt-oss`, `gemma4`),
  /// which all got the 2048 floor and no `think` key. Collapsing `nil` into
  /// `false` would have handed those users the 256 floor — the starvation this
  /// issue exists to remove — on any daemon that omits the field.
  ///
  /// That matters because `capabilities` on `/api/tags` is UNDOCUMENTED. The
  /// published schema (docs.ollama.com/api/tags, read 2026-08-05) lists only
  /// `name`, `model`, `remote_model`, `remote_host`, `modified_at`, `size`,
  /// `digest` and `details`; capabilities are documented on `/api/show`. It is
  /// nonetheless present on every row in practice (measured: Ollama 0.32.4,
  /// 12 models, 2026-08-01 and again 2026-08-05), so the field is used when
  /// present and its absence must never silently downgrade a user.
  ///
  /// `remote_host` needs no such treatment: it IS documented on `/api/tags`,
  /// and absent-means-local is correct rather than a guess.
  public let thinks: Bool?

  public init(isRemote: Bool, thinks: Bool?) {
    self.isRemote = isRemote
    self.thinks = thinks
  }
}

/// #1305: the instant answer to "is an Ollama polish attempt worth starting?"
/// Returned by `OllamaConnector.preflightReadiness(model:)`; consumed by the
/// polish-entry gate in `LLMPolishStep`. Per-attempt truth — callers must NOT
/// cache it across dictations (the user can quit/start Ollama at any time).
public enum OllamaReadiness: Sendable, Equatable {
  /// Server responded and the tags list contains the model — attempt polish.
  ///
  /// #1914: carries the matched row's own facts. Swift permits a bare
  /// `case .ready:` to match and IGNORE this payload, so the compiler does NOT
  /// enforce that consumers read it. A later chunk both consumes the payload in
  /// `LLMPolishStep` and adds the `OllamaReadinessGateTests` coverage that
  /// asserts the binding, because no compiler check can stand in for it.
  case ready(facts: OllamaModelFacts)
  /// Transport error, timeout, non-2xx, or unparseable body — "Ollama is not
  /// responding" class.
  case serverDown
  /// Server responded with a parsed tags list that has no canonical match for
  /// the model. The user HAS a selection; it is not installed.
  case modelMissing
  /// Nothing is armed at all — the model string is empty.
  ///
  /// #1914: split out of `modelMissing`, which used to absorb it. The two states
  /// need different sentences and the difference is not cosmetic: "no model is
  /// installed in Ollama" was flatly false for a user with models installed and
  /// none selected, which is exactly the state the never-auto-arm-a-hosted-model
  /// refusal now creates on purpose.
  ///
  /// The producer names it rather than the consumer re-deriving emptiness later:
  /// only the preflight can see the armed string, and a downstream `isEmpty`
  /// check would be a second authority on the same question.
  case noModelSelected
}

/// Ollama local LLM connector. Uses Ollama's native /api/chat endpoint
/// for access to `think`, `keep_alive`, and timing telemetry.
/// Requires Ollama to be running: https://ollama.com
public struct OllamaConnector: TranscriptPolisher {
  private let baseURL: String

  /// #901 test seam — the network transport for both call sites (evict + polish
  /// retry loop). Defaults to today's exact expression, so production behavior is
  /// identical. A test injects a request-counting fake to assert the empty-name
  /// evict guard makes zero calls (the old test only bounded wall-clock against a
  /// non-routable host, which a deleted guard still satisfied via fast ECONNREFUSED).
  private let networkExecutor: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public init(
    baseURL: String = "http://localhost:11434",
    networkExecutor: @Sendable @escaping (URLRequest) async throws -> (Data, URLResponse) = {
      try await LLMNetworkSession.shared.session.data(for: $0)
    }
  ) {
    self.baseURL = baseURL
    self.networkExecutor = networkExecutor
  }

  /// NOT REACHED IN PRODUCTION, and kept only because `TranscriptPolisher` requires it
  /// (`LLMProtocol.swift:10-15`; the protocol extension's only default covers the
  /// `envelope:` variant, so removing this would break conformance). Every production Ollama
  /// polish goes through `polish(envelope:)` below — the sole `polish(text:instructions:)`
  /// call site in the pipeline sits inside the `provider == .appleIntelligence` branch.
  ///
  /// This method used to substitute a nine-word system prompt for any model
  /// `OllamaSetupService.isWeakModel` accepted, discarding the planned one. Because the
  /// branch was here rather than on the live path, reading this file was enough to conclude
  /// the app shipped a nine-word prompt to its default model — it never did, and an issue,
  /// a plan premise and two benchmark arms were built on that misreading before it was
  /// caught (#1962, withdrawn). The substitution is gone; this note stays so the next reader
  /// checks the call site before drawing a conclusion from this overload.
  public func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    let endpointURL = "\(baseURL)/api/chat"
    guard let url = URL(string: endpointURL) else {
      throw LLMError.requestFailed("Invalid Ollama URL: \(endpointURL)")
    }

    var messages: [[String: String]] = [
      ["role": "system", "content": instructions.systemPrompt]
    ]
    if !text.isEmpty {
      messages.append(["role": "user", "content": text])
    }

    // #1710: local polish requires an explicit computed cap for num_predict.
    guard case .capped(let maxTokens) = config.outputTokens else {
      throw LLMError.requestFailed("Local polish requires an explicit output-token cap")
    }
    let body = Self.makeRequestBody(
      model: config.model,
      messages: messages,
      maxTokens: maxTokens,
      temperature: config.temperature,
      thinking: config.thinking
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60

    let (data, _) = try await performWithRetry(request: request, config: config)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let message = json?["message"] as? [String: Any],
      let content = message["content"] as? String,
      !content.isEmpty
    else {
      throw LLMError.emptyResponse
    }

    Self.logTelemetry(json: json, message: message, model: config.model)

    // Check for truncation via done_reason
    if let doneReason = json?["done_reason"] as? String, doneReason != "stop" {
      Task {
        await AppLogger.shared.log(
          "WARNING: Ollama response truncated (done_reason=\(doneReason), model=\(config.model))",
          level: .info, category: "LLM"
        )
      }
    }

    return LLMResult(
      polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble()
    )
  }

  public func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    // Ollama supports the full messages array (needed for Gemma few-shot).
    // Map PromptEnvelope roles directly to Ollama API roles.
    let messages: [[String: String]] = envelope.messages.map { msg in
      let role: String
      switch msg.role {
      case .system: role = "system"
      case .user: role = "user"
      case .assistant: role = "assistant"
      }
      return ["role": role, "content": msg.content]
    }

    let endpointURL = "\(baseURL)/api/chat"
    guard let url = URL(string: endpointURL) else {
      throw LLMError.requestFailed("Invalid Ollama URL: \(endpointURL)")
    }

    // #1710: local polish requires an explicit computed cap for num_predict.
    guard case .capped(let maxTokens) = config.outputTokens else {
      throw LLMError.requestFailed("Local polish requires an explicit output-token cap")
    }
    let body = Self.makeRequestBody(
      model: config.model,
      messages: messages,
      maxTokens: maxTokens,
      temperature: config.temperature,
      thinking: config.thinking
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60

    let (data, _) = try await performWithRetry(request: request, config: config)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let message = json?["message"] as? [String: Any],
      let content = message["content"] as? String,
      !content.isEmpty
    else {
      throw LLMError.emptyResponse
    }

    Self.logTelemetry(json: json, message: message, model: config.model)

    if let doneReason = json?["done_reason"] as? String, doneReason != "stop" {
      Task {
        await AppLogger.shared.log(
          "WARNING: Ollama response truncated (done_reason=\(doneReason), model=\(config.model))",
          level: .info, category: "LLM"
        )
      }
    }

    // #1948: strip echoed `<transcript>` wrappers ONLY for EG-1, the one builder left on
    // this connector that still sends them (`EGOnePromptBuilder` wraps the transcript and
    // escapes any literal tags the user dictated). Local (`LocalFixedPromptBuilder`) and
    // hosted (`CloudFixedPromptBuilder`) Ollama send a plain user message, so the model is
    // never shown a tag it could echo — and stripping there could only delete a user's own
    // dictated `<transcript>` text. That is the same reasoning that made the cloud
    // connectors pass `false` when #1255 removed their sandwich; removing the Ollama
    // sandwich without following it would have reintroduced the defect on this path.
    // Keyed off the same first-party authority the planner routes on, not a string sniff of
    // the outgoing prompt, which a user's own dictation could satisfy.
    let sentTranscriptTags = OllamaSetupService.isFirstPartyModel(config.model)
    return LLMResult(
      polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble(stripTranscriptTags: sentTranscriptTags)
    )
  }

  // MARK: - Readiness Preflight (#1305)

  /// Dedicated session for the readiness probe: ephemeral, 1.0s request AND
  /// resource timeouts. Separate from `LLMNetworkSession` so a probe against a
  /// down server can never occupy or reconfigure the polish session, and so the
  /// probe's aggressive timeout never leaks into real polish requests.
  private static let readinessSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 1.0
    config.timeoutIntervalForResource = 1.0
    return URLSession(configuration: config)
  }()

  /// One GET /api/tags on this connector's `baseURL` (the same base the polish
  /// request uses, so probe truth cannot diverge from request truth), answering
  /// the three-state readiness question. Localhost-only by construction — the
  /// probe never touches any external host.
  ///
  /// Never throws and performs no retries: every transport failure, timeout,
  /// non-2xx, and unparseable body maps to `.serverDown`. The session timeouts
  /// bound the request; `withDeadline` is the absolute wall-clock net on top so
  /// a socket-accept wedge cannot hang the caller past ~1s either.
  ///
  /// `executor`/`deadlineSeconds` are test seams (deterministic classification
  /// + deadline behavior without a live server); production callers use the
  /// defaults.
  public func preflightReadiness(
    model: String,
    executor: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
    deadlineSeconds: Double = 1.0
  ) async -> OllamaReadiness {
    // Empty model string → nothing armed. Its own state, not `modelMissing`:
    // no selection exists to be missing. Answered without a network round trip.
    guard !model.isEmpty else { return .noModelSelected }
    guard let url = URL(string: "\(baseURL)/api/tags") else { return .serverDown }
    var mutableRequest = URLRequest(url: url)
    mutableRequest.httpMethod = "GET"
    let request = mutableRequest  // immutable copy for the @Sendable closure below
    let transport = executor ?? { try await Self.readinessSession.data(for: $0) }
    let outcome = await withDeadline(seconds: deadlineSeconds) { () -> OllamaReadiness in
      do {
        let (data, response) = try await transport(request)
        return Self.classifyReadiness(data: data, response: response, model: model)
      } catch {
        return .serverDown
      }
    }
    // Deadline elapsed with no answer — the server is wedged, treat as down.
    return outcome ?? .serverDown
  }

  /// Pure response → readiness classifier (#1305). Membership uses
  /// `OllamaSetupService.canonicalModelName` (equates `llama2` and
  /// `llama2:latest`), never raw string equality. Unit-testable without
  /// network mocking, mirroring `classify(statusCode:bodyString:)` below.
  static func classifyReadiness(
    data: Data, response: URLResponse, model: String
  ) -> OllamaReadiness {
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      return .serverDown
    }
    guard
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let models = json["models"] as? [[String: Any]]
    else {
      return .serverDown
    }
    let target = OllamaSetupService.canonicalModelName(model)
    // #1914: find the MATCHED row and read its own facts. Scanning for facts
    // across all rows would let an unrelated cloud model make a local one look
    // remote, so membership and fact extraction must resolve to one row.
    guard
      let matched = models.first(where: {
        guard let name = $0["name"] as? String else { return false }
        return OllamaSetupService.canonicalModelName(name) == target
      })
    else {
      return .modelMissing
    }
    return .ready(facts: modelFacts(fromTagsRow: matched))
  }

  /// #1914: the SOLE derivation site for both daemon-reported facts. One pure
  /// function over one parsed `/api/tags` row, with exactly two production
  /// consumers: the runtime readiness path below, and
  /// `OllamaSetupService.parseDownloadedModels` for the Manage Models catalog.
  /// Both
  /// go through here so the runtime and the UI can never disagree about the
  /// same model. Do not add a third reader of `remote_host` or `capabilities`.
  ///
  /// Every field is optional in practice and absent on older daemons, so each
  /// check fails to `false` rather than trusting a shape. `false` means "not
  /// observed", never "observed to be false" — which is why a defaulted `false`
  /// must not be reported as proven-local telemetry (plan §3d tri-state).
  nonisolated static func modelFacts(fromTagsRow row: [String: Any]) -> OllamaModelFacts {
    // Remote iff `remote_host` is a non-empty STRING. A present-but-empty value
    // and a JSON null both read as local: `as? String` rejects `NSNull`.
    let remoteHost = row["remote_host"] as? String
    let isRemote = !(remoteHost ?? "").isEmpty

    // `capabilities` is an array of strings; `thinking` is one of them.
    //
    // A missing key, a null, or a non-array shape mean the daemon told us
    // NOTHING about capability, and that is `nil`, not `false` — see the
    // three-state table on `OllamaModelFacts.thinks`. An earlier revision
    // collapsed these to `false` under the comment "preserves today's tight
    // budget"; that justification was wrong, because on `main` the retired
    // prefix list gave qwen3 / deepseek-r1 / gpt-oss / gemma4 the 2048 floor,
    // so `false` would have REGRESSED exactly those users on a daemon that
    // omits the field. Cloud review caught it (PR #1949).
    //
    // An EMPTY array is different again: the daemon answered, and its answer
    // lists no thinking. That is a reported `false`.
    let capabilities = row["capabilities"] as? [String]
    let thinks = capabilities.map { $0.contains("thinking") }

    return OllamaModelFacts(isRemote: isRemote, thinks: thinks)
  }

  // MARK: - Eviction (#295)

  /// Tells Ollama to unload the named model from memory immediately.
  ///
  /// Prevents dual-resident model pressure when the user swaps polish models
  /// mid-session. Ollama's default `keep_alive` holds the previous model in
  /// VRAM for its full window, which on constrained machines has disrupted
  /// CoreAudio BT audio (root cause for #286).
  ///
  /// Fire-and-forget from the heart-path view: swallows all errors, short timeout,
  /// never throws. Uses `/api/generate` per Ollama docs — `keep_alive: 0` on
  /// `/api/chat` is not a documented unload pattern.
  ///
  /// #1177 (Telemetry Bible Phase 8): returns an `OllamaEvictOutcome` so the Pipeline
  /// caller (which has telemetry access; this LLM module does not) can observe a quiet
  /// eviction FAILURE — a model that won't unload starves VRAM and has disrupted
  /// CoreAudio BT audio (#286). `@discardableResult` (Codex r1): the previous callers
  /// + tests treat it as fire-and-forget.
  @discardableResult
  public func evictModel(_ modelName: String) async -> OllamaEvictOutcome {
    let endpointURL = "\(baseURL)/api/generate"
    guard !modelName.isEmpty, let url = URL(string: endpointURL) else {
      return OllamaEvictOutcome(result: "skipped", durationMs: 0, reason: "invalid_url_or_empty")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 3.0

    let start = Date()
    do {
      request.httpBody = try JSONSerialization.data(
        withJSONObject: Self.makeEvictRequestBody(model: modelName)
      )
      let (_, response) = try await networkExecutor(request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      let result = (200...299).contains(status) ? "unloaded" : "failed"
      await AppLogger.shared.log(
        "Ollama evict: model=\(modelName) result=\(result) http=\(status) duration_ms=\(elapsedMs)",
        level: .info, category: "LLM"
      )
      return OllamaEvictOutcome(result: result, durationMs: elapsedMs, reason: "http_\(status)")
    } catch {
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      let reason = (error as? URLError)?.code.rawValue.description ?? "error"
      await AppLogger.shared.log(
        "Ollama evict: model=\(modelName) result=failed reason=\(reason) duration_ms=\(elapsedMs)",
        level: .info, category: "LLM"
      )
      return OllamaEvictOutcome(result: "failed", durationMs: elapsedMs, reason: reason)
    }
  }

  // MARK: - Telemetry

  /// Logs Ollama `/api/chat` timing + reasoning-output telemetry (#276).
  ///
  /// `thinking` captures the char count of `message.thinking`, which we
  /// discard but which gemma4 spends significant eval time producing. Non-
  /// thinking models (llama3.2 etc.) log `thinking=0`. Compare against
  /// `eval`/`tokens` to see what fraction of eval time was spent on
  /// reasoning vs the final answer.
  private static func logTelemetry(
    json: [String: Any]?,
    message: [String: Any],
    model: String
  ) {
    guard
      let loadNs = json?["load_duration"] as? Int64,
      let promptNs = json?["prompt_eval_duration"] as? Int64,
      let evalNs = json?["eval_duration"] as? Int64,
      let evalCount = json?["eval_count"] as? Int
    else { return }
    let loadMs = Double(loadNs) / 1_000_000
    let promptMs = Double(promptNs) / 1_000_000
    let evalMs = Double(evalNs) / 1_000_000
    let thinkingChars = (message["thinking"] as? String)?.count ?? 0
    let contentChars = (message["content"] as? String)?.count ?? 0
    Task {
      await AppLogger.shared.log(
        "Ollama timing: load=\(String(format: "%.0f", loadMs))ms prompt=\(String(format: "%.0f", promptMs))ms eval=\(String(format: "%.0f", evalMs))ms tokens=\(evalCount) thinking=\(thinkingChars)chars content=\(contentChars)chars (model=\(model))",
        level: .verbose, category: "LLM"
      )
    }
  }

  // MARK: - Request body

  /// Builds the `/api/chat` request body shared by both polish entry points.
  ///
  /// `think` handling (#272, revised by #1914):
  /// - A model the daemon reports as thinking receives an explicit `"low"`.
  ///   Omitting the key means the model's DEFAULT depth, which is what starved
  ///   `message.content` to empty in ENVIOUSWISPR-4M; `"low"` addresses the
  ///   cause while the larger `num_predict` floor accommodates what remains.
  ///   Measured 2026-08-01: `"low"` was ~3x faster than `"high"` at identical
  ///   output length.
  /// - A model the daemon reports as NOT thinking receives no `think` key at
  ///   all. Boolean `think: false` is forbidden: gemma4 and gpt-oss silently
  ///   ignore it and leak reasoning into `message.content` as a 5-13× expansion
  ///   the validator rejects, while nemotron honours it — a value two of three
  ///   models ignore cannot be a control.
  /// The value arrives on `config.thinking` as `ResolvedThinking`, resolved per
  /// attempt from the daemon's own facts; this builder never infers it.
  /// Returns the model name iff the provider is `.ollama` and the model
  /// is non-empty; nil otherwise. Pure helper used by the settings
  /// observer to snapshot the pre-swap effective Ollama model (#295).
  public static func effectiveOllamaModel(provider: LLMProvider, model: String) -> String? {
    provider == .ollama && !model.isEmpty ? model : nil
  }

  /// Builds the `/api/generate` unload request body (#295).
  /// Uses `keep_alive: 0` with empty prompt. Some Ollama versions
  /// 400 on missing `prompt` key, so it is emitted explicitly.
  static func makeEvictRequestBody(model: String) -> [String: Any] {
    [
      "model": model,
      "prompt": "",
      "keep_alive": 0,
    ]
  }

  static func makeRequestBody(
    model: String,
    messages: [[String: String]],
    maxTokens: Int,
    temperature: Double,
    thinking: ResolvedThinking?
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "messages": messages,
      "stream": false,
      "keep_alive": "60m",
      "options": [
        "num_predict": maxTokens,
        "temperature": temperature,
      ],
    ]
    // #1914: `think` is a TOP-LEVEL key on /api/chat, not an `options` entry.
    // Only the level dialect is emitted; a budget or effort value would be a
    // different provider's dialect reaching the wrong wire format, so it is
    // dropped rather than coerced. `nil` keeps the key absent entirely, which
    // is what a non-thinking model must send — never a boolean false (#272:
    // ignored by gemma4 and gpt-oss, honoured by nemotron, so it is not a
    // control).
    if case .level(let level) = thinking {
      body["think"] = level
    }
    return body
  }

  // MARK: - Retry

  private func performWithRetry(
    request: URLRequest,
    config: LLMProviderConfig,
    maxRetries: Int = LLMRetryPolicy.defaultMaxRetries,
    delays: [UInt64] = LLMRetryPolicy.defaultDelays
  ) async throws -> (Data, HTTPURLResponse) {
    var lastError: Error?
    for attempt in 0...maxRetries {
      if attempt > 0 {
        let delay = delays[min(attempt - 1, delays.count - 1)]
        Task {
          await AppLogger.shared.log(
            "Ollama retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
            level: .verbose, category: "LLM"
          )
        }
        try await Task.sleep(nanoseconds: delay)
      }

      do {
        let (data, response): (Data, URLResponse)
        do {
          (data, response) = try await networkExecutor(request)
        } catch let urlError as URLError {
          switch urlError.code {
          case .notConnectedToInternet, .cannotFindHost:
            throw LLMError.classified(.providerUnreachable)  // not transient, fail fast
          default:
            throw urlError  // let LLMRetryPolicy.isRetryable() decide
          }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
          throw LLMError.requestFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
          return (data, httpResponse)
        default:
          // #945: read the body INSIDE the error arm for classification (404 ->
          // model not pulled, 5xx -> server error). `data` is in hand from above.
          let bodyString = String(data: data, encoding: .utf8) ?? ""
          #if DEBUG
            let truncated = String(bodyString.prefix(200))
            Task {
              await AppLogger.shared.log(
                "Ollama HTTP \(httpResponse.statusCode): \(truncated)",
                level: .verbose, category: "LLM"
              )
            }
          #else
            Task {
              await AppLogger.shared.log(
                "Ollama HTTP \(httpResponse.statusCode)",
                level: .verbose, category: "LLM"
              )
            }
          #endif
          throw LLMError.classified(
            Self.classify(statusCode: httpResponse.statusCode, bodyString: bodyString))
        }
      } catch {
        lastError = error
        if !LLMRetryPolicy.isRetryable(error) { throw error }
      }
    }
    // Convert exhausted connection errors to domain error for UI
    if let urlError = lastError as? URLError, urlError.code == .cannotConnectToHost {
      throw LLMError.classified(.providerUnreachable)
    }
    throw lastError ?? LLMError.requestFailed("All retries exhausted")
  }

  /// Pure status+body -> reason classifier (#945, #1914). 404 means the model
  /// is unavailable; 5xx is an Ollama-side server error. `bodyString` remains
  /// accepted for classifier signature parity, but Ollama's 429 stays
  /// rate-or-quota ambiguous and is never split from body text.
  /// Unit-testable without network mocking.
  ///
  /// The 401 / 402 / 403 / 429 mapping is plan Decision 6 (#1914), which owns the
  /// evidence for each status. Do not re-derive it here.
  static func classify(statusCode: Int, bodyString: String) -> PolishFailureReason {
    switch statusCode {
    case 401:
      return .apiKeyRejected
    case 402:
      return .outOfCredits
    case 403:
      return .accessDenied
    case 404:
      return .modelUnavailable
    case 429:
      return .rateLimitedOrQuota
    case 500...599:
      return .providerServerError
    default:
      return (400...499).contains(statusCode) ? .badRequest : .unknown
    }
  }
}
