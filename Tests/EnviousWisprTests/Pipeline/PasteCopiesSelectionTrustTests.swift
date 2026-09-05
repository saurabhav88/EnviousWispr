import Testing

@testable import EnviousWisprPipeline

// Whether a before-image's SELECTION LENGTH still describes the field the delivery wrote into
// (#2652).
//
// Every route after Tier 1 activates the destination first, and activation is allowed to change
// the selection. A selection that is LOST means the field never shrank, so it grew by a whole
// payload more than expected and reads as TWO COPIES. A false `two` is the one error this
// instrument must never make, so where the selection cannot be trusted the observation declines.
//
// The discriminator went through three review rounds as "did the Tier 1 setter run", and each
// round found another case it trusted wrongly: a setter that failed, and a setter that returned
// no mutation, both hand delivery to a fallback. Reaching the setter never proved it replaced the
// selection. Activation is the property that actually decides.
@Suite("Paste copies: when a selection can still be trusted", .tags(.observabilityContract))
struct PasteCopiesSelectionTrustTests {

  @Test("nothing activated the destination, so the selection still stands")
  func noFallbackIsTrusted() {
    #expect(
      PasteCopiesObserver.selectionStillDescribesTheField(fallbackRan: false, selectionLength: 27))
    #expect(
      PasteCopiesObserver.selectionStillDescribesTheField(fallbackRan: false, selectionLength: 0))
  }

  @Test("a plain caret has no selection to lose")
  func caretWithoutSelectionIsTrusted() {
    #expect(
      PasteCopiesObserver.selectionStillDescribesTheField(fallbackRan: true, selectionLength: 0))
  }

  // The measured failure: a 100-character field with 27 selected, losing its selection during
  // activation and receiving one 27-character paste, reaches 127 where one copy was expected at
  // 100. Without this refusal the observation reports TWO.
  @Test("a selection measured before a fallback ran is NOT trusted")
  func selectionBeforeFallbackIsRefused() {
    #expect(
      !PasteCopiesObserver.selectionStillDescribesTheField(fallbackRan: true, selectionLength: 1))
    #expect(
      !PasteCopiesObserver.selectionStillDescribesTheField(fallbackRan: true, selectionLength: 27))
  }
}
