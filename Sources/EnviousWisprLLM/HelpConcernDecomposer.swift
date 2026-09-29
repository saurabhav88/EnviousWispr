import EnviousWisprCore
import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Splits one feedback message into its distinct concerns on this Mac with Apple's on-device model
/// (#3275), for the in-app help check. Nothing leaves the Mac here. The schema, instructions and
/// generation settings are the ones measured in docs/audits/2026-09-28-issue-3275-benchmark/
/// afm-kit-src/main.swift (macOS 27 and macOS 26); changing them changes measured quality.
public enum HelpConcernDecomposer {
  /// Bumped whenever the schema, instructions or settings change; sent to the server and frozen
  /// into the report's help outcome.
  public static let version = "afm-kit-1"
  /// The model's own cap on concerns; a list this long may be incomplete.
  public static let maxConcerns = 5

  public struct Concern: Equatable, Sendable {
    public let summary: String
    public let evidence: String
    /// bug, how_to, feature_request or other.
    public let kind: String
  }

  public enum Failure: Equatable, Sendable {
    /// No on-device model on this Mac or OS, or it is off or not ready.
    case unavailable
    /// The message's language is not one the model supports.
    case unsupportedLanguage
    /// Instructions, the message and room for the answer do not fit the model's context.
    case tooLong
    /// The model's guardrails refused the message.
    case refused
    /// Generation failed for any other reason.
    case error
  }

  public enum Outcome: Equatable, Sendable {
    /// Concerns in order. `hitCap` is true when the model returned `maxConcerns`.
    case concerns([Concern], hitCap: Bool)
    case failed(Failure)
  }

  static let instructions = """
    You split one piece of user feedback about EnviousWispr (a Mac dictation app) into its distinct actionable concerns.
    An issue is one problem, question, or request that would need its own answer. Different symptoms of the SAME underlying problem are ONE issue. Background, detail and "I already tried X" belong to the issue they describe.
    Return no issues for pure praise, thanks, greetings, test text ("test", "please ignore"), or gibberish.
    Evidence must be copied exactly from the feedback.
    """

  static func prompt(for message: String) -> String { "Feedback:\n\(message)" }

  /// Room kept for the generated answer and the schema the framework adds to the prompt: five
  /// concerns of about 60 tokens each plus the schema, with the #1055 safety margin on top.
  static let reservedTokens = 900

  /// Pure fit decision: instructions + prompt + reserve within the live context window.
  static func fits(instructionTokens: Int, promptTokens: Int, contextTokens: Int) -> Bool {
    instructionTokens + promptTokens + reservedTokens
      + AppleIntelligenceConnector.afmContextSafetyMarginTokens <= contextTokens
  }

  /// The message's language as a base code, or nil when it is too short to judge or unknown.
  static func detectedBase(_ message: String) -> String? {
    let letters = message.unicodeScalars.filter(\.properties.isAlphabetic).count
    guard letters >= OutputLanguageValidator.minAlphabeticScalars else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(message)
    return recognizer.dominantLanguage.flatMap { LanguageNormalizer.baseCode($0.rawValue) }
  }

  /// Pure language decision: text too short or unknown is not judged; a detected language the
  /// model does not support fails.
  static func languageIsSupported(_ base: String?, supported: Set<String>) -> Bool {
    guard let base else { return true }
    return supported.contains(base)
  }

  /// Splits `message` in one fresh session. Never throws; every failure is an `Outcome`.
  public static func decompose(_ message: String) async -> Outcome {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return await AFM.decompose(message)
      }
    #endif
    return .failed(.unavailable)
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    enum AFM {
      @Generable
      enum IssueKind: String {
        case bug, how_to, feature_request, other
      }

      @Generable
      struct Issue {
        @Guide(
          description:
            "At most 12 words, plain English even if the feedback is in another language, naming the concern the way a help center would (feature or setting names, the symptom)."
        )
        var summary: String
        @Guide(
          description:
            "An exact, contiguous, verbatim substring copied from the feedback (same spelling, case and punctuation): the shortest span that states this issue."
        )
        var evidence: String
        var kind: IssueKind
      }

      @Generable
      struct Decomposition {
        @Guide(
          description:
            "Distinct actionable concerns, most important first. Empty for pure praise, thanks, greetings, test text or gibberish.",
          .maximumCount(5))
        var issues: [Issue]
      }

      static func decompose(_ message: String) async -> Outcome {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard case .available = model.availability else { return .failed(.unavailable) }
        let language = HelpConcernDecomposer.detectedBase(message)
        guard
          HelpConcernDecomposer.languageIsSupported(
            language, supported: AppleIntelligenceSupport.productionBaseCodes)
        else { return .failed(.unsupportedLanguage) }
        let prompt = HelpConcernDecomposer.prompt(for: message)
        do {
          let instructionTokens = try await tokens(model: model, text: instructions, lang: nil)
          let promptTokens = try await tokens(model: model, text: prompt, lang: language)
          guard
            HelpConcernDecomposer.fits(
              instructionTokens: instructionTokens, promptTokens: promptTokens,
              contextTokens: model.contextSize)
          else { return .failed(.tooLong) }
          try Task.checkCancellation()
          let session = LanguageModelSession(model: model, instructions: instructions)
          let response = try await session.respond(
            to: prompt, generating: Decomposition.self,
            options: GenerationOptions(sampling: .greedy))
          let concerns = response.content.issues.prefix(maxConcerns).map {
            Concern(summary: $0.summary, evidence: $0.evidence, kind: $0.kind.rawValue)
          }
          return .concerns(Array(concerns), hitCap: concerns.count >= maxConcerns)
        } catch let error as LanguageModelSession.GenerationError {
          if case .guardrailViolation = error { return .failed(.refused) }
          if case .exceededContextWindowSize = error { return .failed(.tooLong) }
          if case .unsupportedLanguageOrLocale = error { return .failed(.unsupportedLanguage) }
          return .failed(.error)
        } catch {
          return .failed(.error)
        }
      }

      /// Apple's exact count where the connector trusts it (#2883), else the connector's
      /// conservative heuristic; the same routing the polish preflight uses.
      private static func tokens(
        model: SystemLanguageModel, text: String, lang: String?
      ) async throws -> Int {
        if #available(macOS 26.4, *) {
          return try await AppleIntelligenceConnector.afmTokenEstimate(
            useExactCounter: AppleIntelligenceConnector.exactTokenCounterIsTrusted, text: text,
            lang: lang, exact: { try await model.tokenCount(for: text) })
        }
        return AppleIntelligenceConnector.heuristicAFMTokens(text, lang: lang)
      }
    }
  #endif
}
