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
    func increment() { count += 1 }
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
      await counter.increment()
      return LLMResult(polishedText: result)
    }
  }

  private func makeStep(
    counter: InvocationCounter,
    result: String = "unused"
  ) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.makePolisher = { _, _, _ in SpyPolisher(counter: counter, result: result) }
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
