import Testing

@testable import EnviousWisprPipeline

/// #2648 — cutting one long transcript into the parts the cleanup chain runs on.
///
/// **When this fails, the user's imported recording comes back with words missing, words duplicated, or
/// a passage silently truncated** — the last one because a part over the ceiling loses its end inside
/// the polisher rather than failing. Product coverage.
///
/// **The ceiling is asserted as a RANGE and the round trip as a SEQUENCE.** Two properties, and neither
/// implies the other: a splitter that drops every second sentence obeys the ceiling perfectly, and one
/// that returns the whole transcript as one part round-trips perfectly.
@Suite(.tags(.productOutcome))
struct TranscriptSplitterTests {

  // MARK: - Inputs

  /// Deterministic prose with real sentence structure: varied lengths, abbreviations, decimals,
  /// quotes and questions, all of which a punctuation rule gets wrong and a tokenizer does not.
  private static func prose(sentences: Int, seed: UInt64) -> String {
    var rng = SplitMix64(seed: seed)
    let shapes = [
      "The %@ was %@ by about %@ percent, which nobody expected.",
      "Dr. %@ said the %@ arrives at 3.5 percent, i.e. roughly %@.",
      "Was the %@ ever %@? %@ thought so.",
      "\"The %@ is %@,\" she said, \"and %@ knows it.\"",
      "%@ %@ %@.",
    ]
    let words = [
      "meeting", "transcript", "engine", "recording", "budget", "latency", "founder", "release",
      "signal", "threshold", "session", "cadence",
    ]
    var out: [String] = []
    for _ in 0..<sentences {
      let shape = shapes[Int(rng.next() % UInt64(shapes.count))]
      var filled = shape
      while let range = filled.range(of: "%@") {
        filled.replaceSubrange(range, with: words[Int(rng.next() % UInt64(words.count))])
      }
      out.append(filled)
    }
    return out.joined(separator: " ")
  }

  /// Unpunctuated output, which is what an ASR engine produces on a speaker who does not pause.
  private static func runOn(words: Int) -> String {
    (0..<words).map { "word\($0)" }.joined(separator: " ")
  }

  /// A small deterministic generator, so a failing case is reproducible from its seed rather than
  /// being a story about a run nobody can repeat.
  private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  private static func words(_ text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  // MARK: - The two properties, over many shapes at once

  /// Every part is 1...500 words, and the parts together are the input's words in order.
  ///
  /// Run over generated inputs rather than one fixture: a single example proves the splitter handles
  /// that example. The seeds are fixed, so a failure names an input that can be reproduced exactly.
  @Test(
    "every part is within the ceiling and the parts are the whole transcript, in order",
    arguments: [
      (12, UInt64(1)), (60, UInt64(2)), (140, UInt64(3)), (400, UInt64(4)), (900, UInt64(5)),
    ])
  func ceilingAndRoundTripHold(_ sentenceCount: Int, _ seed: UInt64) {
    let transcript = Self.prose(sentences: sentenceCount, seed: seed)
    let parts = TranscriptSplitter.split(transcript)

    #expect(!parts.isEmpty, "a transcript with words produced no parts")
    for (index, part) in parts.enumerated() {
      let count = TranscriptSplitter.wordCount(in: part)
      #expect(
        count >= 1 && count <= TranscriptSplitter.maximumWordsPerPart,
        "part \(index) of seed \(seed) holds \(count) words, outside 1...500")
    }
    #expect(
      parts.flatMap(Self.words) == Self.words(transcript),
      "the parts are not the transcript's words in order (seed \(seed))")
  }

  // MARK: - The cases the plan named

  @Test("a sentence of exactly the ceiling stays whole")
  func exactlyTheCeilingStaysWhole() {
    let transcript = Self.runOn(words: 500) + "."
    let parts = TranscriptSplitter.split(transcript)

    #expect(parts.count == 1)
    #expect(TranscriptSplitter.wordCount(in: parts[0]) == 500)
  }

  @Test("a sentence one word over the ceiling is cut, and loses nothing")
  func oneWordOverIsCut() {
    let transcript = Self.runOn(words: 501) + "."
    let parts = TranscriptSplitter.split(transcript)

    #expect(parts.count == 2)
    #expect(TranscriptSplitter.wordCount(in: parts[0]) == 500)
    #expect(TranscriptSplitter.wordCount(in: parts[1]) == 1)
    #expect(parts.flatMap(Self.words) == Self.words(transcript))
  }

  /// The shape unpunctuated ASR actually produces. 972 words with no full stop at all: the sentence
  /// tokenizer finds one sentence, and the word-boundary path has to do all the work.
  @Test("a 972-word run-on with no punctuation is cut at word boundaries")
  func longRunOnIsCut() {
    let transcript = Self.runOn(words: 972)
    let parts = TranscriptSplitter.split(transcript)

    #expect(parts.count == 2)
    #expect(parts.allSatisfy { TranscriptSplitter.wordCount(in: $0) <= 500 })
    #expect(parts.flatMap(Self.words) == Self.words(transcript))
  }

  /// A run-on that is packed AFTER other sentences must not swallow them: everything already packed is
  /// emitted first. Without that, the sentences before the run-on would be re-cut by the run-on's own
  /// boundaries and the part before it would exceed the ceiling.
  @Test("a run-on after ordinary sentences does not absorb them")
  func aRunOnDoesNotAbsorbWhatCameBefore() {
    let transcript = "Short one. Short two. " + Self.runOn(words: 700)
    let parts = TranscriptSplitter.split(transcript)

    #expect(parts.count >= 3)
    #expect(parts[0].contains("Short one"))
    #expect(parts.allSatisfy { TranscriptSplitter.wordCount(in: $0) <= 500 })
    #expect(parts.flatMap(Self.words) == Self.words(transcript))
  }

  /// Non-English punctuation, where a full-stop rule would find no boundaries at all and hand the
  /// whole passage to the word-boundary path.
  @Test(
    "sentences are found in scripts that do not use a full stop",
    arguments: [
      "これは最初の文です。これは二番目の文です。これは三番目の文です。",
      "هذه هي الجملة الأولى؟ وهذه هي الثانية! وهذه هي الثالثة.",
      "Πρώτη πρόταση; Δεύτερη πρόταση; Τρίτη πρόταση.",
    ])
  func nonEnglishPunctuationIsHandled(_ transcript: String) {
    let parts = TranscriptSplitter.split(transcript)

    #expect(!parts.isEmpty)
    #expect(parts.flatMap(Self.words) == Self.words(transcript))
    #expect(parts.allSatisfy { TranscriptSplitter.wordCount(in: $0) <= 500 })
  }

  // MARK: - Nothing to do

  @Test("a transcript with no words produces no parts", arguments: ["", "   ", "\n\n\t "])
  func emptyProducesNothing(_ transcript: String) {
    #expect(TranscriptSplitter.split(transcript).isEmpty)
  }

  /// The word count is whitespace runs, deliberately, because that is the definition the 500 was
  /// measured against. A tokenizer-based count would report a different number for the same text and
  /// the ceiling would quietly mean something else.
  @Test("a hyphenated compound and a contraction each count as one word")
  func wordCountMatchesTheMeasuredDefinition() {
    #expect(TranscriptSplitter.wordCount(in: "well-known") == 1)
    #expect(TranscriptSplitter.wordCount(in: "don't") == 1)
    #expect(TranscriptSplitter.wordCount(in: "  two   words  ") == 2)
  }
}
