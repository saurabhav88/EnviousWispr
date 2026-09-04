import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #628 — the mandatory sentinel resolver.
///
/// `.productOutcome`: when this fails the user's document receives either a raw internal token
/// or their saved text duplicated. The assertion every case shares is the one that matters —
/// **nothing this type returns may contain a sentinel** — because that is the invariant the
/// whole sentinel design rests on, and it is the only one whose failure is unrecoverable once
/// the text has been pasted, stored in History, and written to the recovery spool.
@Suite("Snippet finalization (#628)", .tags(.productOutcome))
struct SnippetFinalizerTests {

  private let email = SnippetExpansionRecord(sentinel: "EWSNIPaaa", expansion: "sam@example.com")
  private let signoff = SnippetExpansionRecord(
    sentinel: "EWSNIPbbb", expansion: "Thanks,\nSam")

  private func context(
    text: String, polished: String?, records: [SnippetExpansionRecord]
  ) -> TextProcessingContext {
    var ctx = TextProcessingContext(text: text, language: "en")
    ctx.polishedText = polished
    ctx.protectedExpansions = records
    ctx.llmProvider = "openai"
    ctx.llmModel = "gpt-4o-mini"
    ctx.polishRanRemote = true
    return ctx
  }

  /// Applied to every case: the invariant, not a per-case detail.
  private func expectNoSentinelSurvives(_ ctx: TextProcessingContext) {
    for record in ctx.protectedExpansions {
      #expect(!ctx.text.contains(record.sentinel))
      #expect(!(ctx.polishedText ?? "").contains(record.sentinel))
    }
  }

  // MARK: - The path an ordinary dictation takes

  @Test("With no records the context is left exactly as it was")
  func noRecordsIsANoOp() {
    var ctx = context(text: "hello there", polished: "Hello there.", records: [])
    let before = ctx

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.text == before.text)
    #expect(ctx.polishedText == before.polishedText)
    #expect(ctx.pipelineFellBackToRaw == false)
    #expect(ctx.polishFallbackReason == nil)
    #expect(ctx.polishRanRemote == true)
  }

  // MARK: - Polish accepted

  @Test("Every sentinel intact: both the deterministic and the polished text are resolved")
  func intactPolishKeepsPolish() {
    var ctx = context(
      text: "email me at EWSNIPaaa", polished: "Email me at EWSNIPaaa.", records: [email])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.text == "email me at sam@example.com")
    #expect(ctx.polishedText == "Email me at sam@example.com.")
    #expect(ctx.pipelineFellBackToRaw == false)
    #expect(ctx.polishFallbackReason == nil)
    expectNoSentinelSurvives(ctx)
  }

  // MARK: - The model is the last writer (#2637)

  private let emailSuppressing = SnippetExpansionRecord(
    sentinel: "EWSNIPccc", expansion: "sam@example.com", suppressFollowingSentenceEnding: true)

  /// The founder's case, at the step that actually delivers it. The expander already dropped the
  /// recogniser's terminator, so polish receives the sentinel — and for an unsegmented script it
  /// reaches a model, because that gate counts characters and a sentinel is 38 of them. Without
  /// this the fix is undone by the step running after it, and the deterministic text would be
  /// right while the delivered text stayed wrong.
  @Test("A period the model added after a suppressing sentinel does not reach the user")
  func polishAddedTerminatorIsDropped() {
    var ctx = context(text: "EWSNIPccc", polished: "EWSNIPccc.", records: [emailSuppressing])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.text == "sam@example.com")
    #expect(ctx.polishedText == "sam@example.com")
    #expect(ctx.pipelineFellBackToRaw == false)
    expectNoSentinelSurvives(ctx)
  }

  /// The control that makes the row above mean something. Same shape, same added period, flag
  /// off — the period stays, because it is the user's sentence and not the snippet's ending.
  @Test("Without the flag the same added period is kept")
  func polishAddedTerminatorIsKeptWithoutTheFlag() {
    var ctx = context(
      text: "email me at EWSNIPaaa", polished: "Email me at EWSNIPaaa.", records: [email])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "Email me at sam@example.com.")
  }

  /// A saved expansion that ends itself. The doubled stop appears only AFTER substitution, so
  /// nothing before this step could have caught it.
  @Test("An expansion that ends a sentence does not gain a second stop from polish")
  func polishAddedTerminatorAfterASelfTerminatingExpansion() {
    let signOff = SnippetExpansionRecord(
      sentinel: "EWSNIPddd", expansion: "Let me know if that works.",
      suppressFollowingSentenceEnding: true)
    var ctx = context(
      text: "tell them EWSNIPddd then send it",
      polished: "Tell them EWSNIPddd. Then send it.", records: [signOff])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "Tell them Let me know if that works. Then send it.")
    expectNoSentinelSurvives(ctx)
  }

  /// Scoping control. Only a sentence terminator is eaten. A comma is the model punctuating a
  /// sentence it can see, and this has no business touching it.
  @Test("A comma after a suppressing sentinel is left alone")
  func aCommaAfterASuppressingSentinelSurvives() {
    var ctx = context(
      text: "EWSNIPccc and more", polished: "EWSNIPccc, and more.",
      records: [emailSuppressing])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "sam@example.com, and more.")
  }

  /// A terminator standing BEHIND a preserved closing mark. Same property as `endsSentence`
  /// once reading only a token's last character, and as the expander once refusing a mixed run:
  /// a loop that stops at the first non-terminator never sees the stop. Two members, because a
  /// row proving one closing mark proves only that mark.
  @Test("A period behind a closing bracket the model kept is still dropped")
  func terminatorBehindAClosingBracket() {
    var ctx = context(
      text: "(EWSNIPccc)", polished: "(EWSNIPccc).", records: [emailSuppressing])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "(sam@example.com)")
    expectNoSentinelSurvives(ctx)
  }

  @Test("A period behind a closing quote the model kept is still dropped")
  func terminatorBehindAClosingQuote() {
    var ctx = context(
      text: "\u{201C}EWSNIPccc\u{201D}", polished: "\u{201C}EWSNIPccc\u{201D}.",
      records: [emailSuppressing])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "\u{201C}sam@example.com\u{201D}")
  }

  /// The closing mark itself must SURVIVE. A fix that dropped the whole run would pass both rows
  /// above and silently eat the user's bracket.
  @Test("The closing mark itself is kept when the period behind it is dropped")
  func closingMarkSurvivesTheDrop() {
    var ctx = context(
      text: "(EWSNIPccc)", polished: "(EWSNIPccc). And more.", records: [emailSuppressing])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "(sam@example.com) And more.")
  }

  /// The deterministic half is a no-op by construction, and asserting it is what keeps the two
  /// paths from drifting: the rule runs on both, so neither can be the one that forgot.
  @Test("The deterministic text is unchanged by the terminator rule")
  func deterministicTextIsUnaffected() {
    var ctx = context(text: "EWSNIPccc", polished: nil, records: [emailSuppressing])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.text == "sam@example.com")
    #expect(ctx.polishedText == nil)
  }

  @Test("Several sentinels, all intact, all resolved")
  func severalIntactSentinels() {
    var ctx = context(
      text: "EWSNIPaaa and EWSNIPbbb",
      polished: "EWSNIPaaa and EWSNIPbbb.",
      records: [email, signoff])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == "sam@example.com and Thanks,\nSam.")
    #expect(ctx.pipelineFellBackToRaw == false)
    expectNoSentinelSurvives(ctx)
  }

  // MARK: - Polish rejected

  @Test("A sentinel the model dropped costs the whole polished version, not a repair")
  func missingSentinelRejectsPolish() {
    var ctx = context(
      text: "email me at EWSNIPaaa", polished: "Email me at your address.", records: [email])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.text == "email me at sam@example.com")
    #expect(ctx.polishedText == nil)
    #expect(ctx.pipelineFellBackToRaw == true)
    #expect(ctx.polishFallbackReason == SnippetFinalizer.sentinelLossReason)
    expectNoSentinelSurvives(ctx)
  }

  /// Duplication is the case "at least once" would wave through, and it is worse than loss:
  /// the user's address gets pasted twice into their own sentence.
  @Test("A sentinel the model duplicated also rejects polish")
  func duplicatedSentinelRejectsPolish() {
    var ctx = context(
      text: "EWSNIPaaa", polished: "EWSNIPaaa and EWSNIPaaa", records: [email])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == nil)
    #expect(ctx.text == "sam@example.com")
    #expect(ctx.pipelineFellBackToRaw == true)
    expectNoSentinelSurvives(ctx)
  }

  @Test("One lost sentinel rejects the polish even when its siblings survived")
  func partialLossRejectsTheWholePolish() {
    var ctx = context(
      text: "EWSNIPaaa and EWSNIPbbb", polished: "EWSNIPaaa and goodbye", records: [email, signoff])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.polishedText == nil)
    #expect(ctx.text == "sam@example.com and Thanks,\nSam")
    expectNoSentinelSurvives(ctx)
  }

  // MARK: - What the fallback must say about itself

  @Test("A rejected polish still records that a model was called")
  func rejectionRetainsAttemptEvidence() {
    var ctx = context(text: "EWSNIPaaa", polished: "nothing here", records: [email])

    SnippetFinalizer.finalize(&ctx)

    // Cleared: no remote polish survived into the delivered text.
    #expect(ctx.polishRanRemote == nil)
    // Retained: polish was genuinely attempted, and erasing this would make an
    // attempted-and-rejected take look identical to one that never called a model.
    #expect(ctx.llmProvider == "openai")
    #expect(ctx.llmModel == "gpt-4o-mini")
  }

  /// `TextProcessingStep.swift` states it: `(polishFallbackReason != nil) == pipelineFellBackToRaw`.
  @Test("The fallback flag and the fallback reason are always set together")
  func fallbackInvariantHolds() {
    for polished in ["EWSNIPaaa", "lost it", "EWSNIPaaa EWSNIPaaa", nil] {
      var ctx = context(text: "EWSNIPaaa", polished: polished, records: [email])
      SnippetFinalizer.finalize(&ctx)
      #expect((ctx.polishFallbackReason != nil) == ctx.pipelineFellBackToRaw)
    }
  }

  // MARK: - Polish never ran

  @Test("With no polished text the deterministic text is still resolved, and nothing is flagged")
  func polishAbsentResolvesDeterministicText() {
    var ctx = context(text: "email me at EWSNIPaaa", polished: nil, records: [email])

    SnippetFinalizer.finalize(&ctx)

    #expect(ctx.text == "email me at sam@example.com")
    #expect(ctx.polishedText == nil)
    // Polish did not fail here — it was skipped, disabled, or already swallowed by the runner.
    // Stamping a snippet fallback would blame this type for someone else's outcome.
    #expect(ctx.pipelineFellBackToRaw == false)
    #expect(ctx.polishFallbackReason == nil)
    expectNoSentinelSurvives(ctx)
  }
}
