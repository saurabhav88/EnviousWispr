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
    guard provider == .gemini || provider == .openAI else { return }
    guard !model.isEmpty else { return }

    let keychainId =
      provider == .openAI
      ? KeychainManager.openAIKeyID : KeychainManager.geminiKeyID
    guard let key = try? keychainManager.retrieve(key: keychainId),
      !key.isEmpty
    else { return }

    guard
      let request = buildWarmupRequest(
        provider: provider, model: model, apiKey: key
      )
    else { return }

    Task.detached { [session] in
      let start = CFAbsoluteTimeGetCurrent()
      do {
        let (_, response) = try await session.data(for: request)
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        let status = (response as? HTTPURLResponse)?.statusCode.description ?? "n/a"
        await AppLogger.shared.log(
          "preWarm completed provider=\(provider.rawValue) model=\(model) duration_ms=\(ms) status=\(status)",
          level: .info, category: "LLM"
        )
      } catch {
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        await AppLogger.shared.log(
          "preWarm failed provider=\(provider.rawValue) model=\(model) duration_ms=\(ms) error=\(String(describing: error))",
          level: .info, category: "LLM"
        )
      }
    }
  }

  private func buildWarmupRequest(
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
