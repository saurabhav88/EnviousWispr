import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1106: removing the saved-transcript re-polish feature must NOT remove the
/// shared `LLMPolishStep` language fallback (`languageDetection?.lang ??
/// context.language`, `LLMPolishStep.swift` ~`:253`). Crash-recovery's
/// `RecoveryTextProcessor` (#1063) sets `languageDetection = nil` and relies on
/// the persisted `context.language` reaching the polisher config, so the Apple
/// Intelligence preflight gate + language-aware prompt still work on a recovered
/// take. The only PREVIOUS caller that cleared `languageDetection` was the
/// deleted re-polish service, which made the fallback look like dead code — it is
/// not. This pins it: with nil live detection, the config handed to the polisher
/// must carry the context's persisted language.
@MainActor
@Suite("LLMPolishStep language fallback survives re-polish removal (#1106)")
struct LLMPolishStepLanguageFallbackTests {

  /// Box for the `detectedLanguage` the step hands the polisher. `@unchecked
  /// Sendable` is an allowed test-fixture use: the value is written once inside
  /// the polisher call and read only AFTER `process()` has fully awaited (a
  /// happens-after, no concurrent access).
  private final class LanguageCapture: @unchecked Sendable {
    var detectedLanguage: String?
    /// #2614: the system prompt the planner built, so the locked-only language hint
    /// can be asserted alongside the config's language.
    var systemPrompt: String?
  }

  /// Captures the config's `detectedLanguage`, then returns a fixed polish.
  /// Implements only the legacy `text:` method; the planner path reaches it via
  /// the protocol's default `envelope:` bridge, which forwards the same `config`.
  private struct CapturingPolisher: TranscriptPolisher {
    let capture: LanguageCapture
    let result: String

    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      capture.detectedLanguage = config.detectedLanguage
      capture.systemPrompt = instructions.systemPrompt
      return LLMResult(polishedText: result)
    }
  }

  // Long enough to clear the short-transcript short-circuit and pass the
  // similar-length polish validator.
  private static let inputSentence =
    "also wir könnten das neue Ding vielleicht nächste Woche ausliefern oder so"
  private static let polishedSentence =
    "Also wir könnten das neue Ding vielleicht nächste Woche ausliefern."

  @Test("nil live detection → polisher config carries the persisted context language")
  func nilDetectionFallsBackToContextLanguage() async throws {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.languageDetection = nil  // mirrors RecoveryTextProcessor (#1063)

    let capture = LanguageCapture()
    step.makePolisher = { _, _, _ in
      CapturingPolisher(capture: capture, result: Self.polishedSentence)
    }

    let context = TextProcessingContext(text: Self.inputSentence, language: "de")
    _ = try await step.process(context)

    #expect(capture.detectedLanguage == "de")
  }
}

// MARK: - #2614 a RESOLVED language is a new producer of `context.language`

/// `TextProcessingRunner` now seeds `context.language` from the resolver, not only from
/// the lock. Two readers, two contracts: the Apple Intelligence preflight config takes
/// the resolved language (the fallback above), while the prompt builders' `LANGUAGE:`
/// hint is documented as locked-only and must NOT fire for a text-resolved language.
@MainActor
extension LLMPolishStepLanguageFallbackTests {

  private func capturedPolish(
    language: String?, source: DictationLanguageResolver.Resolution.Source?
  ) async throws -> LanguageCapture {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.languageDetection = nil
    let capture = LanguageCapture()
    step.makePolisher = { _, _, _ in
      CapturingPolisher(capture: capture, result: Self.polishedSentence)
    }
    var context = TextProcessingContext(text: Self.inputSentence, language: language)
    context.languageSource = source
    _ = try await step.process(context)
    return capture
  }

  @Test("#2614 a text-resolved language reaches the polisher config but not the prompt hint")
  func resolvedLanguageReachesConfigNotPrompt() async throws {
    let capture = try await capturedPolish(language: "de", source: .dictation)
    #expect(capture.detectedLanguage == "de")
    let prompt = try #require(capture.systemPrompt)
    #expect(!prompt.contains("LANGUAGE: This transcript is in"), "\(prompt)")
  }

  @Test("#2614 a locked language still reaches both the config and the prompt hint")
  func lockedLanguageReachesConfigAndPrompt() async throws {
    let capture = try await capturedPolish(language: "de", source: .locked)
    #expect(capture.detectedLanguage == "de")
    let prompt = try #require(capture.systemPrompt)
    #expect(prompt.contains("LANGUAGE: This transcript is in de"), "\(prompt)")
  }

  @Test("#2614 a legacy context that never went through the resolver keeps today's hint")
  func legacyContextKeepsTheHint() async throws {
    let capture = try await capturedPolish(language: "de", source: nil)
    #expect(capture.detectedLanguage == "de")
    let prompt = try #require(capture.systemPrompt)
    #expect(prompt.contains("LANGUAGE: This transcript is in de"), "\(prompt)")
  }
}
