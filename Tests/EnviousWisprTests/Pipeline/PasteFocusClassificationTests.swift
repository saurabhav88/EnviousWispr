import Testing

@testable import EnviousWisprPipeline

@Suite("PasteFocusClassification")
struct PasteFocusClassificationTests {

  @Test("Text field role with element present -> .textField")
  func textFieldRole() {
    let c = classifyPasteFocus(elementPresent: true, roleIsTextField: true)
    #expect(c == .textField)
    #expect(c.canAttemptKeyPaste)
  }

  @Test("Element missing -> .missing (Chromium/Electron lazy AX)")
  func missingElement() {
    let c = classifyPasteFocus(elementPresent: false, roleIsTextField: false)
    #expect(c == .missing)
    #expect(
      c.canAttemptKeyPaste,
      "Missing element must still allow Cmd+V: browsers and Electron apps often have a real DOM input focused even when AX reports nil (#277)."
    )
  }

  @Test("Non-text role with element present -> .nonText (PR #220 void protection)")
  func nonTextRole() {
    let c = classifyPasteFocus(elementPresent: true, roleIsTextField: false)
    #expect(c == .nonText)
    #expect(
      !c.canAttemptKeyPaste,
      "Non-text focused element must block Cmd+V so users see the clipboard overlay instead of pasting into a void (#219 / PR #220)."
    )
  }

  @Test("roleIsTextField is ignored when element is missing")
  func missingDominatesRole() {
    let c = classifyPasteFocus(elementPresent: false, roleIsTextField: true)
    #expect(c == .missing)
  }

  // MARK: - #729: web-wrapper bundle-id hint

  @Test("non-text element in Pake (com.pake.*) classifies as .missing, allowing Cmd+V")
  func pakeBundleIDPromotesNonTextToMissing() {
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false,
      targetBundleID: "com.pake.c6796d")
    #expect(c == .missing)
    #expect(c.canAttemptKeyPaste, "Cmd+V must be attempted into Pake's web view")
  }

  @Test("non-text element in Tauri (com.tauri.*) classifies as .missing")
  func tauriBundleIDPromotesNonTextToMissing() {
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false,
      targetBundleID: "com.tauri.dev")
    #expect(c == .missing)
  }

  @Test("non-text element in native Mac app (com.apple.*) still classifies as .nonText")
  func nativeBundleIDStillNonText() {
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false,
      targetBundleID: "com.apple.Notes")
    #expect(c == .nonText, "Native Mac apps must NOT be promoted — Cmd+V would fire into a void")
    #expect(!c.canAttemptKeyPaste)
  }

  @Test("nil bundle id leaves the existing nonText behavior unchanged")
  func nilBundleIDPreservesExistingBehavior() {
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false, targetBundleID: nil)
    #expect(c == .nonText)
  }

  @Test("text-field role wins over wrapper-bundle hint (full cascade applies)")
  func textFieldRoleWinsOverWrapperHint() {
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: true,
      targetBundleID: "com.pake.c6796d")
    #expect(c == .textField)
  }

  @Test("missing element with wrapper-bundle hint still classifies as .missing")
  func missingElementWithWrapperHint() {
    let c = classifyPasteFocus(
      elementPresent: false, roleIsTextField: false,
      targetBundleID: "com.pake.c6796d")
    #expect(c == .missing)
  }

  @Test("similar-looking but not-actually-pake prefix is rejected")
  func similarPrefixRejected() {
    // Test the hard edge: bundle id starting with "com.pak" should NOT match
    // (only "com.pake." matches).
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false,
      targetBundleID: "com.pakistan.app")
    #expect(c == .nonText)
  }

  @Test("AX-denied path passes nil bundle id so wrapper hint cannot bypass accessibility toast")
  func axDeniedPathDoesNotReceiveHint() {
    // This test documents the contract at PasteCascadeExecutor:152-153:
    // when AX is not trusted, the cascade MUST NOT pass the bundle id to the
    // classifier. Otherwise a com.pake.* target would be promoted to
    // `.missing` and skip the educational accessibility-denied toast.
    // We assert the helper's behavior directly: simulate the AX-denied call
    // by passing nil and verifying it returns `.nonText` regardless of the
    // bundle id we *would* have passed if AX were granted.
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false, targetBundleID: nil)
    #expect(c == .nonText)
  }

  @Test("isKnownWebWrapperBundle: positive and negative cases")
  func wrapperRecognizerCases() {
    #expect(isKnownWebWrapperBundle("com.pake.c6796d"))
    #expect(isKnownWebWrapperBundle("com.pake."))  // bare prefix matches
    #expect(isKnownWebWrapperBundle("com.tauri.dev"))
    #expect(!isKnownWebWrapperBundle("com.pak"))  // close but not equal
    #expect(!isKnownWebWrapperBundle("com.apple.Notes"))
    #expect(!isKnownWebWrapperBundle("com.slack.app"))
    #expect(!isKnownWebWrapperBundle(nil))
    #expect(!isKnownWebWrapperBundle(""))
  }
}
