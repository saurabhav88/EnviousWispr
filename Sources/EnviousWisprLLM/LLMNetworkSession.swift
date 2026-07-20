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
        let (_, response) = try await session.data(for: request)
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let status = statusCode?.description ?? "n/a"
        await AppLogger.shared.log(
          "preWarm completed provider=\(provider.rawValue) model=\(model) duration_ms=\(ms) status=\(status)",
          level: .info, category: "LLM"
        )
        // Cloud review (PR #1211): a non-2xx response does NOT throw (URLSession
        // returns it), so it would otherwise log "completed" and never report the
        // failure — mirror the A5 evict 2xx/non-2xx split. A missing status code
        // (n/a) is NOT treated as a failure (that path already lacks a real signal).
        if let code = statusCode, !(200...299).contains(code) {
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
        "max_completion_tokens": 1,
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
