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
