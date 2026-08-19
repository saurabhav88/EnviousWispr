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

  /// One decision-boundary table replaces nine per-case tests (#1332). Not a
  /// generated cross-product — four arguments do not enumerate — so it is
  /// boundary rows, each ACCEPTED one paired with a near-identical REJECTED one
  /// so a predicate that stopped classifying anything cannot look clean.
  ///
  /// Rows 2 and 11 pin combinations that are NOT reachable today (appending
  /// `menu_paste` requires an enabled item, and a CGEvent failure becomes
  /// `.cgEventCreationFailed` and bypasses this predicate). They are kept as
  /// defence in depth and are deliberately NOT counted as evidence that the
  /// guard binds reachable behaviour — rows 12 and 13 do that.
  ///
  /// What the retired tests protected, and where each now lives:
  /// absent menu probe -> row 3 · confirmed-no-target downgrades -> row 1 ·
  /// failed role identification -> row 3 (roleSource is no longer an input) ·
  /// missing target -> row 8 · text-field focus -> row 9 ·
  /// unreadable menu probe -> row 5 · unrecognised focusClass -> row 7 ·
  /// unrecognised roleSource -> removed by the predicate signature, so it is a
  /// compile error rather than a row · real paste target keeps alerting ->
  /// rows 4 AND 12, because the real press-failure path always carries the
  /// `menu_paste` tier that row 4 alone omits.
  @Test("expected-refusal predicate fails closed across documented decision boundaries")
  func expectedRefusalMatrix() {
    let cases: [([String], PasteFocusClassification, String?, String?, Bool)] = [
      ([], .nonText, "no_paste_target", "com.apple.finder", true),
      (["menu_paste"], .nonText, "no_paste_target", "com.apple.finder", false),
      ([], .nonText, nil, "com.apple.finder", false),
      ([], .nonText, "non_text_with_paste_target", "com.apple.finder", false),
      ([], .nonText, "non_text_menu_unreadable", "com.apple.finder", false),
      ([], .nonText, "non_text_menu_depth_limit", "com.apple.finder", false),
      ([], .nonText, "some_future_label", "com.apple.finder", false),
      ([], .missing, "no_paste_target", "com.apple.finder", false),
      ([], .textField, "no_paste_target", "com.apple.finder", false),
      ([], .missing, nil, "com.apple.loginwindow", true),
      (["cgevent"], .missing, nil, "com.apple.loginwindow", false),
      // Reachable states the first eleven rows missed (Codex chunk-1b review).
      // A menu press that FAILED still carries its tier and an enabled-target
      // label, which is the real shape of the retired real-paste-target test.
      (["menu_paste"], .nonText, "non_text_with_paste_target", "com.apple.finder", false),
      // An attempted paste on the LOCK SCREEN: binds the empty-tiers guard's
      // precedence over the lock-screen acceptance, which nothing else pins.
      (["applescript"], .missing, nil, "com.apple.loginwindow", false),
    ]
    for (tiers, focus, focusClass, bundle, expected) in cases {
      #expect(
        PasteCascadeExecutor.isExpectedNonTextRefusal(
          tiersAttempted: tiers,
          focus: focus,
          focusClass: focusClass,
          targetBundleID: bundle
        ) == expected,
        "tiers=\(tiers) focus=\(focus) focusClass=\(focusClass ?? "nil") bundle=\(bundle ?? "nil")"
      )
    }
  }

  @Test("menu probe outcomes map to stable focus-class labels")
  func menuProbeOutcomesMapToStableLabels() {
    #expect(
      PasteCascadeExecutor.MenuPasteProbe.targetEnabled.focusClassLabel
        == "non_text_with_paste_target")
    #expect(PasteCascadeExecutor.MenuPasteProbe.noTarget.focusClassLabel == "no_paste_target")
    #expect(
      PasteCascadeExecutor.MenuPasteProbe.unreadable.focusClassLabel
        == "non_text_menu_unreadable")
    #expect(
      PasteCascadeExecutor.MenuPasteProbe.depthLimited.focusClassLabel
        == "non_text_menu_depth_limit")
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
