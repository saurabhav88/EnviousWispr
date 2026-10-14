import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3737 Casual mode: which final mark is left off. When this fails, the user sees a stiff full stop at
/// the end of a chat reply, or loses a dot that was not a sentence end (`9 a.m`, German `am 3`).
@Suite("Casual mode final full stop (#3737)", .tags(.productOutcome))
struct CasualEndingTests {

  private func strip(_ text: String, _ language: String? = "en", spoken: Bool = false) -> String {
    CasualEnding.removingFinalFullStop(text, language: language, spokenFinalFullStop: spoken)
  }

  @Test(
    "Removes the final full stop and nothing else",
    arguments: [
      ("Sounds good, see you at three.", "Sounds good, see you at three"),
      ("Hi. See you soon.", "Hi. See you soon"),
      ("Done.\n", "Done\n"),
      ("on my way. ", "on my way "),
      ("The price is 3.5.", "The price is 3.5"),
      ("See you at 5.", "See you at 5"),
      ("**done**.", "**done**"),
      ("今天很好。", "今天很好"),
      ("यह ठीक है।", "यह ठीक है"),
    ])
  func removes(input: String, expected: String) {
    #expect(strip(input) == expected)
  }

  @Test(
    "Keeps every other ending",
    arguments: [
      "Are you free?",
      "That is great!",
      "Wait...",
      "Wait…",
      "Wait.。",
      "Wait.।",
      "Meet me at 9 a.m.",
      "I live in the U.S.",
      "Bring snacks, e.g.",
      "She has a Ph.D.",
      "(see above.)",
      "\"hi.\"",
      "Thanks. 👍",
      ".",
      "  .  ",
      "",
      "no ending",
    ])
  func keeps(input: String) {
    #expect(strip(input) == input)
  }

  @Test("A full stop the user said is kept")
  func spokenFullStopIsKept() {
    #expect(strip("See you.", spoken: true) == "See you.")
    #expect(strip("See you.", spoken: false) == "See you")
  }

  @Test("A dot after a digit is an ordinal outside English, so it stays")
  func ordinalDotOutsideEnglish() {
    #expect(strip("Wir treffen uns am 3.", "de") == "Wir treffen uns am 3.")
    #expect(strip("Wir treffen uns am 3.", "de-DE") == "Wir treffen uns am 3.")
    #expect(strip("Wir treffen uns am 3.", nil) == "Wir treffen uns am 3.")
    #expect(strip("See you at 3.", "en-GB") == "See you at 3")
    // A word ending is not a digit: the German sentence end still goes.
    #expect(strip("Bis morgen.", "de") == "Bis morgen")
  }
}
