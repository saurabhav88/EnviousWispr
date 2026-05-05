import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Phase 2b (#638) — pins the lookup-map cache contract on
/// `WordCorrectionStep`. Bible §8.2 items 5-6, §17 R19.
///
/// #657 (2026-05-05) — the inner 10ms timeout was removed; the only remaining
/// bound is the runner-level 3-second `maxDuration` safety net. Cap-trip
/// telemetry is owned by `TextProcessingRunner`, not this step.
@MainActor
@Suite("WordCorrectionStep — Phase 2b cache + timeout")
struct WordCorrectionStepCacheTests {

  private static func makeContext(text: String) -> TextProcessingContext {
    TextProcessingContext(text: text, language: "en")
  }

  // MARK: - Cache effectiveness

  @Test("Cache: 10 calls with same generation → 1 build + 9 hits")
  func cacheHitsAcrossSameGeneration() async throws {
    let step = WordCorrectionStep()
    step.wordCorrectionEnabled = true
    let words = [
      CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"]),
      CustomWord(canonical: "OpenAI", aliases: ["openai"]),
    ]
    step.correctorVocabulary = CorrectorVocabulary(terms: words, generation: 1)

    for _ in 0..<10 {
      _ = try await step.process(Self.makeContext(text: "I used chatgpt today"))
    }
    #expect(step.lookupCacheBuilds == 1, "Only the first call should build")
    #expect(step.lookupCacheHits == 9, "Subsequent 9 calls should hit cache")
  }

  @Test("Cache invalidation: generation bump triggers rebuild")
  func cacheInvalidatesOnGenerationBump() async throws {
    let step = WordCorrectionStep()
    step.wordCorrectionEnabled = true
    let words = [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    step.correctorVocabulary = CorrectorVocabulary(terms: words, generation: 1)
    _ = try await step.process(Self.makeContext(text: "chatgpt"))
    _ = try await step.process(Self.makeContext(text: "chatgpt"))
    #expect(step.lookupCacheBuilds == 1)
    #expect(step.lookupCacheHits == 1)

    step.correctorVocabulary = CorrectorVocabulary(terms: words, generation: 2)
    _ = try await step.process(Self.makeContext(text: "chatgpt"))
    #expect(step.lookupCacheBuilds == 2, "Generation bump must rebuild")
    #expect(step.lookupCacheHits == 1, "No new hit (just rebuilt)")

    _ = try await step.process(Self.makeContext(text: "chatgpt"))
    #expect(step.lookupCacheBuilds == 2)
    #expect(step.lookupCacheHits == 2, "Subsequent call hits the new cache")
  }

  @Test("Cache: same generation reused even when terms swapped (intentional)")
  func cacheKeyedByGenerationOnly() async throws {
    let step = WordCorrectionStep()
    step.wordCorrectionEnabled = true
    let chatGPT = [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    step.correctorVocabulary = CorrectorVocabulary(terms: chatGPT, generation: 5)
    _ = try await step.process(Self.makeContext(text: "anything"))
    #expect(step.lookupCacheBuilds == 1)

    // Swap terms but keep generation — propagator contract says this would
    // never happen in production (generation bumps on every coordinator
    // update), but pin the contract.
    let openAI = [CustomWord(canonical: "OpenAI", aliases: ["openai"])]
    step.correctorVocabulary = CorrectorVocabulary(terms: openAI, generation: 5)
    _ = try await step.process(Self.makeContext(text: "anything"))
    #expect(step.lookupCacheBuilds == 1, "No rebuild because generation unchanged")
    #expect(step.lookupCacheHits == 1, "1 build + 1 hit = 2 calls total")
  }

  // MARK: - Heart-path correctness through the new path

  @Test("Correction works through cache: chatgpt → ChatGPT")
  func correctionStillWorks() async throws {
    let step = WordCorrectionStep()
    step.wordCorrectionEnabled = true
    let words = [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    step.correctorVocabulary = CorrectorVocabulary(terms: words, generation: 1)

    let result = try await step.process(Self.makeContext(text: "I used chatgpt today"))
    #expect(result.text == "I used ChatGPT today")
  }

  @Test("Empty vocabulary: no-op + no build")
  func emptyVocabularyNoOp() async throws {
    let step = WordCorrectionStep()
    step.wordCorrectionEnabled = true
    step.correctorVocabulary = .empty

    let result = try await step.process(Self.makeContext(text: "hello world"))
    #expect(result.text == "hello world")
    // empty terms still builds an empty Lookups (cheap), so 1 build expected
    #expect(step.lookupCacheBuilds == 1)
  }

  // MARK: - #657 cap value pin

  @Test("Outer cap is 3 seconds (#657)")
  func outerCapIsThreeSeconds() {
    let step = WordCorrectionStep()
    #expect(step.maxDuration == .seconds(3))
  }
}
