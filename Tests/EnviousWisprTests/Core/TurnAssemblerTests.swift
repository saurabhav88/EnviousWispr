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

  /// UTF-16-offset slicing, matching how `TurnCleanupRunner` reads a turn's raw text —
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
    // (untimed, so "unknown" at assignment; since #2851 §3 C a tiny unknown fragment folds
    // into its previous turn, so B's sentence is NOT cut in two) — "meet" / "you." (speaker
    // B again, coalesced with the first B group once the fold made them adjacent) —
    // "Yeah," (unknown, beyond tolerance; folds forward, its measured gap to "likewise." is
    // smaller) — "likewise." (speaker A again, must NOT merge back into the FIRST A turn just
    // because the speaker recurs).
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
    #expect(bySpeaker == ["A", "B", "A"])
    // The A speaker recurring later must NOT merge back into an earlier same-speaker turn
    // once a different speaker has intervened — no word moves across an established speaker
    // change (addendum §3 C). Folded unknown fragments extend a neighbour; they never bridge
    // two different real speakers.
    #expect(turns.count == 3)

    // Each turn's raw-text slice equals exactly its member entries' span, whitespace
    // included, sliced from the SAME text the entries' ranges were computed against.
    #expect(slice(turns[0].originalTextRange, of: text) == "Hi, I'm 24.")
    #expect(slice(turns[1].originalTextRange, of: text) == "Well, nice to meet you.")
    #expect(slice(turns[2].originalTextRange, of: text) == "Yeah, likewise.")

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

  @Test("a tiny unknown fragment folds into the neighbour with the smaller time gap")
  func tinyUnknownFoldsToNearerNeighbour() {
    // A: 0-500ms "hello there" | unknown "um" at 900-950 | B: 1000-1500 "yes right"
    let entries = [
      entry("hello", 0, 5, 0, 200), entry("there", 6, 11, 200, 500),
      entry("um", 12, 14, 900, 950),
      entry("yes", 15, 18, 1000, 1200), entry("right", 19, 24, 1200, 1500),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 1000, endMs: 1500, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    // gap before = 900-500 = 400, gap after = 1000-950 = 50: folds into B.
    #expect(turns.map(\.speakerId) == ["A", "B"])
    #expect(turns[1].originalTextRange == 12..<24)
    #expect(turns[1].startMs == 900)
  }

  @Test("a tie in time gap, and an untimed fragment, both fold into the previous turn")
  func tieAndUntimedFoldToPrevious() {
    let entries = [
      entry("hello", 0, 5, 0, 500),
      entry("um", 6, 8, 700, 800),  // 200 before, 200 after
      entry("yes", 9, 12, 1000, 1500),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 1000, endMs: 1500, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A", "B"])
    #expect(turns[0].originalTextRange == 0..<8)

    let untimed = [
      entry("hello", 0, 5, 0, 500), entry("um", 6, 8, nil, nil), entry("yes", 9, 12, 1000, 1500),
    ]
    let turns2 = TurnAssembler.assemble(entries: untimed, segments: segments)
    #expect(turns2.map(\.speakerId) == ["A", "B"])
    #expect(turns2[0].originalTextRange == 0..<8)
  }

  @Test("an unknown group of five or more entries stays its own turn")
  func longUnknownStays() {
    // The five words sit 500 ms clear of both segments, beyond the 250 ms tolerance.
    let entries = [
      entry("hello", 0, 5, 0, 500),
      entry("a", 6, 7, 1000, 1020), entry("b", 8, 9, 1020, 1040), entry("c", 10, 11, 1040, 1060),
      entry("d", 12, 13, 1060, 1080), entry("e", 14, 15, 1080, 1100),
      entry("yes", 16, 19, 1600, 2000),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: 1600, endMs: 2000, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A", "unknown", "B"])
  }

  @Test("a fragment at the document start folds forward; a lone unknown document stays")
  func fragmentAtStartFoldsForward() {
    let entries = [entry("um", 0, 2, 0, 50), entry("hello", 3, 8, 1000, 1500)]
    let segments = [SpeakerSegment(speakerId: "A", startMs: 1000, endMs: 1500, quality: 1)]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A"])
    #expect(turns[0].originalTextRange == 0..<8)

    let lone = TurnAssembler.assemble(entries: [entry("word", 0, 4, 5000, 5100)], segments: [])
    #expect(lone.map(\.speakerId) == ["unknown"])
  }

  @Test("a fold that leaves two same-speaker groups adjacent coalesces them into one turn")
  func foldThenCoalesce() {
    // A "one" | unknown "um" | A "two": folding "um" into A (either side) leaves A next to A.
    let entries = [
      entry("one", 0, 3, 0, 200), entry("um", 4, 6, 400, 450), entry("two", 7, 10, 500, 700),
    ]
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: 200, quality: 1),
      SpeakerSegment(speakerId: "A", startMs: 500, endMs: 700, quality: 1),
    ]
    let turns = TurnAssembler.assemble(entries: entries, segments: segments)
    #expect(turns.map(\.speakerId) == ["A"])
    #expect(turns[0].originalTextRange == 0..<10)
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
