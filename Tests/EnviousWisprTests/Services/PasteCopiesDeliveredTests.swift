import Testing

@testable import EnviousWisprServices

// How many copies landed (#2652).
//
// The live AX reads are exercised by Live UAT, matching the `classifyInsertOutcome` precedent
// next door. The ARITHMETIC is pure, and it is what this suite pins.
//
// What the instrument is for: `paste.completed` fires once whether one copy or two copies arrive,
// so the reported double-paste defect is invisible fleet-wide. What it is NOT: proof that identical
// content arrived twice. Every row below is about LENGTH GROWTH, and several of them exist
// specifically to document where length and meaning come apart.
@Suite("PasteService.copiesDelivered", .tags(.observabilityContract))
struct PasteCopiesDeliveredTests {

  private func copies(
    before: Int, selection: Int = 0, inserted: Int, after: Int?
  ) -> Int? {
    PasteService.copiesDelivered(
      countAfter: after, countBefore: before, selectionLengthBefore: selection,
      insertedLength: inserted)
  }

  // MARK: - The two answers it exists to give

  @Test("one copy at the exact expected length")
  func oneCopyExact() {
    #expect(copies(before: 13, inserted: 27, after: 40) == 1)
  }

  @Test("two copies at exactly one more copy")
  func twoCopiesExact() {
    #expect(copies(before: 13, inserted: 27, after: 67) == 2)
  }

  // MARK: - A destination may not store what it was given

  // Measured 2026-09-04 across 8 deliveries of one sentence: Discord landed on the exact
  // expected count every time, and Slack was short by exactly one character PER COPY —
  // one copy short by 1, two copies short by 2, reproducibly.
  @Test("Slack's one-fewer-per-copy still reads as one copy")
  func slackShrinksOneCopy() {
    #expect(copies(before: 13, inserted: 27, after: 39) == 1)
  }

  @Test("Slack's two-fewer-for-two-copies still reads as two copies")
  func slackShrinksTwoCopies() {
    #expect(copies(before: 13, inserted: 27, after: 65) == 2)
  }

  // MARK: - Replacing a selection shortens before it lengthens

  @Test("a delivery over a selection accounts for what it replaced")
  func replacesSelection() {
    // 40 characters, 10 of them selected, replaced by 27: 40 - 10 + 27 = 57.
    #expect(copies(before: 40, selection: 10, inserted: 27, after: 57) == 1)
    #expect(copies(before: 40, selection: 10, inserted: 27, after: 84) == 2)
  }

  // MARK: - The bands may never overlap, at any sentence length

  // The tolerance is bounded to a THIRD of one copy. That bound, not its width, is what keeps a
  // single delivery from ever being reported as a duplicate.
  @Test("a very short delivery cannot read one copy as two", arguments: [1, 2, 3, 4, 6, 9])
  func shortDeliveriesKeepTheirBandsApart(inserted: Int) {
    let before = 100
    let oneCopy = before + inserted
    #expect(copies(before: before, inserted: inserted, after: oneCopy) == 1)
    #expect(copies(before: before, inserted: inserted, after: oneCopy + inserted) == 2)
    // The midpoint between the bands belongs to neither.
    if inserted >= 8 {
      #expect(copies(before: before, inserted: inserted, after: oneCopy + inserted / 2) == nil)
    }
  }

  // MARK: - What it refuses to answer

  @Test("an unreadable count is never a copy count")
  func unreadableCountIsNil() {
    #expect(copies(before: 13, inserted: 27, after: nil) == nil)
  }

  @Test("a delivery of nothing is not measurable")
  func zeroLengthIsNil() {
    #expect(copies(before: 13, inserted: 0, after: 13) == nil)
  }

  @Test("a length far from either band is unclassified")
  func farFromBothBandsIsNil() {
    #expect(copies(before: 13, inserted: 27, after: 200) == nil)
  }

  // MARK: - Arbitrary numbers from a foreign application

  // These counts come from another app's accessibility implementation, so they are arbitrary
  // Ints, not values this process produced. Overflow must return nil, never trap.
  @Test("extreme inputs return nil rather than trapping")
  func extremeInputsDoNotTrap() {
    #expect(copies(before: Int.max, inserted: Int.max, after: Int.max) == nil)
    #expect(copies(before: Int.max, selection: 0, inserted: 10, after: Int.max) == nil)
    #expect(copies(before: 0, selection: Int.max, inserted: 10, after: 10) == nil)
    #expect(copies(before: -1, inserted: 10, after: 10) == nil)
    #expect(copies(before: 10, inserted: 10, after: -5) == nil)
  }

  // MARK: - Where length and meaning come apart, documented rather than asserted away

  // A destination that normalises can move a TRUE DOUBLE into the one-copy band: submit 12,
  // have each copy stored as 6, and the field grows by 12. This row is not a bug report. It
  // records that a `one` verdict is an estimate about LENGTH and never a proof about content,
  // which is why the dashboard label says estimate and why Phase 3 may not rest on a small count.
  @Test("a normalising destination can hide a true double, and that is a known limit")
  func normalisationCanHideADouble() {
    #expect(copies(before: 0, inserted: 12, after: 12) == 1)
  }
}
