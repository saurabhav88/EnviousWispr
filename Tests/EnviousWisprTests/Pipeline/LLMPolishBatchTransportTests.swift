import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Mechanical delivery/mapping guarantees. Fake output is not a model-quality measurement.
@MainActor
@Suite(.tags(.productOutcome))
struct LLMPolishBatchTransportTests {
  private static let originals = [
    "please send the final report to the design team before lunch tomorrow",
    "can you check the release notes for the new version before friday"
  ]
  private static let cleaned = [
    "Please send the final report to the design team before lunch tomorrow.",
    "Can you check the release notes for the new version before Friday?"
  ]

  @MainActor
  private final class Spy {
    var envelopes: [PromptEnvelope] = []
    var configs: [LLMProviderConfig] = []
    var reply = SectionEnvelope.wrap(LLMPolishBatchTransportTests.cleaned)
  }
  private struct Polisher: TranscriptPolisher {
    let spy: Spy
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult { throw LLMError.requestFailed("Unexpected legacy path") }
    func polish(
      envelope: PromptEnvelope, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      await MainActor.run {
        spy.envelopes.append(envelope)
        spy.configs.append(config)
        return LLMResult(polishedText: spy.reply)
      }
    }
  }

  private func step(_ spy: Spy, provider: LLMProvider = .openAI) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    step.llmProvider = provider
    step.llmModel = LLMProvider.defaultModel(for: provider)
    step.makePolisher = { _, _, _ in Polisher(spy: spy) }
    return step
  }
  private func contexts() -> [TextProcessingContext] {
    Self.originals.enumerated().map { index, text in
      var context = TextProcessingContext(text: text, language: "en")
      context.languageSource = .locked
      context.takeID = "speaker-\(index)"
      context.englishSpelling = .british
      context.spokenFinalFullStop = index == 0
      return context
    }
  }
  private func prepare(
    _ step: LLMPolishStep, sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> TextProcessingContext {
    let members = try contexts().map { context in
      try #require(step.fileBatchMember(context), sourceLocation: sourceLocation)
    }
    return try #require(step.prepareFileBatch(members), sourceLocation: sourceLocation)
  }

  @Test("Compatible pieces use one request, existing instructions/configuration, full input budget and their own source state")
  func compatibleBatch() async throws {
    let spy = Spy()
    let batchStep = step(spy)
    let input = try prepare(batchStep)
    var observedBudget: Double?
    let runner = TextProcessingRunner(telemetry: .silent, timeoutExecutor: { seconds, operation in
      observedBudget = seconds
      return try await operation()
    })
    let accepted = try await runner.run(context: input, steps: [batchStep])
    let results = try #require(batchStep.takeFileBatchResults(accepted: accepted.context))
    #expect(results.map(\.polishedText) == Self.cleaned.map(Optional.some))
    #expect(results.map(\.text) == Self.originals)
    #expect(results.map(\.takeID) == ["speaker-0", "speaker-1"])
    #expect(results.map(\.englishSpelling) == [.british, .british])
    #expect(results.map(\.spokenFinalFullStop) == [true, false])
    #expect(results.allSatisfy { $0.fileBatchCompletionID == nil })
    #expect(results.allSatisfy { $0.promptFamily == .cloudFixed })
    #expect(spy.envelopes.count == 1)
    #expect(batchStep.takeFileBatchResults(accepted: accepted.context) == nil)
    let sameMembers = try contexts().map { try #require(batchStep.fileBatchMember($0)) }
    #expect(batchStep.prepareFileBatch(sameMembers) == nil)
    let captured = try #require(spy.envelopes.first?.asSingleTurn())
    #expect(captured.user == "Transcript to clean:\n\n" + SectionEnvelope.wrap(Self.originals))
    let soloSpy = Spy()
    soloSpy.reply = Self.cleaned[0]
    let solo = step(soloSpy)
    _ = try await solo.process(contexts()[0])
    let soloPair = try #require(soloSpy.envelopes.first?.asSingleTurn())
    #expect(captured.system == (soloPair.system ?? "") + SectionEnvelope.addendum(count: 2))
    let config = try #require(spy.configs.first)
    let ordinaryConfig = try #require(soloSpy.configs.first)
    #expect(config.model == ordinaryConfig.model)
    #expect(config.apiKeyKeychainId == ordinaryConfig.apiKeyKeychainId)
    #expect(config.outputTokens == ordinaryConfig.outputTokens)
    #expect(config.temperature == ordinaryConfig.temperature)
    #expect(config.thinking == ordinaryConfig.thinking)
    #expect(config.detectedLanguage == ordinaryConfig.detectedLanguage)
    let firstBudget = solo.maxDuration(for: contexts()[0])
    let firstSeconds = Double(firstBudget.components.seconds) + Double(firstBudget.components.attoseconds) / 1e18
    #expect(try #require(observedBudget) > firstSeconds)
  }

  @Test("Malformed replies keep every prepared floor and make no repair request", arguments: [
    "<s1>Only one section.</s1>", "<s2>Second.</s2><s1>First.</s1>"
  ])
  func malformedBatch(reply: String) async throws {
    let spy = Spy(); spy.reply = reply
    let batchStep = step(spy)
    let input = try prepare(batchStep)
    let result = try await TextProcessingRunner(telemetry: .silent).run(context: input, steps: [batchStep])
    #expect(result.context.fileBatchCompletionID == nil)
    #expect(batchStep.takeFileBatchResults(accepted: result.context) == nil)
    #expect(spy.envelopes.count == 1)
    #expect(result.polishNotice != nil)
  }

  @Test("An empty body affects only that piece")
  func blankPiece() async throws {
    let spy = Spy(); spy.reply = SectionEnvelope.wrap([Self.cleaned[0], ""])
    let batchStep = step(spy)
    let input = try prepare(batchStep)
    let result = try await TextProcessingRunner(telemetry: .silent).run(context: input, steps: [batchStep])
    let outputs = try #require(batchStep.takeFileBatchResults(accepted: result.context))
    #expect(outputs[0].polishedText == Self.cleaned[0])
    #expect(outputs[1].text == Self.originals[1])
    #expect(outputs[1].polishedText == nil)
    #expect(outputs[1].llmProvider == nil)
    #expect(outputs[1].polishWasBypassed == false)
    #expect(spy.envelopes.count == 1)
  }

  @Test("Short-prompt and unsupported engines never enter batching", arguments: ["short", "tiny", "Japanese", "local"])
  func excludedMember(kind: String) {
    let spy = Spy()
    let subject = step(spy, provider: kind == "local" ? .ollama : .openAI)
    let text = kind == "short" ? "Please send the report tomorrow."
      : kind == "tiny" ? "thank you" : kind == "Japanese" ? "来週の会議の資料をまとめて送ってください。" : Self.originals[0]
    #expect(subject.fileBatchMember(TextProcessingContext(text: text, language: kind == "Japanese" ? "ja" : "en")) == nil)
    #expect(spy.envelopes.isEmpty)
  }

  @Test("Different existing language, vocabulary, provider, model or backend policies do not share a request",
    arguments: ["language", "source", "vocabulary", "model", "provider", "backend"])
  func incompatibleMembers(kind: String) throws {
    let spy = Spy()
    let firstStep = step(spy)
    let otherStep = step(spy, provider: kind == "provider" ? .gemini : .openAI)
    if kind == "model" { otherStep.llmModel = "gpt-6-luna" }
    if kind == "vocabulary" {
      otherStep.polishVocabulary = PolishVocabulary(terms: [CustomWord(canonical: "EnviousWispr")], generation: 1)
    }
    if kind == "backend" { otherStep.backend = .whisper }
    var other = contexts()[1]
    if kind == "language" { other = TextProcessingContext(text: Self.originals[1], language: "fr") }
    if kind == "source" { other.languageSource = nil }
    let members = [try #require(firstStep.fileBatchMember(contexts()[0])), try #require(otherStep.fileBatchMember(other))]
    #expect(firstStep.prepareFileBatch(members) == nil)
    #expect(spy.envelopes.isEmpty)
  }

  @Test("A rejected timed result cannot expose mappings completed after the timeout")
  func lateCompletion() async throws {
    let spy = Spy()
    let batchStep = step(spy)
    let input = try prepare(batchStep)
    var lateOperation: (@MainActor () async throws -> TextProcessingContext)?
    let runner = TextProcessingRunner(telemetry: .silent, timeoutExecutor: { _, operation in
      lateOperation = operation
      throw TimeoutError(seconds: 15)
    })
    let rejected = try await runner.run(context: input, steps: [batchStep])
    #expect(rejected.context.fileBatchCompletionID == nil)
    let operation = try #require(lateOperation)
    let late = try await operation()
    #expect(late.fileBatchCompletionID != nil)
    #expect(spy.envelopes.count == 1)
    #expect(batchStep.takeFileBatchResults(accepted: rejected.context) == nil)
    #expect(batchStep.takeFileBatchResults(accepted: late) == nil)
  }
}
