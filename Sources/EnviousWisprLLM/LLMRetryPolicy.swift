import Foundation

/// Shared retry infrastructure for LLM connectors.
/// Centralizes retry-eligibility logic so all connectors use the same rules.
enum LLMRetryPolicy {
  /// Default retry delays: 1s, then 3s.
  static let defaultDelays: [UInt64] = [1_000_000_000, 3_000_000_000]
  static let defaultMaxRetries = 2

  /// Determine if an error is transient and worth retrying.
  static func isRetryable(_ error: Error) -> Bool {
    if let llmError = error as? LLMError {
      switch llmError {
      case .rateLimited: return true
      case .requestFailed(let msg):
        return msg.contains("server error")
      case .classified(let reason):
        // Retryability now lives in the catalog. This preserves today's 5xx
        // retry (now `.providerServerError`) and rate-limit retry, while
        // fail-fast reasons (out-of-credits, key problems, the Gemini
        // rate-or-quota ambiguity) surface their actionable notice immediately.
        return reason.isRetryable
      default: return false
      }
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .networkConnectionLost, .cannotConnectToHost:
        return true
      default: return false
      }
    }
    return false
  }
}
