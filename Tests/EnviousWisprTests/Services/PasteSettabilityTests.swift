import Testing

@testable import EnviousWisprServices

/// #1332 Chunk 2. The Tier 1 write targets `kAXSelectedTextAttribute` while its
/// guard asked about `kAXValueAttribute`. These cover the DECISION that fixes
/// that; the AX round trips themselves are live-only, matching the precedent in
/// `PasteAccessibilityInsertionTests`.
@Suite("PasteService.tier1IsRefused", .tags(.productOutcome))
struct PasteSettabilityTests {

  private func settability(
    value: PasteService.AXSettableState,
    selectedText: PasteService.AXSettableState
  ) -> PasteService.AXSettability {
    PasteService.AXSettability(value: value, selectedText: selectedText)
  }

  @Test("a positive refusal on the WRITTEN attribute skips Tier 1")
  func positiveRefusalSkips() {
    // iTerm2, measured 60/60 on 2026-08-19: value settable, selected text not.
    // Tier 1 has never succeeded there in 944 production pastes.
    #expect(
      PasteService.tier1IsRefused(
        by: settability(value: .settable, selectedText: .notSettable)) == true)
  }

  @Test("an UNANSWERED query does not skip — this is the whole point of three states")
  func unreadableProceeds() {
    // Collapsing "did not say" into "said no" would drop an app onto the
    // 18x-slower route for a transient AX failure. Both shapes must proceed.
    #expect(
      PasteService.tier1IsRefused(
        by: settability(value: .settable, selectedText: .unreadable)) == false)
    #expect(
      PasteService.tier1IsRefused(
        by: settability(value: .unreadable, selectedText: .unreadable)) == false)
  }

  @Test("the attribute we do NOT write cannot refuse on its own")
  func valueAttributeDoesNotDecide() {
    // Ghostty reports AXValue not settable and still produced 2 ax_direct wins
    // in 30 days, so this axis must not gate the write we actually make.
    #expect(
      PasteService.tier1IsRefused(
        by: settability(value: .notSettable, selectedText: .settable)) == false)
  }

  @Test("both settable proceeds — TextEdit and Chrome, where Tier 1 wins")
  func bothSettableProceeds() {
    #expect(
      PasteService.tier1IsRefused(
        by: settability(value: .settable, selectedText: .settable)) == false)
  }

  @Test("the telemetry token carries BOTH answers, because the disagreement is the finding")
  func telemetryTokenPairsBothAnswers() {
    #expect(
      settability(value: .settable, selectedText: .notSettable).telemetryValue
        == "value_settable__selected_text_not_settable")
    #expect(
      settability(value: .unreadable, selectedText: .settable).telemetryValue
        == "value_unreadable__selected_text_settable")
  }
}
