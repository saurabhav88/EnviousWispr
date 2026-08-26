import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// How the cascade responds to each Tier 1 Accessibility outcome (#1785 Chunk 1).
//
// The live cascade needs a real focused AX element, so — following the same
// split `PasteFocusClassificationTests` uses for `classifyPasteFocus` — the
// decision is extracted and pinned here, and the wiring is covered by Live UAT.
//
// The property that matters: exactly one outcome may be retried. Retrying an
// unproven write is what puts the user's sentence in twice.
@Suite("PasteCascadeExecutor AX-direct disposition")
struct PasteCascadeAXOutcomeTests {

  @Test("Verified insertion stops the cascade and reports Tier 1 delivery")
  func verifiedDelivers() {
    let disposition = dispositionForAXDirect(.verified)
    #expect(disposition == .delivered)
    #expect(disposition.allowsAutomaticRetry == false)
    #expect(disposition.tierFailureReason == nil)
  }

  @Test("Provable no-mutation continues to the existing Tier 2 fallback")
  func noMutationContinues() {
    let disposition = dispositionForAXDirect(.noMutation)
    #expect(disposition == .continueCascade)
    #expect(
      disposition.allowsAutomaticRetry,
      "Nothing landed, so Tier 2 Cmd+V must still run. Electron apps depend on this path."
    )
    #expect(disposition.tierFailureReason == "refused")
  }

  @Test("Unverifiable insertion blocks every automatic retry")
  func unverifiableStops() {
    let disposition = dispositionForAXDirect(.unverifiable)
    #expect(disposition == .stopUnverified)
    #expect(
      disposition.allowsAutomaticRetry == false,
      "The write may already be in the document. A second paste would duplicate the user's text."
    )
    #expect(disposition.tierFailureReason == "unverifiable")
  }

  @Test("Only a provable no-mutation may be retried")
  func exactlyOneOutcomeRetries() {
    let retryable: [PasteService.AXInsertOutcome] = [.verified, .noMutation, .unverifiable]
      .filter { dispositionForAXDirect($0).allowsAutomaticRetry }
    #expect(retryable == [.noMutation])
  }

  @Test("Every outcome maps to a distinct disposition")
  func mappingIsTotalAndDistinct() {
    let dispositions = [
      dispositionForAXDirect(.verified),
      dispositionForAXDirect(.noMutation),
      dispositionForAXDirect(.unverifiable),
    ]
    #expect(Set(dispositions.map(String.init(describing:))).count == 3)
  }
}

// #2297: whether Tier 1 (AX direct write) runs at all is decided before the
// write, from `classification` and `isChromiumOmnibox` — never inside
// `insertViaAccessibility`, which has no way to know a route was skipped.
// Product outcome: when this misroutes, the user's dictated URL sits
// correctly in Chrome's address bar and Enter silently does nothing.
@Suite("PasteCascadeExecutor Tier 1 decline reason", .tags(.productOutcome))
struct PasteCascadeTier1DeclineReasonTests {

  @Test("A Chromium address bar declines Tier 1 with its own reason, never `nil`")
  func chromiumOmniboxDeclinesWithItsOwnReason() {
    let reason = tier1DeclineReason(
      axTrusted: true, classification: .textField, isChromiumOmnibox: true)
    #expect(reason == .chromiumOmniboxNavigationSeam)
  }

  @Test("An ordinary text field — Chromium or not — still runs Tier 1")
  func ordinaryTextFieldRunsTier1() {
    let reason = tier1DeclineReason(
      axTrusted: true, classification: .textField, isChromiumOmnibox: false)
    #expect(reason == nil)
  }

  @Test("Accessibility being untrusted outranks the Chromium omnibox reason")
  func accessibilityDeniedOutranksChromiumReason() {
    // If AX itself is denied, `isChromiumOmnibox` could never have been
    // computed truthfully (it requires an AX read) — the untrusted branch
    // must win regardless of what is passed for it.
    let reason = tier1DeclineReason(
      axTrusted: false, classification: .textField, isChromiumOmnibox: true)
    #expect(reason == .accessibilityDenied)
  }

  @Test("A Chromium address bar still yields the ordinary reason for .missing and .nonText")
  func nonTextFieldClassificationsUnaffectedByChromiumFlag() {
    #expect(
      tier1DeclineReason(axTrusted: true, classification: .missing, isChromiumOmnibox: true)
        == .focusMissing)
    #expect(
      tier1DeclineReason(axTrusted: true, classification: .nonText, isChromiumOmnibox: true)
        == .focusNonText)
  }
}
