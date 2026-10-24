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
      axTrusted: true, classification: .textField, isChromiumOmnibox: true,
      directWriteSkip: nil)
    #expect(reason == .chromiumOmniboxNavigationSeam)
  }

  @Test("An ordinary text field — Chromium or not — still runs Tier 1")
  func ordinaryTextFieldRunsTier1() {
    let reason = tier1DeclineReason(
      axTrusted: true, classification: .textField, isChromiumOmnibox: false,
      directWriteSkip: nil)
    #expect(reason == nil)
  }

  @Test("Accessibility being untrusted outranks the Chromium omnibox reason")
  func accessibilityDeniedOutranksChromiumReason() {
    // If AX itself is denied, `isChromiumOmnibox` could never have been
    // computed truthfully (it requires an AX read) — the untrusted branch
    // must win regardless of what is passed for it.
    let reason = tier1DeclineReason(
      axTrusted: false, classification: .textField, isChromiumOmnibox: true,
      directWriteSkip: nil)
    #expect(reason == .accessibilityDenied)
  }

  @Test("A recorded-window session declines Tier 1, even for a field, with its own reason (#3304)")
  func recordedWindowDeclinesTier1() {
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .textField, isChromiumOmnibox: false,
        directWriteSkip: nil, recordedWindowSession: true) == .recordedWindowKeyPasteOnly)
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .textField, isChromiumOmnibox: true,
        directWriteSkip: .gecko, recordedWindowSession: true) == .recordedWindowKeyPasteOnly,
      "the recorded window outranks the omnibox and Gecko declines")
    // Accessibility denied, missing focus and non-text focus keep their own reasons.
    #expect(
      tier1DeclineReason(
        axTrusted: false, classification: .textField, isChromiumOmnibox: false,
        directWriteSkip: nil, recordedWindowSession: true) == .accessibilityDenied)
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .missing, isChromiumOmnibox: false,
        directWriteSkip: nil, recordedWindowSession: true) == .focusMissing)
    // Control: without a recorded window a plain field still runs Tier 1.
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .textField, isChromiumOmnibox: false,
        directWriteSkip: nil) == nil)
  }

  @Test("A Gecko browser's text field declines Tier 1 with its own reason (#2652)")
  func geckoDeclinesTier1() {
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .textField, isChromiumOmnibox: false,
        directWriteSkip: .gecko) == .geckoDirectWriteUnconfirmable)
    // Accessibility denied, missing focus and non-text focus keep their own reasons.
    #expect(
      tier1DeclineReason(
        axTrusted: false, classification: .textField, isChromiumOmnibox: false,
        directWriteSkip: .gecko) == .accessibilityDenied)
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .missing, isChromiumOmnibox: false,
        directWriteSkip: .gecko) == .focusMissing)
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: .nonText, isChromiumOmnibox: false,
        directWriteSkip: .gecko) == .focusNonText)
  }

  @Test("cmux skips the direct write while existing decline precedence remains")
  func cmuxDeclinePrecedence() {
    let skip = PasteDeliveryPolicy.directWriteSkip(bundleID: "com.cmuxterm.app")
    #expect(skip == .terminal)
    #expect(PasteFocusClassification.textField.canAttemptKeyPaste)

    let rows: [
      (Bool, PasteFocusClassification, Bool, Bool, PasteService.AXDeclineReason)
    ] = [
      (true, .textField, false, false, .terminalDirectWriteUnconfirmable),
      (false, .textField, false, false, .accessibilityDenied),
      (true, .textField, true, false, .chromiumOmniboxNavigationSeam),
      (true, .textField, true, true, .recordedWindowKeyPasteOnly),
      (true, .missing, false, false, .focusMissing),
      (true, .nonText, false, false, .focusNonText),
    ]
    for (trusted, classification, omnibox, recordedWindow, expected) in rows {
      #expect(
        tier1DeclineReason(
          axTrusted: trusted, classification: classification,
          isChromiumOmnibox: omnibox, directWriteSkip: skip,
          recordedWindowSession: recordedWindow) == expected)
    }

    for id: String? in [
      nil, "", "com.cmuxterm.app.helper", "COM.CMUXTERM.APP",
      "com.stablyai.orca", "com.google.antigravity-ide",
    ] {
      #expect(PasteDeliveryPolicy.directWriteSkip(bundleID: id) == nil)
    }
  }

  @Test("Exactly the four verified Gecko bundle IDs skip the direct write as Gecko; no other browser does")
  func geckoBundleIDsAreExact() {
    let gecko = [
      "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
      "app.zen-browser.zen",
    ]
    for id in gecko {
      #expect(PasteDeliveryPolicy.directWriteSkip(bundleID: id) == .gecko, "\(id)")
    }
    #expect(PasteDeliveryPolicy.directWriteSkips.filter { $0.value == .gecko }.count == gecko.count)
    // The one other listed destination is cmux (#3863), with its own reason.
    #expect(PasteDeliveryPolicy.directWriteSkips.count == gecko.count + 1)
    let others: [String?] = [
      nil, "", "com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
      "com.microsoft.edgemac", "com.apple.TextEdit", "org.mozilla.firefox.helper",
      "ORG.MOZILLA.FIREFOX", "org.mozilla", "org.mozilla.librewolf",
    ]
    for id in others {
      #expect(PasteDeliveryPolicy.directWriteSkip(bundleID: id) == nil, "\(String(describing: id))")
    }
  }

  @Test("A Chromium address bar still yields the ordinary reason for .missing and .nonText")
  func nonTextFieldClassificationsUnaffectedByChromiumFlag() {
    #expect(
      tier1DeclineReason(axTrusted: true, classification: .missing, isChromiumOmnibox: true,
      directWriteSkip: nil)
        == .focusMissing)
    #expect(
      tier1DeclineReason(axTrusted: true, classification: .nonText, isChromiumOmnibox: true,
      directWriteSkip: nil)
        == .focusNonText)
  }
}
