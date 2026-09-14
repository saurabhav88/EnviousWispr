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

  // MARK: - Piecewise binding (#2919)

  /// The one-piece entry and the piecewise entry with one span are the same computation.
  @Test("one piece spanning the whole text equals the whole-text map")
  func onePieceEqualsWholeTextMap() {
    let text = "the cat sat on the mat"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("the", 0, 100), ("cat", 100, 300), ("sat", 300, 500),
      ("on", 500, 600), ("the", 600, 700), ("mat", 700, 900),
    ]
    let whole = WordTimingRangeMapper.map(text: text, audioDurationMs: 1000, words: words)
    let piecewise = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: words)])
    #expect(whole.words == piecewise.words)
    #expect(whole.coverage == piecewise.coverage)
  }

  /// A token the engine split differently in ONE window ("don't" as "don" + "'t") must not
  /// cost the other window a single timing. Whole-text binding on this input also binds the
  /// first window (the LCS is exact below the cap); the piecewise row pins that the second
  /// window's mismatch is confined to itself.
  @Test("a split token in one window leaves the other window fully timed")
  func splitTokenInOneWindowIsConfinedToIt() {
    let first = "we left early"
    let second = "they don't mind"
    let text = first + " " + second
    let secondStart = first.utf16.count + 1
    let pieces = [
      WordTimingRangeMapper.Piece(
        span: 0..<first.utf16.count,
        words: [("we", 0, 100), ("left", 100, 300), ("early", 300, 600)]),
      WordTimingRangeMapper.Piece(
        span: secondStart..<text.utf16.count,
        words: [("they", 600, 700), ("don", 700, 800), ("'t", 800, 850), ("mind", 850, 1000)]),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, pieces: pieces)
    #expect(bound.map(\.word) == ["we", "left", "early", "they", "don't", "mind"])
    #expect(bound.map(\.startMs) == [0, 100, 300, 600, nil, 850])
    #expect(bound[4].range == secondStart + 5..<secondStart + 10)
    #expect(coverage.timed == coverage.total - "don't".utf16.count)
  }

  /// The failure the founder hit (#2919): a transcript long enough that engine words × text
  /// words passes the search cap. Whole-text binding gives up on the whole file once a single
  /// token differs; piecewise binding never sees more than one window.
  @Test("a long transcript with one split token stays timed when bound per window")
  func longTranscriptStaysTimedPerWindow() {
    let windowWords = 80
    let windows = 40  // 3,200 words: 3,200² > forcedAlignmentSearchCap
    var text = ""
    var pieces: [WordTimingRangeMapper.Piece] = []
    var wholeWords: [(word: String, startMs: Int?, endMs: Int?)] = []
    var ms = 0
    for w in 0..<windows {
      var pieceWords: [(word: String, startMs: Int?, endMs: Int?)] = []
      let start = text.utf16.count
      for k in 0..<windowWords {
        let token = "w\(w)x\(k)"
        if !text.isEmpty { text += " " }
        text += token
        // One window carries the engine's own split of one token.
        if w == 17, k == 3 {
          pieceWords.append((token.dropLast(2).description, ms, ms + 5))
          pieceWords.append((token.suffix(2).description, ms + 5, ms + 10))
        } else {
          pieceWords.append((token, ms, ms + 10))
        }
        ms += 10
      }
      wholeWords += pieceWords
      pieces.append(WordTimingRangeMapper.Piece(span: start..<text.utf16.count, words: pieceWords))
    }
    #expect(
      wholeWords.count * (windows * windowWords) > WordTimingRangeMapper.forcedAlignmentSearchCap)

    let whole = WordTimingRangeMapper.map(text: text, audioDurationMs: ms, words: wholeWords)
    #expect(whole.coverage.timed == 0, "the whole-text search gives up past the cap")

    let piecewise = WordTimingRangeMapper.map(text: text, audioDurationMs: ms, pieces: pieces)
    let untimed = piecewise.words.filter { $0.startMs == nil }
    #expect(untimed.map(\.word) == ["w17x3"])
    #expect(piecewise.coverage.timed == piecewise.coverage.total - "w17x3".utf16.count)
  }

  /// Text runs outside every span stay untimed; a window with no words times nothing.
  @Test("runs outside every span and windows without words stay untimed")
  func runsOutsideSpansStayUntimed() {
    let text = "alpha beta gamma delta"
    let pieces = [
      WordTimingRangeMapper.Piece(span: 0..<5, words: [("alpha", 0, 100)]),
      WordTimingRangeMapper.Piece(span: 6..<10, words: []),
      WordTimingRangeMapper.Piece(span: 17..<22, words: [("delta", 300, 400)]),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1000, pieces: pieces)
    #expect(bound.map(\.startMs) == [0, nil, nil, 300])
    #expect(coverage.timed == "alphadelta".utf16.count)
  }

  // MARK: - Space-free scripts (#2838)

  /// WhisperKit's own Japanese fixture (`testSplitToWordTokensJapanese`): the text has no
  /// spaces, so it is one run; the engine's token groups laid end to end ARE the run, and each
  /// group becomes one timed entry.
  @Test("a Japanese run is carved into one timed entry per engine token group")
  func japaneseRunIsCarvedPerEngineWord() {
    let text = "こんにちは、世界！これはテストですよね？"
    let groups = ["こんにちは", "、", "世界", "！", "これは", "テ", "スト", "です", "よね", "？"]
    var words: [(word: String, startMs: Int?, endMs: Int?)] = []
    for (i, g) in groups.enumerated() { words.append((g, i * 100, i * 100 + 100)) }
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 2_000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: words)])
    #expect(bound.map(\.word) == groups)
    #expect(bound.map(\.startMs) == groups.indices.map { $0 * 100 })
    #expect(bound.first?.range == 0..<5)
    #expect(bound[1].range == 5..<6)
    #expect(bound.last?.range == text.utf16.count - 1..<text.utf16.count)
    #expect(coverage.timed == coverage.total)
    #expect(coverage.total == text.utf16.count)
  }

  /// One group that does not match the text aborts the walk; the run falls through to the
  /// forced binding, which times nothing on a single run, exactly as before.
  @Test("a mismatched group aborts the carve and the run stays one untimed entry")
  func mismatchedGroupAbortsTheCarve() {
    let text = "こんにちは世界"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("こんにちは", 0, 100), ("世畍", 100, 200),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1_000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: words)])
    #expect(bound.count == 1)
    #expect(bound.first?.startMs == nil)
    #expect(coverage.timed == 0)
  }

  /// A spaced script never reaches the carve: several runs, so the forced binding decides.
  @Test("a spaced run set is never carved, even when the groups concatenate to it")
  func spacedScriptIsNeverCarved() {
    let text = "hello world"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("hel", 0, 50), ("lo", 50, 100), ("world", 100, 200),
    ]
    let (bound, _) = WordTimingRangeMapper.map(text: text, audioDurationMs: 1_000, words: words)
    #expect(bound.map(\.word) == ["hello", "world"])
    #expect(bound.map(\.startMs) == [nil, 100])
  }

  /// A group with a leading space (WhisperKit's spaced-script tokens) still carves when the
  /// piece is one run, and the ranges skip nothing.
  @Test("groups with engine-side spaces carve by their non-space scalars")
  func groupsWithSpacesCarveByScalars() {
    let text = "世界です"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [(" 世界", 0, 100), (" です", 100, 200)]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1_000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: words)])
    #expect(bound.map(\.range) == [0..<2, 2..<4])
    #expect(coverage.timed == 4)
  }

  /// A spaced-language window holding ONE word is not carved, even though its groups
  /// concatenate to the run: WhisperKit's "don" + "'t" are sub-word pieces of a spaced word
  /// (cloud review of PR #2930).
  @Test("a one-word English window is not carved")
  func oneWordEnglishWindowIsNotCarved() {
    let text = "don't"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [("don", 0, 50), ("'t", 50, 100)]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1_000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: words)])
    #expect(bound.map(\.word) == ["don't"])
    #expect(bound.first?.startMs == nil)
    #expect(coverage.timed == 0)
    #expect(!WordTimingRangeMapper.isSpaceFreeScript("don't"))
    #expect(WordTimingRangeMapper.isSpaceFreeScript("東京"))
    #expect(WordTimingRangeMapper.isSpaceFreeScript("สวัสดี"))
  }

  /// A group boundary inside a grapheme cluster (a base kana and its combining dakuten in
  /// separate groups) must not carve a range that bisects a Character: the walk aborts.
  @Test("a group boundary inside a grapheme cluster aborts the carve")
  func groupBoundaryInsideAClusterAborts() {
    // か + U+3099 (combining dakuten) is one grapheme cluster of two scalars.
    let text = "か\u{3099}き"
    let words: [(word: String, startMs: Int?, endMs: Int?)] = [
      ("か", 0, 50), ("\u{3099}き", 50, 100),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1_000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: words)])
    #expect(bound.count == 1)
    #expect(coverage.timed == 0)
    // The same text with the boundary ON the cluster edge carves.
    let aligned: [(word: String, startMs: Int?, endMs: Int?)] = [("か\u{3099}", 0, 50), ("き", 50, 100)]
    let (bound2, coverage2) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1_000,
      pieces: [WordTimingRangeMapper.Piece(span: 0..<text.utf16.count, words: aligned)])
    #expect(bound2.map(\.range) == [0..<2, 2..<3])
    #expect(coverage2.timed == coverage2.total)
  }

  /// A piece WITH words whose span holds no text run (it covers the space between two runs)
  /// is skipped and the pieces after it still bind. Found by the #2920 night battery: the
  /// earlier rows only had an empty-WORDS piece, which the loop skips before that guard.
  @Test("a piece with words but no text run is skipped, and later pieces still bind")
  func pieceWithWordsButNoRunIsSkipped() {
    let text = "alpha beta"
    let pieces = [
      WordTimingRangeMapper.Piece(span: 0..<5, words: [("alpha", 0, 100)]),
      WordTimingRangeMapper.Piece(span: 5..<6, words: [("ghost", 100, 150)]),
      WordTimingRangeMapper.Piece(span: 6..<10, words: [("beta", 150, 300)]),
    ]
    let (bound, coverage) = WordTimingRangeMapper.map(
      text: text, audioDurationMs: 1_000, pieces: pieces)
    #expect(bound.map(\.startMs) == [0, 150])
    #expect(coverage.timed == coverage.total)
  }
}
