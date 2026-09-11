import Foundation
import Testing

@testable import EnviousWisprCore

/// #2773: the marked-up view's engine. What fails when these fail is a person told the
/// cleanup removed words it kept, or shown a mark on the wrong word.
@Suite("WordDiff (#2773)", .tags(.productOutcome))
struct WordDiffTests {

  // MARK: - The founder's two treatments

  @Test("a removed filler is struck through and counted as removed")
  func aRemovedWordIsRemoved() {
    let r = WordDiff.compare(
      original: "so um the numbers are up", cleaned: "So the numbers are up.")
    #expect(r.segments.map(\.kind) == [.same, .removed, .same, .same, .same, .same])
    #expect(r.segments[1].text == "um")
    #expect(r.removedWords == 1)
    #expect(r.changedWords == 0)
    // The ORIGINAL's spelling is what renders: "so", not the cleanup's "So".
    #expect(r.segments[0].text == "so")
  }

  @Test("a replaced word is highlighted and counted as changed")
  func aReplacedWordIsChanged() {
    let r = WordDiff.compare(original: "we gonna ship it", cleaned: "We are going to ship it.")
    #expect(r.segments.first?.kind == .same)
    #expect(r.segments.filter { $0.kind == .changed }.map(\.text) == ["gonna"])
    #expect(r.removedWords == 0)
    #expect(r.changedWords >= 1)
    #expect(r.segments.filter { $0.kind == .same }.map(\.text) == ["we", "ship", "it"])
  }

  @Test("a word the cleanup added is shown highlighted in place and counted as changed")
  func anAddedWordIsShown() {
    let r = WordDiff.compare(
      original: "call the doctor tomorrow", cleaned: "Call the doctor tomorrow morning.")
    #expect(r.segments.map(\.kind) == [.same, .same, .same, .same, .added])
    #expect(r.segments.last?.text == "morning.")
    #expect(r.removedWords == 0)
    #expect(r.changedWords == 1)
  }

  // MARK: - What is NOT a change

  @Test("capitalisation and punctuation are not changes; the count is about words")
  func punctuationIsNotAChange() {
    let r = WordDiff.compare(
      original: "hello there how are you", cleaned: "Hello there, how are you?")
    #expect(r.segments.allSatisfy { $0.kind == .same })
    #expect(r.removedWords == 0)
    #expect(r.changedWords == 0)
  }

  @Test("case folds the Unicode way, not the ASCII way")
  func caseFoldsUnicode() {
    // A Greek word in capitals against its lowercase form with the final sigma.
    let greek = WordDiff.compare(original: "ΟΣ", cleaned: "ος")
    #expect(greek.segments.map(\.kind) == [.same], "\(greek.segments)")
    // German sharp s against its capital spelling.
    let german = WordDiff.compare(original: "STRASSE", cleaned: "Straße")
    #expect(german.segments.map(\.kind) == [.same], "\(german.segments)")
    // Turkish capital dotted I, whose case fold carries a combining dot no lowercase has.
    let turkish = WordDiff.compare(original: "İstanbul", cleaned: "istanbul")
    #expect(turkish.segments.map(\.kind) == [.same], "\(turkish.segments)")
    // A diacritic is a different word, and a cleanup that adds one changed the word.
    for (a, b) in [("si", "sí"), ("ou", "où"), ("cafe", "café")] {
      let r = WordDiff.compare(original: a, cleaned: b)
      #expect(r.segments.map(\.kind) == [.changed], "\(a) → \(b): \(r.segments)")
      #expect(r.changedWords == 1)
    }
  }

  @Test("identical text is all the same, and an empty side is all one kind")
  func edges() {
    let same = WordDiff.compare(original: "one two three", cleaned: "one two three")
    #expect(same.segments.allSatisfy { $0.kind == .same })
    #expect(same.legend == "0 words removed · 0 changed")

    let gone = WordDiff.compare(original: "one two three", cleaned: "")
    #expect(gone.segments.map(\.kind) == [.removed, .removed, .removed])
    #expect(gone.removedWords == 3)

    let born = WordDiff.compare(original: "", cleaned: "one two")
    #expect(born.segments.map(\.kind) == [.added, .added])
    #expect(born.changedWords == 2)

    #expect(WordDiff.compare(original: "", cleaned: "").segments.isEmpty)
  }

  @Test("the original's layout survives: newlines ride on the word before them")
  func layoutSurvives() {
    let r = WordDiff.compare(
      original: "first line\nsecond line", cleaned: "First line.\nSecond line.")
    #expect(r.segments.map(\.text) == ["first", "line", "second", "line"])
    #expect(r.segments[1].trailing == "\n")
    #expect(r.segments.allSatisfy { $0.kind == .same })
    // Rebuilding the segments gives back the original byte for byte, leading run included.
    let spaced = "  two  spaces\tand a tab\n"
    let s = WordDiff.compare(original: spaced, cleaned: "Two spaces and a tab.")
    #expect(s.segments.map { $0.text + $0.trailing }.joined() == spaced)
    // An addition after the original's last word gets one separator; nothing else is added.
    let added = WordDiff.compare(original: "call the doctor", cleaned: "Call the doctor tomorrow")
    #expect(added.segments.map { $0.text + $0.trailing }.joined() == "call the doctor tomorrow")
  }

  /// The policy the doc comment states, pinned: internal punctuation counts, a lone
  /// punctuation token counts, and a mixed hunk counts its original tokens once.
  @Test("the count policy: internal punctuation and lone tokens count; a hunk counts once")
  func countPolicy() {
    #expect(WordDiff.compare(original: "dont go", cleaned: "don't go").changedWords == 1)
    #expect(WordDiff.compare(original: "wait ...", cleaned: "wait !").changedWords == 1)
    let hunk = WordDiff.compare(original: "x", cleaned: "a b c")
    #expect(hunk.changedWords == 1, "a replacement hunk counts its original tokens, not its inserts")
    #expect(hunk.segments.filter { $0.kind == .added }.isEmpty)
  }

  @Test("the legend reads like the founder's example, in the reader's number format")
  func legend() {
    let r = WordDiff.Result(segments: [], removedWords: 1204, changedWords: 318)
    #expect(r.legend(locale: Locale(identifier: "en_US")) == "1,204 words removed · 318 changed")
    #expect(r.legend(locale: Locale(identifier: "de_DE")) == "1.204 words removed · 318 changed")
    #expect(
      WordDiff.Result(segments: [], removedWords: 1, changedWords: 0)
        .legend(locale: Locale(identifier: "en_US")) == "1 word removed · 0 changed")
  }

  /// Passage by passage (#2773, second-pass review). A global alignment matched a finished
  /// part's few words against the START of the original and marked the untouched waiting
  /// passages as removed; and a passage the splitter cut inside a run with no spaces read as
  /// two words against one.
  @Test("passages are compared with their own originals; an unreached one is all the same")
  func passagesAreComparedSeparately() {
    let r = WordDiff.compare(passages: [
      .init(original: "alpha alpha alpha alpha\n\n", cleaned: "Alpha."),
      .init(original: "alpha alpha four five six", cleaned: nil),
    ])
    #expect(r.removedWords == 3, "three of the first passage's four; none of the waiting one")
    #expect(r.changedWords == 0)
    let waiting = r.segments.suffix(5)
    #expect(waiting.allSatisfy { $0.kind == .same })
    #expect(waiting.map(\.text) == ["alpha", "alpha", "four", "five", "six"])
    // The original's whitespace between passages survives; nothing is inserted.
    #expect(r.segments.map { $0.text + $0.trailing }.joined().hasPrefix("alpha alpha alpha alpha\n\nalpha"))

    // A run with no spaces that the splitter cut in two, each half cleaned to itself.
    let noSpaces = WordDiff.compare(passages: [
      .init(original: String(repeating: "あ", count: 30), cleaned: String(repeating: "あ", count: 30)),
      .init(original: String(repeating: "あ", count: 30), cleaned: String(repeating: "あ", count: 30)),
    ])
    #expect(noSpaces.removedWords == 0 && noSpaces.changedWords == 0)
  }

  // MARK: - The algorithm, against a reference

  /// Myers in linear space against a plain quadratic LCS, on random inputs: the edit
  /// script must rebuild both sides exactly and be as short as the reference says it can be.
  /// A wrong middle snake fails the length; a wrong split fails the rebuild.
  @Test("the edit script rebuilds both sides and is minimal, on 300 random cases")
  func agreesWithTheReference() {
    var rng = SeededGenerator(seed: 2773)
    let alphabet = ["a", "b", "c", "d", "e"]
    for _ in 0..<300 {
      let n = Int.random(in: 0...14, using: &rng)
      let m = Int.random(in: 0...14, using: &rng)
      let a = (0..<n).map { _ in alphabet.randomElement(using: &rng)! }
      let b = (0..<m).map { _ in alphabet.randomElement(using: &rng)! }
      let ops = WordDiff.edits(a, b)

      var rebuiltA: [String] = []
      var rebuiltB: [String] = []
      var nonEqual = 0
      for op in ops {
        switch op {
        case .equal(let i, let j):
          #expect(a[i] == b[j])
          rebuiltA.append(a[i])
          rebuiltB.append(b[j])
        case .delete(let i):
          rebuiltA.append(a[i])
          nonEqual += 1
        case .insert(let j):
          rebuiltB.append(b[j])
          nonEqual += 1
        }
      }
      #expect(rebuiltA == a, "a=\(a) b=\(b)")
      #expect(rebuiltB == b, "a=\(a) b=\(b)")
      #expect(nonEqual == n + m - 2 * Self.lcs(a, b), "not minimal for a=\(a) b=\(b)")
    }
  }

  /// A three-hour transcript's worth of words, with a fifth of them touched, in well under
  /// a second on any supported Mac. The bound is loose on purpose: this is a smoke test for
  /// the linear-space claim, not a benchmark, and the measured figure lives on #2773.
  @Test("27,000 words with a fifth touched completes in bounded time")
  func scale() {
    var rng = SeededGenerator(seed: 27)
    let words = (0..<27_000).map { _ in "w\(Int.random(in: 0...3000, using: &rng))" }
    var cleaned: [String] = []
    for w in words {
      let roll = Int.random(in: 0..<10, using: &rng)
      if roll == 0 { continue }
      if roll == 1 {
        cleaned.append("x\(Int.random(in: 0...99, using: &rng))")
        continue
      }
      cleaned.append(w)
    }
    let start = ContinuousClock.now
    let r = WordDiff.compare(
      original: words.joined(separator: " "), cleaned: cleaned.joined(separator: " "))
    let elapsed = ContinuousClock.now - start
    #expect(r.removedWords + r.changedWords > 0)
    #expect(elapsed < .seconds(5), "\(elapsed)")
  }

  private static func lcs(_ a: [String], _ b: [String]) -> Int {
    var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 1...max(1, a.count) where i <= a.count {
      for j in 1...max(1, b.count) where j <= b.count {
        dp[i][j] = a[i - 1] == b[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
      }
    }
    return dp[a.count][b.count]
  }

  struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    mutating func next() -> UInt64 {
      state ^= state >> 12
      state ^= state << 25
      state ^= state >> 27
      return state &* 2_685_821_657_736_338_717
    }
  }
}
