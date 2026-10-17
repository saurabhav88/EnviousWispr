import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Characterizes the context handoff, not linguistic quality. Losing this state can remove a
/// spelling preference, a protected expansion, checker selection or honest polish attribution.
@Suite(.tags(.driftGuard))
@MainActor
struct TextProcessingContinuationTests {
  enum Scenario: CaseIterable { case completed, bypassed, vetoed, appleFallback }

  @Test("raw entry seeds once and preserves prefix state through the suffix", arguments: Scenario.allCases)
  func rawEntryCharacterization(scenario: Scenario) async throws {
    let fixture = Fixture(scenario: scenario)
    let result = try await fixture.runRaw()
    fixture.expectSeedAndRun(result)
  }

  @Test("continuation retains every context field and does not reseed or replay steps", arguments: Scenario.allCases)
  func continuationMatchesWholeRun(scenario: Scenario) async throws {
    let whole = Fixture(scenario: scenario)
    let split = Fixture(scenario: scenario)
    #expect(whole.prefix !== split.prefix)
    let expected = try await whole.runRaw()
    let steps = split.fullChain
    let seeded = await split.runner.makeContext(
      rawText: Fixture.raw, evidence: split.evidence, targetAppName: "Notes", steps: steps,
      frozenCorrectorVocabulary: Fixture.vocabulary, takeID: "take-2905")
    let prefix = try await split.runner.run(context: seeded, steps: Array(steps.prefix(5)))
    let handoff = try await split.runner.run(context: prefix.context, steps: [])
    expectSameContext(handoff.context, prefix.context)
    let result = try await split.runner.run(context: handoff.context, steps: Array(steps.dropFirst(5)))
    split.expectSeedAndRun(result)
    #expect(split.executor.callCount == whole.executor.callCount)
    expectSameContext(result.context, expected.context)
  }

  /// Inspect the complete field population without a second production serializer or a frozen
  /// field-count assertion. Explicit byte checks also catch canonical-Unicode normalization.
  private func expectSameContext(
    _ actual: TextProcessingContext,
    _ expected: TextProcessingContext,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let actualFields = Array(Mirror(reflecting: actual).children)
    let expectedFields = Array(Mirror(reflecting: expected).children)
    #expect(
      actualFields.map(\.label) == expectedFields.map(\.label),
      sourceLocation: sourceLocation)
    for (a, e) in zip(actualFields, expectedFields) {
      // Sets have no iteration order. Prefer native value equality where it is available.
      if let actualValue = a.value as? AnyHashable, let expectedValue = e.value as? AnyHashable {
        #expect(actualValue == expectedValue, "context field \(a.label ?? "unknown")",
          sourceLocation: sourceLocation)
      } else {
        #expect(String(reflecting: a.value) == String(reflecting: e.value),
          "context field \(a.label ?? "unknown")", sourceLocation: sourceLocation)
      }
    }
    #expect(
      Array(actual.text.utf8) == Array(expected.text.utf8),
      sourceLocation: sourceLocation)
    #expect(
      actual.polishedText.map { Array($0.utf8) }
        == expected.polishedText.map { Array($0.utf8) },
      sourceLocation: sourceLocation)
    #expect(
      actual.protectedExpansions.map { Array($0.expansion.utf8) }
        == expected.protectedExpansions.map { Array($0.expansion.utf8) },
      sourceLocation: sourceLocation)
    #expect(
      (actual.frozenLearnedWordChecker?.checker as? Checker) === Fixture.checker,
      sourceLocation: sourceLocation)
  }

  @MainActor
  private final class Fixture {
    static let raw = "\tCafe\u{301} met Color at the center  \n"
    static let vocabulary = CorrectorVocabulary(
      terms: [CustomWord(canonical: "Color"), CustomWord(
        canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
        learnedAt: Date(timeIntervalSince1970: 1_790_000_000))], generation: 71)
    static let checker = Checker()

    let scenario: Scenario
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0)
    var identified = 0
    var selected = 0
    var selectedProvider: LLMProvider?
    var seeded: TextProcessingContext?
    var suffixInput: TextProcessingContext?
    var sequence: [String] = []
    let wordCorrection = WordCorrectionStep()
    let learned = LearnedWordCheckStep()
    let polish = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    let spelling = EnglishSpellingStep(target: .polishedText)

    lazy var runner = TextProcessingRunner(
      telemetry: .silent,
      languageIdentifier: { [weak self] _ in
        guard let self else { return nil }
        identified += 1
        return scenario == .vetoed ? ("nl", 0.55) : ("en", 0.97)
      }, timeoutExecutor: executor.run)
    lazy var prefix = ContextStep("prefix") { [weak self] context in
      guard let self else { return context }
      seeded = context
      sequence.append("prefix")
      var next = context
      next.text += "EW_SNIPPET"
      next.protectedExpansions = [SnippetExpansionRecord(
        sentinel: "EW_SNIPPET", expansion: "\tCafe\u{301}\n", suppressFollowingSentenceEnding: true)]
      next.spokenFinalFullStop = true
      next.cleanupRoute = .english
      next.englishSpellingSwaps = 19
      return next
    }
    lazy var receipt = ContextStep("receipt") { [weak self] context in
      guard let self else { return context }
      sequence.append("receipt")
      var next = context
      switch scenario {
      case .completed, .vetoed:
        next.polishRanRemote = true
        next.llmProvider = LLMProvider.ollama.rawValue
        next.llmModel = "hosted-fixture"
        next.promptFamily = .cloudFixed
        next.polishValidatorGuard = "symbol_drop"
        next.symbolTokens = 2
      case .bypassed:
        next.polishedText = nil
        next.llmProvider = nil
        next.llmModel = nil
        next.promptFamily = nil
        next.polishWasBypassed = true
        next.pipelineFellBackToRaw = false
        next.polishFallbackReason = nil
      case .appleFallback:
        next.llmProvider = LLMProvider.appleIntelligence.rawValue
        next.llmModel = "system"
        next.promptFamily = nil
        next.afmPrewarmOutcome = .hit
        next.polishMetadata = PolishMetadata(filterTripped: "fixture", filterFellBackToRaw: true)
        next.pipelineFellBackToRaw = true
        next.polishFallbackReason = "guard_discard"
      }
      return next
    }
    lazy var suffix = ContextStep("suffix observer") { [weak self] context in
      guard let self else { return context }
      sequence.append("suffix")
      suffixInput = context
      return context
    }
    var fullChain: [any TextProcessingStep] {
      [wordCorrection, learned, prefix, polish, receipt, spelling, suffix]
    }
    var evidence: LanguageEvidence {
      LanguageEvidence(lockedLanguage: scenario == .vetoed ? nil : "en",
        engineDetectsLanguage: false, engineReportedLanguage: nil, englishSpelling: .british)
    }

    init(scenario: Scenario) {
      self.scenario = scenario
      wordCorrection.correctorVocabulary = Self.vocabulary
      learned.correctorVocabulary = Self.vocabulary
      learned.wordCorrectionEnabled = true
      learned.selectionProvider = { [weak self] provider, _ in
        guard let self else { return LearnedWordCheckerSelection(absence: .serverUnavailable) }
        selected += 1
        selectedProvider = provider
        return LearnedWordCheckerSelection(
          checker: Self.checker, identity: "frozen-checker", judge: LearnedWordJudge(displayName: "Fixture"))
      }
      polish.llmProvider = .claude
      polish.llmModel = "claude-haiku-4-5"
      polish.makePolisher = { _, _, _ in EchoPolisher() }
    }

    func runRaw() async throws -> TextProcessingRunResult {
      try await runner.run(rawText: Self.raw, evidence: evidence, targetAppName: "Notes",
        steps: fullChain, frozenCorrectorVocabulary: Self.vocabulary, takeID: "take-2905")
    }

    func expectSeedAndRun(
      _ result: TextProcessingRunResult,
      sourceLocation: SourceLocation = #_sourceLocation
    ) {
      #expect(identified == 1, sourceLocation: sourceLocation)
      #expect(selected == 1, sourceLocation: sourceLocation)
      #expect(selectedProvider == .claude, sourceLocation: sourceLocation)
      #expect(sequence == ["prefix", "receipt", "suffix"], sourceLocation: sourceLocation)
      #expect(seeded?.frozenCorrectorVocabulary == Self.vocabulary, sourceLocation: sourceLocation)
      #expect(seeded?.spellingProtectedWords.contains("color") == true, sourceLocation: sourceLocation)
      #expect(seeded?.englishSpelling == .british, sourceLocation: sourceLocation)
      #expect(seeded?.takeID == "take-2905", sourceLocation: sourceLocation)
      #expect(seeded?.targetAppName == "Notes", sourceLocation: sourceLocation)
      #expect(
        (result.context.frozenLearnedWordChecker?.checker as? Checker) === Self.checker,
        sourceLocation: sourceLocation)
      #expect(result.context.frozenLearnedWordChecker?.identity == "frozen-checker", sourceLocation: sourceLocation)
      #expect(result.context.protectedExpansions.count == 1, sourceLocation: sourceLocation)
      #expect(result.context.spokenFinalFullStop, sourceLocation: sourceLocation)
      #expect(result.context.cleanupRoute == .english, sourceLocation: sourceLocation)
      #expect(
        Array(result.context.text.utf8) == Array((Self.raw + "EW_SNIPPET").utf8),
        sourceLocation: sourceLocation)
      #expect(result.polishNotice == nil, sourceLocation: sourceLocation)
      #expect(result.polishTakeOutcome == nil, sourceLocation: sourceLocation)
      #expect(result.context.englishRulesVetoed == (scenario == .vetoed), sourceLocation: sourceLocation)
      if scenario == .bypassed {
        #expect(result.context.polishedText == nil, sourceLocation: sourceLocation)
        #expect(result.context.polishWasBypassed, sourceLocation: sourceLocation)
      } else {
        let expected = scenario == .vetoed
          ? Self.raw + "EW_SNIPPET"
          : Self.raw.replacingOccurrences(of: "center", with: "centre") + "EW_SNIPPET"
        #expect(
          result.context.polishedText.map { Array($0.utf8) } == Array(expected.utf8),
          sourceLocation: sourceLocation)
        #expect(
          result.context.englishSpellingSwaps == (scenario == .vetoed ? 19 : 20),
          sourceLocation: sourceLocation)
      }
    }
  }

  private final class Checker: LearnedWordChecking {
    let armName = "context-fixture"
    let scoresAreComparable = false
    func decide(_ questions: [LearnedWordCheckQuestion]) async throws -> [LearnedWordCheckDecision] {
      questions.map { LearnedWordCheckDecision(questionID: $0.id, approved: false) }
    }
  }

  private struct EchoPolisher: TranscriptPolisher {
    func polish(text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?) async throws -> LLMResult {
      LLMResult(polishedText: text.replacingOccurrences(of: "Transcript to clean:\n\n", with: ""))
    }
  }

  @MainActor
  private final class ContextStep: TextProcessingStep {
    let name: String
    let isEnabled = true
    let maxDuration: Duration = .seconds(5)
    let operation: @MainActor (TextProcessingContext) -> TextProcessingContext
    init(_ name: String, operation: @escaping @MainActor (TextProcessingContext) -> TextProcessingContext) {
      self.name = name
      self.operation = operation
    }
    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext { operation(context) }
  }
}
