import Foundation
import Testing

@testable import EnviousWisprPostProcessing
@testable import EnviousWisprServices

/// The policy the wiring introduces: what a SCREEN-derived context may and may
/// not authorise.
///
/// These are the rules that keep a terminal read from reaching a route whose
/// safety argument depends on evidence a screen cannot supply.
@Suite("Terminal insertion policy")
struct TerminalInsertionPolicyTests {

  /// Every word this suite dictates is an ordinary lowercase word, so the
  /// leading-case rule is exercised rather than skipped as a proper noun.
  static let ordinaryWords = EnglishWordOracle(
    unavailableReason: nil,
    dictionaryVerdict: { ["fix", "first", "second", "a", "b"].contains($0) ? .ordinary : .notOrdinary },
    isLearnedWord: { _ in false },
    isRecognizedName: { _, _ in false })

  private func terminalContext(line: String) -> PasteService.CaretContext {
    PasteService.CaretContext(
      leftWindow: line,
      rightWindow: "",
      selectionLocation: line.utf16.count,
      selectionLength: 0,
      terminalEvidence: TerminalEvidence(
        surface: .ghostty,
        runningCLIs: [.init(processIdentifier: 42, cli: .claudeCode)],
        screenTail: "\u{276F} \(line)",
        located: .init(cli: .claudeCode, inputLine: line)))
  }

  // MARK: - Provenance

  @Test("A caret-derived context is not screen-derived, and a terminal one is")
  func provenanceIsTyped() {
    let caret = PasteService.CaretContext(
      leftWindow: "abc", rightWindow: "", selectionLocation: 3, selectionLength: 0)
    #expect(!caret.isScreenDerived)
    #expect(terminalContext(line: "abc").isScreenDerived)
  }

  @Test("The screen tail is the identity: a scrolled buffer is a different context")
  func screenTailParticipatesInEquality() {
    // A screen-derived context has no selection offsets to compare, so the raw
    // tail is the ONLY thing that can detect the buffer moving underneath it.
    let line = "git commit -m fix the"
    let original = terminalContext(line: line)
    let scrolled = PasteService.CaretContext(
      leftWindow: line, rightWindow: "", selectionLocation: line.utf16.count, selectionLength: 0,
      terminalEvidence: TerminalEvidence(
        surface: .ghostty,
        runningCLIs: [.init(processIdentifier: 42, cli: .claudeCode)],
        screenTail: "one more line\n\u{276F} \(line)",
        located: .init(cli: .claudeCode, inputLine: line)))
    #expect(original != scrolled)
  }

  @Test("A terminal context's right window is empty by construction")
  func rightWindowIsEmptyByConstruction() {
    // This is what keeps the drop-our-full-stop rule inert in a terminal: that
    // rule needs a character to the RIGHT, and under the founder's end-of-line
    // assumption there is none.
    #expect(terminalContext(line: "some text").rightWindow.isEmpty)
  }

  // MARK: - The rules that DO run

  @Test("The leading capital is lowered when continuing a sentence in a terminal")
  func loweringHappensInATerminal() {
    // The complaint this whole feature exists for: pause mid-sentence, resume,
    // and the next word arrives capitalised.
    let payloads = CursorInsertionRepair.repair(
      text: "Fix the handler",
      context: .init(left: "git commit -m ", right: "", isScreenDerived: true),
      protectedWords: [],
      oracle: Self.ordinaryWords)
    #expect(payloads.repairedText?.hasPrefix("fix") == true)
  }

  @Test("A sentence that genuinely ends keeps its capital")
  func capitalSurvivesAfterAFullStop() {
    let payloads = CursorInsertionRepair.repair(
      text: "Fix the handler",
      context: .init(left: "done. ", right: "", isScreenDerived: true),
      protectedWords: [],
      oracle: Self.ordinaryWords)
    #expect(payloads.repairedText?.hasPrefix("Fix") != false)
  }

  // MARK: - The multiline refusal

  @Test(
    "A screen-derived payload containing ANY line break refuses",
    arguments: ["a\nb", "a\r\nb", "a\rb", "a\u{2028}b", "a\u{2029}b", "a\u{0085}b"])
  func screenDerivedMultilineRefuses(text: String) {
    // A screen-derived context describes ONE rendered row, and in a terminal a
    // newline can SUBMIT the command. Refusing is cheaper than reasoning.
    let payloads = CursorInsertionRepair.repair(
      text: text,
      context: .init(left: "git commit -m ", right: "", isScreenDerived: true),
      protectedWords: [],
      oracle: Self.ordinaryWords)
    #expect(payloads.repairedText == nil, "a line break must refuse in a terminal")
    #expect(payloads.legacyText.hasPrefix(text))
  }

  @Test("The same payload is NOT refused in an ordinary app")
  func caretDerivedMultilineIsUnaffected() {
    // The two-way control: the refusal must be scoped to screen-derived
    // contexts, not applied to every app in the product.
    let payloads = CursorInsertionRepair.repair(
      text: "first\nsecond",
      context: .init(left: "notes: ", right: "", isScreenDerived: false),
      protectedWords: [],
      oracle: Self.ordinaryWords)
    #expect(payloads.repairedText != nil, "ordinary apps must keep today's behaviour")
  }

  // MARK: - Tier 1 exclusion

  @Test("Screen evidence never authorises the accessibility-write route")
  func tierOneNeverCommitsAScreenDerivedRepair() {
    // Every OTHER condition is deliberately satisfied — matching offsets and a
    // field whose windows agree — so the ONLY thing that can refuse here is the
    // screen-derived rule itself. An earlier version of this test passed a nil
    // element and therefore proved "no element means legacy" instead.
    let line = "git commit -m fix the"
    let context = terminalContext(line: line)
    let payload = PasteService.accessibilityWritePayload(
      legacy: "Fix the handler ",
      repaired: "fix the handler ",
      context: context,
      rangeBefore: CFRange(location: context.selectionLocation, length: 0),
      fieldBefore: line)
    #expect(payload.kind == .legacy)
    #expect(payload.text == "Fix the handler ")
  }

  @Test("A caret-derived repair IS authorised on the same route")
  func tierOneCommitsACaretDerivedRepair() {
    // The two-way control. Without it, the test above could pass because the
    // route refuses everything.
    let left = "git commit -m "
    let caret = PasteService.CaretContext(
      leftWindow: left, rightWindow: "", selectionLocation: left.utf16.count, selectionLength: 0)
    let payload = PasteService.accessibilityWritePayload(
      legacy: "Fix the handler ",
      repaired: "fix the handler ",
      context: caret,
      rangeBefore: CFRange(location: left.utf16.count, length: 0),
      fieldBefore: left)
    #expect(payload.kind == .repaired)
    #expect(payload.text == "fix the handler ")
  }

  @Test("A nil element at a commit boundary always takes today's payload")
  func commitBoundaryWithoutAnElementIsLegacy() {
    let payload = PasteService.payloadAtCommitBoundary(
      legacy: "legacy ", repaired: "repaired ", context: nil, element: nil)
    #expect(payload.kind == .legacy)
  }
}
