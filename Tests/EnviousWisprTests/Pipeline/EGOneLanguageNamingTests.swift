import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #3111: when EG-1 is told which language a dictation is in. When this fails, a Polish,
/// French or Japanese user on EG-1 gets their words back in English again, or a user locked
/// to one language who dictates another gets translated INTO the lock.
@Suite("EG-1 language naming decision", .tags(.productOutcome))
struct EGOneLanguageNamingDecisionTests {

  typealias Source = DictationLanguageResolver.Resolution.Source

  @Test(
    "The decision table",
    arguments: [
      // text, resolved, source, expected
      ("pl", "pl", Source.dictation, EGOneLanguageNaming.Decision.named("pl")),
      ("pl", "pl", .locked, .named("pl")),
      ("pl", "pl", .engine, .named("pl")),
      ("zh-Hans", "zh", .engine, .named("zh")),
      ("pl", nil, Source.none, .named("pl")),
      (nil, "pl", .locked, .notNamed(.unsure)),
      (nil, nil, .dictation, .notNamed(.unsure)),
      ("en", "en", .dictation, .notNamed(.english)),
      ("en", "de", .locked, .notNamed(.english)),
      ("pl", "de", .locked, .notNamed(.conflict)),
      ("pl", "en-GB", .locked, .notNamed(.conflict)),
      ("pl", "en", .engine, .notNamed(.conflict)),
      ("pl", nil, .engine, .notNamed(.conflict)),
      ("fi", "fi", .dictation, .notNamed(.untested)),
      ("el", "el", .locked, .notNamed(.untested)),
    ] as [(String?, String?, Source, EGOneLanguageNaming.Decision)])
  func table(
    text: String?, resolved: String?, source: Source, expected: EGOneLanguageNaming.Decision
  ) {
    #expect(
      EGOneLanguageNaming.decide(textLanguage: text, resolvedLanguage: resolved, source: source)
        == expected)
  }

  @Test("A context that never went through the resolver names only on the text's own answer")
  func legacyNilSource() {
    #expect(
      EGOneLanguageNaming.decide(textLanguage: "pl", resolvedLanguage: "de", source: nil)
        == .named("pl"))
    #expect(
      EGOneLanguageNaming.decide(textLanguage: nil, resolvedLanguage: "pl", source: nil)
        == .notNamed(.unsure))
  }
}

/// #3111 end to end: a real `TextProcessingRunner` resolves the language from the raw text,
/// a real `LLMPolishStep` plans the EG-1 prompt, and a fake EG-1 polisher records the system
/// prompt it was sent.
@MainActor
@Suite("EG-1 language naming through the pipeline", .tags(.productOutcome))
struct EGOneLanguageNamingPipelineTests {

  static let raw =
    "daty płatności są późniejsze niż daty zakupu prawdopodobnie różnica w rejestracji"
  nonisolated static let polishedOutput =
    "Daty płatności są późniejsze niż daty zakupu, prawdopodobnie różnica w rejestracji."
  static let namedPolish =
    EGOneEnvelopePromptBuilder.systemPrompt
    + " The transcript is in Polish; write the cleaned text in Polish."

  @MainActor
  final class FakeRuntime: EGOneEndpointProviding {
    func activeEndpoint() async -> EGOneEndpoint? {
      EGOneEndpoint(port: 1, authToken: "t", contextTokens: 32768)
    }
  }

  final class PromptCapture: @unchecked Sendable {
    var systemPrompt: String?
    var userText: String?
  }

  struct CapturingPolisher: TranscriptPolisher {
    let capture: PromptCapture
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      capture.systemPrompt = instructions.systemPrompt
      capture.userText = text
      return LLMResult(polishedText: EGOneLanguageNamingPipelineTests.polishedOutput)
    }
  }

  /// Rewrites the text before polish, standing in for any deterministic cleanup step.
  final class RewriteStep: TextProcessingStep {
    let name = "Rewrite"
    let replacement: String
    var isEnabled: Bool { true }
    var maxDuration: Duration { .seconds(5) }
    init(_ replacement: String) { self.replacement = replacement }
    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
      var result = context
      result.text = replacement
      return result
    }
  }

  func run(
    evidence: LanguageEvidence,
    family: PromptFamily = .egOneEnvelopeNamedLanguage,
    identify: @escaping (String) -> (language: String, confidence: Double)?,
    before: [any TextProcessingStep] = []
  ) async throws -> PromptCapture {
    let capture = PromptCapture()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .egOne
    step.llmModel = LLMProvider.egOneModelName
    step.egOneRuntime = FakeRuntime()
    step.promptPlanner = DefaultPromptPlanner(egOneFamily: family)
    step.makeEGOnePolisher = { _ in CapturingPolisher(capture: capture) }
    let runner = TextProcessingRunner(
      telemetry: .silent, languageIdentifier: identify,
      timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: 0.0).run)
    _ = try await runner.run(
      rawText: Self.raw, evidence: evidence, targetAppName: nil, steps: before + [step])
    return capture
  }

  static func fixed(_ language: String, _ confidence: Double)
    -> (String) -> (language: String, confidence: Double)?
  {
    { _ in (language, confidence) }
  }

  @Test("Automatic, Polish text: EG-1 is told Polish")
  func automaticPolishIsNamed() async throws {
    let capture = try await run(evidence: .none, identify: Self.fixed("pl", 0.97))
    #expect(capture.systemPrompt == Self.namedPolish)
  }

  @Test("Locked Polish, Polish text: EG-1 is told Polish")
  func lockedPolishIsNamed() async throws {
    let capture = try await run(evidence: .locked("pl"), identify: Self.fixed("pl", 0.97))
    #expect(capture.systemPrompt == Self.namedPolish)
  }

  @Test(
    "English, unsure, conflicting or untested: the byte-identical 1.2 prompt",
    arguments: [
      ("en", 0.99, "none"), ("pl", 0.6, "none"), ("pl", 0.97, "de"), ("fi", 0.97, "none"),
    ] as [(String, Double, String)])
  func unnamedCasesSendTheShippedPrompt(language: String, confidence: Double, lock: String)
    async throws
  {
    let evidence: LanguageEvidence = lock == "none" ? .none : .locked(lock)
    let capture = try await run(evidence: evidence, identify: Self.fixed(language, confidence))
    #expect(capture.systemPrompt == EGOneEnvelopePromptBuilder.systemPrompt)
  }

  @Test("A cleanup step that rewrites the text does not change the language named")
  func namingReadsTheRawText() async throws {
    // The recogniser answers by CONTENT: Polish for the raw text, English for anything else.
    // If polish re-identified the cleaned text, this would name nothing.
    let identify: (String) -> (language: String, confidence: Double)? = { text in
      text == Self.raw ? ("pl", 0.97) : ("en", 0.99)
    }
    let capture = try await run(
      evidence: .none, identify: identify, before: [RewriteStep("payment dates are later")])
    #expect(capture.systemPrompt == Self.namedPolish)
    #expect(capture.userText?.contains("payment dates are later") == true)
  }

  @Test("The 1.1 family never names a language")
  func olderFamilyUnchanged() async throws {
    let capture = try await run(
      evidence: .none, family: .egOneFixed, identify: Self.fixed("pl", 0.97))
    #expect(capture.systemPrompt == EGOnePromptBuilder.systemPrompt)
  }

  @Test("A cloud provider is never handed a named language")
  func cloudProviderGetsNoName() async throws {
    final class InputSpy: PromptPlanning, @unchecked Sendable {
      var namedLanguage: String?? = .none
      let inner = DefaultPromptPlanner(egOneFamily: .egOneEnvelopeNamedLanguage)
      func plan(input: PromptBuildInput) -> PolishPlan {
        namedLanguage = .some(input.namedLanguage)
        return inner.plan(input: input)
      }
    }
    let spy = InputSpy()
    let capture = PromptCapture()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.promptPlanner = spy
    step.makePolisher = { _, _, _ in CapturingPolisher(capture: capture) }
    let runner = TextProcessingRunner(
      telemetry: .silent, languageIdentifier: Self.fixed("pl", 0.97),
      timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: 0.0).run)
    _ = try await runner.run(
      rawText: Self.raw, evidence: .none, targetAppName: nil, steps: [step])
    let recorded = try #require(spy.namedLanguage, "the planner was reached")
    #expect(recorded == nil)
  }
}
