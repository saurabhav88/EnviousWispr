import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

@MainActor
@Suite("Paste telemetry payload")
struct PasteTelemetryPayloadTests {

  @Test("clipboard-only payload includes captured target diagnostics")
  func clipboardOnlyPayloadIncludesTargetDiagnostics() {
    let extra = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(
      tiersAttempted: [],
      focus: .nonText,
      targetBundleID: "us.zoom.xos",
      accessibilityTrusted: true,
      targetDiagnostics: PasteElementDiagnostics(
        role: "AXGroup",
        subrole: "AXUnknown",
        roleSource: "captured_target",
        subroleStatus: "present"
      ),
      tierFailures: [:]
    )

    #expect(extra["paste.tiers_attempted"] as? [String] == [])
    #expect(extra["paste.focus_classification"] as? String == "non_text")
    #expect(extra["paste.target_bundle_id"] as? String == "us.zoom.xos")
    #expect(extra["paste.outcome"] as? String == "clipboard_only")
    #expect(extra["paste.accessibility_trusted"] as? Bool == true)
    #expect(extra["paste.target_element_role"] as? String == "AXGroup")
    #expect(extra["paste.target_element_subrole"] as? String == "AXUnknown")
    #expect(extra["paste.target_element_role_source"] as? String == "captured_target")
    #expect(extra["paste.target_element_subrole_status"] as? String == "present")
    assertNoContentLikeKeys(extra)
  }

  @Test("clipboard-only payload records missing target without changing fallback shape")
  func clipboardOnlyPayloadRecordsMissingTarget() {
    let extra = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(
      tiersAttempted: ["cgevent"],
      focus: .missing,
      targetBundleID: nil,
      accessibilityTrusted: true,
      targetDiagnostics: .missing,
      tierFailures: ["activation": "timeout_ms=1000"]
    )

    #expect(extra["paste.focus_classification"] as? String == "missing")
    #expect(extra["paste.target_bundle_id"] is NSNull)
    #expect(extra["paste.accessibility_trusted"] as? Bool == true)
    #expect(extra["paste.target_element_role"] is NSNull)
    #expect(extra["paste.target_element_subrole"] is NSNull)
    #expect(extra["paste.target_element_role_source"] as? String == "missing")
    #expect(extra["paste.target_element_subrole_status"] as? String == "missing")
    #expect((extra["paste.tier_failures"] as? [String: String])?["activation"] == "timeout_ms=1000")
  }

  @Test("AX-denied path is distinguishable from trusted non-text fallback")
  func axDeniedPathIsDistinguishable() {
    let extra = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(
      tiersAttempted: [],
      focus: .nonText,
      targetBundleID: "com.example.target",
      accessibilityTrusted: false,
      targetDiagnostics: .unavailable,
      tierFailures: [:]
    )

    #expect(extra["paste.focus_classification"] as? String == "non_text")
    #expect(extra["paste.accessibility_trusted"] as? Bool == false)
    #expect(extra["paste.target_element_role_source"] as? String == "unavailable")
    #expect(extra["paste.target_element_subrole_status"] as? String == "unavailable")
  }

  @Test("AX role diagnostics are capped and scrubbed before telemetry")
  func axRoleDiagnosticsAreCappedAndScrubbed() {
    let longRole = "AX" + String(repeating: "VeryLongRole", count: 20)
    let extra = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(
      tiersAttempted: [],
      focus: .nonText,
      targetBundleID: "com.example.target",
      accessibilityTrusted: true,
      targetDiagnostics: PasteElementDiagnostics(
        role: longRole,
        subrole: " AXSubrole With Spaces 🚨 ",
        roleSource: "captured_target",
        subroleStatus: "present"
      ),
      tierFailures: [:]
    )

    let role = extra["paste.target_element_role"] as? String
    let subrole = extra["paste.target_element_subrole"] as? String

    #expect(role?.count == 128)
    #expect(subrole == "AXSubrole_With_Spaces__")
    #expect(extra["paste.target_element_subrole_status"] as? String == "present")
    assertNoContentLikeKeys(extra)
  }

  @Test("#729: focus_class present only when the menu probe ran")
  func focusClassPresentOnlyWhenProbed() {
    // No probe (default nil) -> key absent.
    let noProbe = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(
      tiersAttempted: [],
      focus: .nonText,
      targetBundleID: "com.microsoft.Word",
      accessibilityTrusted: true,
      targetDiagnostics: .missing,
      tierFailures: [:]
    )
    #expect(noProbe["paste.focus_class"] == nil)

    // Scenario A: probe ran, no paste target.
    let noTarget = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(
      tiersAttempted: [],
      focus: .nonText,
      targetBundleID: "com.microsoft.Word",
      accessibilityTrusted: true,
      targetDiagnostics: .missing,
      tierFailures: [:],
      focusClass: "no_paste_target"
    )
    #expect(noTarget["paste.focus_class"] as? String == "no_paste_target")
    assertNoContentLikeKeys(noTarget)
  }

  @Test("absent menu probe keeps full alerting, does not default to downgrade (Codex code-diff r2)")
  func absentMenuProbeKeepsAlerting() {
    // focusClass is nil whenever Tier 2c's probe never ran or never resolved:
    // activation timeout, a terminated target app, or no target app captured
    // at all. None of these confirm "no real target" -- only an explicit
    // "no_paste_target" result does, so nil must NOT default to a downgrade.
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "captured_target", focusClass: nil
      ) == false
    )
  }

  @Test("confident non-text refusal with a confirmed-no-target probe downgrades")
  func confirmedNoTargetProbeDowngrades() {
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "captured_target", focusClass: "no_paste_target"
      ) == true
    )
  }

  @Test("menu probe finding a real paste target keeps full alerting (Codex code-diff r1)")
  func menuProbeFoundRealTargetKeepsAlerting() {
    // Tier 2c found an enabled Edit > Paste item and pressing it failed
    // (tierFailures["menu_paste"] == "press_failed") -- a real paste failure,
    // not a no-target refusal, even though the earlier AX role read said
    // non-text with high confidence.
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "captured_target",
        focusClass: "non_text_with_paste_target"
      ) == false
    )
  }

  @Test("failed role identification keeps full alerting")
  func failedRoleIdentificationKeepsAlerting() {
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "unavailable", focusClass: nil
      ) == false
    )
  }

  @Test("missing target keeps full alerting regardless of roleSource")
  func missingTargetKeepsAlerting() {
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .missing, roleSource: "captured_target", focusClass: nil
      ) == false
    )
  }

  @Test("text field focus keeps full alerting regardless of roleSource")
  func textFieldFocusKeepsAlerting() {
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .textField, roleSource: "captured_target", focusClass: nil
      ) == false
    )
  }

  @Test("unrecognized roleSource string fails closed to full alerting")
  func unrecognizedRoleSourceFailsClosed() {
    // Guards against an unrelated future rename of the "captured_target"
    // literal elsewhere silently reopening the false-positive noise (#1430).
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "ax_success", focusClass: nil
      ) == false
    )
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "", focusClass: nil
      ) == false
    )
  }

  @Test("unrecognized focusClass string fails closed to full alerting")
  func unrecognizedFocusClassFailsClosed() {
    // Guards the same fail-closed invariant for the focusClass corroboration:
    // an unrelated future label added to MenuPasteProbe must not silently
    // reopen the false-positive noise by being mistaken for "no target".
    #expect(
      PasteCascadeExecutor.isExpectedNonTextRefusal(
        focus: .nonText, roleSource: "captured_target", focusClass: "some_future_label"
      ) == false
    )
  }

  private func assertNoContentLikeKeys(_ extra: [String: Any]) {
    for key in extra.keys {
      let lower = key.lowercased()
      #expect(!lower.contains("text"))
      #expect(!lower.contains("transcript"))
      #expect(!lower.contains("content"))
      #expect(!lower.contains("prompt"))
      #expect(!lower.contains("output"))
    }
  }
}
