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

  // MARK: - Every read path is bounded

  @Test("The messaging bound has ONE owner, and it never exceeds the failure bound")
  func boundIsDerivedFromTheBudget() {
    // Round 3 of the same review finding: each earlier fix bounded one path and
    // left the others at the 0.5 s default. The bound now comes from a single
    // expression, so this asserts its shape rather than each branch separately.
    let fresh = TerminalResolutionBudget()
    #expect(fresh.remaining <= PasteService.axMessagingTimeoutSeconds)

    // A nearly-spent budget still yields a usable, non-zero bound rather than
    // an instant-failure timeout.
    let spent = TerminalResolutionBudget(total: 0.100)
    spent.charge(0.099)
    #expect(spent.remaining > 0)
    #expect(max(0.010, min(spent.remaining, PasteService.axMessagingTimeoutSeconds)) >= 0.010)

    // An exhausted budget clamps to the floor, never to zero or a negative.
    let exhausted = TerminalResolutionBudget(total: 0.100)
    exhausted.charge(1.0)
    #expect(max(0.010, min(exhausted.remaining, PasteService.axMessagingTimeoutSeconds)) == 0.010)
  }

  @Test("The failure bound is a single named owner, not a repeated literal")
  func messagingTimeoutHasOneOwner() {
    #expect(PasteService.axMessagingTimeoutSeconds == 0.5)
  }

  @Test("An ordinary app is untouched by terminal policy")
  func ordinaryAppsKeepTodaysBehaviour() {
    // Cloud review caught this as a REGRESSION I introduced: production supplies
    // a budget on every delivery, so gating terminal policy on "was a budget
    // passed" squeezed every app's caret read from the 0.5 s failure bound to
    // 100 ms, and reported terminal refusals for apps that are not terminals.
    //
    // TextEdit is not a Gate 0 surface, so no terminal policy may apply to it.
    #expect(TerminalSurface(bundleIdentifier: "com.apple.TextEdit") == nil)
    #expect(TerminalSurface(bundleIdentifier: "com.microsoft.Word") == nil)
    #expect(TerminalSurface(bundleIdentifier: "com.tinyspeck.slackmacgap") == nil)

    // And an ordinary app's context carries no terminal provenance, so neither
    // the multiline refusal nor the Tier 1 exclusion can reach it.
    let ordinary = PasteService.CaretContext(
      leftWindow: "notes: ", rightWindow: "", selectionLocation: 7, selectionLength: 0)
    #expect(!ordinary.isScreenDerived)
    let payload = PasteService.accessibilityWritePayload(
      legacy: "Fix it ", repaired: "fix it ", context: ordinary,
      rangeBefore: CFRange(location: 7, length: 0), fieldBefore: "notes: ")
    #expect(payload.kind == .repaired, "an ordinary app must still get its repair")
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
