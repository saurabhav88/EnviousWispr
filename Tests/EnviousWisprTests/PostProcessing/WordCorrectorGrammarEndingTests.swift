import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3892: word correction keeps the ending of a word it knows ("ChatGPT's", "MacBooks") and leaves a
/// non-Latin word plus a short ending alone ("Иванову"). Each defect row fails on the parent commit
/// because the ending was deleted; each compatibility row is a correction that must keep working.
@MainActor
@Suite("Word correction keeps word endings", .tags(.productOutcome))
struct WordCorrectorGrammarEndingTests {
  private let corrector = WordCorrector()
  private var shipped: [CustomWord] { CustomWordsManager.builtinDefaults.map(\.word) }

  private func shippedCorrected(_ input: String) -> String {
    corrector.correct(input, against: shipped).0
  }

  private func corrected(_ input: String, _ words: [CustomWord]) -> String {
    corrector.correct(input, against: words).0
  }

  // MARK: Defect rows (shipped dictionary)

  @Test(
    "a built-in brand keeps its possessive",
    arguments: [
      "ChatGPT's answer was good", "ChatGPT\u{2019}s answer was good", "EnviousWispr's settings",
    ])
  func builtInPossessiveKept(_ input: String) {
    #expect(shippedCorrected(input) == input)
  }

  @Test("a lowercase possessive of a built-in brand gets the brand spelling and keeps its ending")
  func lowercasePossessiveGetsBrandSpelling() {
    #expect(shippedCorrected("chatgpt's answer was good") == "ChatGPT's answer was good")
  }

  // MARK: Defect rows (hand-built words)

  @Test("a plural of a saved word keeps its s")
  func pluralKept() {
    let word = CustomWord(canonical: "MacBook", aliases: [], category: .brand)
    #expect(corrected("two MacBooks are here", [word]) == "two MacBooks are here")
  }

  @Test("a misheard possessive is corrected and keeps its apostrophe s")
  func misheardPossessiveKeepsEnding() {
    let word = CustomWord(canonical: "MacBook", aliases: [], category: .brand)
    #expect(corrected("the MacBok's screen is bright", [word]) == "the MacBook's screen is bright")
  }

  @Test("a misspelling that ends in s keeps the whole-word correction (Salesfors is Salesforce)")
  func misspellingEndingInSIsNotAPlural() {
    let word = CustomWord(canonical: "Salesforce", aliases: [], category: .brand)
    #expect(corrected("we use Salesfors daily", [word]) == "we use Salesforce daily")
  }

  @Test("an alias prefix does not block a non-Latin spelling fix (Иваноф is Иванов)")
  func aliasPrefixDoesNotBlockNonLatinFix() {
    let word = CustomWord(canonical: "Иванов", aliases: ["иван"], category: .person)
    #expect(corrected("письмо Иваноф вчера", [word]) == "письмо Иванов вчера")
  }

  @Test(
    "a lowercase plural of a saved word gets its spelling and keeps its s (#3630 class, ending kept)"
  )
  func lowercasePluralGetsSpelling() {
    let word = CustomWord(canonical: "Slack", aliases: [], category: .brand)
    #expect(corrected("my slacks", [word]) == "my Slacks")
  }

  @Test(
    "a Russian saved name plus a case ending stays as dictated",
    arguments: [("Иванову", "Иванов"), ("Петрова", "Петров")])
  func russianInflectionKept(_ spoken: String, _ saved: String) {
    let word = CustomWord(canonical: saved, aliases: [], category: .person)
    #expect(corrected("письмо \(spoken) вчера", [word]) == "письмо \(spoken) вчера")
  }

  // MARK: Compatibility rows (these corrections keep working)

  @Test("a lowercase non-Latin saved word still gets its casing")
  func nonLatinCasingStillCorrected() {
    let word = CustomWord(canonical: "Иванов", aliases: [], category: .person)
    #expect(corrected("письмо иванов вчера", [word]) == "письмо Иванов вчера")
  }

  @Test("a Latin near miss still corrects")
  func latinNearMissStillCorrects() {
    let word = CustomWord(canonical: "Ivanov", aliases: [], category: .person)
    #expect(corrected("a note for ivanof today", [word]) == "a note for Ivanov today")
  }

  @Test("an alias plus an ending is another word: clods is not Claudes")
  func aliasPlusEndingIsNotRewritten() {
    #expect(shippedCorrected("clods of dirt") == "clods of dirt")
  }

  @Test("an alias that is itself a plural still wins over the peel (kelloggs)")
  func exactAliasBeatsPeel() {
    let word = CustomWord(canonical: "Kellogg's", aliases: ["kelloggs"], category: .brand)
    #expect(corrected("I like kelloggs cereal", [word]) == "I like Kellogg's cereal")
  }

  @Test("a correctly spelled pack word that ends in s is left alone (Databricks, not Databrickss)")
  func packWordEndingInSUntouched() {
    let word = CustomWord(canonical: "Databricks", aliases: [], source: .pack)
    #expect(corrected("we use Databricks daily", [word]) == "we use Databricks daily")
  }

  @Test("a misspelled pack word that ends in s is not given a second s")
  func misspelledPackWordEndingInSNoDoubleS() {
    let word = CustomWord(canonical: "Databricks", aliases: [], source: .pack)
    let result = corrected("we use Databrics daily", [word])
    #expect(result == "we use Databricks daily", "the whole word is corrected, no second s: \(result)")
  }

  @Test("a word that ends in s and is itself saved is left alone")
  func savedWordEndingInSUntouched() {
    let word = CustomWord(canonical: "Jones", aliases: [], category: .person)
    #expect(corrected("ask Jones about it", [word]) == "ask Jones about it")
  }
}
