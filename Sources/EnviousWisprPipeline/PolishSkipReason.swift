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
/// AFM cases are pre-attempt bypasses. All 15 cases share the same contract
/// (Bypass, per `llm-contract.md`): no `polishedText`, no provider stamp, no
/// error banner.
enum PolishSkipReason: Sendable, Equatable {
  case contextWindowPredicted
  case contextWindowCaught
  case contextWindowTimeout
  case localPolishTimeout
  case egOne(EGOneSkipReason)
  case ollamaProviderUnreachable
  case ollamaModelUnavailable
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
    case .egOne(let reason):
      switch reason {
      case .notReady: return "local_polish_not_ready"
      case .downloadPending: return "local_polish_download_pending"
      case .crashed: return "local_polish_crashed"
      case .inputTooLong: return "local_polish_input_too_long"
      case .outputTruncated: return "local_polish_output_truncated"
      }
    case .ollamaProviderUnreachable: return "local_polish_ollama_server_down"
    case .ollamaModelUnavailable: return "local_polish_ollama_model_missing"
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
    case .localPolishTimeout, .egOne:
      return .egOne
    case .ollamaProviderUnreachable, .ollamaModelUnavailable:
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
  init?(silentLLMError error: LLMError) {
    switch error {
    case .frameworkUnavailable: self = .frameworkUnavailable
    case .unsupportedInputLanguage: self = .unsupportedInputLanguage
    case .outputLanguageDrift: self = .outputLanguageDrift
    case .egOneSkipped(let reason): self = .egOne(reason)
    default: return nil
    }
  }
}
