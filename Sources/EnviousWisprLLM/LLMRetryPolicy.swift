import Foundation

/// Shared retry infrastructure for LLM connectors.
/// Centralizes retry-eligibility logic so all connectors use the same rules.
enum LLMRetryPolicy {
  /// Default retry delays: 200ms, then 400ms.
  ///
  /// #2093: was 1s then 3s. Those sleeps are spent INSIDE the polish step's own
  /// budget, so on the old 5 s cloud base two retries burned 4 of the 5 seconds
  /// doing nothing — one transient 5xx made a short dictation's timeout
  /// arithmetically certain, and the user was then told "timed out" rather than
  /// what actually happened. The failure was rebranded by our own backoff.
  ///
  /// 200ms x attempt matches FluidVoice's shipped `retryDelayMs` (open source,
  /// same providers, same BYOK-direct architecture). Worst case is now 0.6 s of
  /// sleep inside the 15 s cloud budget instead of 4 s inside 5 s.
  ///
  /// KNOWN LIMIT, deliberately not fixed here: these sleeps are still charged to
  /// the caller's budget rather than deducted from a remaining-time ledger. The
  /// ledger is the fuller fix and is its own change; this one removes the
  /// arithmetic certainty without adding a mechanism.
  static let defaultDelays: [UInt64] = [200_000_000, 400_000_000]
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
      case .egOneSkipped:
        // EXPLICIT (#1271): EG-1 bypasses are silent skips, and the single
        // connection-refused retry that covers the server restart-once
        // window already happened inside `EGOneConnector`. Retrying here
        // would stack retries and delay the raw-text fallback.
        return false
      case .localPolishNotReady:
        // EXPLICIT (#1305): the Ollama preflight found the server down or the
        // model missing BEFORE any attempt started. Retrying would reintroduce
        // the doomed-wait the preflight exists to remove; the next dictation
        // re-probes fresh.
        return false
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
