import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Discovers available LLM models from provider APIs and probes their availability.
public struct LLMModelDiscovery: Sendable {
  /// #4353 D6: the cloud model list this discovery run captured. Endpoint eligibility and the
  /// Claude probe's request shape read it, so one run asks one set of rules.
  private let cloudModelList: CloudModelList?

  /// #4353 PR 5: one physical HTTP exchange. Every request this type sends (catalog pages and
  /// availability probes) goes through it. Production always uses the shared session; the
  /// weekly routine's catalog tests inject a scripted transport, so a test request can never
  /// reach a real provider.
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let transport: Transport

  public init(cloudModelList: CloudModelList?) {
    self.cloudModelList = cloudModelList
    self.transport = { request in try await LLMNetworkSession.shared.session.data(for: request) }
  }

  /// Test seam. Production callers use the public init.
  init(cloudModelList: CloudModelList?, transport: @escaping Transport) {
    self.cloudModelList = cloudModelList
    self.transport = transport
  }

  /// #2884: "transcribe" and "audio" are audio-input ids (gemini-3.5-transcribe,
  /// the native-audio Live models) that advertise `generateContent` and so pass
  /// `fetchGeminiModels`, then reject a text polish request with 400. The OpenAI
  /// branch's `isOpenAIChatCompletionCandidate` already skipped both. Named on its own so
  /// a leftover pick's 400 can be read as "this model cannot be used" (#4353 G5).
  static let audioInputPatterns = ["transcribe", "audio"]

  /// Exclusion patterns for model IDs that aren't useful for transcript polishing.
  static let excludePatterns =
    [
      "tts", "image", "robotics", "computer-use", "deep-research",
      "gemma", "exp-", "embedding", "aqa", "vision", "nano-banana",
      "lyria",
    ] + audioInputPatterns

  /// #4353 G5: an audio-input model id (`gemini-3.5-transcribe`, `gpt-4o-audio-preview`), which
  /// rejects a text polish request with HTTP 400.
  public static func isAudioInputModelID(_ id: String) -> Bool {
    let lowered = id.lowercased()
    return audioInputPatterns.contains { lowered.contains($0) }
  }

  /// Suffixes that indicate versioned duplicates (keep only the base model).
  private static let versionedSuffixes = ["-001", "-002", "-003"]

  /// Alias prefixes to exclude (keep specific versioned models only).
  private static let aliasPatterns = ["latest"]

  /// #1914: one fetched row on its way to becoming an `LLMModelInfo`.
  ///
  /// Replaces the bare `(id:displayName:)` tuple the fetchers used to hand
  /// around, because remoteness now has to survive the trip from `/api/tags` to
  /// the selection dropdown and a tuple cannot carry it without every cloud
  /// fetcher also growing a field it has no answer for. #4353 D5: the cloud fetchers now
  /// build candidates directly (`openAICandidates`, `claudeCandidates`, `geminiCandidates`), so
  /// the provider's release date travels the same way.
  /// `internal`, not `private`, so the pure mapping below is directly testable.
  /// The picker's fetchers had no HTTP mock (see `LLMModelDiscoveryTests`), so the
  /// established answer here is to extract the pure decision and test that — the same shape
  /// as `claudePaginationDecision`. #4353 PR 5 added the `Transport` seam for the routine's
  /// catalog tests (`CloudModelRoutineCatalogTests`).
  struct DiscoveryCandidate: Sendable, Equatable {
    let id: String
    let displayName: String
    /// Meaningful for `.ollama` only — see `LLMModelInfo.isRemote`.
    let isRemote: Bool
    /// #4353 D5: the provider's own release date, nil when it gives none; see
    /// `LLMModelInfo.releaseDate`.
    var releaseDate: Date? = nil
  }

  /// #1914: the FINAL handoff — a candidate becomes the row selection and
  /// auto-selection actually consume.
  ///
  /// Production-owned rather than inline in the task group because remoteness
  /// crosses TWO links, and testing only the first proves nothing about the
  /// second: `ollamaCandidates` carries the fact out of the wire format, and
  /// this carries it into `LLMModelInfo`. A mutation to an inline construction
  /// would have evaded every control aimed at the parser.
  static func modelInfo(
    from candidate: DiscoveryCandidate,
    provider: LLMProvider,
    availability: LLMModelAvailability,
    observedAt: ContinuousClock.Instant?
  ) -> LLMModelInfo {
    LLMModelInfo(
      id: candidate.id,
      displayName: candidate.displayName,
      provider: provider,
      availability: availability,
      isRemote: candidate.isRemote,
      availabilityObservedAt: observedAt,
      releaseDate: candidate.releaseDate
    )
  }

  /// #4353 D4: what one cloud probe's answer says about the model, as a pure decision so the
  /// three probes cannot disagree and tests reach the rule the probes call.
  ///
  /// `statusCode == nil` means no HTTP answer (offline, timeout, cancellation, not HTTP).
  /// Only evidence about the MODEL for this key confirms unavailability: the provider's own
  /// classifier saying `.modelUnavailable` (404) or `.accessDenied` (403), or Gemini's
  /// quota-zero lock (a 429 whose body reports `limit: 0`). A rate limit, a busy server, a
  /// rejected key, a billing problem or an unclassified answer says nothing about the model,
  /// so it is inconclusive and the row stays selectable.
  static func probeAvailability(
    provider: LLMProvider, statusCode: Int?, body: String
  ) -> LLMModelAvailability {
    guard let statusCode else { return .inconclusive }
    if statusCode == 200 { return .available }
    let reason: PolishFailureReason
    switch provider {
    case .openAI: reason = OpenAIConnector.classify(statusCode: statusCode, bodyString: body)
    case .claude: reason = ClaudeConnector.classify(statusCode: statusCode, bodyString: body)
    case .gemini:
      if statusCode == 429, body.contains("limit: 0") { return .confirmedUnavailable }
      reason = GeminiConnector.classify(statusCode: statusCode, bodyString: body)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return .inconclusive
    }
    switch reason {
    case .modelUnavailable, .accessDenied: return .confirmedUnavailable
    default: return .inconclusive
    }
  }

  /// #1914: `/api/tags` rows to selection-dropdown candidates.
  ///
  /// The whole body is a delegation on purpose. Discovery must NOT read
  /// `remote_host` or `capabilities` itself. `OllamaConnector.modelFacts` has
  /// exactly two production callers by design — `parseDownloadedModels` (the
  /// catalog) and `classifyReadiness` (the runtime) — and discovery reaches it
  /// THROUGH the first rather than becoming a third. A third reader of one wire
  /// format is exactly how the dropdown and the runtime would come to disagree
  /// about the same model.
  ///
  /// Extracted from `fetchOllamaModels` so remoteness reaching a candidate is
  /// assertable without a live daemon. Without this seam, breaking the link
  /// would fail no test at all.
  static func ollamaCandidates(fromTagsModels models: [[String: Any]]) -> [DiscoveryCandidate] {
    OllamaSetupService.parseDownloadedModels(fromTagsModels: models)
      .map {
        DiscoveryCandidate(
          id: $0.exactName,
          displayName: $0.displayName,
          isRemote: $0.facts.isRemote
        )
      }
  }

  // #4353 D5: the three cloud list parsers, pure so the date's trip from the wire format to
  // the row is testable without HTTP (as `ollamaCandidates` is). Cloud candidates are never
  // remote in the Ollama sense: no Ollama daemon is in their path. A missing or unusable date
  // keeps the row, undated.

  /// OpenAI `/v1/models` `data` rows: `created` is Unix seconds.
  static func openAICandidates(
    fromModels models: [[String: Any]], list: CloudModelList?
  ) -> [DiscoveryCandidate] {
    models.compactMap { model -> DiscoveryCandidate? in
      guard let id = model["id"] as? String else { return nil }
      guard isOpenAIChatCompletionCandidate(id, list: list) else { return nil }
      let displayName = id.replacingOccurrences(of: "-", with: " ")
        .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(
          separator: " ")
      let released = unixSecondsDate(model["created"])
      return DiscoveryCandidate(
        id: id, displayName: displayName, isRemote: false, releaseDate: released)
    }
  }

  /// Anthropic `/v1/models` `data` rows (one page): `created_at` is an RFC 3339 date-time.
  static func claudeCandidates(fromModels models: [[String: Any]]) -> [DiscoveryCandidate] {
    models.compactMap { model -> DiscoveryCandidate? in
      guard let id = model["id"] as? String else { return nil }
      let displayName = model["display_name"] as? String ?? id
      return DiscoveryCandidate(
        id: id, displayName: displayName, isRemote: false,
        releaseDate: (model["created_at"] as? String).flatMap(rfc3339Date).flatMap(knownDate))
    }
  }

  /// Gemini `/v1beta/models` rows that can generate content. Gemini publishes no release
  /// date, so the rows are undated (PR 4's model list supplies dates).
  static func geminiCandidates(fromModels models: [[String: Any]]) -> [DiscoveryCandidate] {
    models.compactMap { model -> DiscoveryCandidate? in
      guard let name = model["name"] as? String, geminiExclusion(model) == nil,
        let displayName = model["displayName"] as? String
      else { return nil }
      let id = name.replacingOccurrences(of: "models/", with: "")
      return DiscoveryCandidate(id: id, displayName: displayName, isRemote: false)
    }
  }

  /// #4353 PR 5: why `geminiCandidates` drops a Gemini row, nil when it keeps it. The one
  /// owner of that decision, so the routine's catalog reports the same reason the picker acts on.
  static func geminiExclusion(_ model: [String: Any]) -> CatalogExclusion? {
    guard let methods = model["supportedGenerationMethods"] as? [String],
      methods.contains("generateContent")
    else { return .noGenerateContent }
    guard model["displayName"] is String else { return .incompleteMetadata }
    return nil
  }

  /// A JSON number of Unix seconds as a known date; nil for a boolean (which `NSNumber`
  /// would otherwise accept), a non-finite value or anything else.
  static func unixSecondsDate(_ value: Any?) -> Date? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
    else { return nil }
    return knownDate(Date(timeIntervalSince1970: number.doubleValue))
  }

  /// A provider's "release date unknown" marker is the Unix epoch (Anthropic documents an
  /// epoch value for an unknown date); that and anything earlier is no date at all.
  static func knownDate(_ date: Date) -> Date? {
    date.timeIntervalSince1970 > 0 ? date : nil
  }

  /// An RFC 3339 date-time, with or without fractional seconds; nil for anything else.
  static func rfc3339Date(_ text: String) -> Date? {
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    if let date = whole.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
  }

  // MARK: - Public API

  /// Discover and probe models for the given provider.
  /// Returns models sorted: available first, then locked, alphabetically within each group.
  public func discoverModels(
    provider: LLMProvider, apiKey: String,
    didListModels: (@Sendable () async -> Void)? = nil
  ) async throws -> [LLMModelInfo] {
    let candidates: [DiscoveryCandidate]

    // #1914: each cloud branch now filters at its own call site. Previously one
    // shared `provider == .ollama ? modelIDs : filterModels(modelIDs)` line did
    // it — identical behaviour, since Ollama was the sole unfiltered provider,
    // but the conditional no longer earns its keep once the branches differ in
    // what they return.
    switch provider {
    case .gemini:
      candidates = filterModels(try await fetchGeminiModels(apiKey: apiKey))
    case .openAI:
      candidates = filterModels(try await fetchOpenAIModels(apiKey: apiKey))
    case .claude:
      candidates = filterModels(try await fetchClaudeModels(apiKey: apiKey))
    case .ollama:
      candidates = try await fetchOllamaModels()
    case .appleIntelligence:
      return Self.appleIntelligenceModelInfo()
    case .egOne:
      // #1271: fixed first-party model — nothing to discover; the settings
      // row renders manifest identity from `LocalPolishRuntime`, not from here.
      return []
    case .s1Mini:
      // #2649: fixed third-party model, same answer. Routing it into the
      // key-provider discovery path instead would hand the coordinator an empty
      // model list and let it overwrite `llmModel` — the defect #1271 Codex r7
      // already fixed once for EG-1.
      return []
    case .none:
      return []
    }

    await didListModels?()

    // Probe models with concurrency limit to avoid rate limiting
    var results: [LLMModelInfo] = []

    // Process in batches to limit concurrent requests
    for batch in candidates.chunked(into: LLMConstants.maxConcurrentProbes) {
      let batchResults = await withTaskGroup(of: LLMModelInfo.self, returning: [LLMModelInfo].self)
      { group in
        for model in batch {
          group.addTask {
            let availability = await probeModel(
              id: model.id, provider: provider, apiKey: apiKey)
            // #4353: this model's answer arrived now, inside its own probe task; neither the
            // discovery's start nor the list's publication stands in for it.
            let observedAt = ContinuousClock.now
            return Self.modelInfo(
              from: model,
              provider: provider,
              availability: availability,
              observedAt: observedAt
            )
          }
        }

        var batchItems: [LLMModelInfo] = []
        for await result in group {
          batchItems.append(result)
        }
        return batchItems
      }
      results.append(contentsOf: batchResults)
    }

    return Self.sortedForPicker(results)
  }

  /// Selectable rows first, then confirmed-locked rows; each by display name (#4353 D4). A row
  /// discovery was not sure about sorts WITH the working rows: being unsure is not a reason to
  /// push a model down the menu.
  static func sortedForPicker(_ rows: [LLMModelInfo]) -> [LLMModelInfo] {
    rows.sorted { lhs, rhs in
      if lhs.isSelectable != rhs.isSelectable { return lhs.isSelectable }
      return lhs.displayName < rhs.displayName
    }
  }

  // MARK: - Gemini

  /// What a Gemini model-list answer that is not 200 means (#3438).
  ///
  /// Only Google's structured `ErrorInfo` with reason `API_KEY_INVALID` is evidence that the
  /// KEY was refused: `{"error": {"status": "INVALID_ARGUMENT", "details": [{"@type":
  /// "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID", ...}]}}`
  /// (Google AIP-193 error model). The token appearing only in message text is
  /// `invalidKeyUnconfirmed`, and a 403 is a permission failure (billing, API not enabled,
  /// region or project restrictions), `permissionDenied`. The key check SHOWS both exactly as
  /// it did before (an invalid key), but neither is recorded as a rejected key.
  static func geminiFailure(statusCode: Int, body: String) -> (any Error)? {
    if statusCode == 403 { return ModelDiscoveryFailure.permissionDenied }
    if statusCode == 400 {
      if geminiErrorInfoReasons(body).contains("API_KEY_INVALID") { return LLMError.invalidAPIKey }
      // The old text match, kept for what the key check shows; not evidence of a refused key.
      if body.contains("API_KEY_INVALID") { return ModelDiscoveryFailure.invalidKeyUnconfirmed }
    }
    guard statusCode == 200 else { return ModelDiscoveryFailure.httpStatus(statusCode) }
    return nil
  }

  /// The `reason` of every `google.rpc.ErrorInfo` in a Google error envelope; empty when the
  /// body is not that envelope.
  static func geminiErrorInfoReasons(_ body: String) -> [String] {
    guard let data = body.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = root["error"] as? [String: Any],
      let details = error["details"] as? [[String: Any]]
    else { return [] }
    return details.compactMap { detail in
      guard (detail["@type"] as? String) == "type.googleapis.com/google.rpc.ErrorInfo" else {
        return nil
      }
      return detail["reason"] as? String
    }
  }

  private func fetchGeminiModels(apiKey: String) async throws -> [DiscoveryCandidate] {
    // One page, as before #4353 PR 5; the routine's catalog follows every page.
    Self.geminiCandidates(
      fromModels: try await geminiModelPage(apiKey: apiKey, pageToken: nil, strict: false).rows)
  }

  /// One Gemini `/v1beta/models` page. `pageToken == nil && !strict` sends the exact request
  /// the picker always sent (no query). `strict` (the routine's catalog, #4353 PR 5) asks for
  /// the largest page, and refuses a reply that is not a JSON object or whose `models` is not a
  /// list of objects, instead of reading it as an empty catalog. Google omits an empty list, so
  /// a missing `models` is a valid empty page in both modes.
  private func geminiModelPage(apiKey: String, pageToken: String?, strict: Bool) async throws
    -> (rows: [[String: Any]], nextPageToken: Any?)
  {
    guard var components = URLComponents(
      string: "https://generativelanguage.googleapis.com/v1beta/models")
    else { throw ModelDiscoveryFailure.invalidURL }
    if strict {
      components.queryItems =
        [URLQueryItem(name: "pageSize", value: "1000")]
        + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
    }
    guard let url = components.url else { throw ModelDiscoveryFailure.invalidURL }
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = 15

    let (data, response) = try await transport(request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ModelDiscoveryFailure.invalidResponse
    }

    if let failure = Self.geminiFailure(
      statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
    {
      throw failure
    }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if strict {
      guard let json else { throw CatalogFailure.malformedResponse }
      guard let value = json["models"] else { return ([], json["nextPageToken"]) }
      guard let models = value as? [[String: Any]] else { throw CatalogFailure.malformedResponse }
      return (models, json["nextPageToken"])
    }
    guard let models = json?["models"] as? [[String: Any]] else { return ([], nil) }
    return (models, nil)
  }

  private func probeGemini(modelID: String, apiKey: String) async -> LLMModelAvailability {
    let urlString =
      "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent"
    guard let url = URL(string: urlString) else { return .inconclusive }

    let body = Self.makeGeminiProbeRequestBody()

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 10

    guard let (data, response) = try? await transport(request),
      let httpResponse = response as? HTTPURLResponse
    else { return .inconclusive }
    return Self.probeAvailability(
      provider: .gemini, statusCode: httpResponse.statusCode,
      body: String(data: data, encoding: .utf8) ?? "")
  }

  static func makeGeminiProbeRequestBody() -> [String: Any] {
    [
      "contents": [["parts": [["text": "Hi"]]]],
      "generationConfig": ["maxOutputTokens": 5],
      "store": false,
    ]
  }

  // MARK: - OpenAI

  private func fetchOpenAIModels(apiKey: String) async throws -> [DiscoveryCandidate] {
    Self.openAICandidates(
      fromModels: try await openAIModelRows(apiKey: apiKey, strict: false), list: cloudModelList)
  }

  /// The OpenAI `/v1/models` rows. `strict` (the routine's catalog, #4353 PR 5) refuses a reply
  /// without a `data` list of objects instead of reading it as an empty catalog.
  private func openAIModelRows(apiKey: String, strict: Bool) async throws -> [[String: Any]] {
    guard let url = URL(string: "https://api.openai.com/v1/models") else {
      throw ModelDiscoveryFailure.invalidURL
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    let (data, response) = try await transport(request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ModelDiscoveryFailure.invalidResponse
    }

    if httpResponse.statusCode == 401 { throw LLMError.invalidAPIKey }
    guard httpResponse.statusCode == 200 else {
      throw ModelDiscoveryFailure.httpStatus(httpResponse.statusCode)
    }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let models = json?["data"] as? [[String: Any]] else {
      if strict { throw CatalogFailure.malformedResponse }
      return []
    }
    return models
  }

  /// Whether an OpenAI model id belongs in the picker's candidate list.
  /// Owns the OpenAI-specific prefix and modality checks and consults the
  /// capability authority for endpoint eligibility, so Responses-API-only
  /// families (-pro, codex) never appear as permanently locked rows (#1330).
  /// Shared alias ("latest") and version-duplicate ("-001") filtering stays
  /// in `filterModels` — it applies to every provider, not just OpenAI.
  static func isOpenAIChatCompletionCandidate(_ modelID: String, list: CloudModelList?) -> Bool {
    openAIExclusion(modelID, list: list) == nil
  }

  /// #4353 PR 5: why `isOpenAIChatCompletionCandidate` refuses an id, nil when it accepts it.
  /// The predicate is defined as "no reason", so the routine's catalog and the picker share
  /// one decision.
  static func openAIExclusion(_ modelID: String, list: CloudModelList?) -> CatalogExclusion? {
    let id = modelID.lowercased()
    // Only chat-capable text models (gpt- and o- prefixes).
    guard
      id.hasPrefix("gpt-") || id.hasPrefix("o-") || id.hasPrefix("o1") || id.hasPrefix("o3")
        || id.hasPrefix("o4")
    else { return .notChatTextFamily }
    // Skip non-text modalities.
    let skipPatterns = ["realtime", "audio", "search", "transcribe"]
    if skipPatterns.contains(where: { id.contains($0) }) { return .nonTextModality }
    return LLMProvider.openAI.modelCapabilities(model: id, list: list).supportsChatCompletions
      ? nil : .noChatCompletions
  }

  private func probeOpenAI(modelID: String, apiKey: String) async -> LLMModelAvailability {
    let body = Self.makeOpenAIProbeRequestBody(modelID: modelID)

    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
      return .inconclusive
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 10

    guard let (data, response) = try? await transport(request),
      let httpResponse = response as? HTTPURLResponse
    else { return .inconclusive }
    return Self.probeAvailability(
      provider: .openAI, statusCode: httpResponse.statusCode,
      body: String(data: data, encoding: .utf8) ?? "")
  }

  static func makeOpenAIProbeRequestBody(modelID: String) -> [String: Any] {
    [
      "model": modelID,
      "messages": [["role": "user", "content": "Hi"]],
      "max_completion_tokens": 5,
      "store": false,
    ]
  }

  // MARK: - Claude

  /// One page's pagination outcome, decided from `has_more`/`last_id` alone —
  /// pure and network-free so the malformed/repeated-cursor guard is directly
  /// unit-testable (`LLMModelDiscoveryTests.swift`) without mocking HTTP.
  enum ClaudePaginationDecision: Equatable {
    case `continue`(afterID: String)
    case stop
    case malformedCursor
  }

  static func claudePaginationDecision(
    hasMore: Bool, lastID: String?, seenCursors: Set<String>
  ) -> ClaudePaginationDecision {
    guard hasMore else { return .stop }
    guard let lastID, !lastID.isEmpty, !seenCursors.contains(lastID) else {
      return .malformedCursor
    }
    return .continue(afterID: lastID)
  }

  /// Fetches the full Claude model catalog, following cursor pagination
  /// (`has_more`/`last_id`/`after_id`) rather than assuming a single page.
  /// The founder's live account returned one page on 2026-07-20, but
  /// Anthropic's documented default page size (20) is smaller than a
  /// growing catalog, so a single-page assumption would silently truncate
  /// the picker once the account has more models than fit on one page.
  private func fetchClaudeModels(apiKey: String) async throws -> [DiscoveryCandidate] {
    Self.claudeCandidates(fromModels: try await claudeModelRows(apiKey: apiKey, strict: false))
  }

  /// Every Claude catalog row across every page. `strict` (the routine's catalog, #4353 PR 5)
  /// refuses a page without a `data` list of objects or without a boolean `has_more`, where the
  /// picker stops early (keeping the rows so far) or reads "no more pages".
  private func claudeModelRows(apiKey: String, strict: Bool) async throws -> [[String: Any]] {
    var allModels: [[String: Any]] = []
    var afterID: String?
    var seenCursors: Set<String> = []

    while true {
      var urlString = "https://api.anthropic.com/v1/models?limit=1000"
      if let afterID {
        urlString += "&after_id=\(afterID)"
      }
      guard let url = URL(string: urlString) else {
        throw ModelDiscoveryFailure.invalidURL
      }
      var request = URLRequest(url: url)
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      request.timeoutInterval = 15

      let (data, response) = try await transport(request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw ModelDiscoveryFailure.invalidResponse
      }

      if httpResponse.statusCode == 401 { throw LLMError.invalidAPIKey }
      guard httpResponse.statusCode == 200 else {
        throw ModelDiscoveryFailure.httpStatus(httpResponse.statusCode)
      }

      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard let models = json?["data"] as? [[String: Any]] else {
        if strict { throw CatalogFailure.malformedResponse }
        break
      }
      // An exact JSON boolean: `is Bool` would also accept a bridged number such as 0, and a
      // malformed `has_more: 0` must not end the catalog early (the shape `CloudModelList` reads
      // booleans with).
      if strict {
        guard let value = json?["has_more"] as? NSNumber,
          CFGetTypeID(value) == CFBooleanGetTypeID()
        else { throw CatalogFailure.malformedResponse }
      }

      allModels.append(contentsOf: models)

      switch Self.claudePaginationDecision(
        hasMore: json?["has_more"] as? Bool ?? false,
        lastID: json?["last_id"] as? String,
        seenCursors: seenCursors
      ) {
      case .stop:
        return allModels
      case .malformedCursor:
        throw ModelDiscoveryFailure.malformedPagination
      case .continue(let nextAfterID):
        seenCursors.insert(nextAfterID)
        afterID = nextAfterID
      }
    }

    return allModels
  }

  private func probeClaude(modelID: String, apiKey: String) async -> LLMModelAvailability {
    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
      return .inconclusive
    }
    let body = ClaudeConnector.makeRequestBody(
      model: modelID, list: cloudModelList, maxTokens: 5, system: nil, userText: "Hi")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 10

    guard let (data, response) = try? await transport(request),
      let httpResponse = response as? HTTPURLResponse
    else { return .inconclusive }
    // A transient rate limit or server-side overload is not proof the key lacks access to
    // this model (Codex local review; Anthropic's 429 `rate_limit_error` and 5xx, incl. 529
    // `overloaded_error`). Before #4353 those read as AVAILABLE; now they are inconclusive,
    // which keeps the row selectable without claiming the probe succeeded.
    return Self.probeAvailability(
      provider: .claude, statusCode: httpResponse.statusCode,
      body: String(data: data, encoding: .utf8) ?? "")
  }

  // MARK: - Ollama

  private func fetchOllamaModels() async throws -> [DiscoveryCandidate] {
    guard let url = URL(string: "http://localhost:11434/api/tags") else {
      throw ModelDiscoveryFailure.invalidOllamaURL
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5

    do {
      let (data, response) = try await transport(request)
      guard let httpResponse = response as? HTTPURLResponse,
        httpResponse.statusCode == 200
      else {
        throw LLMError.providerUnavailable
      }

      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard let models = json?["models"] as? [[String: Any]] else { return [] }

      // #1914: parsing lives in `ollamaCandidates` so it is testable without a
      // live daemon. That also deleted a duplicate: the name-prettifying block
      // that used to sit here was byte-identical to
      // `OllamaSetupService.inferDisplayName`, which the shared parser already
      // applies, so dropdown labels are unchanged.
      return Self.ollamaCandidates(fromTagsModels: models)
    } catch let urlError as URLError {
      switch urlError.code {
      case .cannotConnectToHost, .timedOut, .cannotFindHost,
        .networkConnectionLost, .notConnectedToInternet:
        throw LLMError.providerUnavailable
      default:
        throw ModelDiscoveryFailure.network(urlError.localizedDescription)
      }
    }
  }

  // MARK: - Apple Intelligence

  /// The Apple Intelligence row, from a local availability check (#3142: also re-run on every
  /// cache load, so a stale cached row never shows an old status or an old language). The
  /// English `displayName` stays as data; the picker shows `localizedDisplayName`.
  public static func appleIntelligenceModelInfo() -> [LLMModelInfo] {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
          return [appleIntelligenceRow(.onDevice, isAvailable: true)]
        case .unavailable(let reason):
          let status: AppleIntelligenceModelStatus
          switch reason {
          case .deviceNotEligible: status = .deviceNotSupported
          case .appleIntelligenceNotEnabled: status = .notEnabled
          case .modelNotReady: status = .modelNotReady
          @unknown default: status = .unavailable
          }
          return [appleIntelligenceRow(status, isAvailable: false)]
        }
      }
    #endif
    return [appleIntelligenceRow(.requiresMacOS26, isAvailable: false)]
  }

  /// One Apple Intelligence row. `displayName` is the English label, as before (#3142);
  /// `isRemote` is false because Apple Intelligence runs on this Mac by definition, stated
  /// rather than defaulted (`LLMModelInfo.init` requires it).
  static func appleIntelligenceRow(_ status: AppleIntelligenceModelStatus, isAvailable: Bool)
    -> LLMModelInfo
  {
    LLMModelInfo(
      id: "apple-intelligence", displayName: englishAppleIntelligenceLabel(status),
      provider: .appleIntelligence,
      availability: isAvailable ? .available : .confirmedUnavailable, isRemote: false,
      appleIntelligenceStatus: status)
  }

  /// The English label each status had before the catalog, kept as the row's data.
  static func englishAppleIntelligenceLabel(_ status: AppleIntelligenceModelStatus) -> String {
    switch status {
    case .onDevice: return "Apple Intelligence (On-Device)"
    case .deviceNotSupported: return "Apple Intelligence (Device Not Supported)"
    case .notEnabled: return "Apple Intelligence (Not Enabled in Settings)"
    case .modelNotReady: return "Apple Intelligence (Model Not Ready)"
    case .unavailable: return "Apple Intelligence (Unavailable)"
    case .requiresMacOS26: return "Apple Intelligence (Requires macOS 26+)"
    }
  }

  // MARK: - Catalog only (#4353 PR 5)

  /// Why a fetched cloud model id is not one the picker would offer. Each case is produced by
  /// exactly one shipped decision: `openAIExclusion`, `geminiExclusion` or `sharedExclusion`.
  enum CatalogExclusion: String, Sendable, Equatable, CaseIterable {
    /// OpenAI: not a `gpt-`/`o`-family text model.
    case notChatTextFamily
    /// OpenAI: a realtime, audio, search or transcription model.
    case nonTextModality
    /// OpenAI: the capability rules say it has no chat-completions endpoint (#1330).
    case noChatCompletions
    /// Gemini: does not list `generateContent`.
    case noGenerateContent
    /// Gemini: has no display name, which the picker requires.
    case incompleteMetadata
    /// Every provider: an `excludePatterns` id (tts, image, audio input, ...).
    case excludedPattern
    /// Every provider: a `-001`-style versioned duplicate.
    case versionedDuplicate
    /// Every provider: a `latest` alias.
    case alias
  }

  /// One provider's complete catalog for the weekly cloud model routine (D7 detail, Stage 1
  /// harness item 2), read WITHOUT availability probes: the routine pays only for the
  /// dictations it runs on the new models it selects.
  struct CloudCatalog: Sendable, Equatable {
    struct Excluded: Sendable, Equatable {
      let id: String
      let reason: CatalogExclusion
    }

    let provider: LLMProvider
    /// Every id the provider listed, across every page, in first-seen order, BEFORE any
    /// eligibility rule. Absence accounting reads this population, so a model the picker
    /// excludes still counts as present.
    let identities: [String]
    /// Exactly the rows ordinary discovery would go on to probe: the provider's parser, then
    /// `filterModels`, with a repeated id kept once.
    let eligible: [DiscoveryCandidate]
    /// Every identity not in `eligible`, with the first shipped rule that removed it.
    let excluded: [Excluded]
  }

  /// A catalog that could not be read completely. Never an empty catalog: a routine that
  /// mistook a broken reply for "no models" would mark every listed model missing.
  enum CatalogFailure: Error, Equatable {
    case unsupportedProvider
    /// A reply that is not the documented shape, or a row without an id.
    case malformedResponse
    /// A next-page cursor that is empty, not text, or already followed.
    case malformedPagination
  }

  /// Read one cloud provider's whole catalog through the shared parsers and eligibility rules,
  /// following every page, with no probe and no generation request. Throws instead of
  /// returning a partial catalog: HTTP failures keep their discovery errors
  /// (`LLMError.invalidAPIKey`, `ModelDiscoveryFailure`), shape failures are `CatalogFailure`.
  func fetchCatalog(provider: LLMProvider, apiKey: String) async throws -> CloudCatalog {
    let rows: [[String: Any]]
    switch provider {
    case .openAI: rows = try await openAIModelRows(apiKey: apiKey, strict: true)
    case .claude: rows = try await claudeModelRows(apiKey: apiKey, strict: true)
    case .gemini: rows = try await geminiCatalogRows(apiKey: apiKey)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      throw CatalogFailure.unsupportedProvider
    }
    return try Self.catalog(provider: provider, rows: rows, list: cloudModelList)
  }

  /// Every Gemini page, following `nextPageToken` (ordinary discovery reads one page).
  private func geminiCatalogRows(apiKey: String) async throws -> [[String: Any]] {
    var rows: [[String: Any]] = []
    var token: String?
    var seenTokens: Set<String> = []
    while true {
      let page = try await geminiModelPage(apiKey: apiKey, pageToken: token, strict: true)
      rows.append(contentsOf: page.rows)
      switch Self.geminiPageDecision(nextPageToken: page.nextPageToken, seenTokens: seenTokens) {
      case .stop: return rows
      case .malformed: throw CatalogFailure.malformedPagination
      case .next(let next):
        seenTokens.insert(next)
        token = next
      }
    }
  }

  enum GeminiPageDecision: Equatable {
    case next(String)
    case stop
    case malformed
  }

  /// Gemini omits `nextPageToken` (or sends it empty) on the last page. Any other value must
  /// be text not followed before, or the catalog is refused rather than looped or truncated.
  static func geminiPageDecision(nextPageToken: Any?, seenTokens: Set<String>)
    -> GeminiPageDecision
  {
    guard let value = nextPageToken else { return .stop }
    guard let token = value as? String else { return .malformed }
    if token.isEmpty { return .stop }
    return seenTokens.contains(token) ? .malformed : .next(token)
  }

  /// The catalog from raw rows. Each row goes through the same parser the picker uses, one row
  /// at a time, so eligibility is the shipped decision and not a copy of it.
  static func catalog(provider: LLMProvider, rows: [[String: Any]], list: CloudModelList?)
    throws -> CloudCatalog
  {
    var identities: [String] = []
    var seen: Set<String> = []
    var eligible: [DiscoveryCandidate] = []
    var excluded: [CloudCatalog.Excluded] = []
    for row in rows {
      let id: String
      let parsed: DiscoveryCandidate?
      let providerReason: CatalogExclusion?
      switch provider {
      case .openAI:
        guard let raw = row["id"] as? String else { throw CatalogFailure.malformedResponse }
        id = raw
        providerReason = openAIExclusion(raw, list: list)
        parsed = openAICandidates(fromModels: [row], list: list).first
      case .claude:
        guard let raw = row["id"] as? String else { throw CatalogFailure.malformedResponse }
        id = raw
        providerReason = nil
        parsed = claudeCandidates(fromModels: [row]).first
      case .gemini:
        guard let name = row["name"] as? String else { throw CatalogFailure.malformedResponse }
        id = name.replacingOccurrences(of: "models/", with: "")
        providerReason = geminiExclusion(row)
        parsed = geminiCandidates(fromModels: [row]).first
      case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
        throw CatalogFailure.unsupportedProvider
      }
      guard !id.isEmpty else { throw CatalogFailure.malformedResponse }
      guard seen.insert(id).inserted else { continue }
      identities.append(id)
      if let providerReason {
        excluded.append(.init(id: id, reason: providerReason))
        continue
      }
      // The parser keeps every row its exclusion function passes; a nil here means the two
      // disagree, which must fail loudly rather than drop a model from the population.
      guard let parsed else { throw CatalogFailure.malformedResponse }
      if let sharedReason = sharedExclusion(id) {
        excluded.append(.init(id: id, reason: sharedReason))
        continue
      }
      eligible.append(parsed)
    }
    return CloudCatalog(
      provider: provider, identities: identities, eligible: eligible, excluded: excluded)
  }

  // MARK: - Shared Helpers

  private func probeModel(id: String, provider: LLMProvider, apiKey: String) async
    -> LLMModelAvailability
  {
    switch provider {
    case .gemini: return await probeGemini(modelID: id, apiKey: apiKey)
    case .openAI: return await probeOpenAI(modelID: id, apiKey: apiKey)
    case .claude: return await probeClaude(modelID: id, apiKey: apiKey)
    case .ollama: return .available  // If model appears in tags list, it's available
    case .appleIntelligence: return .available
    case .egOne: return .available  // #1271: availability is the health probe's job, not discovery's
    case .s1Mini: return .available  // #2649: same — a fixed local model, health-probed, never discovered
    case .none: return .confirmedUnavailable
    }
  }

  /// #2884: the one reader of `excludePatterns`. Discovery calls it through
  /// `filterModels`; `LLMModelDiscoveryCoordinator.loadCachedModels` calls it on a
  /// catalog cached BEFORE a pattern was added, so an already-cached dead id
  /// leaves the picker on the next Settings open rather than on the next key save.
  public static func isExcludedModelID(_ id: String) -> Bool {
    let lowered = id.lowercased()
    return excludePatterns.contains { lowered.contains($0) }
  }

  /// `internal`, not `private`, so the pure exclusion decision is directly
  /// testable (#2884) — same reasoning as `DiscoveryCandidate` above.
  func filterModels(_ models: [DiscoveryCandidate]) -> [DiscoveryCandidate] {
    models.filter { Self.sharedExclusion($0.id) == nil }
  }

  /// #4353 PR 5: why `filterModels` drops an id, nil when it keeps it; the one owner of the
  /// every-provider exclusions, so the routine's catalog reports the reason the picker acts on.
  static func sharedExclusion(_ id: String) -> CatalogExclusion? {
    let lowered = id.lowercased()

    if isExcludedModelID(id) { return .excludedPattern }

    // Exclude versioned duplicates (-001, -002, etc.)
    for suffix in versionedSuffixes {
      if lowered.hasSuffix(suffix) { return .versionedDuplicate }
    }

    // Exclude alias names containing "latest"
    for alias in aliasPatterns {
      if lowered.contains(alias) { return .alias }
    }

    return nil
  }
}

// MARK: - Array Helper Extension

extension Array {
  /// Split array into chunks of specified size.
  fileprivate func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}

/// A model-discovery failure the app itself describes (#3142), as opposed to text from the
/// provider or the system. Only the Settings key check shows it.
///
/// `errorDescription` is the fixed English diagnostic, the exact sentence the key check showed
/// before the catalog; `displayMessage` is the same sentence in the app's language. A carried
/// system network description passes through unchanged and may follow the system's language.
public enum ModelDiscoveryFailure: LocalizedError, Sendable, Equatable {
  case invalidURL
  case invalidResponse
  case httpStatus(Int)
  case malformedPagination
  case invalidOllamaURL
  case network(String)
  /// The provider refused the request for a permission reason (Gemini 403). Not evidence that
  /// the key itself is invalid (#3438).
  case permissionDenied
  /// A Gemini 400 that mentions `API_KEY_INVALID` without the structured reason. Shown as an
  /// invalid key, as before, but not evidence the key was refused (#3438).
  case invalidKeyUnconfirmed

  public var errorDescription: String? {
    switch self {
    case .invalidURL: return "LLM request failed: Invalid URL"
    case .invalidResponse: return "LLM request failed: Invalid response"
    case .httpStatus(let code): return "LLM request failed: HTTP \(code)"
    case .malformedPagination:
      return "LLM request failed: Claude model pagination returned a malformed cursor"
    case .invalidOllamaURL: return "LLM request failed: Invalid Ollama URL"
    case .network(let detail): return "LLM request failed: Network error: \(detail)"
    case .permissionDenied: return "LLM request failed: HTTP 403"
    case .invalidKeyUnconfirmed: return "LLM request failed: HTTP 400"
    }
  }

  public var displayMessage: String {
    switch self {
    case .invalidURL:
      return String(
        localized: "LLM request failed: Invalid URL",
        comment: "AI Polish settings, checking the API key: the app built an invalid address.")
    case .invalidResponse:
      return String(
        localized: "LLM request failed: Invalid response",
        comment: "AI Polish settings, checking the API key: the provider's reply was not usable.")
    case .httpStatus(let code):
      return String(
        localized: "LLM request failed: HTTP \(String(code))",
        comment:
          "AI Polish settings, checking the API key: the provider answered with an error. %@ is an HTTP status code, such as 500."
      )
    case .malformedPagination:
      return String(
        localized: "LLM request failed: Claude model pagination returned a malformed cursor",
        comment:
          "AI Polish settings, checking the API key: Claude's model list came back broken. Claude is a product name; keep it."
      )
    case .invalidOllamaURL:
      return String(
        localized: "LLM request failed: Invalid Ollama URL",
        comment:
          "AI Polish settings, checking the API key: the address of Ollama is invalid. Ollama is a product name; keep it."
      )
    case .network(let detail):
      return String(
        localized: "LLM request failed: Network error: \(detail)",
        comment:
          "AI Polish settings, checking the API key: a network error. %@ is the system's description of it; keep it as is."
      )
    // The key check shows the invalid-key sentence for this (`LLMModelDiscoveryCoordinator`);
    // a caller that reaches here gets the same words as any other 403.
    case .permissionDenied:
      return ModelDiscoveryFailure.httpStatus(403).displayMessage
    case .invalidKeyUnconfirmed:
      return ModelDiscoveryFailure.httpStatus(400).displayMessage
    }
  }
}
