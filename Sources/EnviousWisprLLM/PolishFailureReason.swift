import EnviousWisprCore
import Foundation

/// The single catalog/adapter for a cloud or local AI-cleanup failure (#945).
///
/// One closed set of distinguishable failure reasons. Each reason owns everything
/// that downstream code needs for that failure:
///   - `telemetryTag` — the low-cardinality Sentry reason tag.
///   - `leadIn` — whether the on-screen notice reads "AI polish failed:" (a real
///     error) or "AI cleanup skipped:" (not-really-broken: no key yet, too long,
///     timed out).
///   - `message(provider:)` — the actionable, self-contained user sentence.
///   - `composedMessage(provider:)` — `<leadIn> <message>`, the full notice.
///   - `isRetryable` — whether a connector's retry loop should retry this.
///
/// Adding a future warning is a one-file change here: a new case plus its four
/// properties, and (only if it needs new detection) one branch in a provider's
/// `classify`. UI, telemetry, the runner, and `LLMError` are untouched.
///
/// `LLMError` carries this through the existing `throws LLMError` contract via the
/// single `LLMError.classified(_:)` case, so the type is `public` only because
/// that public case carries it. The per-connector `classify` functions stay
/// `internal`. The reason never holds raw provider text (privacy: telemetry and
/// the user message both use this closed set, never the provider's error body).
public enum PolishFailureReason: String, Sendable, Equatable, CaseIterable {
  /// No API key configured for the selected cloud provider, or the stored key
  /// could not be read (re-entering it in Settings fixes both).
  case apiKeyMissing
  /// The provider rejected the supplied key (401; Gemini `API_KEY_INVALID`).
  case apiKeyRejected
  /// 403: permissions / billing-disabled / API-disabled / region.
  case accessDenied
  /// OpenAI 429 `insufficient_quota` — the account is out of credits.
  case outOfCredits
  /// OpenAI 429 rate limit (transient).
  case rateLimited
  /// Gemini 429 `RESOURCE_EXHAUSTED` — rate OR quota; Gemini does not cleanly
  /// split the two, so the message names both honestly.
  case rateLimitedOrQuota
  /// 404 / model not found / Ollama model not pulled.
  case modelUnavailable
  /// 400 `context_length_exceeded` / token budget — the dictation is too long.
  case inputTooLong
  /// Provider blocked the text (content filter / safety). Best-effort detection.
  case contentBlocked
  /// Offline / DNS / connection lost / Ollama daemon down.
  case providerUnreachable
  /// 500 / 503 — the provider is having problems (transient).
  case providerServerError
  /// Residual 4xx the app constructed wrong (rare).
  case badRequest
  /// A 200 with no usable cleanup text.
  case emptyResponse
  /// Our polish budget was exceeded (the runner's timeout).
  case timedOut
  /// Unclassified.
  case unknown

  /// Whether the on-screen notice leads with "AI polish failed:" (a real error)
  /// or "AI cleanup skipped:" (not-really-broken).
  public enum LeadIn: Sendable, Equatable {
    case failed
    case skipped

    public var text: String {
      switch self {
      case .failed: return "AI polish failed:"
      case .skipped: return "AI cleanup skipped:"
      }
    }
  }

  /// Low-cardinality Sentry reason tag (`polish.error_case`).
  public var telemetryTag: String {
    switch self {
    case .apiKeyMissing: return "api_key_missing"
    case .apiKeyRejected: return "api_key_rejected"
    case .accessDenied: return "access_denied"
    case .outOfCredits: return "out_of_credits"
    case .rateLimited: return "rate_limited"
    case .rateLimitedOrQuota: return "rate_or_quota"
    case .modelUnavailable: return "model_unavailable"
    case .inputTooLong: return "input_too_long"
    case .contentBlocked: return "content_blocked"
    case .providerUnreachable: return "provider_unreachable"
    case .providerServerError: return "provider_server_error"
    case .badRequest: return "bad_request"
    case .emptyResponse: return "empty_response"
    case .timedOut: return "timed_out"
    case .unknown: return "unknown"
    }
  }

  /// "skipped" for the not-really-broken cases (no key yet, too long, timed out);
  /// "failed" for the rest.
  public var leadIn: LeadIn {
    switch self {
    case .apiKeyMissing, .inputTooLong, .timedOut: return .skipped
    default: return .failed
    }
  }

  /// Whether a connector retry loop should retry this failure. Preserves today's
  /// behavior: transient server errors and rate limits retry; everything else
  /// (out-of-credits, key problems, the Gemini rate-or-quota ambiguity, etc.)
  /// fails fast so the actionable notice surfaces immediately.
  public var isRetryable: Bool {
    switch self {
    case .providerServerError, .rateLimited: return true
    default: return false
    }
  }

  /// The actionable user sentence (no lead-in). Always rendered with a concrete
  /// provider by the runner; `<Provider>` is the hardcoded display name, never a
  /// user host URL.
  public func message(provider: LLMProvider) -> String {
    let name = provider.displayName
    let isOllama = provider == .ollama
    switch self {
    case .apiKeyMissing:
      return "no \(name) API key set yet. Add one in Settings."
    case .apiKeyRejected:
      return "\(name) rejected your API key. Check or replace it in Settings."
    case .accessDenied:
      return
        "\(name) denied access. Check your provider billing, API access, region, or selected model."
    case .outOfCredits:
      return "your \(name) account is out of credits. Check your provider billing."
    case .rateLimited:
      return "too many requests to \(name) right now. It should work again in a moment."
    case .rateLimitedOrQuota:
      return
        "\(name) hit a rate or quota limit. Wait a moment, or check your \(name) billing if it keeps happening."
    case .modelUnavailable:
      return isOllama
        ? "that Ollama model isn't downloaded yet. Pull it in Ollama or pick another in Settings."
        : "the selected \(name) model isn't available. Pick another in Settings."
    case .inputTooLong:
      return
        "this dictation is too long for the selected model. Try a shorter one or a larger model in Settings."
    case .contentBlocked:
      return "\(name) blocked this text. Your original was pasted unchanged."
    case .providerUnreachable:
      return isOllama
        ? "Ollama isn't reachable. Start Ollama and try again."
        : "couldn't reach \(name). Check your internet connection, VPN, or proxy."
    case .providerServerError:
      return "\(name) is having problems right now. Try again shortly."
    case .badRequest:
      return "a configuration problem stopped it. Your original text was pasted unchanged."
    case .emptyResponse:
      return "\(name) returned no cleanup text. Try again."
    case .timedOut:
      return "the dictation took too long. Your original text was pasted unchanged."
    case .unknown:
      return "an unexpected error stopped it. Your original text was pasted unchanged."
    }
  }

  /// The full self-contained notice: `<leadIn> <message>`.
  public func composedMessage(provider: LLMProvider) -> String {
    "\(leadIn.text) \(message(provider: provider))"
  }

  /// Whether a composed notice string represents a "skipped" (not-really-broken)
  /// outcome rather than a hard failure. Keyed off the single `LeadIn.skipped.text`
  /// constant that `composedMessage` also uses, so it can never drift from the
  /// notice it inspects. The completion planner uses this to suppress the
  /// transient "Polish failed -- using raw text" overlay for skips (the in-window
  /// notice still shows the actionable "AI cleanup skipped: ..." message). A
  /// legacy raw message or the Apple Intelligence "AI polish failed: ..." string
  /// is correctly treated as NOT a skip, so its hard-failure toast still fires.
  public static func isSkipNotice(_ noticeMessage: String) -> Bool {
    noticeMessage.hasPrefix(LeadIn.skipped.text)
  }

  /// Maps every error the runner sees directly to a reason: the `.classified`
  /// carrier (unwrap), the legacy `LLMError` cases connectors still throw on the
  /// polish path (empty response, provider-unavailable, model-not-found,
  /// ambiguous invalid-key, rate-limited, request-failed), the runner's own
  /// `TimeoutError`, and a raw `URLError` from a cloud connector whose internal
  /// retries were exhausted. Cancellation-like errors are excluded by the runner
  /// before this is called.
  public static func from(_ error: any Error) -> PolishFailureReason {
    if let llmError = error as? LLMError {
      switch llmError {
      case .classified(let reason):
        return reason
      case .invalidAPIKey:
        // Legacy ambiguous case: read as "key present but rejected". The
        // connectors now disambiguate the no-key path via `.classified(.apiKeyMissing)`.
        return .apiKeyRejected
      case .rateLimited:
        return .rateLimited
      case .emptyResponse:
        return .emptyResponse
      case .providerUnavailable:
        return .providerUnreachable
      case .modelNotFound:
        return .modelUnavailable
      case .requestFailed(let msg):
        return msg.contains("server error") ? .providerServerError : .badRequest
      case .frameworkUnavailable, .modelNotReady,
        .unsupportedInputLanguage, .outputLanguageDrift:
        // Apple-Intelligence-only / silent-skip cases the runner never routes
        // here (AFM is excluded; language gates are silent skips). Defensive.
        return .unknown
      }
    }
    if error is TimeoutError { return .timedOut }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .notConnectedToInternet, .cannotFindHost,
        .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff:
        return .providerUnreachable
      default:
        return .unknown
      }
    }
    return .unknown
  }
}
