import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// A spoken list of numbers before a unit word is a list, never one summed number (#4632).
///
/// **When this fails, a dictated "this 40, 20, 10 percent" pastes "this 70%", a plausible
/// number the speaker never said.** Product coverage. The first row is the founder's own
/// dictation (2026-11-16), exactly as the speech engine wrote it; the controls pin what must
/// NOT change: a thousands comma is still one number, and a spoken number with a digit in it
/// still converts whole.
@Suite("ITN keeps a list of numbers apart before percent and dollars (#4632)", .tags(.productOutcome))
struct InverseTextNormalizerDigitListTests {

  private func itn(_ s: String) -> String {
    InverseTextNormalizer().normalize(s, spokenPunctuation: true)
  }

  nonisolated static let lists: [(dictated: String, expected: String)] = [
    (
      "I just feel like this 40, 20, 10 percent is just such arbitrary",
      "I just feel like this 40, 20, 10% is just such arbitrary"
    ),
    ("we tried 5, 10, 15 percent", "we tried 5, 10, 15%"),
    ("prices were 40, 20, 10 dollars", "prices were 40, 20, $10"),
    // no commas at all: still never summed, left as said
    ("the split is 40 20 10 percent", "the split is 40 20 10 percent"),
    ("the split is 100 20 percent", "the split is 100 20 percent"),
  ]

  @Test("a list of numbers is never added into one", arguments: lists)
  func listRows(row: (dictated: String, expected: String)) {
    let got = itn(row.dictated)
    #expect(got == row.expected, "\"\(row.dictated)\" gave \"\(got)\"")
  }

  nonisolated static let controls: [(dictated: String, expected: String)] = [
    // a thousands comma is part of the number (house style: no comma in a percent, millions as words)
    ("growth of 1,234 percent", "growth of 1234%"),
    ("it cost 40,000 dollars", "it cost $40,000"),
    ("it cost 1,250,000 dollars", "it cost $1.25 million"),
    // a spoken number that mixes words and digits still converts whole
    ("about twenty 5 percent", "about 25%"),
    ("about two thousand 500 dollars", "about $2,500"),
    ("about twenty five percent", "about 25%"),
    ("about 25 percent", "about 25%"),
    // an explicit "and" after a whole hundred joins one amount, as the words do
    ("it cost 100 and 5 dollars", "it cost $105"),
    ("it cost 100 and five dollars", "it cost $105"),
    ("it cost 200 and 20 dollars", "it cost $220"),
  ]

  @Test("one number, with or without a thousands comma, still converts", arguments: controls)
  func controlRows(row: (dictated: String, expected: String)) {
    let got = itn(row.dictated)
    #expect(got == row.expected, "\"\(row.dictated)\" gave \"\(got)\"")
  }

  @Test("one pass is enough: a second pass over the output changes nothing")
  func idempotent() {
    for row in Self.lists + Self.controls {
      let once = itn(row.dictated)
      #expect(itn(once) == once, "\"\(row.dictated)\" needed a second pass")
    }
  }
}
