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
