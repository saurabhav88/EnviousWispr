import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #341 EmojiFormatterStep — pipeline wrapper for the deterministic emoji formatter.
@MainActor
@Suite("EmojiFormatterStep — pipeline step contract")
struct EmojiFormatterStepTests {

  private static func makeContext(text: String) -> TextProcessingContext {
    TextProcessingContext(text: text, language: "en")
  }

  private static func makeFormatter() -> EmojiFormatter {
    try! EmojiFormatter(
      entries: [
        EmojiFormatter.Entry(phrase: "thumbs up", emoji: "👍", synonyms: []),
        EmojiFormatter.Entry(phrase: "fire", emoji: "🔥", synonyms: []),
      ], enablePhonetic: false)
  }

  // MARK: - Enable gate

  @Test("Disabled toggle: isEnabled is false — runner skips step entirely")
  func disabledToggleReportsNotEnabled() async throws {
    let step = EmojiFormatterStep(formatter: Self.makeFormatter())
    step.emojiFormatterEnabled = false
    // The runner uses `isEnabled` to decide whether to call `process`. When false,
    // the step is fully bypassed; the per-step contract does NOT promise a no-op
    // when the toggle is off and `process` is called directly. Match
    // FillerRemovalStep / WordCorrectionStep precedent.
    #expect(step.isEnabled == false)
  }

  @Test("Enabled toggle: process converts the trigger")
  func enabledTogglePerformsConversion() async throws {
    let step = EmojiFormatterStep(formatter: Self.makeFormatter())
    step.emojiFormatterEnabled = true
    #expect(step.isEnabled == true)
    let out = try await step.process(Self.makeContext(text: "thumbs up emoji"))
    #expect(out.text == "👍")
  }

  // MARK: - Dictionary load failure

  @Test("Dictionary load failure: isEnabled false even when toggle on")
  func dictionaryFailureBypassesStep() async {
    let step = EmojiFormatterStep(formatter: nil)
    step.emojiFormatterEnabled = true
    #expect(step.isEnabled == false)
  }

  @Test("Dictionary load failure: process returns input context untouched")
  func dictionaryFailureProcessPassesThrough() async throws {
    let step = EmojiFormatterStep(formatter: nil)
    step.emojiFormatterEnabled = true
    let out = try await step.process(Self.makeContext(text: "thumbs up emoji"))
    #expect(out.text == "thumbs up emoji")
  }

  // MARK: - No-op preservation

  @Test("No match: process returns original context (no modification)")
  func noMatchReturnsOriginalContext() async throws {
    let step = EmojiFormatterStep(formatter: Self.makeFormatter())
    step.emojiFormatterEnabled = true
    let original = Self.makeContext(text: "I want a rocket ride to the moon")
    let out = try await step.process(original)
    #expect(out.text == original.text)
  }
}
