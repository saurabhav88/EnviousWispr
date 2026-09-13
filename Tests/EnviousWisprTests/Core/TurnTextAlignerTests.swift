import Foundation
import Testing

@testable import EnviousWisprCore

/// #2851 chunk 1: the alignment that replaces the second cleanup. When these fail, a turn
/// shows another speaker's words, loses words, or claims a clean cut it did not have.
@Suite("TurnTextAligner", .tags(.productOutcome))
struct TurnTextAlignerTests {

  /// A turn whose range is the UTF-16 span of `words` inside `raw` (first word start to last
  /// word end), the way `TurnAssembler` derives it from entries.
  private func turn(_ id: String, _ speaker: String, in raw: String, from: String, to: String)
    -> Turn
  {
    let u = Array(raw.utf16)
    func find(_ s: String, after: Int = 0) -> Int {
      let needle = Array(s.utf16)
      var i = after
      while i + needle.count <= u.count {
        if Array(u[i..<(i + needle.count)]) == needle { return i }
        i += 1
      }
      Issue.record("'\(s)' not found in raw")
      return 0
    }
    let lower = find(from)
    let toStart = find(to, after: lower)
    let upper = toStart + to.utf16.count
    return Turn(id: id, speakerId: speaker, startMs: 0, endMs: 0, originalTextRange: lower..<upper)
  }

  private func placed(_ raw: String, cleaned: String?, wasPolished: Bool = true)
    -> TurnTextAligner.Passage
  {
    let lead = raw.prefix { $0.isWhitespace }.utf16.count
    return .init(
      placement: .placed(rawRange: 0..<raw.utf16.count, contentRange: lead..<raw.utf16.count),
      cleaned: cleaned, wasPolished: wasPolished)
  }

  private func text(_ outcome: TurnTextAligner.Outcome, _ id: String) -> TurnTextAligner.TurnText? {
    outcome.texts.first { $0.turnID == id }
  }

  @Test("an unchanged passage cuts exactly at the raw turn boundaries")
  func equalOnlyCutsAtBoundaries() {
    let raw = "hello there friend. yes it is."
    let turns = [
      turn("a", "A", in: raw, from: "hello", to: "friend."),
      turn("b", "B", in: raw, from: "yes", to: "is."),
    ]
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: raw)], turns: turns)
    #expect(text(out, "a")?.processedText == "hello there friend.")
    #expect(text(out, "b")?.processedText == "yes it is.")
    #expect(text(out, "a")?.cleanedCut == true && text(out, "a")?.wasPolished == true)
    #expect(out.fallbacks.isEmpty)
  }

  @Test("a removal inside a turn stays inside that turn")
  func removalInsideTurn() {
    let raw = "so um I think we should go. okay sure."
    let turns = [
      turn("a", "A", in: raw, from: "so", to: "go."),
      turn("b", "B", in: raw, from: "okay", to: "sure."),
    ]
    let cleaned = "so I think we should go. okay sure."
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == "so I think we should go.")
    #expect(text(out, "b")?.processedText == "okay sure.")
    #expect(out.fallbacks.isEmpty)
  }

  @Test("a change inside a turn (delete plus insert) stays inside that turn")
  func changeInsideTurn() {
    let raw = "we was going home. right, and then?"
    let turns = [
      turn("a", "A", in: raw, from: "we", to: "home."),
      turn("b", "B", in: raw, from: "right,", to: "then?"),
    ]
    let cleaned = "we were going home. right, and then?"
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == "we were going home.")
    #expect(text(out, "b")?.processedText == "right, and then?")
  }

  @Test("a rewrite that straddles a boundary makes both turns keep their raw words")
  func straddlingHunkFailsBothTurns() {
    let raw = "I did not approve it at all. no way."
    let turns = [
      turn("a", "A", in: raw, from: "I", to: "not"),
      turn("b", "B", in: raw, from: "approve", to: "all."),
      turn("c", "C", in: raw, from: "no way.", to: "way."),
    ]
    // The model rewrote across A|B: "did not approve" became "never approved".
    let cleaned = "I never approved it at all. no way."
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == nil)
    #expect(text(out, "b")?.processedText == nil)
    #expect(out.fallbacks["a"] == .boundary && out.fallbacks["b"] == .boundary)
    #expect(text(out, "c")?.processedText == "no way.", "the untouched neighbour is unaffected")
  }

  @Test("a repeated word removed at a boundary is ambiguous: both turns keep raw words")
  func repeatedWordAtBoundaryIsAmbiguous() {
    let raw = "are you sure yes yes I am."
    let turns = [
      turn("a", "A", in: raw, from: "are", to: "yes"),
      turn("b", "B", in: raw, from: "yes I", to: "am."),
    ]
    // Turn A ends with "yes", turn B starts with "yes"; the cleanup kept one.
    let cleaned = "are you sure yes I am."
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == nil)
    #expect(text(out, "b")?.processedText == nil)
  }

  @Test("a pure insertion at a boundary goes to the preceding turn and moves no raw word")
  func insertionAtBoundaryGoesToPrecedingTurn() {
    let raw = "we leave at nine. fine."
    let turns = [
      turn("a", "A", in: raw, from: "we", to: "nine."),
      turn("b", "B", in: raw, from: "fine.", to: "fine."),
    ]
    let cleaned = "we leave at nine tomorrow. fine."
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    // "nine." and "nine" compare EQUAL under the punctuation-blind key, so "tomorrow." is a
    // pure insertion after A's last word: attributed to A, and no raw word moved.
    #expect(text(out, "a")?.processedText == "we leave at nine tomorrow.")
    #expect(text(out, "b")?.processedText == "fine.")
    // A change on A's last word ("nine." to "ten.") has one owner and repeats nothing across
    // the boundary, so it is attributed to A; only a repeated word (see the test above)
    // makes a boundary ambiguous.
    let cleaned3 = "we leave at ten. fine."
    let out3 = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned3)], turns: turns)
    #expect(text(out3, "a")?.processedText == "we leave at ten.")
    #expect(text(out3, "b")?.processedText == "fine.")
    // A genuine pure insertion mid-turn is attributed.
    let cleaned2 = "we leave at exactly nine. fine."
    let out2 = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned2)], turns: turns)
    #expect(text(out2, "a")?.processedText == "we leave at exactly nine.")
    #expect(text(out2, "b")?.processedText == "fine.")
  }

  @Test("a turn spanning two passages joins its pieces with the raw separator, once")
  func turnSpanningTwoPassages() {
    let raw = "first part ends here and continues there. done."
    let turns = [
      turn("a", "A", in: raw, from: "first", to: "there."),
      turn("b", "B", in: raw, from: "done.", to: "done."),
    ]
    let cut = "first part ends here".utf16.count
    let p1 = TurnTextAligner.Passage(
      placement: .placed(rawRange: 0..<cut, contentRange: 0..<cut), cleaned: "first part ends here", wasPolished: true)
    let rest = String(decoding: Array(raw.utf16)[cut...], as: UTF16.self)  // " and continues there. done."
    let p2 = TurnTextAligner.Passage(
      placement: .placed(rawRange: cut..<raw.utf16.count, contentRange: (cut + 1)..<raw.utf16.count), cleaned: "and continues there. done.",
      wasPolished: true)
    _ = rest
    let out = TurnTextAligner.align(rawText: raw, passages: [p1, p2], turns: turns)
    #expect(text(out, "a")?.processedText == "first part ends here and continues there.")
    #expect(text(out, "b")?.processedText == "done.")
  }

  @Test("an unplaceable passage poisons the raw interval up to the next placed one")
  func unplaceablePassageFallsBack() {
    let raw = "alpha beta. gamma delta. epsilon zeta."
    let turns = [
      turn("a", "A", in: raw, from: "alpha", to: "beta."),
      turn("b", "B", in: raw, from: "gamma", to: "delta."),
      turn("c", "C", in: raw, from: "epsilon", to: "zeta."),
    ]
    let first = "alpha beta.".utf16.count
    let last = "alpha beta. gamma delta.".utf16.count
    let passages = [
      TurnTextAligner.Passage(
        placement: .placed(rawRange: 0..<first, contentRange: 0..<first), cleaned: "alpha beta.",
        wasPolished: true),
      TurnTextAligner.Passage(placement: .unplaceable, cleaned: "gamma delta.", wasPolished: true),
      // The unplaceable passage's words ride in the next passage's leading gap, as the
      // coordinator's scan produces them: raw range from the previous end, content from the
      // found piece.
      TurnTextAligner.Passage(
        placement: .placed(rawRange: first..<raw.utf16.count, contentRange: (last + 1)..<raw.utf16.count),
        cleaned: "epsilon zeta.", wasPolished: true),
    ]
    let out = TurnTextAligner.align(rawText: raw, passages: passages, turns: turns)
    #expect(text(out, "a")?.processedText == "alpha beta.")
    #expect(text(out, "b")?.processedText == nil && out.fallbacks["b"] == .unplaced)
    #expect(text(out, "c")?.processedText == "epsilon zeta.")
  }

  @Test("a passage not yet cleaned leaves its turns raw and unreached")
  func unreachedPassage() {
    let raw = "one two. three four."
    let turns = [
      turn("a", "A", in: raw, from: "one", to: "two."),
      turn("b", "B", in: raw, from: "three", to: "four."),
    ]
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: nil)], turns: turns)
    #expect(text(out, "a")?.processedText == nil && out.fallbacks["a"] == .unreached)
    #expect(text(out, "b")?.processedText == nil && out.fallbacks["b"] == .unreached)
  }

  @Test("a failed part aligns its floor text but reports wasPolished false")
  func failedPartKeepsFloorTextUnpolished() {
    let raw = "one two. three four."
    let turns = [
      turn("a", "A", in: raw, from: "one", to: "two."),
      turn("b", "B", in: raw, from: "three", to: "four."),
    ]
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: raw, wasPolished: false)], turns: turns)
    #expect(text(out, "a")?.processedText == "one two.")
    #expect(text(out, "a")?.cleanedCut == true)
    #expect(text(out, "a")?.wasPolished == false)
    #expect(text(out, "b")?.wasPolished == false)
  }

  @Test("a turn the cleanup emptied keeps its raw words and is disclosed")
  func emptiedTurnKeepsRawWords() {
    let raw = "we should go now. yeah. and then we left."
    let turns = [
      turn("a", "A", in: raw, from: "we should", to: "now."),
      turn("b", "B", in: raw, from: "yeah.", to: "yeah."),
      turn("c", "C", in: raw, from: "and then", to: "left."),
    ]
    let cleaned = "we should go now. and then we left."
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == "we should go now.")
    #expect(text(out, "b")?.processedText == nil && out.fallbacks["b"] == .emptied)
    #expect(text(out, "c")?.processedText == "and then we left.")
  }

  @Test("a repeated PHRASE across a boundary is ambiguous: both turns keep raw words")
  func repeatedPhraseAcrossBoundaryIsAmbiguous() {
    let raw = "go now go now please"
    let turns = [
      turn("a", "A", in: raw, from: "go now", to: "now"),
      turn("b", "B", in: raw, from: "go now please", to: "please"),
    ]
    // Myers keeps one "go now" and deletes the other; which speaker kept it is a guess.
    let cleaned = "go now please"
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == nil && text(out, "b")?.processedText == nil)
    #expect(out.fallbacks["a"] == .boundary && out.fallbacks["b"] == .boundary)
  }

  @Test("a repeat that is NOT at the edge of the deleted run is still ambiguous")
  func nonAdjacentRepeatAcrossBoundaryIsAmbiguous() {
    let raw = "go now yes go now please"
    let turns = [
      turn("a", "A", in: raw, from: "go now", to: "now"),
      turn("b", "B", in: raw, from: "yes go now please", to: "please"),
    ]
    // Myers deletes B's "yes go now" and keeps A's "go now"; the cleanup could equally have
    // removed A's repetition and B's "yes", leaving B's "go now please" (chunk 1 review r2).
    let cleaned = "go now please"
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == nil && text(out, "b")?.processedText == nil)
    #expect(out.fallbacks["a"] == .boundary && out.fallbacks["b"] == .boundary)
  }

  @Test("a deleted filler at a boundary that repeats nothing is attributed, not failed")
  func distinctFillerAtBoundaryIsAttributed() {
    let raw = "life's too short. like you know that."
    let turns = [
      turn("a", "A", in: raw, from: "life's", to: "short."),
      turn("b", "B", in: raw, from: "like", to: "that."),
    ]
    let cleaned = "life's too short. you know that."
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: cleaned)], turns: turns)
    #expect(text(out, "a")?.processedText == "life's too short.")
    #expect(text(out, "b")?.processedText == "you know that.")
  }

  @Test("a passage in the middle of a turn that lost all its words does not come back via the join")
  func joinNeverRestoresDeletedWords() {
    let raw = "one um two"
    let turns = [turn("a", "A", in: raw, from: "one", to: "two")]
    let passages = [
      TurnTextAligner.Passage(
        placement: .placed(rawRange: 0..<3, contentRange: 0..<3), cleaned: "one", wasPolished: true),
      TurnTextAligner.Passage(
        placement: .placed(rawRange: 3..<6, contentRange: 4..<6), cleaned: "", wasPolished: true),
      TurnTextAligner.Passage(
        placement: .placed(rawRange: 6..<10, contentRange: 7..<10), cleaned: "two", wasPolished: true),
    ]
    let out = TurnTextAligner.align(rawText: raw, passages: passages, turns: turns)
    #expect(text(out, "a")?.processedText == "one two")
  }

  @Test("a space-free passage is one token and aligns whole or falls back whole")
  func spaceFreePassage() {
    let raw = "今日は天気がいいですね"
    let turns = [turn("a", "A", in: raw, from: "今日は", to: "ですね")]
    let out = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: raw)], turns: turns)
    #expect(text(out, "a")?.processedText == raw)
    // Two turns inside one space-free token: the token straddles them, both fall back.
    let split = [
      turn("a", "A", in: raw, from: "今日は", to: "天気"),
      turn("b", "B", in: raw, from: "がいい", to: "ですね"),
    ]
    let out2 = TurnTextAligner.align(
      rawText: raw, passages: [placed(raw, cleaned: raw)], turns: split)
    #expect(text(out2, "a")?.processedText == nil && text(out2, "b")?.processedText == nil)
  }

  @Test("tokens carry the raw UTF-16 range of their own characters, never the folded key")
  func tokenOffsetsFollowOriginalCharacters() {
    let text = "  İstanbul  straße done"
    let tokens = WordDiff.tokenize(text, locale: Locale(identifier: "tr"))
    let u = Array(text.utf16)
    for t in tokens {
      #expect(String(decoding: u[t.range], as: UTF16.self) == t.text)
    }
    #expect(tokens.map(\.text) == ["İstanbul", "straße", "done"])
  }
}
