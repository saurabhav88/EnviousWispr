import Testing

@testable import EnviousWisprServices

// Tier 1 Accessibility insertion verification (#1785 Chunk 1).
//
// The live AX round-trips in `insertViaAccessibility` are exercised by Live
// UAT, matching the `isPasteShortcut` / `findPasteMenuItem` precedent. The
// DECISION those round-trips feed is pure, and it is what this suite pins.
//
// The defect being fixed: verification used `countAfter > countBefore`, so a
// successful replacement that shortened or preserved the field's length was
// reported as failure. The caller then fell through to Tier 2 and pasted a
// SECOND time. Cursor-aware insertion can shorten text, so this had to be
// fixed before that feature could exist.
@Suite("PasteService.classifyInsertOutcome")
struct PasteAccessibilityInsertionTests {

  private func probe(
    inserted: Int,
    selection: Int = 0,
    before: Int,
    after: Int?,
    readBack: Bool? = nil,
    fieldUnchanged: Bool? = nil
  ) -> PasteService.AXInsertProbe {
    PasteService.AXInsertProbe(
      insertedUTF16Length: inserted,
      selectionLengthBefore: selection,
      countBefore: before,
      countAfter: after,
      readBackMatched: readBack,
      fieldUnchanged: fieldUnchanged
    )
  }

  // MARK: - Verified

  @Test("Insertion at a plain caret is verified by expected length plus read-back")
  func caretInsertionVerified() {
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 6, selection: 0, before: 10, after: 16, readBack: true))
    #expect(outcome == .verified)
  }

  @Test("Replacing a selection with SHORTER text is verified, not a failure")
  func shorterReplacementVerified() {
    // 20 characters selected, 5 written back: the field legitimately shrinks.
    // The old `countAfter > countBefore` rule called this a failure and the
    // cascade pasted again, duplicating the text.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 5, selection: 20, before: 40, after: 25, readBack: true))
    #expect(
      outcome == .verified,
      "A shorter replacement is a legitimate success. Reporting it as failure is what makes the cascade paste a second time."
    )
  }

  @Test("Replacing a selection with EQUAL-length text is verified via read-back")
  func equalLengthReplacementVerified() {
    // Counts cannot distinguish an equal-length replacement from nothing
    // happening, so this case requires positive content read-back.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 8, selection: 8, before: 30, after: 30, readBack: true))
    #expect(outcome == .verified)
  }

  @Test("Read-back alone does NOT verify when counts are unreadable")
  func readBackWithoutCountsIsUnverifiable() {
    // Revised after chunk review. Read-back can match text that was already
    // there, so without a length to corroborate it there is no proof.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 4, selection: 0, before: 12, after: nil, readBack: true))
    #expect(outcome == .unverifiable)
  }

  // MARK: - No mutation: safe to continue the cascade

  @Test("Field length unchanged when a change was expected means nothing landed")
  func unchangedFieldIsNoMutation() {
    // The Electron case the original code was written for: AX reports success
    // but the field never changes. Must stay `.noMutation` so Tier 2 Cmd+V
    // still runs, or those apps lose automatic paste entirely.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 6, selection: 0, before: 10, after: 10, fieldUnchanged: true))
    #expect(
      outcome == .noMutation,
      "Electron apps report a successful AX write without mutating. Tier 2 must still run for them."
    )
  }

  @Test("Read-back mismatch with an unchanged field is no mutation")
  func mismatchWithUnchangedFieldIsNoMutation() {
    let outcome = PasteService.classifyInsertOutcome(
      probe(
        inserted: 6, selection: 0, before: 10, after: 10, readBack: false,
        fieldUnchanged: true))
    #expect(outcome == .noMutation)
  }

  // MARK: - Unverifiable: stop, never retry

  @Test("Unreadable result after a successful write is unverifiable")
  func unreadableResultIsUnverifiable() {
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 6, selection: 0, before: 10, after: nil))
    #expect(
      outcome == .unverifiable,
      "The write reported success and we cannot read the result. It may have landed, so retrying risks duplicating it."
    )
  }

  @Test("A count that contradicts the request is unverifiable")
  func contradictoryCountIsUnverifiable() {
    // Asked to add 6 characters; the field grew by 2. Something happened, but
    // not what we asked for.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 6, selection: 0, before: 10, after: 12))
    #expect(outcome == .unverifiable)
  }

  @Test("Equal-length replacement without read-back is unverifiable, not verified")
  func equalLengthWithoutReadBackIsUnverifiable() {
    // Genuinely ambiguous: identical to "nothing happened". Refuse rather than
    // guess, per the repository's ambiguous-input rule.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 8, selection: 8, before: 30, after: 30))
    #expect(outcome == .unverifiable)
  }

  @Test("Read-back mismatch on a changed field is unverifiable")
  func mismatchOnChangedFieldIsUnverifiable() {
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 6, selection: 0, before: 10, after: 16, readBack: false))
    #expect(
      outcome == .unverifiable,
      "The field changed but the span does not contain our text. Unprovable, so do not paste again."
    )
  }

  // MARK: - Adversarial: the two ways positive evidence can lie

  @Test("Pre-existing matching text cannot falsely verify an ignored insertion")
  func preExistingMatchingTextDoesNotVerify() {
    // The caret sits immediately before text identical to what was dictated,
    // and the app ignores the write. Read-back matches text that was already
    // there. Trusting read-back alone would report success and SILENTLY DISCARD
    // the user's dictation — worse than pasting twice. The unchanged length is
    // what exposes it.
    let outcome = PasteService.classifyInsertOutcome(
      probe(
        inserted: 6, selection: 0, before: 10, after: 10, readBack: true,
        fieldUnchanged: true))
    #expect(
      outcome == .noMutation,
      "Read-back matching pre-existing text is not proof of a write. Verifying here would lose the dictation."
    )
  }

  @Test("Same count with a changed field is unverifiable")
  func sameCountWithChangedFieldIsUnverifiable() {
    // A same-length rewrite mutates content without moving the count. Treating
    // an unchanged count as proof of no mutation would retry over a write that
    // already landed.
    let outcome = PasteService.classifyInsertOutcome(
      probe(
        inserted: 6, selection: 0, before: 10, after: 10, readBack: false,
        fieldUnchanged: false))
    #expect(outcome == .unverifiable)
  }

  @Test("Same-count mutation outside the original selection is unverifiable")
  func sameCountMutationElsewhereIsUnverifiable() {
    // The selection moved between our range read and our write, and the write
    // landed there as an equal-length replacement. Total count is unchanged and
    // a window around the ORIGINAL selection still reads identical, so a local
    // comparison would call this "nothing happened" and paste a second time.
    // Only whole-field evidence catches it.
    let outcome = PasteService.classifyInsertOutcome(
      probe(
        inserted: 6, selection: 6, before: 100, after: 100, readBack: false,
        fieldUnchanged: false))
    #expect(
      outcome == .unverifiable,
      "A bounded window cannot prove no mutation when the selection moves between AX calls."
    )
  }

  @Test("Unchanged count with no field evidence is unverifiable, not retryable")
  func unchangedCountWithoutFieldEvidenceIsUnverifiable() {
    // No positive proof in either direction: refuse.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 6, selection: 0, before: 10, after: 10))
    #expect(outcome == .unverifiable)
  }

  @Test("Same-length combining-mark reorder cannot prove no mutation")
  func sameLengthCombiningMarkReorderIsUnverifiable() {
    // Swift's `String ==` is canonical-equivalence-aware, so these two compare
    // equal despite storing different code units. If the field comparison used
    // `==`, a destination that reorders combining marks would look untouched and
    // we would paste again over a write that landed.
    let before = "a\u{0301}\u{0323}"
    let after = "a\u{0323}\u{0301}"

    #expect(before.utf16.count == after.utf16.count)
    #expect(Array(before.unicodeScalars) != Array(after.unicodeScalars))
    #expect(
      PasteService.stringsHaveIdenticalUTF16(before, after) == false,
      "UTF-16 identity must see through canonical equivalence, or 'unchanged' is not proof."
    )

    let outcome = PasteService.classifyInsertOutcome(
      probe(
        inserted: 3,
        selection: 3,
        before: before.utf16.count,
        after: after.utf16.count,
        readBack: false,
        fieldUnchanged: PasteService.stringsHaveIdenticalUTF16(before, after)
      ))
    #expect(outcome == .unverifiable)
  }

  // MARK: - The old heuristic must be gone

  @Test("Growth alone no longer proves success")
  func growthAloneIsNotProof() {
    // Grew by the wrong amount. The retired rule returned true for any growth.
    let outcome = PasteService.classifyInsertOutcome(
      probe(inserted: 3, selection: 0, before: 5, after: 40))
    #expect(outcome != .verified)
  }
}
