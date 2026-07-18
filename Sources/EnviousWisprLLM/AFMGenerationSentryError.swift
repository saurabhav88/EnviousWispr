import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// #1525 PR I-B: pinned Sentry identity for Apple's `FoundationModels.LanguageModelSession
/// .GenerationError`, whose 9 cases otherwise bridge via Swift's ordinal-derived `NSError`
/// identity (`StableSentryErrorIdentity`'s own doc comment explains why that is unstable).
/// Framework-free by design — no `FoundationModels` import at file scope — so it stays
/// usable from macOS-14-compatible call sites; only the mapping initializer below needs
/// the framework, gated the same way `AppleIntelligenceConnector.polish()` gates its own
/// FoundationModels use.
///
/// `internal` visibility (default, no modifier): nothing outside `EnviousWisprLLM` needs to
/// name this type. It only ever surfaces as `AFMPolishError.underlying`, already typed as
/// plain existential `Error` at the module boundary.
///
/// Each case carries the original error's description as an associated `String` —
/// `TextProcessingRunner.swift:378` surfaces `"AI polish failed: " + error.localizedDescription`
/// to the user for some AFM failures, so a bare no-payload case would regress that
/// customer-visible text. The description travels with the case but is never part of the
/// fingerprint or semantic ID.
enum AFMGenerationSentryError: Error, LocalizedError, Sendable, Equatable {
  case assetsUnavailable(String)
  case guardrailViolation(String)
  case unsupportedGuide(String)
  case unsupportedLanguageOrLocale(String)
  case decodingFailure(String)
  case rateLimited(String)
  case concurrentRequests(String)
  case refusal(String)
  case unknownFutureCase(String)

  var errorDescription: String? {
    switch self {
    case .assetsUnavailable(let d), .guardrailViolation(let d), .unsupportedGuide(let d),
      .unsupportedLanguageOrLocale(let d), .decodingFailure(let d), .rateLimited(let d),
      .concurrentRequests(let d), .refusal(let d), .unknownFutureCase(let d):
      return d
    }
  }
}

#if canImport(FoundationModels)
  @available(macOS 26.0, *)
  extension AFMGenerationSentryError {
    /// The ONLY site that constructs this type from the concrete Apple type — the
    /// caller (`AppleIntelligenceConnector.generateGuardingContextWindow`) has
    /// already intercepted `.exceededContextWindowSize` before calling this, so
    /// that branch below is unreachable in practice but still must satisfy the
    /// exhaustive switch.
    init(mapping error: LanguageModelSession.GenerationError) {
      let d = error.localizedDescription
      switch error {
      case .exceededContextWindowSize: self = .unknownFutureCase(d)  // unreachable — caller intercepts this case first
      case .assetsUnavailable: self = .assetsUnavailable(d)
      case .guardrailViolation: self = .guardrailViolation(d)
      case .unsupportedGuide: self = .unsupportedGuide(d)
      case .unsupportedLanguageOrLocale: self = .unsupportedLanguageOrLocale(d)
      case .decodingFailure: self = .decodingFailure(d)
      case .rateLimited: self = .rateLimited(d)
      case .concurrentRequests: self = .concurrentRequests(d)
      case .refusal: self = .refusal(d)
      @unknown default: self = .unknownFutureCase(d)
      }
    }
  }
#endif

extension AFMGenerationSentryError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .assetsUnavailable: return "FoundationModels.LanguageModelSession.GenerationError#1"
    case .guardrailViolation: return "FoundationModels.LanguageModelSession.GenerationError#2"
    case .unsupportedGuide: return "FoundationModels.LanguageModelSession.GenerationError#3"
    case .unsupportedLanguageOrLocale:
      // LIVE: ENVIOUSWISPR-2J, 5u/12e, production — must not change.
      return "FoundationModels.LanguageModelSession.GenerationError#4"
    case .decodingFailure: return "FoundationModels.LanguageModelSession.GenerationError#5"
    case .rateLimited: return "FoundationModels.LanguageModelSession.GenerationError#6"
    case .concurrentRequests: return "FoundationModels.LanguageModelSession.GenerationError#7"
    case .refusal: return "FoundationModels.LanguageModelSession.GenerationError#8"
    case .unknownFutureCase: return "EnviousWisprLLM.AFMGenerationSentryError.unknownFutureCase"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .assetsUnavailable: return "afm.assets_unavailable"
    case .guardrailViolation: return "afm.guardrail_violation"
    case .unsupportedGuide: return "afm.unsupported_guide"
    case .unsupportedLanguageOrLocale: return "afm.unsupported_language_or_locale"
    case .decodingFailure: return "afm.decoding_failure"
    case .rateLimited: return "afm.rate_limited"
    case .concurrentRequests: return "afm.concurrent_requests"
    case .refusal: return "afm.refusal"
    case .unknownFutureCase: return "afm.unknown_future_case"
    }
  }
}
