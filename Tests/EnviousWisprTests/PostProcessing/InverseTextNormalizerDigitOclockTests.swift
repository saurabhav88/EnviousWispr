import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// A digit hour before "o'clock" keeps its hour (#4991).
///
/// **When this fails, a dictated "at 3 o'clock" pastes "at 30 'clock"**, a wrong time that AI
/// polish then turns into "30:00". Product coverage. The engine sometimes writes the hour as a
/// digit; the digit-read pass must not read the "o" of "o'clock" as a spoken zero. The controls
/// pin what must NOT change: a spelled hour still becomes "3:00", and a spoken "o" between
/// numbers is still a zero.
@Suite("ITN keeps a digit hour before o'clock (#4991)", .tags(.productOutcome))
struct InverseTextNormalizerDigitOclockTests {

  private func itn(_ s: String) -> String {
    InverseTextNormalizer().normalize(s, spokenPunctuation: true)
  }

  nonisolated static let rows: [(dictated: String, expected: String)] = [
    ("3 o'clock", "3 o'clock"),
    ("10 o'clock", "10 o'clock"),
    ("12 o'clock", "12 o'clock"),
    ("let's meet at 3 o'clock tomorrow", "let's meet at 3 o'clock tomorrow"),
    ("let's meet at 3 o'clock on Friday", "let's meet at 3 o'clock on Friday"),
    ("it starts at 3 o'clock.", "it starts at 3 o'clock."),
    ("it starts at 3 o\u{2019}clock", "it starts at 3 o\u{2019}clock"),
    ("it starts at 3 oclock", "it starts at 3 oclock"),
    ("it starts at 3 O'clock", "it starts at 3 O'clock"),
    ("it starts at 3 O'Clock", "it starts at 3 O'Clock"),
    ("seat 2 O'Neil by the door", "seat 2 O'Neil by the door"),
    ("O'Brien is in room 3 o 5", "O'Brien is in room 305"),
    // controls: behavior from before #4991
    ("it starts at three o'clock", "it starts at 3:00"),
    ("the code is two o five", "the code is 205"),
    ("go to room 3 o 5", "go to room 305"),
    ("type \u{2018}3 o\u{2019} here", "type \u{2018}30\u{2019} here"),
  ]

  @Test("a digit hour before o'clock is kept", arguments: rows)
  func row(row: (dictated: String, expected: String)) {
    let got = itn(row.dictated)
    #expect(got == row.expected, "\"\(row.dictated)\" gave \"\(got)\"")
  }
}
