import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// The single serialization authority for every `llm.polish_skipped.skip_reason`
/// value AND the provider each reason is attributed to (#1448, #1461).
///
/// Before this type, skip-reason strings were scattered across
/// `TextProcessingRunner` (raw literals for context-window/EG-1-timeout),
/// `EGOneSkipReason.rawValue`, and `PolishFailureReason.ollamaPreflightSkipTelemetryReason`
/// — and provider attribution for the AFM/EG-1 trio depended on a runner-side
/// snapshot (`polishProviderAtStart`) taken before the step's own, later
/// snapshot, which could theoretically diverge. `PolishSkipReason` fixes both:
/// one owner for the tag string, one owner for the provider, always in sync
/// with the classified reason itself.
///
/// "Skip" means no polish output was accepted — NOT "never attempted."
/// `outputLanguageDrift` fires only after a real generation attempt; the other
/// AFM cases are pre-attempt bypasses. All 16 cases share the same contract
/// (Bypass, per `llm-contract.md`): no `polishedText`, no provider stamp, no
/// error banner.
enum PolishSkipReason: Sendable, Equatable {
  case contextWindowPredicted
  case contextWindowCaught
  case contextWindowTimeout
  /// #2649 (cloud review): the two bundled engines share one skip family, so
  /// the PROVIDER rides on the case. Hard-coding `.egOne` here attributed every
  /// S1-mini skip and timeout to EG-1 in `llm.polish_skipped`, which is the
  /// query that diagnosed #2634 and would have pointed at the wrong engine.
  case localPolishTimeout(LLMProvider)
  case localEngine(EGOneSkipReason, LLMProvider)
  case ollamaProviderUnreachable
  case ollamaModelUnavailable
  case ollamaNoModelSelected
  case tooShort(LLMProvider)
  case frameworkUnavailable
  case unsupportedInputLanguage
  case outputLanguageDrift

  var telemetryTag: String {
    switch self {
    case .contextWindowPredicted: return "context_window_predicted"
    case .contextWindowCaught: return "context_window_caught"
    case .contextWindowTimeout: return "context_window_timeout"
    case .localPolishTimeout: return "local_polish_timeout"
    case .localEngine(let reason, _):
      switch reason {
      case .notReady: return "local_polish_not_ready"
      case .downloadPending: return "local_polish_download_pending"
      case .crashed: return "local_polish_crashed"
      case .inputTooLong: return "local_polish_input_too_long"
      case .outputTruncated: return "local_polish_output_truncated"
      }
    case .ollamaProviderUnreachable: return "local_polish_ollama_server_down"
    case .ollamaModelUnavailable: return "local_polish_ollama_model_missing"
    case .ollamaNoModelSelected: return "local_polish_ollama_no_model_selected"
    case .tooShort: return "too_short"
    case .frameworkUnavailable: return "framework_unavailable"
    case .unsupportedInputLanguage: return "unsupported_input_language"
    case .outputLanguageDrift: return "output_language_drift"
    }
  }

  /// Provider attribution owned here, not derived from a separately-snapshotted
  /// value elsewhere. Every case except `.tooShort` implies exactly one
  /// provider by construction; `.tooShort` carries the step's own snapshot
  /// since the bypass can fire under any provider.
  var provider: LLMProvider {
    switch self {
    case .contextWindowPredicted, .contextWindowCaught, .contextWindowTimeout,
      .frameworkUnavailable, .unsupportedInputLanguage, .outputLanguageDrift:
      return .appleIntelligence
    case .localPolishTimeout(let provider), .localEngine(_, let provider):
      return provider
    case .ollamaProviderUnreachable, .ollamaModelUnavailable, .ollamaNoModelSelected:
      return .ollama
    case .tooShort(let provider):
      return provider
    }
  }

  /// Replaces the deleted `PolishFailureReason.ollamaPreflightSkipTelemetryReason`.
  init?(ollamaPreflight reason: PolishFailureReason) {
    switch reason {
    case .providerUnreachable: self = .ollamaProviderUnreachable
    case .modelUnavailable: self = .ollamaModelUnavailable
    // #1914: explicit arm, because this `default:` returns nil and a missing
    // mapping does NOT surface as a wrong tag — the skip event simply never
    // fires, so the outcome would be invisible in analytics while the user sees
    // the pill. Silent absence is the failure mode this arm exists to stop.
    case .noModelSelected: self = .ollamaNoModelSelected
    default: return nil
    }
  }

  /// The ONE classification of "is this LLMError one of the silent AFM skip
  /// cases" — read by BOTH `TextProcessingRunner` (to emit the skip tag) and
  /// `LLMPolishStep`'s AFM catch block (to suppress its own alert), so the two
  /// call sites cannot independently drift out of agreement. `frameworkUnavailable`
  /// has two producer paths (a normal preflight throw, and a rarer wrapped path
  /// via `AppleIntelligenceConnector.makeSession`'s defensive re-check) — both
  /// classify the same way here regardless of which one actually threw.
  /// Attribution comes from the ERROR, never from a runner-side snapshot
  /// (#1448). `LLMPolishStep` wraps every connector `egOneSkipped` with its own
  /// entry snapshot as `localEngineSkipped`; a bare `egOneSkipped` reaching
  /// here is one that escaped the wrap, and its name is the only engine it can
  /// honestly claim.
  init?(silentLLMError error: LLMError) {
    switch error {
    case .frameworkUnavailable: self = .frameworkUnavailable
    case .unsupportedInputLanguage: self = .unsupportedInputLanguage
    case .outputLanguageDrift: self = .outputLanguageDrift
    case .localEngineSkipped(let reason, let provider): self = .localEngine(reason, provider)
    case .egOneSkipped(let reason): self = .localEngine(reason, .egOne)
    default: return nil
    }
  }
}
