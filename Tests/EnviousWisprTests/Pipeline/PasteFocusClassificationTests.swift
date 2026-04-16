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
}
