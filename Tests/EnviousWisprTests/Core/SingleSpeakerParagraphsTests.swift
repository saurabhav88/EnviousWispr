import Foundation
import Testing

@testable import EnviousWisprCore

/// #4611 T4: a one-voice transcript gets a time per natural paragraph, never per sentence, and
/// no words are lost between paragraphs. A failure here is a wrong or missing time on the page,
/// or words missing from a paragraph.
@Suite("SingleSpeakerParagraphs", .tags(.productOutcome))
struct SingleSpeakerParagraphsTests {

  /// Builds a text and its word timings from sentences, each with the pause (ms) after it.
  private func build(_ sentences: [(text: String, pauseAfterMs: Int)], msPerWord: Int = 300)
    -> (text: String, words: [ASRWordTiming])
  {
    var text = ""
    var words: [ASRWordTiming] = []
    var clock = 0
    for (index, sentence) in sentences.enumerated() {
      if index > 0 { text += " " }
      let parts = sentence.text.split(separator: " ")
      for (n, part) in parts.enumerated() {
        if n > 0 { text += " " }
        let lower = text.utf16.count
        text += part
        words.append(
          ASRWordTiming(
            word: String(part), range: lower..<text.utf16.count, startMs: clock,
            endMs: clock + msPerWord - 50))
        clock += msPerWord
      }
      clock += sentence.pauseAfterMs
    }
    return (text, words)
  }

  private func sentence(_ words: Int, end: String = ".") -> String {
    (0..<words).map { "w\($0)" }.joined(separator: " ") + end
  }

  private func slice(_ range: Range<Int>, of text: String) -> String {
    let units = Array(text.utf16)
    return String(decoding: units[range], as: UTF16.self)
  }

  @Test("a long pause at a sentence end after enough words starts a new paragraph")
  func breaksAtNaturalParagraph() throws {
    let (text, words) = build([
      (sentence(25), 300), (sentence(20), 3_000), (sentence(10), 300), (sentence(35), 0),
    ])
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    #expect(turns.count == 2)
    #expect(turns.allSatisfy { $0.speakerId == SingleSpeakerParagraphs.speakerID })
    #expect(turns[0].startMs == 0)
    #expect(turns[1].startMs == words[45].startMs)
  }

  @Test("a long pause in the middle of a sentence, or before 40 words, does not break")
  func noBreakMidSentenceOrTooShort() throws {
    let (text, words) = build([
      (sentence(30, end: ""), 3_000), (sentence(30), 300),
      (sentence(5), 3_000), (sentence(5), 0),
    ])
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    // The first long pause follows no sentence end, so it does not break. The second follows
    // a sentence end once the paragraph holds 65 words, so it breaks.
    #expect(turns.count == 2)
    #expect(turns[1].startMs == words[65].startMs)
  }

  @Test("a long pause at a sentence end before 40 words does not break")
  func noBreakBeforeFortyWords() throws {
    let (text, words) = build([(sentence(20), 5_000), (sentence(20), 0)])
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    #expect(turns.count == 1)
  }

  @Test("a stretch with no long pause breaks at the first sentence end after two minutes")
  func forcedBreakAfterTwoMinutes() throws {
    // 50 sentences of 10 words at 300 ms a word: 150 s, short pauses only.
    let (text, words) = build(Array(repeating: (sentence(10), 300), count: 50))
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    #expect(turns.count == 2)
    let firstEnd = try #require(turns[0].endMs)
    #expect(firstEnd >= SingleSpeakerParagraphs.forcedBreakMs)
    #expect(firstEnd < SingleSpeakerParagraphs.forcedBreakMs + 4_000)
  }

  @Test("the paragraphs hold every word of the text, in order")
  func noWordsLost() throws {
    let (text, words) = build([
      (sentence(45), 3_000), (sentence(45), 3_000), (sentence(45), 0),
    ])
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    #expect(turns.count == 3)
    let rebuilt = turns.map { slice($0.originalTextRange, of: text) }.joined(separator: " ")
    #expect(rebuilt == text)
  }

  @Test("an untimed word beside a pause never becomes a paragraph edge")
  func noBreakBesideUntimedWord() throws {
    let (text, words) = build([(sentence(45), 3_000), (sentence(45), 0)])
    // The first word after the long pause has no time: no break may land before or after it.
    let patched = words.enumerated().map { index, word in
      index == 45
        ? ASRWordTiming(word: word.word, range: word.range, startMs: nil, endMs: nil) : word
    }
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: patched, rawText: text))
    #expect(turns.count == 1)
  }

  @Test("a punctuation token that runs over the silence still leaves the pause, and sub-word tokens count as one word")
  func parakeetStyleTokens() throws {
    // 45 words, each timed as two tokens ("w" + "N"), then "." timed across a 3 s silence.
    var text = ""
    var tokens: [ASRWordTiming] = []
    var clock = 0
    func add(_ piece: String, _ start: Int, _ end: Int, space: Bool) {
      if space, !text.isEmpty { text += " " }
      let lower = text.utf16.count
      text += piece
      tokens.append(ASRWordTiming(word: piece, range: lower..<text.utf16.count, startMs: start, endMs: end))
    }
    func sentence(words: Int) {
      for n in 0..<words {
        add("w", clock, clock + 100, space: true)
        add("\(n)", clock + 100, clock + 250, space: false)
        clock += 300
      }
      add(".", clock, clock + 3_000, space: false)
      clock += 3_000
    }
    sentence(words: 45)
    sentence(words: 45)
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: tokens, rawText: text))
    #expect(turns.count == 2)
  }

  @Test("a pause hidden in a word that runs up to the next start still breaks (Parakeet word times)")
  func pauseInsideWordDuration() throws {
    var (text, words) = build([(sentence(45), 3_000), (sentence(45), 0)])
    // Each word ends where the next starts, as Parakeet's mapped word times do.
    words = words.indices.map { i in
      let w = words[i]
      let end = i + 1 < words.count ? words[i + 1].startMs : w.endMs
      return ASRWordTiming(word: w.word, range: w.range, startMs: w.startMs, endMs: end)
    }
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    #expect(turns.count == 2)
  }

  @Test("untimed spoken words before a timed full stop are never read as silence")
  func noPauseAcrossUntimedSpeech() throws {
    // 45 words; the last ten (3 s of speech) are untimed; then "." as its own timed token.
    var text = ""
    var tokens: [ASRWordTiming] = []
    var clock = 0
    func add(_ piece: String, _ start: Int?, _ end: Int?, space: Bool) {
      if space, !text.isEmpty { text += " " }
      let lower = text.utf16.count
      text += piece
      tokens.append(ASRWordTiming(word: piece, range: lower..<text.utf16.count, startMs: start, endMs: end))
    }
    for n in 0..<45 {
      if n >= 35 { add("u\(n)", nil, nil, space: true) } else { add("w\(n)", clock, clock + 250, space: true) }
      clock += 300
    }
    add(".", clock, clock + 100, space: false)
    clock += 400
    for n in 0..<45 {
      add("v\(n)", clock, clock + 250, space: true)
      clock += 300
    }
    add(".", clock, clock + 100, space: false)
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: tokens, rawText: text))
    #expect(turns.count == 1)
  }

  @Test("mostly untimed words give no paragraph times")
  func mostlyUntimedGivesNil() {
    let (text, words) = build([(sentence(50), 0)])
    let untimed = words.enumerated().map { index, word in
      index % 2 == 0
        ? ASRWordTiming(word: word.word, range: word.range, startMs: nil, endMs: nil) : word
    }
    #expect(SingleSpeakerParagraphs.paragraphs(words: untimed, rawText: text) == nil)
  }

  @Test("one-voice paragraph turns are stored with no speaker names")
  func storedWithoutNames() throws {
    let (text, words) = build([(sentence(45), 3_000), (sentence(45), 0)])
    let turns = try #require(SingleSpeakerParagraphs.paragraphs(words: words, rawText: text))
    let row = Transcript(text: text).mergingSpeakerFields(analysis: .single, turns: turns)
    #expect(row.turns == turns)
    #expect(row.speakerNames == nil)
    #expect(row.speakerAnalysis == .single)
  }
}
