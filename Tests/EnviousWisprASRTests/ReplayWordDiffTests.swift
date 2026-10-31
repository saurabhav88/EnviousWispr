import Testing

/// #4254 chunk 4: when these fail, the replay's preservation report miscounts lost or invented
/// words, hides a repeated word's loss, or treats a clip with no reference as checked.
@Suite("Replay word diff (#4254)", .tags(.harnessContract))
struct ReplayWordDiffTests {
  typealias Diff = ReplayWordDiff

  @Test("a repeated word lost once is one delete, not hidden by the other occurrence")
  func repeatedWordLoss() {
    let edits = Diff.edits(expected: Diff.tokens("no no no"), actual: Diff.tokens("no no"))
    // Which of the identical words is called lost is arbitrary; that exactly one is, is not.
    #expect(edits.count == 1)
    #expect(edits.first?.kind == .delete && edits.first?.expected == "no")
  }

  @Test("substitutions, inserts and deletes keep their order and positions")
  func orderedEdits() {
    let edits = Diff.edits(
      expected: Diff.tokens("the quick brown fox"), actual: Diff.tokens("the quack brown fox jumps")
    )
    #expect(
      edits == [
        .init(kind: .substitute, position: 1, expected: "quick", actual: "quack"),
        .init(kind: .insert, position: 4, expected: nil, actual: "jumps"),
      ])
    #expect(
      Diff.edits(expected: Diff.tokens("Hello, world."), actual: Diff.tokens("hello world")).isEmpty
    )
  }

  @Test("unspaced scripts compare character by character")
  func unspacedScripts() {
    #expect(Diff.tokens("今日は晴れ") == ["今", "日", "は", "晴", "れ"])
    let edits = Diff.edits(expected: Diff.tokens("今日は晴れ"), actual: Diff.tokens("今日晴れ"))
    #expect(edits == [.init(kind: .delete, position: 2, expected: "は", actual: nil)])
  }

  @Test("a clip without a reference is not adjudicated, never a clean comparison")
  func missingReference() {
    #expect(Diff.compare("anything", reference: nil) == .notAdjudicated)
    #expect(Diff.compare("anything", reference: "  ") == .notAdjudicated)
    #expect(Diff.compare("same words", reference: "Same words.") == .compared([]))
  }
}
