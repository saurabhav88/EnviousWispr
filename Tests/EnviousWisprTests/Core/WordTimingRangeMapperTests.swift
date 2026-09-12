import Foundation
import Testing

@testable import EnviousWisprCore

/// #2809 chunk 1: what fails when these fail is a word later attributed to the wrong
/// speaker, or to a time it was never spoken at.
@Suite("WordTimingRangeMapper", .tags(.productOutcome))
struct WordTimingRangeMapperTests {

  @Test("identical sequences bind every word, even with repeats")
  func identicalSequencesBindEverything() {
    let text = "the cat sat on the mat"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("the", 0, 100), ("cat", 100, 300), ("sat", 300, 500),
      ("on", 500, 600), ("the", 600, 700), ("mat", 700, 900),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, words: words)
    #expect(bound.map(\.word) == ["the", "cat", "sat", "on", "the", "mat"])
    #expect(bound.map(\.startMs) == [0, 100, 300, 500, 600, 700])
    #expect(bound.map(\.endMs) == [100, 300, 500, 600, 700, 900])
    #expect(coverage.timed == coverage.total)
  }

  @Test("rewritten text with repeats and a punctuation-only piece: only forced matches are timed")
  func rewrittenTextRepeatsAndPunctuation() {
    // Simulates `withRescoring`: the fork keeps the ORIGINAL token timings against
    // text that vocabulary boosting rewrote. The engine's own subsequence ("well the cat
    // and ... sat well.") only fits `text` one way — using the SECOND "the"/"cat" pair
    // would leave "and" with nothing after it to match — so those six stay forced even
    // though "the" and "cat" each appear twice in `text`. Only the leftover second "the"
    // and second "cat" (never reached by any maximum alignment) stay untimed. "." is a
    // punctuation-only trailing piece the engine attached to "well" per the fork's own
    // finalization; it never appears as its own text word.
    let text = "well the cat and the cat sat well."
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("well", 0, 200), ("the", 200, 300), ("cat", 300, 500), ("and", 500, 600),
      ("sat", 900, 1100), ("well.", 1100, 1300),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 2000, words: words)
    #expect(bound.count == 8)  // "well the cat and the cat sat well." — 8 whitespace runs
    #expect(bound[0].word == "well" && bound[0].startMs == 0 && bound[0].endMs == 200)
    #expect(bound[1].word == "the" && bound[1].startMs == 200 && bound[1].endMs == 300)
    #expect(bound[2].word == "cat" && bound[2].startMs == 300 && bound[2].endMs == 500)
    #expect(bound[3].word == "and" && bound[3].startMs == 500 && bound[3].endMs == 600)
    // The second "the"/"cat" pair is never reached by any maximum alignment: untimed.
    #expect(bound[4].word == "the" && bound[4].startMs == nil && bound[4].endMs == nil)
    #expect(bound[5].word == "cat" && bound[5].startMs == nil && bound[5].endMs == nil)
    #expect(bound[6].word == "sat" && bound[6].startMs == 900 && bound[6].endMs == 1100)
    // "well." (with the trailing period) is a distinct string from "well" and unique.
    #expect(bound[7].word == "well." && bound[7].startMs == 1100 && bound[7].endMs == 1300)
    #expect(coverage.timed < coverage.total)
    #expect(coverage.timed > 0)
  }

  @Test("a genuinely ambiguous repeat stays untimed on BOTH occurrences, not a guess")
  func genuinelyAmbiguousRepeatStaysUntimed() {
    // Unlike the rewritten-text case above, nothing here forces a choice: one timed "go"
    // could equally be either occurrence, and no other word disambiguates it.
    let text = "go go"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [("go", 0, 300)]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, words: words)
    #expect(bound.map(\.word) == ["go", "go"])
    #expect(bound.allSatisfy { $0.startMs == nil && $0.endMs == nil })
    #expect(coverage.timed == 0)
  }

  @Test("no engine words at all leaves every text word untimed")
  func noEngineWordsLeavesTextUntimed() {
    let text = "hello there"
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, words: [])
    #expect(bound.map(\.word) == ["hello", "there"])
    #expect(bound.allSatisfy { $0.startMs == nil && $0.endMs == nil })
    #expect(coverage.timed == 0)
    #expect(coverage.total == "hello".utf16.count + "there".utf16.count)
  }

  @Test("a word with end before start becomes untimed but keeps its range")
  func invalidBoundsBecomeNil() {
    let text = "hello there"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("hello", 500, 100), ("there", 100, 300),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, words: words)
    #expect(bound[0].word == "hello")
    #expect(bound[0].startMs == nil && bound[0].endMs == nil)
    #expect(bound[1].startMs == 100 && bound[1].endMs == 300)
    #expect(coverage.timed == "there".utf16.count)
  }

  @Test("a negative start becomes untimed")
  func negativeStartBecomesNil() {
    let text = "hello"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [("hello", -10, 100)]
    let (bound, _) = WordTimingRangeMapper.map(text: text, audioDurationMs: 1000, words: words)
    #expect(bound[0].startMs == nil)
  }

  @Test("a timing that runs past the audio's own duration becomes untimed")
  func beyondAudioDurationBecomesNil() {
    let text = "hello"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [("hello", 0, 2000)]
    let (bound, _) = WordTimingRangeMapper.map(text: text, audioDurationMs: 1000, words: words)
    #expect(bound[0].startMs == nil && bound[0].endMs == nil)
  }

  @Test("a nil start or end on the engine word becomes untimed")
  func nilBoundsStayNil() {
    let text = "hello"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [("hello", nil, 100)]
    let (bound, _) = WordTimingRangeMapper.map(text: text, audioDurationMs: 1000, words: words)
    #expect(bound[0].startMs == nil && bound[0].endMs == nil)
  }

  @Test("an engine word with no match in the text is dropped, never attached elsewhere")
  func unmatchedEngineWordIsDropped() {
    let text = "hello there"
    // "goodbye" never appears in `text`; it must not attach to either real word.
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("hello", 0, 100), ("goodbye", 100, 200), ("there", 200, 300),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, words: words)
    #expect(bound.map(\.word) == ["hello", "there"])
    #expect(bound[0].startMs == 0 && bound[0].endMs == 100)
    #expect(bound[1].startMs == 200 && bound[1].endMs == 300)
    #expect(coverage.timed == coverage.total)
  }

  @Test(
    "range offsets are correct UTF-16 units, including a non-Latin script and a hyphenated word")
  func rangesAreCorrectUTF16Units() {
    let text = "café-style 東京 done"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("café-style", 0, 500), ("東京", 500, 800), ("done", 800, 900),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, words: words)
    #expect(bound.count == 3)
    for word in bound {
      let lower = String.Index(utf16Offset: word.range.lowerBound, in: text)
      let upper = String.Index(utf16Offset: word.range.upperBound, in: text)
      let slice = String(text[lower..<upper])
      #expect(slice == word.word)
    }
    #expect(coverage.timed == coverage.total)
  }

  @Test("legacy JSON without the new keys decodes with both fields nil")
  func legacyJSONDecodesWithNilFields() throws {
    let legacyJSON = """
      {"text":"hi","language":"en","duration":1.0,"processingTime":0.5,"backendType":"parakeet"}
      """
    let decoded = try JSONDecoder().decode(ASRResult.self, from: Data(legacyJSON.utf8))
    #expect(decoded.text == "hi")
    #expect(decoded.wordTimings == nil)
    #expect(decoded.wordTimingCoverage == nil)
  }

  @Test("empty text with no words yields zero coverage, not a crash")
  func emptyTextYieldsZeroCoverage() {
    let (bound, coverage) = WordTimingRangeMapper.map(text: "", audioDurationMs: 0, words: [])
    #expect(bound.isEmpty)
    #expect(coverage.timed == 0 && coverage.total == 0)
  }
}
