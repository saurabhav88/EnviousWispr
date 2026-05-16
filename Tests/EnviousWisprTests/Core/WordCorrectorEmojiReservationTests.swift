import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #341 — pins the WordCorrector trigger-word reservation guard. Verifies
/// that "emoji" and "emoticon" tokens cannot be substituted by any custom-word
/// pass (n-gram compound, multi-word exact, multi-word fuzzy, single-word
/// exact, single-word fuzzy). The guard is unconditional — applies even when
/// EmojiFormatter is disabled in Settings. See plan §3.4 global-behavior caveat.
@Suite("WordCorrector — #341 emoji trigger reservation")
struct WordCorrectorEmojiReservationTests {
  let corrector = WordCorrector()

  // MARK: - Single-word passes

  @Test("Single-word: 'emoji' as a custom-word alias DOES NOT substitute")
  func singleWordAliasEmojiReserved() {
    let foo = CustomWord(canonical: "Foo", aliases: ["emoji"])
    let (result, replacements) = corrector.correct(
      "thumbs up emoji ship it", against: [foo])
    #expect(result == "thumbs up emoji ship it", "Reserved trigger word must NOT be replaced")
    #expect(replacements.isEmpty)
  }

  @Test("Single-word: 'emoticon' as a custom-word alias DOES NOT substitute")
  func singleWordAliasEmoticonReserved() {
    let foo = CustomWord(canonical: "Foo", aliases: ["emoticon"])
    let (result, replacements) = corrector.correct(
      "fire emoticon today", against: [foo])
    #expect(result == "fire emoticon today")
    #expect(replacements.isEmpty)
  }

  // MARK: - N-gram compound (Pass 0)

  @Test("N-gram: 'emoji forge' against ['EmojiForge'] DOES NOT substitute")
  func ngramConsumingEmojiTokenReserved() {
    let ef = CustomWord(canonical: "EmojiForge", aliases: ["emoji forge"])
    let (result, _) = corrector.correct(
      "the emoji forge feature", against: [ef])
    #expect(
      result == "the emoji forge feature",
      "N-gram substitution that would consume the 'emoji' token must be skipped")
  }

  // MARK: - Multi-word exact (Pass 1)

  @Test("Multi-word exact: 'emoji emoji' as alias DOES NOT substitute")
  func multiWordExactReserved() {
    let foo = CustomWord(canonical: "EmojiPair", aliases: ["emoji emoji"])
    let (result, _) = corrector.correct("emoji emoji combo", against: [foo])
    #expect(result == "emoji emoji combo")
  }

  // MARK: - Persistence (R2 grounded-review addition)

  @Test(
    "Persistence: 'emoji' custom-word entry stays in the vocabulary list (only the runtime substitution is suppressed)"
  )
  func customWordEntryPersistsButIsNotApplied() {
    let foo = CustomWord(canonical: "Foo", aliases: ["emoji"])
    // The vocabulary itself is unchanged — entry remains. Only the per-correction
    // substitution is suppressed at runtime.
    #expect(foo.aliases == ["emoji"])
    let (result, _) = corrector.correct("emoji", against: [foo])
    #expect(result == "emoji", "Runtime substitution suppressed for reserved trigger")
  }

  // MARK: - Negative control

  @Test("Negative control: a non-reserved custom word DOES substitute normally")
  func nonReservedCustomWordStillSubstitutes() {
    let openai = CustomWord(canonical: "OpenAI", aliases: ["openai"])
    let (result, replacements) = corrector.correct(
      "I used openai today", against: [openai])
    #expect(result == "I used OpenAI today")
    #expect(replacements.count == 1)
  }
}
