import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// A phrase the English cleanup keeps spelled must not gain a space when it opens a line (#3240).
///
/// **When this fails, a dictation that puts "quarter past five", "the whole nine yards" or "a few
/// hundred" at the start of a new line pastes with a stray space before it.** Product coverage.
/// Expected outputs are written by hand, not read back from the normalizer.
@Suite("ITN keeps a protected phrase tight at a line start (#3240)", .tags(.productOutcome))
struct InverseTextNormalizerLineStartPadTests {

  private func english(_ s: String) -> String {
    InverseTextNormalizer().normalize(s, spokenPunctuation: false)
  }

  /// One row per protected phrase family, each opening or ending a line next to a line break.
  nonisolated static let lineStartRows: [(dictated: String, expected: String)] = [
    ("Note:\nquarter past five works.", "Note:\nquarter past five works."),
    ("Note:\nhalf to six works.", "Note:\nhalf to six works."),
    ("Note:\na quarter past five works.", "Note:\na quarter past five works."),
    ("Note:\nthe whole nine yards.", "Note:\nthe whole nine yards."),
    ("Note:\neleventh hour fixes.", "Note:\neleventh hour fixes."),
    ("Note:\na few hundred people came.", "Note:\na few hundred people came."),
    ("Note:\r\nquarter past five works.", "Note:\r\nquarter past five works."),
    ("Note:\rquarter past five works.", "Note:\rquarter past five works."),
    ("Meet at quarter past five\nthen the whole nine yards\ndone", "Meet at quarter past five\nthen the whole nine yards\ndone"),
    ("Alpha\nbeta\nquarter past five\nhalf past six", "Alpha\nbeta\nquarter past five\nhalf past six"),
  ]

  @Test("a protected phrase that opens a line gets no stray space next to the line break", arguments: lineStartRows)
  func opensALine(row: (dictated: String, expected: String)) {
    #expect(english(row.dictated) == row.expected)
  }

  /// A phrase inside a line keeps today's behavior, so the fix cannot leak past line starts.
  nonisolated static let midLineRows: [(dictated: String, expected: String)] = [
    ("Meet at quarter past five.", "Meet at quarter past five."),
    ("It was the whole nine yards, really.", "It was the whole nine yards, really."),
    ("Note: quarter past five works.", "Note: quarter past five works."),
  ]

  @Test("a protected phrase inside a line is unchanged", arguments: midLineRows)
  func insideALine(row: (dictated: String, expected: String)) {
    #expect(english(row.dictated) == row.expected)
  }
}
