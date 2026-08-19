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

/// #1332 Chunk 3. The decline reason is a TELEMETRY CONTRACT: its raw values are
/// grouped on in PostHog and Sentry, so a rename is a silent data break, not a
/// refactor. Observability rather than product outcome — when these fail, a
/// dashboard lies; no user notices.
@Suite("PasteService.AXDeclineReason", .tags(.observabilityContract))
struct PasteDeclineReasonTests {

  @Test("a verified write has no decline reason")
  func verifiedHasNoReason() {
    #expect(PasteService.declineReason(for: .verified) == nil)
  }

  @Test("the two non-delivering outcomes map to distinct reasons")
  func outcomesMapDistinctly() {
    // These are opposite instructions to the cascade — one authorises a second
    // paste, the other forbids it — so they must never collapse in the data.
    #expect(PasteService.declineReason(for: .noMutation) == .noMutation)
    #expect(PasteService.declineReason(for: .unverifiable) == .unverifiable)
    #expect(
      PasteService.declineReason(for: .noMutation)
        != PasteService.declineReason(for: .unverifiable))
  }

  @Test("every one of the fourteen raw values is pinned exactly")
  func rawValuesAreStable() {
    // Frozen because they are grouped on in PostHog and Sentry, so a rename is a
    // silent data break rather than a refactor. All fourteen, not a sample: the
    // earlier version pinned five and would have let a rename of the other nine
    // through (chunk whole-diff review).
    //
    // The `not_attempted_` prefix is load bearing. Those declines happen before
    // the write is ever called and are the MAJORITY, so a query must separate
    // them without a join.
    let expected: [(PasteService.AXDeclineReason, String)] = [
      (.accessibilityDenied, "not_attempted_accessibility_denied"),
      (.focusMissing, "not_attempted_focus_missing"),
      (.focusNonText, "not_attempted_focus_non_text"),
      (.roleUnreadable, "role_unreadable"),
      (.roleNotText, "role_not_text"),
      (.selectedTextNotSettable, "selected_text_not_settable"),
      (.countUnreadableOrInvalid, "count_unreadable_or_invalid"),
      (.rangeUnreadable, "range_unreadable"),
      (.rangeInvalid, "range_invalid"),
      (.beforeImageUnreadableOrIncomplete, "before_image_unreadable_or_incomplete"),
      (.focusUnconfirmed, "focus_unconfirmed"),
      (.setFailed, "set_failed"),
      (.noMutation, "no_mutation"),
      (.unverifiable, "unverifiable"),
    ]
    for (reason, rawValue) in expected {
      #expect(reason.rawValue == rawValue, "raw value drifted for \(reason)")
    }
    #expect(expected.count == 14)
  }

  @Test("no two reasons share a raw value")
  func rawValuesAreUnique() {
    // A duplicate would silently merge two causes in every chart built on this.
    let all: [PasteService.AXDeclineReason] = [
      .accessibilityDenied, .focusMissing, .focusNonText, .roleUnreadable, .roleNotText,
      .selectedTextNotSettable, .countUnreadableOrInvalid, .rangeUnreadable, .rangeInvalid,
      .beforeImageUnreadableOrIncomplete, .focusUnconfirmed, .setFailed, .noMutation, .unverifiable,
    ]
    #expect(Set(all.map(\.rawValue)).count == all.count)
    #expect(all.count == 14)
  }
}
