import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 3a (#631) — pins the new `Replacement` attribution contract.
/// Each replacement returned by `WordCorrector.correct(...)` must carry the
/// source `CustomWord.id`. Bible §9.2.
@Suite("WordCorrector — Replacement source attribution")
struct WordCorrectorReplacementTests {
  let corrector = WordCorrector()

  @Test("Single-word alias replacement carries source ID")
  func singleAliasSourceID() {
    let chatGPT = CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])
    let (result, replacements) = corrector.correct("I used chatgpt today", against: [chatGPT])
    #expect(result == "I used ChatGPT today")
    #expect(replacements.count == 1)
    #expect(replacements.first?.sourceID == chatGPT.id)
  }

  @Test("Multi-word exact alias carries source ID")
  func multiWordExactSourceID() {
    let vsCode = CustomWord(canonical: "Visual Studio Code", aliases: ["vs code"])
    let (_, replacements) = corrector.correct("I opened vs code", against: [vsCode])
    #expect(replacements.count == 1)
    #expect(replacements.first?.sourceID == vsCode.id)
  }

  @Test("Multiple replacements each carry their own source ID")
  func multipleReplacementsEachAttributed() {
    let chatGPT = CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])
    let openAI = CustomWord(canonical: "OpenAI", aliases: ["openai"])
    let (_, replacements) = corrector.correct(
      "openai made chatgpt", against: [chatGPT, openAI])
    #expect(replacements.count == 2)
    let sourceIDs = Set(replacements.map(\.sourceID))
    #expect(sourceIDs.contains(chatGPT.id))
    #expect(sourceIDs.contains(openAI.id))
  }

  @Test("Canonical self-entry casing fix carries source ID")
  func canonicalSelfEntrySourceID() {
    let iPhone = CustomWord(canonical: "iPhone")
    let (_, replacements) = corrector.correct("I have an iphone", against: [iPhone])
    #expect(replacements.count == 1)
    #expect(replacements.first?.sourceID == iPhone.id)
  }

  @Test("Fuzzy canonical fallback carries source ID")
  func fuzzyCanonicalFallbackSourceID() {
    let kubernetes = CustomWord(canonical: "Kubernetes")
    let (_, replacements) = corrector.correct("deployed to kuberntes", against: [kubernetes])
    #expect(replacements.count == 1)
    #expect(replacements.first?.sourceID == kubernetes.id)
  }

  @Test("No match returns empty replacements list")
  func noMatchEmptyReplacements() {
    let kubernetes = CustomWord(canonical: "Kubernetes")
    let (result, replacements) = corrector.correct("I like bananas", against: [kubernetes])
    #expect(result == "I like bananas")
    #expect(replacements.isEmpty)
  }

  @Test("Empty word list returns empty replacements list")
  func emptyWordListEmptyReplacements() {
    let (result, replacements) = corrector.correct("hello", against: [])
    #expect(result == "hello")
    #expect(replacements.isEmpty)
  }
}
