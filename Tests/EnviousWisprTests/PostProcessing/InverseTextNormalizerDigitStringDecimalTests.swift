import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// A number read out digit by digit and followed by "point" or "dot" is one decimal (#2874).
///
/// **When this fails, a dictated "two four oh seven point one two three" pastes 24070.123, a
/// plausible number that is not what was said, or "one two dot three four" stays as words.**
/// Product coverage. The nine-row table is the issue's own repro, measured with the real
/// normalizer before the fix; the controls pin what must NOT change: a lone "oh" is a word, a
/// cardinal before "point" still reads as a cardinal, and a multi-dot chain stays shielded.
@Suite("ITN reads a digit string before point/dot as one decimal (#2874)", .tags(.productOutcome))
struct InverseTextNormalizerDigitStringDecimalTests {

  private func itn(_ s: String) -> String {
    InverseTextNormalizer().normalize(s, spokenPunctuation: true)
  }

  nonisolated static let issueTable: [(id: String, dictated: String, expected: String)] = [
    ("D", "the build is two four oh seven point one two three", "the build is 2407.123"),
    ("A", "the build is two four oh seven dot one two three", "the build is 2407.123"),
    ("F", "call oh seven point one", "call 07.1"),
    ("H", "call four oh seven point one", "call 407.1"),
    ("J", "version one two dot three four", "version 12.34"),
    ("B", "the build is 2407 dot one two three", "the build is 2407.123"),
    ("G", "call seven point one two three", "call 7.123"),
    ("I", "version two point one two three", "version 2.123"),
    ("E", "call two four oh seven", "call 2407"),
  ]

  @Test("the issue's nine rows", arguments: issueTable)
  func issueRows(row: (id: String, dictated: String, expected: String)) {
    let got = itn(row.dictated)
    #expect(got == row.expected, "row \(row.id): \"\(row.dictated)\" gave \"\(got)\"")
  }

  @Test("one pass is enough: a second pass over the output changes nothing")
  func idempotent() {
    for row in Self.issueTable {
      let once = itn(row.dictated)
      #expect(itn(once) == once, "row \(row.id) needed a second pass")
    }
  }

  nonisolated static let controls: [(dictated: String, expected: String)] = [
    // a lone "oh" is a word, before and after the fix
    ("oh ok let us wait", "oh ok let us wait"),
    ("oh point five is fine", "oh point five is fine"),
    // a cardinal before "point" still reads as a cardinal, never as digits
    ("twenty five point three", "25.3"),
    ("one hundred forty seven point one seven", "147.17"),
    // the everyday noun stays
    ("at this point one thing matters", "at this point one thing matters"),
    // a multi-dot chain is shielded from the decimal pass
    ("one nine two dot one six eight dot one dot one", "one nine two dot one six eight dot one dot one"),
    // a digit string has no length cap, so a scale word can push it past what Int holds; the
    // decimal pass leaves the match alone instead of trapping in the heart path (local Codex,
    // round 1), and the later digit-read pass then formats the ten digits as a phone number
    (
      "nine nine nine nine nine nine nine nine nine nine point one billion",
      "999-999-9999 point 1 billion"
    ),
  ]

  @Test("what must not move", arguments: controls)
  func controlRows(row: (dictated: String, expected: String)) {
    #expect(itn(row.dictated) == row.expected, "\"\(row.dictated)\"")
  }
}
