import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

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

  @Test("Unverifiable AX write keeps the clipboard-only presentation label")
  func axWriteUnverifiableUsesClipboardOnlyLabel() {
    // The typed result records that the destination is unknown, but the user
    // still sees the ordinary clipboard notice — no new user-facing state.
    let result = PasteDeliveryResult(
      tier: .clipboardOnly,
      durationMs: 1,
      outcome: .axWriteUnverifiable(
        targetBundleID: "com.example.target",
        targetDiagnostics: .unavailable
      )
    )

    #expect(result.pasteTierLabel == PasteTier.clipboardOnly.rawValue)
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
        tier: .menuPaste,
        durationMs: 3,
        outcome: .delivered(tier: .menuPaste, durationMs: 3)
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
          targetBundleID: nil,
          accessibilityTrusted: true,
          targetDiagnostics: .missing
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
