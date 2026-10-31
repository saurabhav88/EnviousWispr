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
  func emptyBatchPiece() throws {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    var input = source()
    input.polishedText = "stale result"
    input.llmProvider = "stale provider"
    input.llmModel = "stale model"
    input.promptFamily = .localFixed
    input.polishMetadata = PolishMetadata(filterTripped: "stale", filterFellBackToRaw: true)
    let context = try step.finishResult(
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
  func batchProtection(kind: String) throws {
    let original = kind == "question" ? "Can you send the report to the team tomorrow?" : Self.original
    let candidate = kind == "question" ? "I will send the report to the team tomorrow."
      : "Please keep exit in the release notes for the team tomorrow."
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    let context = try step.finishResult(
      LLMResult(polishedText: candidate), context: TextProcessingContext(text: original, language: "en"),
      mode: .message, provider: .openAI, model: "gpt-4o-mini", ollamaRemote: nil,
      family: .cloudFixed, policy: .batchPiece)
    #expect(context.polishedText == original)
    #expect(context.polishValidatorGuard == (kind == "question" ? "question_flip" : "symbol_drop"))
    #expect(context.polishFallbackReason == "validator_discard")
    #expect(context.pipelineFellBackToRaw)
  }

  @Test("Batch finishing does not reject false-start removal by a word-retention heuristic")
  func compressedBatchPiece() throws {
    let original = "send the first draft no actually send the second draft no wait send the final draft tomorrow"
    let cleaned = "Send the final draft tomorrow."
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    let input = TextProcessingContext(text: original, language: "en")
    let result = LLMResult(polishedText: cleaned)
    let ordinary = try step.finishResult(
      result, context: input, mode: .message, provider: .openAI, model: "gpt-4o-mini",
      ollamaRemote: nil, family: .cloudFixed)
    let batch = try step.finishResult(
      result, context: input, mode: .message, provider: .openAI, model: "gpt-4o-mini",
      ollamaRemote: nil, family: .cloudFixed, policy: .batchPiece)
    #expect(ordinary.polishValidatorGuard == "content_drop")
    #expect(ordinary.polishedText == original)
    #expect(batch.polishedText == cleaned)
    #expect(batch.polishValidatorGuard == nil)
    #expect(batch.pipelineFellBackToRaw == false)
    #expect(batch.promptFamily == .cloudFixed)
  }

  @Test("ordinary processing keeps dictated words and removes only added chatter",
    arguments: [true, false])
  func sourceBoundCompletion(wasDictated: Bool) async throws {
    let source = wasDictated ? "sure I can do that tomorrow" : "I can do that tomorrow"
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.makePolisher = { _, _, _ in
      CannedPolisher(result: LLMResult(polishedText: "Sure, I can do that tomorrow."))
    }
    let result = try await step.process(TextProcessingContext(text: source, language: "en"))
    #expect(result.polishedText == (wasDictated ? "Sure, I can do that tomorrow." : "I can do that tomorrow."))
    #expect(result.text == source)
    #expect(result.llmProvider == LLMProvider.openAI.rawValue)
  }

  @Test("ordinary completion applies only one bounded cleanup pass")
  func ordinaryCleanupRunsOnce() async throws {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.makePolisher = { _, _, _ in
      CannedPolisher(result: LLMResult(polishedText:
        "Here is the cleaned transcript:\nThe cleaned text:\nPlease send the invoice."))
    }
    let result = try await step.process(
      TextProcessingContext(text: "please send the invoice", language: "en"))
    #expect(result.polishedText == "The cleaned text:\nPlease send the invoice.")
    #expect(result.polishFallbackReason == nil)
  }

  @Test("native cleanup-empty skips keep provider attribution and emit no completion",
    arguments: [LLMProvider.egOne, .s1Mini])
  func nativeEmptyBeforeCompletion(provider: LLMProvider) async throws {
    var completions = 0
    let seams = LLMPolishStep.TelemetrySeams(
      limbFailureObserved: { _, _, _, _, _ in }, breadcrumbStarted: { _, _ in },
      captureProviderInitError: { _ in }, captureAFMPolishError: { _ in },
      breadcrumbCompleted: { _, _ in completions += 1 },
      recordPolishSkipped: { _, _, _ in }, recordPolishLanguageHint: { _, _ in })
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: seams)
    step.llmProvider = provider
    step.llmModel = LLMProvider.defaultModel(for: provider)
    step.egOneRuntime = ReadyEGOneRuntime()
    step.s1MiniRuntime = ReadyEGOneRuntime()
    step.makeEGOnePolisher = { _ in CannedPolisher(result: LLMResult(polishedText: "Here is the cleaned text:")) }
    step.makeS1MiniPolisher = { _ in CannedPolisher(result: LLMResult(polishedText: "Here is the cleaned text:")) }
    await #expect(throws: LLMError.localEngineSkipped(.crashed, provider)) {
      _ = try await step.process(TextProcessingContext(text: "please send the invoice before noon", language: "en"))
    }
    #expect(completions == 0)
  }

}
