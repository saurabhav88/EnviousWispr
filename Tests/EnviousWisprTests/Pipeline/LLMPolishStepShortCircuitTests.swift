import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1022: the too-short skip is a Bypass — it must leave NO polish output and
/// NO provider attribution, because `polishedText != nil` is the UI's signal
/// for "AI was applied" (history badge, Enhance visibility) and `llmProvider`
/// is its attribution (llm-contract FACT: llm-contract-signals).
///
/// Before the fix, both skip branches copied the raw text into `polishedText`,
/// so 1-3 word dictations showed the AI badge though AI never ran.
@MainActor
@Suite("LLMPolishStep short-circuit bypass")
struct LLMPolishStepShortCircuitTests {

  /// Counts polisher invocations on an actor so the read after `process()`
  /// returns is race-free (the polish call completes before process returns).
  private actor InvocationCounter {
    private(set) var count = 0
    private(set) var systemPrompt: String?

    func record(systemPrompt: String) {
      count += 1
      self.systemPrompt = systemPrompt
    }
  }

  /// Deterministic polisher: records the call, returns a fixed result.
  /// Implements the legacy `text:` method; the planner path reaches it via
  /// the protocol's default `envelope:` bridge.
  private struct SpyPolisher: TranscriptPolisher {
    let counter: InvocationCounter
    let result: String

    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      await counter.record(systemPrompt: instructions.systemPrompt)
      return LLMResult(polishedText: result)
    }
  }

  private func makeStep(
    counter: InvocationCounter,
    result: String = "unused",
    provider: LLMProvider = .openAI
  ) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    step.setPolish(provider: provider)
    step.llmModel = provider == .claude ? "claude-haiku-4-5" : "gpt-4o-mini"
    step.makePolisher = { _, _, _, _ in SpyPolisher(counter: counter, result: result) }
    return step
  }

  private func expectBypass(
    _ ctx: TextProcessingContext,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(ctx.polishedText == nil, sourceLocation: sourceLocation)
    #expect(ctx.llmProvider == nil, sourceLocation: sourceLocation)
    #expect(ctx.llmModel == nil, sourceLocation: sourceLocation)
  }

  // MARK: English word-count gate (skip at <= 3 words, polish at 4+)

  @Test(
    "3-word English input bypasses: no polish output, no provider stamp, no LLM call",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1022",
      "AI badge on short dictations AI never touched"
    )
  )
  func threeWordEnglishBypasses() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter)
    let ctx = try await step.process(
      TextProcessingContext(text: "hey running late", language: "en"))
    expectBypass(ctx)
    #expect(ctx.text == "hey running late")
    #expect(await counter.count == 0)
  }

  @Test("founder repro: \"Other apps.\" (2 words, punctuation kept) bypasses")
  func founderReproBypasses() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter)
    let ctx = try await step.process(TextProcessingContext(text: "Other apps.", language: "en"))
    expectBypass(ctx)
    #expect(await counter.count == 0)
  }

  @Test("4-word English input polishes: output set, provider stamped (no over-suppression)")
  func fourWordEnglishPolishes() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter, result: "Hey, I am late.")
    let ctx = try await step.process(TextProcessingContext(text: "hey i am late", language: "en"))
    #expect(ctx.polishedText == "Hey, I am late.")
    #expect(ctx.llmProvider == LLMProvider.openAI.rawValue)
    #expect(ctx.llmModel == "gpt-4o-mini")
    #expect(await counter.count == 1)
  }

  // MARK: Unsegmented-script char-count gate (skip at < 10 chars, polish at 10+)

  @Test("9-char Japanese input bypasses via the char-count branch")
  func nineCharJapaneseBypasses() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter)
    // 9 non-whitespace scalars.
    let ctx = try await step.process(TextProcessingContext(text: "こんにちは元気です", language: "ja"))
    expectBypass(ctx)
    #expect(await counter.count == 0)
  }

  @Test("10-char Japanese input polishes")
  func tenCharJapanesePolishes() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter, result: "こんにちは、元気ですか。")
    // 10 non-whitespace scalars.
    let ctx = try await step.process(TextProcessingContext(text: "こんにちは元気ですか", language: "ja"))
    #expect(ctx.polishedText == "こんにちは、元気ですか。")
    #expect(ctx.llmProvider == LLMProvider.openAI.rawValue)
    #expect(await counter.count == 1)
  }

  @Test("short Thai input routes to the char-count branch and bypasses")
  func shortThaiBypasses() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter)
    // 6 non-whitespace scalars — would be 1 "word" by whitespace split either
    // way; the char-count branch is what makes the gate honest for Thai.
    let ctx = try await step.process(TextProcessingContext(text: "สวัสดี", language: "th"))
    expectBypass(ctx)
    #expect(await counter.count == 0)
  }

  @Test(
    "Translation keeps the existing word and character cutoffs",
    arguments: [
      ("please call today", "en", false),
      ("please call me today", "en", true),
      ("こんにちは元気です", "ja", false),
      ("こんにちは元気ですか", "ja", true),
    ])
  func translationKeepsCutoff(text: String, language: String, expectsCall: Bool) async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter, result: "Ruf mich bitte heute an.", provider: .claude)
    var input = TextProcessingContext(text: text, language: language)
    input.requestedTranslationTarget = .german

    let result = try await step.process(input)

    #expect(await counter.count == (expectsCall ? 1 : 0))
    #expect(result.acceptedTranslationTarget == (expectsCall ? .german : nil))
    #expect(result.text == text)
  }

  @Test("A valid translated opening survives the existing provider call")
  func translationKeepsOpening() async throws {
    let counter = InvocationCounter()
    let reply = "Sure, I’ll bring the key."
    let step = makeStep(counter: counter, result: reply, provider: .claude)
    var input = TextProcessingContext(text: "Klar, ich bringe den Schlüssel mit.", language: "de")
    input.requestedTranslationTarget = .english

    let result = try await step.process(input)

    #expect(await counter.count == 1)
    let systemPrompt = try #require(await counter.systemPrompt)
    #expect(systemPrompt.contains("Translate this dictation into English."))
    #expect(result.polishedText == reply)
    #expect(result.acceptedTranslationTarget == .english)
  }

  @Test("A translated command survives, but the existing same-language question check still applies")
  func translationDoesNotTreatCommandsAsQuestions() async throws {
    let source = "Do not send that email until Friday."
    let command = "Schick diese E-Mail erst am Freitag."
    let translated = makeStep(counter: InvocationCounter(), result: command, provider: .claude)
    var input = TextProcessingContext(text: source, language: "en")
    input.requestedTranslationTarget = .german
    let translatedResult = try await translated.process(input)
    #expect(translatedResult.polishedText == command)
    #expect(translatedResult.acceptedTranslationTarget == .german)

    let question = "Can you send that email by Friday?"
    input.text = question
    let rejectedAnswer = try await translated.process(input)
    #expect(rejectedAnswer.polishedText == nil)
    #expect(rejectedAnswer.text == question)
    #expect(rejectedAnswer.polishValidatorGuard == "question_flip")

    let english = makeStep(
      counter: InvocationCounter(), result: "Wait until Friday to send that email.",
      provider: .claude)
    input.text = source
    input.requestedTranslationTarget = nil
    let ordinary = try await english.process(input)
    input.requestedTranslationTarget = .english
    let sameLanguage = try await english.process(input)
    #expect(ordinary.polishValidatorGuard == "question_flip")
    #expect(sameLanguage.polishValidatorGuard == ordinary.polishValidatorGuard)
    #expect((sameLanguage.polishedText ?? sameLanguage.text).utf8.elementsEqual(
      (ordinary.polishedText ?? ordinary.text).utf8))
  }

  @Test("Only translation from a recognized unsegmented source can exceed the usual length ceiling")
  func unsegmentedTranslationKeepsNaturalExpansion() async throws {
    let source = "明早九点在北门集合。带护照、雨衣、水和车票。下雨就去车站咖啡馆等。别忘了告诉李娜改到周五。"
    let reply = "Meet at the north gate at nine tomorrow morning. Bring your passport, a raincoat, "
      + "some water, and your train ticket. If it rains, wait at the café inside the train station. "
      + "Remember to tell Li Na that we moved it to Friday."
    #expect(reply.count > max(3 * source.count, 200))
    let step = makeStep(counter: InvocationCounter(), result: reply, provider: .claude)
    var input = TextProcessingContext(text: source, language: "zh")
    input.requestedTranslationTarget = .english

    let translated = try await step.process(input)
    #expect(translated.polishedText == reply)
    #expect(translated.acceptedTranslationTarget == .english)

    input.requestedTranslationTarget = nil
    let ordinaryChinese = try await step.process(input)
    #expect(ordinaryChinese.polishValidatorGuard == "expansion")
    #expect(ordinaryChinese.polishedText?.utf8.elementsEqual(source.utf8) == true)

    let englishSource = "Meet at the north gate tomorrow morning."
    input = TextProcessingContext(text: englishSource, language: "en")
    let ordinaryEnglish = try await step.process(input)
    input.requestedTranslationTarget = .english
    let sameLanguage = try await step.process(input)
    #expect(ordinaryEnglish.polishValidatorGuard == "expansion")
    #expect(sameLanguage.polishValidatorGuard == ordinaryEnglish.polishValidatorGuard)
    #expect((sameLanguage.polishedText ?? sameLanguage.text).utf8.elementsEqual(
      (ordinaryEnglish.polishedText ?? ordinaryEnglish.text).utf8))
  }

  @Test("Other cloud providers keep ordinary polish with a saved translation target")
  func translationTargetDoesNotApplyToOpenAI() async throws {
    let counter = InvocationCounter()
    let reply = "Mira bringt heute den Schlüssel."
    let step = makeStep(counter: counter, result: reply)
    var input = TextProcessingContext(text: "Mira bringt heute den Schlüssel", language: "de")
    input.requestedTranslationTarget = .english

    let result = try await step.process(input)

    let systemPrompt = try #require(await counter.systemPrompt)
    #expect(systemPrompt.contains("Never translate it"))
    #expect(result.polishedText == reply)
    #expect(result.acceptedTranslationTarget == nil)
  }

  @Test("A discarded translation leaves the entire prepared source for delivery")
  func translationRejectionKeepsSource() async throws {
    let source = "Bitte bring mir am Freitag um 15 Uhr die drei Schlüssel mit."
    let counter = InvocationCounter()
    let step = makeStep(counter: counter, result: "The keys.", provider: .claude)
    var input = TextProcessingContext(text: source, language: "de")
    input.requestedTranslationTarget = .english

    let result = try await step.process(input)

    #expect(await counter.count == 1)
    #expect(result.polishedText == nil)
    #expect(result.text == source)
    #expect(result.polishValidatorGuard == "content_drop")
    #expect(result.acceptedTranslationTarget == nil)
  }

  // MARK: Stale-field defense

  @Test("bypass clears pre-set AI fields: the Bypass contract holds even for a stale context")
  func bypassClearsStaleFields() async throws {
    let counter = InvocationCounter()
    let step = makeStep(counter: counter)
    var stale = TextProcessingContext(text: "Other apps.", language: "en")
    stale.polishedText = "stale polished"
    stale.llmProvider = "openai"
    stale.llmModel = "gpt-4o-mini"
    let ctx = try await step.process(stale)
    expectBypass(ctx)
    #expect(await counter.count == 0)
  }
}
