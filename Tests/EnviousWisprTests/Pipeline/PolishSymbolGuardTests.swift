import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3038 Guard 4: a slash or backslash the deterministic text carried must survive polish. When
/// one of these fails the user says "apples slash bananas slash strawberries" and gets "apples,
/// bananas, or strawberries" (EG-1, 2026-09-18), or says "users backslash shared" and gets
/// `users/shared` (#2957). The guard is exercised through the real `validatePolishOutput`, so the
/// three older guards' precedence is measured, not assumed.
@Suite(.tags(.productOutcome))
@MainActor
struct PolishSymbolGuardTests {

  private let step = LLMPolishStep(keychainManager: KeychainManager())

  private func validate(_ polished: String, original: String) -> LLMPolishStep.PolishValidation {
    step.validatePolishOutput(
      polished: polished, original: original, mode: .message, provider: .egOne, model: "eg-1")
  }

  // MARK: - The founder's takes

  @Test("A destroyed list falls back to the deterministic text")
  func destroyedList() {
    let original = "For the picnic tomorrow, please bring apples/bananas/strawberries."
    let v = validate("For the picnic tomorrow, please bring apples, bananas, or strawberries.", original: original)
    #expect(v.text == original)
    #expect(v.guardName == "symbol_drop")
    #expect(v.symbolTokens == 2)
  }

  @Test("A backslash rewritten as a slash falls back (#2957)")
  func backslashRewritten() {
    let original = "The pros/cons list and the path is users\\shared."
    let v = validate("The pros/cons list and the path is users/shared.", original: original)
    #expect(v.text == original)
    #expect(v.guardName == "symbol_drop")
    #expect(v.symbolTokens == 2)
  }

  // MARK: - What passes

  @Test("A backticked or re-spaced command keeps its token and passes")
  func decoratedCommandPasses() {
    let original = "Man, I love using /exit as a command to close out of Claude Code quickly."
    let polished = "Man, I love using `/exit` as a command to close out of Claude Code quickly."
    let v = validate(polished, original: original)
    #expect(v.text == polished)
    #expect(v.guardName == nil)
    #expect(v.symbolTokens == 1)
    let bold = validate("Use **and/or** in that clause.", original: "Use and/or in that clause.")
    #expect(bold.guardName == nil)
    #expect(bold.text == "Use **and/or** in that clause.")
    // Typographic quotes around the command are decoration too.
    let curly = validate("Please use \u{201C}/exit\u{201D} now.", original: "please use /exit now")
    #expect(curly.guardName == nil)
    #expect(curly.text == "Please use \u{201C}/exit\u{201D} now.")
    #expect(
      LLMPolishStep.symbolTokens(in: "\u{2018}/exit\u{2019} and \u{AB}/clear\u{BB}")
        == ["/exit", "/clear"])
  }

  @Test("A retained URL path passes; a stripped scheme falls back")
  func urlPath() {
    let kept = validate("Docs live at https://example.com/docs now.", original: "docs live at https://example.com/docs now")
    #expect(kept.guardName == nil)
    #expect(kept.symbolTokens == 2)
    let stripped = validate("Docs live at example.com/docs now.", original: "docs live at https://example.com/docs now")
    #expect(stripped.guardName == "symbol_drop")
    #expect(stripped.text == "docs live at https://example.com/docs now")
  }

  @Test("Whole tokens: /clear-all does not stand in for /clear; a duplicate is presence")
  func wholeTokens() {
    let v = validate("Please use /clear-all now.", original: "Please use /clear now.")
    #expect(v.guardName == "symbol_drop")
    let dup = validate("Run /clear /clear now.", original: "Run /clear now.")
    #expect(dup.guardName == nil)
    #expect(dup.text == "Run /clear /clear now.")
  }

  @Test("Case does not matter; a bare trailing slash is not a token; zero tokens is a measured zero")
  func caseTrailingAndZero() {
    let cased = validate("Type /Help please.", original: "type /help please")
    #expect(cased.guardName == nil)
    let trailing = validate("Open docs now.", original: "Open docs/ now.")
    #expect(trailing.guardName == nil)
    #expect(trailing.symbolTokens == 0)
    let none = validate("Hello there.", original: "hello there")
    #expect(none.guardName == nil)
    #expect(none.symbolTokens == 0)
    #expect(none.text == "Hello there.")
  }

  // MARK: - Precedence and the three older guards

  @Test("An earlier guard names itself and leaves the token count nil")
  func earlierGuardPrecedence() {
    let original = "we need /exit here"
    let expansion = validate(String(repeating: "word ", count: 80), original: original)
    #expect(expansion.guardName == "expansion")
    #expect(expansion.symbolTokens == nil)
    #expect(expansion.text == original)
    let question = validate("You should try /exit.", original: "should I try /exit here or not?")
    #expect(question.guardName == "question_flip")
    #expect(question.symbolTokens == nil)
    let tenWords = "one two three four five six seven eight nine /ten"
    let drop = validate("one", original: tenWords)
    #expect(drop.guardName == "content_drop")
    #expect(drop.symbolTokens == nil)
  }

  @Test("An empty original passes the polish through untouched")
  func emptyOriginal() {
    let v = validate("Hello.", original: "")
    #expect(v.text == "Hello.")
    #expect(v.guardName == nil)
    #expect(v.symbolTokens == nil)
  }

  @Test("The token set is what the guard compares")
  func tokenSet() {
    #expect(LLMPolishStep.symbolTokens(in: "https://example.com/docs and 4/6/2021") == ["/example", "/docs", "/6", "/2021"])
    #expect(LLMPolishStep.symbolTokens(in: "C:\\Users\\me") == ["\\users", "\\me"])
    #expect(LLMPolishStep.symbolTokens(in: "`/exit`, **and/or**, (a/b)") == ["/exit", "/or", "/b"])
    #expect(LLMPolishStep.symbolTokens(in: "docs/").isEmpty)
  }
}
