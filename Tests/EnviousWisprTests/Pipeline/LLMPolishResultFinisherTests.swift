import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// A completed polish must preserve its source context and honest success/fallback attribution.
@MainActor
@Suite(.tags(.productOutcome))
struct LLMPolishResultFinisherTests {
  private struct CannedPolisher: TranscriptPolisher {
    let result: LLMResult
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult { result }
  }

  private static let original = "please keep /exit in the release notes for the team tomorrow"
  private static let cleaned = "Please keep /exit in the release notes for the team tomorrow."

  private func source() -> TextProcessingContext {
    var context = TextProcessingContext(text: Self.original, language: "en")
    context.takeID = "retained-take"
    context.targetAppName = "Notes"
    context.languageSource = .locked
    context.learnLanguage = "en"
    context.textLanguage = "en"
    context.englishSpelling = .british
    context.spellingProtectedWords = ["EnviousWispr", "release"]
    context.englishSpellingSwaps = 2
    context.spokenFinalFullStop = true
    return context
  }

  private func expectRetained(
    _ context: TextProcessingContext, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(context.text == Self.original, sourceLocation: sourceLocation)
    #expect(context.takeID == "retained-take", sourceLocation: sourceLocation)
    #expect(context.targetAppName == "Notes", sourceLocation: sourceLocation)
    #expect(context.language == "en", sourceLocation: sourceLocation)
    #expect(context.languageSource == .locked, sourceLocation: sourceLocation)
    #expect(context.learnLanguage == "en", sourceLocation: sourceLocation)
    #expect(context.textLanguage == "en", sourceLocation: sourceLocation)
    #expect(context.englishSpelling == .british, sourceLocation: sourceLocation)
    #expect(context.spellingProtectedWords == ["EnviousWispr", "release"], sourceLocation: sourceLocation)
    #expect(context.englishSpellingSwaps == 2, sourceLocation: sourceLocation)
    #expect(context.spokenFinalFullStop, sourceLocation: sourceLocation)
  }

  @Test("Ordinary completed results preserve text, guard precedence, metadata and source state",
    arguments: ["changed", "unchanged", "symbol-loss", "metadata"])
  func ordinaryCompletion(kind: String) async throws {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    let text = kind == "unchanged" ? Self.original
      : kind == "symbol-loss" ? "Please keep exit in the release notes for the team tomorrow."
      : Self.cleaned
    let metadata: PolishMetadata? = kind == "metadata"
      ? PolishMetadata(filterTripped: "test-filter", filterFellBackToRaw: true) : nil
    step.makePolisher = { _, _, _ in
      CannedPolisher(result: LLMResult(polishedText: text, polishMetadata: metadata))
    }
    let context = try await step.process(source())
    expectRetained(context)
    let rejected = kind == "symbol-loss"
    #expect(context.polishedText == (rejected ? Self.original : text))
    #expect(context.polishValidatorGuard == (rejected ? "symbol_drop" : nil))
    #expect(context.symbolTokens == 1)
    #expect(context.llmProvider == LLMProvider.openAI.rawValue)
    #expect(context.llmModel == "gpt-4o-mini")
    #expect(context.afmPrewarmOutcome == nil)
    #expect(context.polishMetadata == metadata)
    #expect(context.pipelineFellBackToRaw == (kind != "changed"))
    let reason: String? = kind == "unchanged" ? "no_change"
      : kind == "symbol-loss" ? "validator_discard" : kind == "metadata" ? "guard_discard" : nil
    #expect(context.polishFallbackReason == reason)
    #expect(context.polishRanRemote == nil)
    #expect(context.promptFamily == .cloudFixed)
    #expect(context.polishWasBypassed == false)
  }

  @Test("An empty batch answer preserves its prepared text without claiming success or bypass")
  func emptyBatchPiece() {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    var input = source()
    input.polishedText = "stale result"
    input.llmProvider = "stale provider"
    input.llmModel = "stale model"
    input.promptFamily = .localFixed
    input.polishMetadata = PolishMetadata(filterTripped: "stale", filterFellBackToRaw: true)
    let context = step.finishResult(
      LLMResult(polishedText: "  \n "), context: input, mode: .message,
      provider: .openAI, model: "gpt-4o-mini", ollamaRemote: nil,
      family: .cloudFixed, policy: .batchPiece)
    expectRetained(context)
    #expect(context.polishedText == nil)
    #expect(context.llmProvider == nil)
    #expect(context.llmModel == nil)
    #expect(context.promptFamily == nil)
    #expect(context.polishMetadata == nil)
    #expect(context.polishRanRemote == nil)
    #expect(context.polishWasBypassed == false)
  }

  @Test("Batch pieces keep the existing question and symbol protections", arguments: ["question", "symbol"])
  func batchProtection(kind: String) {
    let original = kind == "question" ? "Can you send the report to the team tomorrow?" : Self.original
    let candidate = kind == "question" ? "I will send the report to the team tomorrow."
      : "Please keep exit in the release notes for the team tomorrow."
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    let context = step.finishResult(
      LLMResult(polishedText: candidate), context: TextProcessingContext(text: original, language: "en"),
      mode: .message, provider: .openAI, model: "gpt-4o-mini", ollamaRemote: nil,
      family: .cloudFixed, policy: .batchPiece)
    #expect(context.polishedText == original)
    #expect(context.polishValidatorGuard == (kind == "question" ? "question_flip" : "symbol_drop"))
    #expect(context.polishFallbackReason == "validator_discard")
    #expect(context.pipelineFellBackToRaw)
  }

  @Test("Batch finishing does not reject false-start removal by a word-retention heuristic")
  func compressedBatchPiece() {
    let original = "send the first draft no actually send the second draft no wait send the final draft tomorrow"
    let cleaned = "Send the final draft tomorrow."
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    let input = TextProcessingContext(text: original, language: "en")
    let result = LLMResult(polishedText: cleaned)
    let ordinary = step.finishResult(
      result, context: input, mode: .message, provider: .openAI, model: "gpt-4o-mini",
      ollamaRemote: nil, family: .cloudFixed)
    let batch = step.finishResult(
      result, context: input, mode: .message, provider: .openAI, model: "gpt-4o-mini",
      ollamaRemote: nil, family: .cloudFixed, policy: .batchPiece)
    #expect(ordinary.polishValidatorGuard == "content_drop")
    #expect(ordinary.polishedText == original)
    #expect(batch.polishedText == cleaned)
    #expect(batch.polishValidatorGuard == nil)
    #expect(batch.pipelineFellBackToRaw == false)
    #expect(batch.promptFamily == .cloudFixed)
  }

}
