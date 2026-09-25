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

/// #3111 cloud review: a Polish dictation carrying an English clause must not be named Polish,
/// because EG-1 then translated the clause (4 of 20 measured). When this fails, a Polish user
/// quoting an English email gets the quote back in Polish.
@Suite("EG-1 language naming: English stretches", .tags(.productOutcome))
struct EGOneEnglishStretchTests {

  /// The four measured sentences EG-1 translated when told "Polish".
  static let translatedWhenNamed = [
    "Klient napisał: please send the updated contract by Friday, więc musimy się pospieszyć.",
    "W mailu było napisane the invoice is overdue, więc zadzwoniłem do księgowości.",
    "Dostaliśmy odpowiedź we will get back to you shortly, i nic więcej.",
    "Ona zawsze mówi it is what it is, kiedy coś nie wychodzi.",
  ]
  /// Single English product names: naming Polish made no net difference, so these stay named.
  static let productNames = [
    "Wrzuć ten plik na Google Drive i wyślij link na Slacku.",
    "Nowy MacBook Pro przyszedł, trzeba go skonfigurować.",
    "Sprawdź dashboard w PostHogu, czy spadł retention.",
  ]
  static let pure = [
    "Daty płatności są późniejsze niż daty zakupu, prawdopodobnie różnica w rejestracji transakcji.",
    "Die Zahlungsdaten liegen später als die Kaufdaten, wahrscheinlich ein Unterschied bei der Erfassung.",
    "支払日が購入日より後になっているのは、おそらく取引の記録方法の違いによるものです。",
    "Даты платежей позже дат покупки, вероятно, разница в регистрации транзакций.",
  ]

  @Test("The real recogniser finds the English stretch in every sentence EG-1 translated")
  func translatedSentencesAreMixed() {
    for sentence in Self.translatedWhenNamed {
      #expect(DictationLanguageResolver.englishStretch(in: sentence) == .mixed, "\(sentence)")
    }
  }

  @Test("Single product names and pure non-English text stay clear")
  func productNamesAndPureTextAreClear() {
    for sentence in Self.productNames + Self.pure {
      #expect(DictationLanguageResolver.englishStretch(in: sentence) == .clear, "\(sentence)")
    }
  }

  @Test("Past the word limit the answer is scanLimit, never clear")
  func overLimitIsScanLimit() {
    let words = DictationLanguageResolver.englishStretchWordLimit + 20
    let text = Array(repeating: "tak", count: words).joined(separator: " ")
    #expect(DictationLanguageResolver.englishStretch(in: text) == .scanLimit)
  }

  @Test(
    "A preliminary name survives only a clear scan; other answers pass through",
    arguments: [
      (EGOneLanguageNaming.Decision.named("pl"), DictationLanguageResolver.EnglishStretchScan.clear,
       EGOneLanguageNaming.Decision.named("pl")),
      (.named("pl"), .mixed, .notNamed(.mixed)),
      (.named("pl"), .scanLimit, .notNamed(.scanLimit)),
      (.notNamed(.english), .mixed, .notNamed(.english)),
      (.notNamed(.conflict), .clear, .notNamed(.conflict)),
    ] as [(EGOneLanguageNaming.Decision, DictationLanguageResolver.EnglishStretchScan, EGOneLanguageNaming.Decision)])
  func applying(
    preliminary: EGOneLanguageNaming.Decision, scan: DictationLanguageResolver.EnglishStretchScan,
    expected: EGOneLanguageNaming.Decision
  ) {
    #expect(EGOneLanguageNaming.applying(scan, to: preliminary) == expected)
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
    before: [any TextProcessingStep] = [],
    scan: @escaping @Sendable (String) -> DictationLanguageResolver.EnglishStretchScan = { _ in .clear }
  ) async throws -> PromptCapture {
    let capture = PromptCapture()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .egOne
    step.llmModel = LLMProvider.egOneModelName
    step.egOneRuntime = FakeRuntime()
    step.promptPlanner = DefaultPromptPlanner(egOneFamily: family)
    step.makeEGOnePolisher = { _ in CapturingPolisher(capture: capture) }
    step.englishStretchScanner = scan
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

  @Test("An English stretch in the text EG-1 receives withholds the name", arguments: [
    DictationLanguageResolver.EnglishStretchScan.mixed, .scanLimit,
  ])
  func englishStretchWithholdsTheName(scan: DictationLanguageResolver.EnglishStretchScan) async throws {
    let capture = try await run(
      evidence: .locked("pl"), identify: Self.fixed("pl", 0.97), scan: { _ in scan })
    #expect(capture.systemPrompt == EGOneEnvelopePromptBuilder.systemPrompt)
  }

  @Test("The real scanner withholds the name for a Polish sentence quoting English")
  func realScannerOnAQuote() async throws {
    let capture = try await run(
      evidence: .locked("pl"), identify: Self.fixed("pl", 0.97),
      before: [RewriteStep(EGOneEnglishStretchTests.translatedWhenNamed[0])],
      scan: DictationLanguageResolver.englishStretch)
    #expect(capture.systemPrompt == EGOneEnvelopePromptBuilder.systemPrompt)
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
