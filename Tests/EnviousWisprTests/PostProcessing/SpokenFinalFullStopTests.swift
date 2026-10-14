import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3737: the spoken-punctuation matchers report a full stop the user SAID at the very end, so Casual
/// mode keeps it. When this fails, a Casual-mode user who says "period" at the end loses that full stop,
/// or an engine's own dot is wrongly treated as spoken and kept.
@Suite("Spoken final full stop provenance (#3737)", .tags(.productOutcome))
struct SpokenFinalFullStopTests {

  private let normalizer = InverseTextNormalizer()

  private func english(_ text: String, spoken: Bool = true) -> (String, Bool) {
    let r = normalizer.normalizeReportingFinalFullStop(text, spokenPunctuation: spoken)
    return (r.text, r.spokenFinalFullStop)
  }

  private func german(_ text: String, startWord: String = "Diktiere") -> SpokenPunctuationResult {
    normalizer.applyStartWordPunctuation(
      text, language: "de", startWord: startWord, protectedSentinels: [])
  }

  @Test(
    "English bare words: a final period command reports true",
    arguments: [
      "see you period",
      "see you full stop",
      "see you period.",
      "see you period..",
      "see you Period",
      "see you period new paragraph",
      "see you period new line.",
      "see you comma okay period",
      "see you period?",
      "see you period!",
    ])
  func englishTrue(input: String) {
    #expect(english(input).1 == true)
  }

  @Test(
    "English bare words: anything surviving after the command reports false",
    arguments: [
      "the grace period expires",
      "period, see you",
      "hello period?.",
      "hello period new line new paragraph.",
      "see you period comma",
      "see you.",
      "see you",
    ])
  func englishFalse(input: String) {
    #expect(english(input).1 == false)
  }

  @Test("English: never true while Spoken punctuation is off")
  func englishOff() {
    #expect(english("see you period", spoken: false).1 == false)
  }

  @Test("English: the converted text is what normalize returns")
  func englishTextUnchangedByReporting() {
    let input = "See you period new paragraph thanks"
    // The released break shape keeps a space on each side (pinned by SpokenPunctuationToggleTests).
    #expect(english(input).0 == "See you. \n\n Thanks")
    #expect(normalizer.normalize(input, spokenPunctuation: true) == "See you. \n\n Thanks")
  }

  @Test("Start word: a final period command reports true")
  func startWordTrue() {
    #expect(german("Bis morgen Diktiere Punkt").spokenFinalFullStop)
    #expect(german("Bis morgen Diktiere Punkt.").spokenFinalFullStop)
    #expect(german("Bis morgen Diktiere Punkt Diktiere neuer Absatz").spokenFinalFullStop)
    #expect(german("Bis morgen Punkt", startWord: "").spokenFinalFullStop)
    #expect(german("Bis morgen Diktiere Punkt?").spokenFinalFullStop)
    #expect(german("Bis morgen Diktiere Punkt!").spokenFinalFullStop)
  }

  @Test("Start word: anything surviving after the command reports false")
  func startWordFalse() {
    #expect(!german("Hallo Diktiere Punkt;.").spokenFinalFullStop)
    #expect(!german("Hallo Diktiere Punkt..").spokenFinalFullStop)
    #expect(!german("Hallo Diktiere Punkt wie geht es").spokenFinalFullStop)
    #expect(!german("Hallo Diktiere Punkt Diktiere Komma").spokenFinalFullStop)
    #expect(!german("Bis morgen Punkt").spokenFinalFullStop)
    #expect(!german("Bis morgen.").spokenFinalFullStop)
  }
}
