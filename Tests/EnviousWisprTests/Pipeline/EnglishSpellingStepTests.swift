import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3124 English (UK) in the text chain. Expected strings are written out by hand. When one of
/// these fails, a British user gets American spelling, or an American user gets British spelling
/// they never asked for.
@MainActor
@Suite("English (UK) spelling in the text chain", .tags(.productOutcome))
struct EnglishSpellingStepTests {

  // MARK: - Fixtures

  /// A stand-in for polish that always answers with a fixed American text, the way a model
  /// "corrects" British spelling back.
  final class AmericanPolishStep: TextProcessingStep {
    let name = "Fake Polish"
    let output: String
    var isEnabled: Bool { true }
    var maxDuration: Duration { .seconds(5) }
    init(output: String) { self.output = output }
    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
      var result = context
      result.polishedText = output
      return result
    }
  }

  /// Times out exactly the calls whose index (0-based, in chain order) is listed.
  @MainActor
  final class SelectiveTimeouts {
    let failing: Set<Int>
    private(set) var calls = 0
    init(failing: Set<Int>) { self.failing = failing }
    func run(
      _ seconds: Double, _ op: @escaping @MainActor () async throws -> TextProcessingContext
    ) async throws -> TextProcessingContext {
      defer { calls += 1 }
      if failing.contains(calls) {
        await Task.yield()
        throw TimeoutError(seconds: seconds)
      }
      return try await op()
    }
  }

  private static func context(
    _ text: String, language: String? = "en", spelling: EnglishSpelling = .british
  ) -> TextProcessingContext {
    var context = TextProcessingContext(text: text, language: language)
    context.englishSpelling = spelling
    return context
  }

  private static func userWords(_ canonicals: [String], builtin: [String] = [])
    -> WordCorrectionStep
  {
    let step = WordCorrectionStep()
    step.correctorVocabulary = CorrectorVocabulary(
      terms: canonicals.map { CustomWord(canonical: $0) }
        + builtin.map { CustomWord(canonical: $0, source: .builtin) },
      generation: 1)
    return step
  }

  // MARK: - The one decision

  @Test("British is in force only with an English lock and a British preference")
  func effectiveValue() {
    #expect(EnglishSpelling.effective(languageMode: .locked("en"), stored: .british) == .british)
    #expect(EnglishSpelling.effective(languageMode: .locked("en"), stored: .american) == .american)
    #expect(EnglishSpelling.effective(languageMode: .locked("de"), stored: .british) == .american)
    #expect(EnglishSpelling.effective(languageMode: .auto, stored: .british) == .american)
  }

  // MARK: - One pass

  @Test("the pre-polish pass converts a British English take and records its swaps")
  func textPassConverts() async throws {
    let step = EnglishSpellingStep(target: .text)
    let result = try await step.process(Self.context("the color of the center"))
    #expect(result.text == "the colour of the centre")
    #expect(result.englishSpellingSwaps == 2)
  }

  @Test("an American take is returned untouched, with no swap count")
  func americanUntouched() async throws {
    let step = EnglishSpellingStep(target: .text)
    let input = Self.context("the color of the center", spelling: .american)
    let result = try await step.process(input)
    #expect(result.text == "the color of the center")
    #expect(result.englishSpellingSwaps == nil)
  }

  @Test("a non-English or vetoed take is returned untouched even with a British preference")
  func notEnglishUntouched() async throws {
    let step = EnglishSpellingStep(target: .text)
    let german = try await step.process(Self.context("the color", language: "de"))
    #expect(german.text == "the color")
    #expect(german.englishSpellingSwaps == nil)

    var vetoed = Self.context("the color")
    vetoed.englishRulesVetoed = true
    let vetoedResult = try await step.process(vetoed)
    #expect(vetoedResult.text == "the color")
    #expect(vetoedResult.englishSpellingSwaps == nil)
  }

  @Test("the after-polish pass rewrites only the polish output, and does nothing without one")
  func polishedPass() async throws {
    let step = EnglishSpellingStep(target: .polishedText)
    var withPolish = Self.context("the colour")
    withPolish.polishedText = "The color."
    let result = try await step.process(withPolish)
    #expect(result.polishedText == "The colour.")
    #expect(result.text == "the colour")

    let noPolish = try await step.process(Self.context("the color"))
    #expect(noPolish.polishedText == nil)
    #expect(noPolish.text == "the color", "the after-polish pass must not touch the floor text")
  }

  @Test("a missing table disables the step instead of failing the take")
  func missingTableDisables() {
    #expect(EnglishSpellingStep(target: .text, converter: nil).isEnabled == false)
    #expect(EnglishSpellingStep(target: .text).isEnabled, "the shipped table must load")
  }

  @Test("the deadline scales with the words the pass will convert")
  func deadlineScales() {
    let step = EnglishSpellingStep(target: .text)
    let words = String(repeating: "color ", count: 10_000)
    #expect(step.maxDuration(for: Self.context("color")) == .milliseconds(50))
    #expect(step.maxDuration(for: Self.context(words)) == .milliseconds(150))
  }

  // MARK: - Through the runner

  @Test("polish cannot turn British back into American, and the no-polish floor is British")
  func chainKeepsBritishThroughPolish() async throws {
    let runner = TextProcessingRunner(telemetry: .silent)
    let steps: [any TextProcessingStep] = [
      EnglishSpellingStep(target: .text),
      AmericanPolishStep(output: "The color of the center."),
      EnglishSpellingStep(target: .polishedText),
    ]
    let result = try await runner.run(
      rawText: "the color of the center",
      evidence: .locked("en", englishSpelling: .british),
      targetAppName: nil, steps: steps)
    #expect(result.context.text == "the colour of the centre")
    #expect(result.context.polishedText == "The colour of the centre.")
    #expect(result.context.englishSpellingSwaps == 4)
  }

  @Test("an American take through the full spelling chain is byte-identical to today")
  func americanChainUnchanged() async throws {
    let runner = TextProcessingRunner(telemetry: .silent)
    let steps: [any TextProcessingStep] = [
      EnglishSpellingStep(target: .text),
      AmericanPolishStep(output: "The color of the center."),
      EnglishSpellingStep(target: .polishedText),
    ]
    let result = try await runner.run(
      rawText: "the color of the center",
      evidence: .locked("en", englishSpelling: .american),
      targetAppName: nil, steps: steps)
    #expect(Array(result.context.text.utf8) == Array("the color of the center".utf8))
    #expect(result.context.polishedText == "The color of the center.")
    #expect(result.context.englishSpellingSwaps == nil)
  }

  @Test("the user's Custom Words are protected in both passes; app-shipped words are not")
  func customWordsProtectedInBothPasses() async throws {
    let runner = TextProcessingRunner(telemetry: .silent)
    let wordCorrection = Self.userWords(["Color Street"], builtin: ["recognizer"])
    let steps: [any TextProcessingStep] = [
      wordCorrection,
      EnglishSpellingStep(target: .text),
      AmericanPolishStep(output: "The color recognizer is at the center."),
      EnglishSpellingStep(target: .polishedText),
    ]
    let result = try await runner.run(
      rawText: "the color recognizer is at the center",
      evidence: .locked("en", englishSpelling: .british),
      targetAppName: nil, steps: steps)
    #expect(result.context.spellingProtectedWords == ["color street", "color", "street"])
    #expect(result.context.text == "the color recogniser is at the centre")
    #expect(result.context.polishedText == "The color recogniser is at the centre.")
  }

  @Test("a timed-out first pass loses only its own work: the after-polish pass still converts")
  func timedOutFirstPass() async throws {
    // The word-correction step is disabled (switched off by default), so the runner skips it
    // without calling the executor: call 0 is the pre-polish spelling pass.
    let timeouts = SelectiveTimeouts(failing: [0])
    let runner = TextProcessingRunner(telemetry: .silent, timeoutExecutor: timeouts.run)
    let steps: [any TextProcessingStep] = [
      Self.userWords(["Color Street"]),
      EnglishSpellingStep(target: .text),
      AmericanPolishStep(output: "The color of the center."),
      EnglishSpellingStep(target: .polishedText),
    ]
    let result = try await runner.run(
      rawText: "the color of the center",
      evidence: .locked("en", englishSpelling: .british),
      targetAppName: nil, steps: steps)
    #expect(timeouts.calls == 3)
    #expect(result.context.text == "the color of the center", "the discarded pass left the floor")
    #expect(
      result.context.polishedText == "The color of the centre.",
      "protected words were seeded before the loop, so the second pass still honours them")
    #expect(result.context.englishSpellingSwaps == 1, "only the accepted pass is counted")
  }
}
