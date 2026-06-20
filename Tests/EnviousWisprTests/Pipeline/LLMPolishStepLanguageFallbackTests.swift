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
