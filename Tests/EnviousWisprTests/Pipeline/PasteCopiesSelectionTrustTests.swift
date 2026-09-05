import Testing

@testable import EnviousWisprPipeline

// Whether a before-image's SELECTION LENGTH still describes the field the delivery wrote into
// (#2652).
//
// The fallback activates the destination before pasting, and activation is allowed to change the
// selection. A selection that is LOST means the field never shrank, so it grew by a whole payload
// more than expected and reads as TWO COPIES. A false `two` is the one error this instrument must
// never make, so where the selection cannot be trusted the observation declines.
@Suite("Paste copies: when a selection can still be trusted", .tags(.observabilityContract))
struct PasteCopiesSelectionTrustTests {

  @Test("a write that reached the setter wrote over the selection it measured")
  func setterReachedIsAlwaysTrusted() {
    #expect(
      PasteCopiesObserver.selectionStillDescribesTheField(setterReached: true, selectionLength: 27))
    #expect(
      PasteCopiesObserver.selectionStillDescribesTheField(setterReached: true, selectionLength: 0))
  }

  @Test("a plain caret has no selection to lose")
  func caretWithoutSelectionIsTrusted() {
    #expect(
      PasteCopiesObserver.selectionStillDescribesTheField(setterReached: false, selectionLength: 0))
  }

  @Test("a selection measured before a decline is NOT trusted")
  func selectionAfterDeclineIsRefused() {
    #expect(
      !PasteCopiesObserver.selectionStillDescribesTheField(
        setterReached: false, selectionLength: 1))
    #expect(
      !PasteCopiesObserver.selectionStillDescribesTheField(
        setterReached: false, selectionLength: 27))
  }
}
