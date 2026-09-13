import Foundation
import Testing

@testable import EnviousWisprCore

/// #2810 chunk 1: what fails when these fail is a real user-visible defect once phase 4
/// renders turns — a word attributed to the wrong speaker, dropped, or duplicated.
@Suite("TurnAssembler", .tags(.productOutcome))
struct TurnAssemblerTests {

  private func entry(_ word: String, _ lower: Int, _ upper: Int, _ start: Int?, _ end: Int?)
    -> ASRWordTiming
  {
    ASRWordTiming(word: word, range: lower..<upper, startMs: start, endMs: end)
  }

  /// UTF-16-offset slicing, matching how `TurnTextAligner` reads a turn's raw text —
  /// `Range(_:in:)` does not accept a bare `Range<Int>`.
  private func slice(_ range: Range<Int>, of text: String) -> String {
    let lower = String.Index(utf16Offset: range.lowerBound, in: text)
    let upper = String.Index(utf16Offset: range.upperBound, in: text)
    return String(text[lower..<upper])
  }

  @Test("every entry lands in exactly one turn, in order, with no loss or duplication")
  func noLostOrReassignedWords() {
    let entries = [
      entry("hello", 0, 5, 0, 200), entry("there", 6, 11, 200, 500),
      entry("hi", 12, 14, 600, 800), entry("back", 15, 19, 800, 1000),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 600, endMs: 1000, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.count == 2)
    #expect(turns[0].speakerId == "A")
    #expect(turns[1].speakerId == "B")
    // Every original entry accounted for: the two turns' ranges cover exactly the
    // entries' own spans, first-to-last, with none dropped or duplicated.
    #expect(turns[0].originalTextRange == 0..<11)
    #expect(turns[1].originalTextRange == 12..<19)
  }

  @Test(
    "a mixed A-to-B-to-A fixture with punctuation, numerals and an untimed span: every entry attributed exactly once, no forbidden regrouping"
  )
  func mixedFixtureNoRegroupingAcrossSpeakerChanges() {
    let text = "Hi, I'm 24. Well, nice to meet you. Yeah, likewise."
    // Entries: "Hi," / "I'm" / "24." (speaker A) — "Well," / "nice" (speaker B) — "to"
    // (untimed, so "unknown"; with the #2851 fold OFF, as shipped, it splits the B turn) —
    // "meet" / "you." (speaker B again, a SEPARATE turn since "unknown" sits between them)
    // — "Yeah," (unknown, beyond tolerance) — "likewise." (speaker A again, must NOT merge
    // back into the FIRST A turn just because the speaker recurs).
    let entries: [ASRWordTiming] = [
      entry("Hi,", 0, 3, 0, 300),
      entry("I'm", 4, 7, 300, 500),
      entry("24.", 8, 11, 500, 700),
      entry("Well,", 12, 17, 5000, 5300),
      entry("nice", 18, 22, 5300, 5600),
      entry("to", 23, 25, nil, nil),  // untimed span
      entry("meet", 26, 30, 5900, 6100),
      entry("you.", 31, 35, 6100, 6400),
      entry("Yeah,", 36, 41, 50_000, 50_200),
      entry("likewise.", 42, 51, 900, 1100),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 700, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 5000, endMs: 6400, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)

    // Every entry belongs to exactly one turn, under its expected speaker, in original order.
    let bySpeaker = turns.map(\.speakerId)
    #expect(bySpeaker == ["A", "B", "unknown", "B", "unknown", "A"])
    // The A speaker (and B speaker) recurring later must NOT merge back into an earlier
    // same-speaker turn once a different speaker (even "unknown") has intervened — no word
    // moves across an established speaker change (addendum §3 C).
    #expect(turns.count == 6)

    // Each turn's raw-text slice equals exactly its member entries' span, whitespace
    // included, sliced from the SAME text the entries' ranges were computed against.
    #expect(slice(turns[0].originalTextRange, of: text) == "Hi, I'm 24.")
    #expect(slice(turns[1].originalTextRange, of: text) == "Well, nice")
    #expect(slice(turns[2].originalTextRange, of: text) == "to")
    #expect(slice(turns[3].originalTextRange, of: text) == "meet you.")
    #expect(slice(turns[4].originalTextRange, of: text) == "Yeah,")
    #expect(slice(turns[5].originalTextRange, of: text) == "likewise.")

    // With the #2851 fold ON (the internal step, exercised directly since the shipped
    // constant is off): "to" folds back into B and B's halves coalesce; "Yeah," sits at
    // 50 s while "likewise." is at 0.9 s, an out-of-order timing that is NOT closeness, so
    // it folds to the previous turn, B, not forward.
    let groups = TurnAssembler.foldingTinyUnknownGroups([
      ("A", Array(entries[0..<3])), ("B", Array(entries[3..<5])), ("unknown", [entries[5]]),
      ("B", Array(entries[6..<8])), ("unknown", [entries[8]]), ("A", [entries[9]]),
    ])
    let folded = TurnAssembler.coalescingAdjacentSpeakers(groups)
    #expect(folded.map(\.speaker) == ["A", "B", "A"])
    #expect(folded[1].entries.map(\.word) == ["Well,", "nice", "to", "meet", "you.", "Yeah,"])

    // No entry lost or duplicated: every entry's range appears inside exactly one turn's
    // range, and the union of all turn ranges accounts for every entry.
    var coveredEntries = 0
    for entry in entries {
      let owners = turns.filter {
        $0.originalTextRange.lowerBound <= entry.range.lowerBound
          && entry.range.upperBound <= $0.originalTextRange.upperBound
      }
      #expect(owners.count == 1, "entry \(entry.word) must belong to exactly one turn")
      coveredEntries += 1
    }
    #expect(coveredEntries == entries.count)
  }

  @Test("adjacent same-speaker entries group into one turn; a speaker change starts a new one")
  func adjacencyGrouping() {
    let entries = [
      entry("a", 0, 1, 0, 100), entry("b", 2, 3, 100, 200), entry("c", 4, 5, 100_100, 100_200),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 200, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 100_000, endMs: 100_300, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A", "B"])
    #expect(turns[0].originalTextRange == 0..<3)
    #expect(turns[1].originalTextRange == 4..<5)
  }

  @Test("greatest overlap wins over a segment the entry merely touches")
  func greatestOverlapWins() {
    // Entry spans 100-300ms. Segment A covers 90-150 (60ms overlap); segment B covers
    // 140-400 (160ms overlap). B has the larger overlap and must win.
    let entries = [entry("word", 0, 4, 100, 300)]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 90, endMs: 150, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 140, endMs: 400, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["B"])
  }

  @Test(
    "a tie breaks deterministically by lowest segment start, then lowest speakerId, regardless of array order"
  )
  func deterministicTieBreak() {
    // Two segments each overlap the entry by exactly 100ms; same start, so speakerId decides.
    let entries = [entry("word", 0, 4, 100, 300)]
    let segments = [
      SpeakerSegment(speakerId: "Z", startMs: 100, endMs: 300, quality: 1),
      SpeakerSegment(speakerId: "A", startMs: 100, endMs: 300, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A"])

    // Reversed array order must not change the outcome — the tie-break is a property of
    // the segments themselves, never of how the caller happened to order them.
    let reversedTurns = TurnAssembler.assemble(entries: entries, segments: segments.reversed())
    #expect(reversedTurns.map(\.speakerId) == ["A"])
  }

  @Test("the earliest segment start wins a tie even when it is not first in the array")
  func earliestStartWinsTieRegardlessOfArrayPosition() {
    // Both segments overlap the entry by 100ms, but "B" starts earlier — "B" must win the
    // tie even though "A" (the later start) is listed first and would win on speakerId alone.
    let entries = [entry("word", 0, 4, 100, 300)]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 150, endMs: 300, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 50, endMs: 250, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["B"])
  }

  @Test("zero overlap within tolerance assigns to the nearest segment")
  func nearestSegmentFallbackWithinTolerance() {
    // Entry at 1000-1100ms; nearest segment ends at 900ms, 100ms away (<= 250ms tolerance).
    let entries = [entry("word", 0, 4, 1000, 1100)]
    let segments = [SpeakerSegment(speakerId: "A", startMs: 200, endMs: 900, quality: 1)]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A"])
  }

  @Test("the tolerance boundary is exact: 250ms away assigns, 251ms away is unknown")
  func exactToleranceBoundary() {
    // Segment ends at 900ms. An entry starting at 1150ms is exactly 250ms away (within
    // tolerance); one starting at 1151ms is 251ms away (beyond it).
    let segments = [SpeakerSegment(speakerId: "A", startMs: 200, endMs: 900, quality: 1)]

    let atBoundary = TurnAssembler.assemble(
      entries: [entry("word", 0, 4, 1150, 1250)], segments: segments)
    #expect(atBoundary.map(\.speakerId) == ["A"])

    let overBoundary = TurnAssembler.assemble(
      entries: [entry("word", 0, 4, 1151, 1251)], segments: segments)
    #expect(overBoundary.map(\.speakerId) == ["unknown"])
  }

  @Test("beyond tolerance, and with no segments at all, the entry is unknown")
  func beyondToleranceAndNoSegmentsAreUnknown() {
    let entries = [entry("word", 0, 4, 5000, 5100)]
    let segments = [SpeakerSegment(speakerId: "A", startMs: 200, endMs: 900, quality: 1)]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["unknown"])

    let noSegmentTurns = TurnAssembler.assemble(entries: entries, segments: [])
    #expect(noSegmentTurns.map(\.speakerId) == ["unknown"])
  }

  @Test("an untimed entry (nil bounds) is unknown regardless of segments present")
  func untimedEntryIsUnknown() {
    let entries = [entry("word", 0, 4, nil, nil)]
    let segments = [SpeakerSegment(speakerId: "A", startMs: 0, endMs: 100, quality: 1)]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["unknown"])
    #expect(turns[0].startMs == nil)
    #expect(turns[0].endMs == nil)
  }

  @Test("a turn's bounds are the min/max among ALL its timed members, not just one")
  func minMaxAmongMultipleTimedMembers() {
    // Three entries, all falling beyond tolerance so they group as one "unknown" turn:
    // bounds must be the overall min start and max end across all three, not the first
    // or last member's own bounds.
    let entries = [
      entry("a", 0, 1, 9500, 9600), entry("b", 2, 3, 9000, 9200), entry("c", 4, 5, 9800, 10_000),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: [])
    #expect(turns.count == 1)
    #expect(turns[0].startMs == 9000)
    #expect(turns[0].endMs == 10_000)
  }

  @Test("a turn's bounds are the min/max among its TIMED members, even if one member is untimed")
  func mixedTimedAndUntimedBoundsWithinOneTurn() {
    // Both fall outside any segment's tolerance, so both are "unknown" and group together —
    // one is timed, one is not. Bounds must reflect only the timed one.
    let entries = [entry("a", 0, 1, 9000, 9100), entry("b", 2, 3, nil, nil)]
    let turns = TurnAssembler.assemble(entries: entries, segments: [])
    #expect(turns.count == 1)
    #expect(turns[0].startMs == 9000)
    #expect(turns[0].endMs == 9100)
  }

  @Test("a turn made entirely of untimed entries has nil bounds")
  func allUntimedTurnHasNilBounds() {
    let entries = [entry("a", 0, 1, nil, nil), entry("b", 2, 3, nil, nil)]
    let turns = TurnAssembler.assemble(entries: entries, segments: [])
    #expect(turns.count == 1)
    #expect(turns[0].startMs == nil)
    #expect(turns[0].endMs == nil)
  }

  @Test("a space-free script groups by adjacency exactly like a spaced one")
  func spaceFreeScript() {
    // Simulates CJK text: WordTimingRangeMapper still produces per-glyph-run entries;
    // TurnAssembler does not care about whitespace at all, only entry order and timing.
    let entries = [
      entry("你好", 0, 2, 0, 200), entry("世界", 2, 4, 200, 400),
      entry("再见", 4, 6, 5000, 5200),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 400, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 4900, endMs: 5300, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A", "B"])
    #expect(turns[0].originalTextRange == 0..<4)
    #expect(turns[1].originalTextRange == 4..<6)
  }

  // MARK: - Unknown-fragment fold (#2851 §3 C)
  //
  // The shipped constant is OFF until the plan's twenty-fragment audio check; these drive
  // the fold step directly on groups whose timings sit beyond the 250 ms tolerance, so every
  // case exercises folding itself (chunk 2 review: fixtures inside the tolerance were being
  // assigned by the resolver and passed with the fold disabled).

  private typealias Group = (speaker: String, entries: [ASRWordTiming])

  private func fold(_ groups: [Group]) -> [Group] {
    TurnAssembler.coalescingAdjacentSpeakers(TurnAssembler.foldingTinyUnknownGroups(groups))
  }

  @Test("a tiny unknown fragment folds into the neighbour with the smaller time gap")
  func tinyUnknownFoldsToNearerNeighbour() {
    let a = [entry("hello", 0, 5, 0, 500)]
    let um = [entry("um", 6, 8, 1100, 1150)]  // 600 after A, 350 before B
    let b = [entry("yes", 9, 12, 1500, 2000)]
    let folded = fold([("A", a), ("unknown", um), ("B", b)])
    #expect(folded.map(\.speaker) == ["A", "B"])
    #expect(folded[1].entries.map(\.word) == ["um", "yes"])
  }

  @Test("a tie in time gap, and an untimed fragment, both fold into the previous turn")
  func tieAndUntimedFoldToPrevious() {
    let a = [entry("hello", 0, 5, 0, 500)]
    let tie = [entry("um", 6, 8, 900, 1000)]  // 400 after A, 400 before B
    let b = [entry("yes", 9, 12, 1400, 2000)]
    let folded = fold([("A", a), ("unknown", tie), ("B", b)])
    #expect(folded.map(\.speaker) == ["A", "B"])
    #expect(folded[0].entries.map(\.word) == ["hello", "um"])

    let untimed = [entry("um", 6, 8, nil, nil)]
    let folded2 = fold([("A", a), ("unknown", untimed), ("B", b)])
    #expect(folded2[0].entries.map(\.word) == ["hello", "um"])
  }

  @Test("a four-entry unknown group folds; five entries stay their own turn")
  func fourFoldsFiveStays() {
    let a = [entry("hello", 0, 5, 0, 500)]
    let b = [entry("yes", 30, 33, 3000, 3500)]
    let four = (0..<4).map { entry("w\($0)", 6 + $0 * 2, 7 + $0 * 2, 1000 + $0 * 20, 1010 + $0 * 20) }
    let five = (0..<5).map { entry("w\($0)", 6 + $0 * 2, 7 + $0 * 2, 1000 + $0 * 20, 1010 + $0 * 20) }
    #expect(fold([("A", a), ("unknown", four), ("B", b)]).map(\.speaker) == ["A", "B"])
    #expect(fold([("A", a), ("unknown", five), ("B", b)]).map(\.speaker) == ["A", "unknown", "B"])
  }

  @Test("a fragment at the document start folds forward; a trailing one folds back; a lone one stays")
  func edgesAndLone() {
    let a = [entry("hello", 3, 8, 1000, 1500)]
    let lead = [entry("um", 0, 2, 0, 50)]
    let tail = [entry("uh", 9, 11, 9000, 9050)]
    let folded = fold([("unknown", lead), ("A", a), ("unknown", tail)])
    #expect(folded.map(\.speaker) == ["A"])
    #expect(folded[0].entries.map(\.word) == ["um", "hello", "uh"])
    #expect(fold([("unknown", lead)]).map(\.speaker) == ["unknown"])
  }

  @Test("a fold that leaves two same-speaker groups adjacent coalesces them into one turn")
  func foldThenCoalesce() {
    let a1 = [entry("one", 0, 3, 0, 200)]
    let um = [entry("um", 4, 6, 600, 650)]  // 400 after, 350 before: folds forward into A
    let a2 = [entry("two", 7, 10, 1000, 1200)]
    let folded = fold([("A", a1), ("unknown", um), ("A", a2)])
    #expect(folded.map(\.speaker) == ["A"])
    #expect(folded[0].entries.map(\.word) == ["one", "um", "two"])
  }

  @Test("with the shipped constant off, assemble leaves unknown fragments untouched")
  func shippedConstantIsOff() {
    #expect(TurnAssembler.unknownFoldEnabled == false)
    let entries = [entry("hello", 0, 5, 0, 500), entry("um", 6, 8, 1100, 1150), entry("yes", 9, 12, 1500, 2000)]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 1500, endMs: 2000, quality: 1),
    ]
    #expect(TurnAssembler.assemble(entries: entries, segments: segments).map(\.speakerId) == ["A", "unknown", "B"])
  }

  @Test("empty input produces no turns")
  func emptyInput() {
    #expect(TurnAssembler.assemble(entries: [], segments: []).isEmpty)
  }

  @Test("default speaker names are assigned in first-appearance order, excluding unknown")
  func defaultSpeakerNamesExcludeUnknown() {
    let entries = [
      entry("a", 0, 1, 0, 100), entry("b", 2, 3, nil, nil), entry("c", 4, 5, 9000, 9100),
    ]
    let segments = [SpeakerSegment(speakerId: "Z", startMs: 0, endMs: 100, quality: 1)]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    // "Z" appears first, "unknown" (from the untimed entry) groups separately, then the
    // beyond-tolerance entry is also "unknown" but adjacent so it merges with the prior
    // unknown group only if immediately adjacent — here it is not (Z, unknown, unknown are
    // three distinct adjacency groups only if speaker changes between them; unknown ==
    // unknown so entries 2 and 3 merge into ONE unknown turn).
    let names = TurnAssembler.defaultSpeakerNames(for: turns)
    #expect(names["Z"] == "Speaker 1")
    #expect(names["unknown"] == nil)
  }

  @Test("multiple recurring real speakers get one stable name each, in first-appearance order")
  func multipleRecurringSpeakersGetOneNameEach() {
    let entries = [
      entry("a", 0, 1, 0, 100), entry("b", 2, 3, 9000, 9100), entry("c", 4, 5, 100, 200),
    ]
    let segments = [
      SpeakerSegment(speakerId: "B", startMs: 0, endMs: 200, quality: 1),
      SpeakerSegment(speakerId: "A", startMs: 9000, endMs: 9200, quality: 1),
    ]
    // Turn order: B (entry a), A (entry b), B again (entry c) — three turns, two speakers.
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["B", "A", "B"])
    let names = TurnAssembler.defaultSpeakerNames(for: turns)
    // "B" appeared first (turn 0), so it gets "Speaker 1" even though it recurs later;
    // "A" appeared second, gets "Speaker 2"; exactly two entries, not three.
    #expect(names == ["B": "Speaker 1", "A": "Speaker 2"])
  }

  @Test("a fresh assembly over identical input reproduces identical, range-derived turn ids")
  func repeatedAssemblyProducesStableIDs() {
    let entries = [
      entry("hello", 0, 5, 0, 200), entry("there", 6, 11, 200, 500),
    ]
    let segments = [SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1)]
    let first = TurnAssembler.assemble(entries: entries, segments: segments)
    let second = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.first?.id == "0-11")
  }

  @Test(
    "assemble stops at the first entry when its own Task is already cancelled, never fabricating a result for cancelled work"
  )
  func assembleStopsWhenCancelled() async {
    let entries = [
      entry("hello", 0, 5, 0, 200), entry("there", 6, 11, 200, 500),
    ]
    let segments = [SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1)]
    let task = Task {
      TurnAssembler.assemble(entries: entries, segments: segments)
    }
    // Cancelled BEFORE the task's body has a chance to run — cancellation is a monotonic
    // flag, so this is deterministic, never a race against the task's own scheduling.
    task.cancel()
    let turns = await task.value
    #expect(turns.isEmpty, "a cancelled task must not process any entries")
  }
}
