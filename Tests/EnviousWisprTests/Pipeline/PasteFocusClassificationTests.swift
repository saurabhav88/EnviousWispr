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

  @Test("similar-looking but not-actually-pake prefix is rejected")
  func similarPrefixRejected() {
    // Test the hard edge: bundle id starting with "com.pak" should NOT match
    // (only "com.pake." matches).
    let c = classifyPasteFocus(
      elementPresent: true, roleIsTextField: false,
      targetBundleID: "com.pakistan.app")
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

  // MARK: - #1070: remote-desktop windows

  /// Roles and subroles as production Sentry recorded them (`paste.target_element_role` /
  /// `paste.target_element_subrole`, ENVIOUSWISPR-24, 30 days to 2026-11-21).
  private func classify(
    _ bundle: String?, role: String?, subrole: String?, textRole: Bool = false
  ) -> PasteFocusClassification {
    classifyPasteFocus(
      elementPresent: true, roleIsTextField: textRole, targetBundleID: bundle,
      focusRole: role, focusSubrole: subrole)
  }

  @Test(
    "A remote client's own standard window is a remote session: key paste allowed, Tier 1 declined",
    arguments: [
      "com.citrix.receiver.icaviewer.mac", "com.utmapp.UTM", "com.parallels.desktop.console",
      "com.microsoft.rdc.macos", "com.carriez.rustdesk", "com.splashtop.stb.macosx",
    ])
  func remoteClientWindowIsRemoteSession(_ bundle: String) {
    let c = classify(bundle, role: "AXWindow", subrole: "AXStandardWindow")
    #expect(c == .remoteSession)
    #expect(c.canAttemptKeyPaste)
    #expect(
      tier1DeclineReason(
        axTrusted: true, classification: c, isChromiumOmnibox: false, directWriteSkip: nil)
        == .focusRemoteSession)
  }

  @Test("Screen Sharing's shared screen stays non-text (#3279 is out of scope)")
  func screenSharingStaysNonText() {
    #expect(classify("com.apple.ScreenSharing", role: "AXSharedScreen", subrole: nil) == .nonText)
  }

  @Test("The macOS password dialog never becomes a remote session")
  func securityAgentStaysNonText() {
    let c = classify("com.apple.SecurityAgent", role: "AXWindow", subrole: "AXStandardWindow")
    #expect(c == .nonText)
    #expect(!c.canAttemptKeyPaste)
  }

  @Test("A password field in a remote client keeps today's classification")
  func secureFieldsKeepTodaysRoute() {
    // `AXSecureTextField` as a ROLE is not a text role, so it is non-text, never a remote session.
    #expect(
      classify("com.citrix.receiver.icaviewer.mac", role: "AXSecureTextField", subrole: nil)
        == .nonText)
    // As a SUBROLE of `AXTextField` it is a text field today, unchanged by #1070.
    #expect(
      classify(
        "com.citrix.receiver.icaviewer.mac", role: "AXTextField", subrole: "AXSecureTextField",
        textRole: true) == .textField)
  }

  @Test("A remote client's dialogs and its own login box keep today's classification")
  func remoteClientDialogsAndFields() {
    let citrix = "com.citrix.receiver.icaviewer.mac"
    #expect(classify(citrix, role: "AXWindow", subrole: "AXDialog") == .nonText)
    #expect(classify(citrix, role: "AXWindow", subrole: "AXSystemDialog") == .nonText)
    #expect(classify(citrix, role: "AXTextField", subrole: nil, textRole: true) == .textField)
  }

  @Test(
    "A local app's standard window stays non-text",
    arguments: ["org.gnu.Emacs", "com.apple.Safari", "ru.keepcoder.Telegram", "com.enviouswispr.app"])
  func localStandardWindowStaysNonText(_ bundle: String) {
    #expect(classify(bundle, role: "AXWindow", subrole: "AXStandardWindow") == .nonText)
  }

  @Test("An unreadable role or subrole, or no bundle, stays non-text")
  func unreadableDiagnosticsStayNonText() {
    let citrix = "com.citrix.receiver.icaviewer.mac"
    #expect(classify(citrix, role: nil, subrole: nil) == .nonText)
    #expect(classify(citrix, role: "AXWindow", subrole: nil) == .nonText)
    #expect(classify(citrix, role: nil, subrole: "AXStandardWindow") == .nonText)
    #expect(classify(nil, role: "AXWindow", subrole: "AXStandardWindow") == .nonText)
  }

  @Test("A near-miss bundle stays non-text: the list matches exactly")
  func nearMissBundlesStayNonText() {
    // The Citrix Workspace app's own local window reached `cgevent` in production on its own.
    for bundle in ["com.citrix.receiver.nomas", "com.citrix.receiver.icaviewer.mac.helper"] {
      #expect(classify(bundle, role: "AXWindow", subrole: "AXStandardWindow") == .nonText, "\(bundle)")
    }
  }
}
