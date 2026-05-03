import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite("PasteDeliveryResult pasteTierLabel")
struct PasteDeliveryResultLabelTests {

  @Test("AX-denied clipboard outcome uses sentinel paste tier label")
  func axDeniedClipboardOutcomeUsesSentinelLabel() {
    let result = PasteDeliveryResult(
      tier: .clipboardOnly,
      durationMs: 4,
      outcome: .clipboardOnlyAccessibilityDenied(targetBundleID: "com.example.target")
    )

    #expect(result.pasteTierLabel == "clipboard_only_ax_denied")
  }

  @Test("non-AX-denied outcomes use raw tier value")
  func nonAXDeniedOutcomesUseRawTierValue() {
    let results: [PasteDeliveryResult] = [
      PasteDeliveryResult(
        tier: .axDirect,
        durationMs: 1,
        outcome: .delivered(tier: .axDirect, durationMs: 1)
      ),
      PasteDeliveryResult(
        tier: .cgEvent,
        durationMs: 2,
        outcome: .delivered(tier: .cgEvent, durationMs: 2)
      ),
      PasteDeliveryResult(
        tier: .appleScript,
        durationMs: 3,
        outcome: .delivered(tier: .appleScript, durationMs: 3)
      ),
      PasteDeliveryResult(
        tier: .clipboardOnly,
        durationMs: 4,
        outcome: .delivered(tier: .clipboardOnly, durationMs: 4)
      ),
      PasteDeliveryResult(
        tier: .clipboardOnly,
        durationMs: 5,
        outcome: .clipboardOnly(
          tiersAttempted: [],
          focus: .missing,
          targetBundleID: nil
        )
      ),
      PasteDeliveryResult(
        tier: .clipboardOnly,
        durationMs: 6,
        outcome: .cgEventCreationFailed(accessibilityTrusted: false)
      ),
    ]

    for result in results {
      #expect(result.pasteTierLabel == result.tier.rawValue)
    }
  }
}
