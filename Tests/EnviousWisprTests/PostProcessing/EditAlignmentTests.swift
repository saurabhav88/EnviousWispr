import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #996 chunk 5b: alignment decides WHICH edited runs the user can be asked
/// about. If it is wrong the user is asked about a rewording, a whole
/// sentence, or a casing fix, or never asked about a real name fix.
/// Class: `.productOutcome`.
@Suite(.tags(.productOutcome)) struct EditAlignmentTests {

  /// "original→replacement" per run, so lists compare as plain strings.
  private func runs(_ pasted: String, _ edited: String) -> [String] {
    EditAlignment.align(pasted: pasted, edited: edited).runs.map { "\($0.original)→\($0.replacement)" }
  }

  @Test("a single substituted word is one run with its surface text and positions")
  func substitution() throws {
    let result = EditAlignment.align(
      pasted: "Ask Sarah to review the draft.", edited: "Ask Saira to review the draft.")
    #expect(result.runs.count == 1 && result.dropped.isEmpty)
    let run = try #require(result.runs.first)
    #expect(run.original == "Sarah" && run.replacement == "Saira")
    #expect(run.originalRange == 1..<2 && run.editedRange == 1..<2)
    #expect(run.labels == [.substitute])
  }

  @Test("pure insertion and pure deletion produce no run; they are counted drops")
  func insertionAndDeletion() {
    let inserted = EditAlignment.align(pasted: "send the report", edited: "send the full report")
    #expect(inserted.runs.isEmpty)
    #expect(inserted.dropped.map(\.reason) == [.insertionOrDeletionOnly])
    #expect(inserted.dropped[0].run.replacement == "full" && inserted.dropped[0].run.original == "")
    let deleted = EditAlignment.align(pasted: "send the full report", edited: "send the report")
    #expect(deleted.runs.isEmpty)
    #expect(deleted.dropped.map(\.reason) == [.insertionOrDeletionOnly])
    #expect(deleted.dropped[0].run.original == "full")
  }

  @Test("casing-only and punctuation-only runs are dropped by the shared shape rule")
  func casingAndPunctuationOnly() {
    let casing = EditAlignment.align(pasted: "see you monday", edited: "see you Monday")
    #expect(casing.runs.isEmpty && casing.dropped.map(\.reason) == [.casingOrPunctuationOnly])
    #expect(casing.steps.map(\.label) == [.match, .match, .casing])
    let punct = EditAlignment.align(pasted: "thanks its done", edited: "thanks it's done")
    #expect(punct.runs.isEmpty && punct.dropped.map(\.reason) == [.casingOrPunctuationOnly])
    // A join changes the word count and is NOT shape-dropped (the judge decides).
    #expect(runs("we use post hog daily", "we use PostHog daily") == ["post hog→PostHog"])
  }

  @Test("a run longer than four words on either side is dropped as too long")
  func tooLong() {
    let long = EditAlignment.align(
      pasted: "please send the quarterly numbers to the board",
      edited: "kindly forward all of our final figures to them")
    #expect(long.runs.isEmpty)
    #expect(long.dropped.map(\.reason) == [.tooLong])
    // Exactly four on each side is still a run.
    let four = runs("a b c d e", "a w x y z")
    #expect(four == ["b c d e→w x y z"])
    // Five on each side is over the limit.
    #expect(runs("a b c d e f", "a v w x y z").isEmpty)
  }

  @Test("two separate edits are two runs in source order")
  func twoRuns() {
    #expect(
      runs("Ask Sarah to ping Preeanka today", "Ask Saira to ping Priyanka today")
        == ["Sarah→Saira", "Preeanka→Priyanka"])
  }

  @Test("a single CJK token on both sides is dropped; CJK inside a spaced sentence is not")
  func cjkSingleToken() {
    let single = EditAlignment.align(pasted: "東京に行きます", edited: "東亰に行きます")
    #expect(single.runs.isEmpty && single.dropped.map(\.reason) == [.cjkSingleToken])
    // A spaced CJK particle swap is still one CJK token each side: dropped too.
    #expect(runs("メール を 送る", "メール で 送る").isEmpty)
    #expect(runs("ping 田中 tomorrow", "ping 田中さん tomorrow").count == 0)  // one CJK token each side
    #expect(runs("ping 田中 tomorrow", "ping Tanaka tomorrow") == ["田中→Tanaka"])
  }

  @Test("NFD and NFC spellings of the same word align as a match, not an edit")
  func nfdInput() {
    let nfd = "Jose\u{0301}"
    let nfc = "Jos\u{00E9}"
    let result = EditAlignment.align(pasted: "ask \(nfd) tomorrow", edited: "ask \(nfc) tomorrow")
    #expect(result.runs.isEmpty && result.dropped.isEmpty)
    // A real change next to an NFD token is still found with its surface text intact.
    let changed = EditAlignment.align(pasted: "ask \(nfd) tomorow", edited: "ask \(nfc) tomorrow")
    #expect(changed.runs.map { "\($0.original)→\($0.replacement)" } == ["tomorow→tomorrow"])
  }

  @Test("unchanged text, repeated tokens and Unicode whitespace behave deterministically")
  func unchangedRepeatedAndWhitespace() {
    #expect(EditAlignment.align(pasted: "same same same", edited: "same same same").runs.isEmpty)
    #expect(EditAlignment.align(pasted: "", edited: "").steps.isEmpty)
    // Repeated tokens: the changed one is found, not its twin.
    let rep = EditAlignment.align(pasted: "the the cat", edited: "the a cat")
    #expect(
      rep.runs.map { ($0.original, $0.replacement, $0.originalRange) }.map {
        "\($0.0)|\($0.1)|\($0.2)"
      } == ["the|a|1..<2"])
    // Unicode whitespace (no-break space, ideographic space) splits tokens too.
    #expect(runs("ask\u{00A0}Sarah\u{3000}now", "ask Saira now") == ["Sarah→Saira"])
    // Determinism: the same input gives the same steps every time.
    let a = EditAlignment.align(pasted: "one two three four", edited: "one 2 three 4")
    let b = EditAlignment.align(pasted: "one two three four", edited: "one 2 three 4")
    #expect(a == b && a.runs.count == 2)
  }

  @Test("equal-cost alignments break ties the documented way: diagonal, then delete, then insert")
  func tieBreaking() {
    // "a b" -> "b a": cost 2 either as two substitutions (diagonal twice) or
    // delete+match+insert. The diagonal wins, giving ONE two-word run.
    let result = EditAlignment.align(pasted: "a b", edited: "b a")
    #expect(result.steps.map(\.label) == [.substitute, .substitute])
    #expect(result.runs.map { "\($0.original)→\($0.replacement)" } == ["a b→b a"])
    // Mixed casing and lexical change in one run keeps both labels.
    let mixed = EditAlignment.align(pasted: "ping sarah smith", edited: "ping Sarah Smyth")
    #expect(mixed.runs.count == 1 && mixed.runs[0].labels == [.casing, .substitute])
    #expect(mixed.runs[0].original == "sarah smith" && mixed.runs[0].replacement == "Sarah Smyth")
  }

  @Test("inputs are never mutated and the drop reasons are the closed set")
  func inputsUntouched() {
    let pasted = "Ask Sarah to review."
    let edited = "Ask Saira to review."
    _ = EditAlignment.align(pasted: pasted, edited: edited)
    #expect(pasted == "Ask Sarah to review." && edited == "Ask Saira to review.")
    #expect(EditAlignment.DropReason.allCases.count == 5)
  }

  @Test("sentence decoration stays on the surface run and off its lexical core")
  func decorationAndCore() throws {
    let r = try #require(EditAlignment.align(pasted: "Ask Sarah.", edited: "Ask Saira.").runs.first)
    #expect(r.original == "Sarah." && r.replacement == "Saira.")
    #expect(r.coreOriginal == "Sarah" && r.coreReplacement == "Saira")
    let q = try #require(
      EditAlignment.align(pasted: "she said \"pree anka\" today", edited: "she said \"Priyanka\" today").runs.first)
    #expect(q.original == "\"pree anka\"" && q.coreOriginal == "pree anka" && q.coreReplacement == "Priyanka")
    // Internal apostrophes, hyphens and identifier punctuation survive.
    let h = try #require(EditAlignment.align(pasted: "use co operation now", edited: "use co-operation now").runs.first)
    #expect(h.coreReplacement == "co-operation" && h.coreOriginal == "co operation")
// Adding only an apostrophe is punctuation-only under the shared shape rule
    // (its → it's is dropped); a lexical fix keeps its internal apostrophe.
    #expect(EditAlignment.align(pasted: "call oreilly, please", edited: "call O'Reilly, please").dropped.map(\.reason) == [.casingOrPunctuationOnly])
    let o = try #require(EditAlignment.align(pasted: "call oreily, please", edited: "call O'Reilly, please").runs.first)
    #expect(o.coreReplacement == "O'Reilly" && o.original == "oreily,")
    // Decoration-only edits are dropped with their own reason.
    let deco = EditAlignment.align(pasted: "see ( it", edited: "see ) it")
    #expect(deco.runs.isEmpty && deco.dropped.map(\.reason) == [.decorationOnly])
  }

  @Test("token counts beyond the cell budget are refused as an explicit limit, never as \"no changes\"")
  func cellBudget() {
    let many = (0..<600).map { "w\($0)" }.joined(separator: " ")  // 601 × 601 cells > budget
    let result = EditAlignment.align(pasted: many, edited: many + " extra")
    #expect(result.limitExceeded && result.runs.isEmpty && result.dropped.isEmpty && result.steps.isEmpty)
    // Just inside the budget still aligns.
    let some = (0..<400).map { "w\($0)" }.joined(separator: " ")
    let ok = EditAlignment.align(pasted: some + " tail", edited: some + " tale")
    #expect(ok.limitExceeded == false && ok.runs.map { "\($0.original)→\($0.replacement)" } == ["tail→tale"])
    // One extremely long token is a single cell, not a budget problem.
    let long = String(repeating: "x", count: 50_000)
    let single = EditAlignment.align(pasted: "a \(long) b", edited: "a \(long)y b")
    #expect(single.limitExceeded == false && single.runs.count == 1)
  }
}
