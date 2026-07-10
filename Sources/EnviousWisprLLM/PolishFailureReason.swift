import EnviousWisprCore
import Foundation

/// Which telemetry channel a live polish failure earns (#1446).
///
/// `alertingSentryError` means "this is OUR bug." Nothing else earns it.
///
/// The predicate is ownership of the CAUSE, not the shape of the error: could a
/// change to EnviousWispr's own code have prevented this? A user with no key, an
/// exhausted quota, a revoked key, a blocked-content filter, a five-minute
/// dictation, an offline laptop, a provider having an outage — none of those are
/// defects, and none of them should page anyone. They are still worth counting:
/// the rate of each tells us which walls real users hit, which is a prompt to write
/// a guide or add in-app guidance, not to open a bug (founder directive
/// 2026-07-09; `sentry-operations.md` RULE: sentry-for-bugs-posthog-for-behaviour).
///
/// Two cases, not three: both are consumed at the single call site in
/// `TextProcessingRunner`. A third "aggregate alert candidate" state would have no
/// reader on the day it shipped.
public enum PolishFailureTelemetryChannel: Sendable, Equatable {
  /// An alerting Sentry `.error` event, plus the counted `llm.polish_failed`.
  /// Reserved for EnviousWispr's own defects.
  case alertingSentryError
  /// A breadcrumb and the counted `llm.polish_failed` event only. The cause belongs
  /// to the user or to the provider, so no code change of ours would alter the
  /// outcome — but the rate is a product signal worth watching.
  case nonAlertingAnalytics
}

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
///   - `telemetryChannel(provider:)` — whether a live failure pages us or is
///     merely counted (#1446).
///
/// Adding a future warning is a one-file change here: a new case plus its five
/// properties, and (only if it needs new detection) one branch in a provider's
/// `classify`. UI, telemetry, the runner, and `LLMError` are untouched. Note that
/// only `telemetryTag`, `message(provider:)`, and `telemetryChannel(provider:)`
/// are exhaustive switches the compiler will force you to update; `leadIn` and
/// `isRetryable` carry a `default:` and will silently absorb a new case, so read
/// them both before assuming the default is right (#1446).
///
/// `LLMError` carries this through the existing `throws LLMError` contract via the
/// single `LLMError.classified(_:)` case, so the type is `public` only because
/// that public case carries it. The per-connector `classify` functions stay
/// `internal`. The reason never holds raw provider text (privacy: telemetry and
/// the user message both use this closed set, never the provider's error body).
public enum PolishFailureReason: String, Sendable, Equatable, CaseIterable {
  /// No API key configured for the selected cloud provider. A user-configuration
  /// state, not a defect.
  case apiKeyMissing
  /// A key IS configured but the stored value could not be read (corrupt or
  /// inaccessible Keychain entry, entitlement change, migration bug). This is an
  /// EnviousWispr defect and keeps its own alerting fingerprint, which is the
  /// whole reason it is split from `apiKeyMissing` (#1446). The user-facing copy
  /// is deliberately identical: re-entering the key in Settings fixes both.
  case apiKeyUnreadable
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
    case .apiKeyUnreadable: return "api_key_unreadable"
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

  /// "skipped" for the not-really-broken cases (no usable key yet, too long, timed
  /// out); "failed" for the rest.
  ///
  /// `apiKeyUnreadable` shares `apiKeyMissing`'s arm on purpose: the user sees the
  /// same actionable sentence and the same not-broken tone, because re-entering
  /// the key fixes both. Only the telemetry channel differs (#1446). The shared
  /// arm makes that parity structural rather than something a `default:` could
  /// silently break.
  public var leadIn: LeadIn {
    switch self {
    case .apiKeyMissing, .apiKeyUnreadable, .inputTooLong, .timedOut: return .skipped
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

  /// Which telemetry channel a LIVE polish failure earns (#1446).
  ///
  /// `provider` is consulted for exactly ONE reason — `modelUnavailable` — because
  /// that is the only reason whose MEANING changes with where the provider runs:
  /// a model the user never pulled into Ollama is their setup, while a cloud model
  /// our Picker offered and the provider then 404s is a dead id in OUR catalog.
  /// The gate is `.ollama` specifically, not "any local provider": EG-1's server is
  /// one WE spawn and manage. (Today EG-1 reaches the runner only through its own
  /// silent-skip path, so that arm is a guarantee for a future throw, not a live
  /// one.)
  ///
  /// `providerUnreachable` is NOT provider-keyed, though it is tempting. On a cloud
  /// provider it arrives as `URLError.notConnectedToInternet` / `.dataNotAllowed` /
  /// `.internationalRoamingOff` / `.networkConnectionLost` — the user's own network,
  /// VPN, or firewall. Alerting on it would page us for every user who dictates on
  /// a plane. A genuinely broken base URL or ATS setting is not lost with it: that
  /// breaks EVERY cloud user at once and shows up as a `llm.polish_failed` rate
  /// cliff, which is what the durable event exists to make queryable. The same
  /// argument retires the whole "a spike here MIGHT mean we regressed" school of
  /// alerting: a real regression moves the rate, and the rate is now measured.
  ///
  /// Exhaustive on purpose — no `default:`. A future reason is a compile error
  /// until it chooses a channel, which is the only completeness guarantee this
  /// classification gets for free. (Correctness of the choice is a test's job;
  /// see `PolishFailureReasonTests`.)
  public func telemetryChannel(provider: LLMProvider) -> PolishFailureTelemetryChannel {
    switch self {
    // OUR code: we built the request wrong, mis-parsed the response, failed to
    // classify the error, could not read a key we had stored, or blew the polish
    // budget WE set (`timedOut` is our own `TimeoutError`, never a network one).
    case .badRequest, .emptyResponse, .unknown, .apiKeyUnreadable, .timedOut:
      return .alertingSentryError
    // A cloud model id our catalog offered but the provider rejects is a dead id
    // we shipped; an Ollama model the user never pulled is their setup.
    case .modelUnavailable:
      return provider == .ollama ? .nonAlertingAnalytics : .alertingSentryError
    // Everything the user or the provider owns: their network, machine, key,
    // account, billing, quota, dictation length, or the provider's own outage and
    // content rules. No code change of ours alters any of these outcomes.
    //
    // These are NOT defects, and treating them as such filed GitHub issues about
    // nothing (#1421 / #1424 / #1423 / #1422 / #1318). They ARE valuable: the
    // `llm.polish_failed` rate per reason tells us which walls real users hit, so
    // we can answer with guides and in-app education (founder directive
    // 2026-07-09). Analytics is where that question gets answered; Sentry is not.
    //
    // (`rateLimitedOrQuota` is the documented blind spot: it would also cover a
    // retry storm of ours. #1446 §14.2.)
    case .providerUnreachable, .apiKeyMissing, .apiKeyRejected, .accessDenied,
      .outOfCredits, .rateLimited, .rateLimitedOrQuota, .providerServerError,
      .contentBlocked, .inputTooLong:
      return .nonAlertingAnalytics
    }
  }

  /// The actionable user sentence (no lead-in). Always rendered with a concrete
  /// provider by the runner; `<Provider>` is the hardcoded display name, never a
  /// user host URL.
  public func message(provider: LLMProvider) -> String {
    let name = provider.displayName
    let isOllama = provider == .ollama
    switch self {
    case .apiKeyMissing, .apiKeyUnreadable:
      // One arm, not two: copy parity between the two key reasons is a contract
      // (#1446), and a shared arm cannot drift the way two arms can.
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

  /// #1305: the pinned surfaced-skip notice for the Ollama readiness PREFLIGHT
  /// path only (server down / model missing found before any attempt started).
  /// Nil for every other reason. Deliberately distinct from the mid-flight
  /// `composedMessage` copy: at preflight time no attempt failed, so the tone
  /// is the skip lead-in (which `isSkipNotice` and the completion planner
  /// already recognize), and the "no model is installed" wording never implies
  /// a visible selection the picker may honestly not show. Mid-flight failures
  /// on a running server keep today's `composedMessage(provider:)` copy.
  public var ollamaPreflightSkipMessage: String? {
    switch self {
    case .providerUnreachable:
      return "\(LeadIn.skipped.text) Ollama isn't running. Start it in Settings → AI Polish."
    case .modelUnavailable:
      return
        "\(LeadIn.skipped.text) no model is installed in Ollama. Download one in Settings → AI Polish."
    default:
      return nil
    }
  }

  /// #1305: the `llm.polish_skipped` reason string for the Ollama preflight
  /// path. Joins the existing `local_polish_` prefix family (EG-1's
  /// `EGOneSkipReason`) so one analytics query prefix captures every local
  /// polish skip mode. Content-free; nil for non-preflight reasons.
  public var ollamaPreflightSkipTelemetryReason: String? {
    switch self {
    case .providerUnreachable: return "local_polish_ollama_server_down"
    case .modelUnavailable: return "local_polish_ollama_model_missing"
    default: return nil
    }
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
      case .localPolishNotReady(let reason):
        // #1305: the runner handles this case on its dedicated surfaced-skip
        // arm before reaching here. Defensive unwrap for any other caller.
        return reason
      case .modelNotReady:
        // The on-device model is not usable yet (still downloading, or
        // org-restricted). Reached since #1446: an Apple Intelligence failure is
        // surfaced, not silently skipped, and the runner now classifies it to
        // count `llm.polish_failed`. `.modelUnavailable` is the truthful reason —
        // it means exactly "the selected model isn't available".
        return .modelUnavailable
      case .frameworkUnavailable,
        .unsupportedInputLanguage, .outputLanguageDrift, .egOneSkipped:
        // Silent-skip cases the runner never routes here (permanent AFM
        // incapability, language gates, and EG-1 bypasses, #1271). Defensive.
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
