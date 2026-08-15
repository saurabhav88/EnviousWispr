import EnviousWisprCore
import Foundation
import os

/// Singleton URLSession for LLM API requests.
/// Reuses a single session for HTTP/2 multiplexing and TLS session resumption.
/// Pre-warms connections to reduce first-request latency.
///
/// URLSession is thread-safe, so this class is safe to use from any isolation domain.
public final class LLMNetworkSession: Sendable {
  public static let shared = LLMNetworkSession()

  public let session: URLSession

  /// Per-process monotonic counter for polish calls. Increments from 1. Lets
  /// diagnostic log lines distinguish the very first call after launch from
  /// subsequent calls without carrying extra state.
  private let callCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

  private init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 180
    config.waitsForConnectivity = false
    config.networkServiceType = .responsiveData
    session = URLSession(configuration: config)
  }

  /// Returns the next process-wide polish call number (starting at 1).
  func nextCallNumber() -> Int {
    callCounter.withLock { n in
      n += 1
      return n
    }
  }

  /// Pre-warm the LLM backend with a real lightweight inference request.
  /// Warms both the transport layer (QUIC/TLS) AND the provider's model routing.
  /// Silently ignores errors — pre-warming is best-effort.
  public func preWarmModel(
    provider: LLMProvider, model: String, keychainManager: KeychainManager
  ) {
    guard let keychainId = Self.warmupKeychainId(for: provider) else { return }
    guard !model.isEmpty else { return }

    guard let key = try? keychainManager.retrieve(key: keychainId),
      !key.isEmpty
    else { return }

    guard
      let request = buildWarmupRequest(
        provider: provider, model: model, apiKey: key
      )
    else { return }

    // #1177 (Telemetry Bible Phase 8): A6 reads the LLM module's telemetry sink off
    // the `keychainManager` it already receives (carried there because the LLM module
    // has no telemetry dependency — KeychainManager is the App-injected seam). The
    // sink is `Sendable`, so it crosses into the detached task cleanly.
    Task.detached { [session, sink = keychainManager.telemetrySink] in
      let start = CFAbsoluteTimeGetCurrent()
      do {
        let (data, response) = try await session.data(for: request)
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let status = statusCode?.description ?? "n/a"
        await AppLogger.shared.log(
          "preWarm completed provider=\(provider.rawValue) model=\(model) duration_ms=\(ms) status=\(status)",
          level: .info, category: "LLM"
        )
        // #2062: the response body used to be discarded (`let (_, response)`),
        // which made every non-2xx a dead end — we recorded the status code and
        // threw away the one thing that says why. 314 HTTP 400s were
        // uninvestigable for it.
        //
        // Debug app log ONLY, never telemetry. A provider error body is
        // free-form vendor text that can quote the request, so it is barred from
        // PostHog and Sentry by the `TelemetryService.polishFailed` contract
        // ("No transcript, prompt, provider error body, key, or endpoint URL").
        // `AppLogger` is entirely `#if DEBUG` and additionally gated on in-app
        // Debug Mode, so this reaches a release build's disk never.
        //
        // Cloud review (PR #1211): a non-2xx response does NOT throw (URLSession
        // returns it), so it would otherwise log "completed" and never report the
        // failure — mirror the A5 evict 2xx/non-2xx split. A missing status code
        // (n/a) is NOT treated as a failure (that path already lacks a real signal).
        if let code = statusCode, !(200...299).contains(code) {
          // `#if DEBUG` at the CALL SITE, not just inside `AppLogger` (cloud
          // review, PR #2072). `AppLogger.log` takes a `String`, so the
          // interpolation — and therefore the whole decode-and-copy of the
          // response body — is evaluated by the caller before the call. The
          // logger's own `#if DEBUG` removes only its body, so a release build
          // would pay to render a multi-KB provider error page and then throw it
          // away. This whole diagnostic is debug-only by intent; make that true
          // of the work as well as the output.
          #if DEBUG
            await AppLogger.shared.log(
              "preWarm failure body provider=\(provider.rawValue) model=\(model) "
                + "status=\(code) body=\(Self.warmupFailureBodyForLog(data))",
              level: .info, category: "LLM"
            )
          #endif
          sink.limbFailure(
            "llm_prewarm", "prewarm", "failed", "\(provider.rawValue)_http_\(code)", ms)
        }
      } catch {
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        await AppLogger.shared.log(
          "preWarm failed provider=\(provider.rawValue) model=\(model) duration_ms=\(ms) error=\(String(describing: error))",
          level: .info, category: "LLM"
        )
        // Best-effort cloud warm-up failed → first real polish pays a cold start.
        // Population only (the polish call's own telemetry covers persistent issues);
        // the sink hops to the @MainActor TelemetryService. Low-cardinality category:
        // provider + URLError code, never any content.
        let category =
          "\(provider.rawValue)_\((error as? URLError)?.code.rawValue.description ?? "error")"
        sink.limbFailure("llm_prewarm", "prewarm", "failed", category, ms)
      }
    }
  }

  /// Selects the Keychain id `preWarmModel` reads for each cloud provider —
  /// extracted to a pure, testable function (mirroring
  /// `LLMModelDiscovery.claudePaginationDecision`) after this exact
  /// selection was a two-way ternary that routed any non-OpenAI provider to
  /// Gemini's key id (Grounded Review R2/R3, issue #158). `nil` for any
  /// non-cloud or future provider — the caller's early guard.
  static func warmupKeychainId(for provider: LLMProvider) -> String? {
    switch provider {
    case .openAI: return KeychainManager.openAIKeyID
    case .gemini: return KeychainManager.geminiKeyID
    case .claude: return KeychainManager.claudeKeyID
    default: return nil
    }
  }

  /// Renders a warm-up failure body for the DEBUG app log (#2062).
  ///
  /// Bounded, because a provider can return an HTML error page or a multi-KB
  /// JSON blob and this line goes to a rotating file the user may send us. The
  /// first 512 bytes carry the `error.message` for every provider we route to.
  /// Non-UTF8 bodies report their size rather than dropping the line silently,
  /// so "we got a body and could not read it" stays distinguishable from "there
  /// was no body".
  static func warmupFailureBodyForLog(_ data: Data, limit: Int = 512) -> String {
    guard !data.isEmpty else { return "<empty>" }
    // Decode the WHOLE body, then truncate the STRING — never `data.prefix()`
    // before decoding (cloud review, PR #2072). A byte cutoff can land inside a
    // multi-byte scalar, and `String(data:encoding:)` then returns nil for a body
    // that is perfectly valid UTF-8, so the line would read `<non-utf8 N bytes>`
    // and throw the provider's message away — defeating the entire reason this
    // function exists. Any non-ASCII character near the boundary triggers it: a
    // curly quote in an OpenAI message is enough.
    //
    // The body is already fully in memory (URLSession handed us `Data`), so
    // decoding all of it costs nothing extra, and truncating by Character keeps
    // the `<non-utf8>` branch meaning what it says: the body really is not UTF-8.
    guard let text = String(data: data, encoding: .utf8) else {
      return "<non-utf8 \(data.count) bytes>"
    }
    let flattened = text.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard flattened.count > limit else { return flattened }
    return flattened.prefix(limit) + "…<truncated \(data.count) bytes>"
  }

  /// Output-token ceiling for the OpenAI warm-up ping (#2062).
  ///
  /// Was `1`, which every `gpt-5.x` model rejects with a real HTTP 400:
  /// `"Could not finish the message because max_tokens or model output limit was
  /// reached. Please try again with higher max_tokens."` Reasoning models draw
  /// reasoning tokens from this same budget, so a ceiling of 1 cannot be
  /// satisfied even by an empty answer. It cost 314 warm-up failures across 4
  /// users in 90 days, every one of them a silent no-op.
  ///
  /// Measured against the live API on 2026-08-15, prompt `"."`, one request per
  /// cell — the cliff is between 2 and 4 and is identical on all three models:
  ///
  /// | max_completion_tokens | gpt-5.4-mini | gpt-5.6-sol | gpt-5-mini | gpt-4o-mini |
  /// |---|---|---|---|---|
  /// | 1 | 400 | 400 | 400 | 200 |
  /// | 2 | 400 | 400 | 400 | 200 |
  /// | 4 | 200 | 200 | 200 | 200 |
  /// | 16 | 200 | 200 | 200 | 200 |
  ///
  /// 16 rather than the measured minimum of 4: it is 4x the observed cliff, it
  /// matches OpenAI's documented floor for reasoning models, and the cost of
  /// being generous is bounded by the ceiling itself (~16 output tokens on one
  /// ping per session). The cost of being tight is another silent 400 on a model
  /// family that did not exist when this was written — which is exactly how the
  /// `1` got here.
  ///
  /// Deliberately ONE unconditional value, not a per-family branch. `gpt-4o`,
  /// `gpt-4o-mini` and `gpt-4.1-mini` were all verified to still return 200 at
  /// this ceiling, so no branch is needed — and a model-family branch is a table
  /// that goes stale every time OpenAI ships a family, silently reverting this
  /// fix for it.
  static let openAIWarmupMaxCompletionTokens = 16

  func buildWarmupRequest(
    provider: LLMProvider, model: String, apiKey: String
  ) -> URLRequest? {
    switch provider {
    case .gemini:
      let urlString =
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
      guard let url = URL(string: urlString) else { return nil }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
      request.timeoutInterval = 5
      let body = Self.makeGeminiWarmupRequestBody()
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
      return request

    case .openAI:
      guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
        return nil
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 5
      let body: [String: Any] = [
        "model": model,
        "messages": [["role": "user", "content": "."]],
        "max_completion_tokens": Self.openAIWarmupMaxCompletionTokens,
        "store": false,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
      return request

    case .claude:
      guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      request.setValue("application/json", forHTTPHeaderField: "content-type")
      request.timeoutInterval = 5
      let body = ClaudeConnector.makeRequestBody(
        model: model, maxTokens: 1, system: nil, userText: ".")
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
      return request

    default:
      return nil
    }
  }

  /// Invalidate the session on app termination.
  /// Uses finishTasksAndInvalidate to allow in-flight requests to complete.
  public func invalidate() {
    session.finishTasksAndInvalidate()
  }

  static func makeGeminiWarmupRequestBody() -> [String: Any] {
    [
      "contents": [["parts": [["text": "."]]]],
      "generationConfig": ["maxOutputTokens": 1],
      "store": false,
    ]
  }
}
