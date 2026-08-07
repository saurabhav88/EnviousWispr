import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

// MARK: - EmojiRestoreStepTests (#761)
//
// Unit coverage for the pipeline wrapper around `EmojiRestorer`: the provider
// gate (Apple Intelligence, plus Ollama since #1948), the no-op guards
// (non-restoring provider, nil polish, nothing dropped), the toggle
// closure, and the per-run telemetry outcome. The restore algorithm's own
// correctness (placement, retention, runs, kept-emoji no-op) is locked by
// `EmojiRestorerTests`; this suite only proves the wrapper gates and reports.

@MainActor
@Suite struct EmojiRestoreStepTests {

  private func step() -> EmojiRestoreStep {
    EmojiRestoreStep()
  }

  /// A context as it reaches the restore step: `text` is the emoji-bearing
  /// pre-polish floor, `polishedText` is the AFM output, `llmProvider` is the
  /// provider `LLMPolishStep` stamped.
  private func afmContext(pre: String, polished: String?) -> TextProcessingContext {
    var c = TextProcessingContext(text: pre, language: nil)
    c.llmProvider = LLMProvider.appleIntelligence.rawValue
    c.polishedText = polished
    return c
  }

  // MARK: Always-on contract

  @Test("the step is ALWAYS enabled — it can never be skipped by a live toggle (#761)")
  func alwaysEnabled() {
    // Gating on the live emoji toggle would strand a glyph the converter already
    // inserted if the user flipped emoji off mid-polish. Always-on + the
    // dropped==0 no-op is the correct, race-free coupling.
    #expect(step().isEnabled == true)
  }

  @Test("maxDuration is a generous backstop, not a real deadline")
  func maxDurationBackstop() {
    #expect(step().maxDuration == .milliseconds(50))
  }

  // MARK: Provider gate

  @Test("Non-AFM provider is left completely untouched (no restore, no telemetry)")
  func nonAFMProviderUntouched() async throws {
    var c = TextProcessingContext(text: "Shipped it 🚀.", language: nil)
    c.llmProvider = LLMProvider.openAI.rawValue
    c.polishedText = "Shipped it."  // pretend a cloud model dropped the emoji
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText == "Shipped it.")  // unchanged — cloud owns its own emoji
    #expect(s.lastRun == nil)
  }

  @Test("Nil polished text → no-op, no telemetry (delivery uses the emoji-bearing text)")
  func nilPolishedIsNoop() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "Shipped it 🚀.", polished: nil))
    #expect(out.polishedText == nil)
    #expect(s.lastRun == nil)
  }

  // MARK: AFM restore behavior

  @Test("AFM dropped an emoji → restored into polishedText, telemetry stamped")
  func afmRestoresAndStampsTelemetry() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "Shipped it 🚀.", polished: "Shipped it."))
    #expect(out.polishedText == "Shipped it 🚀.")
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.emojiInInput == 1)
    #expect(s.lastRun?.dropped == 1)
    #expect(s.lastRun?.restored == 1)
    #expect(s.lastRun?.incomplete == false)
  }

  @Test("AFM kept the emoji → polishedText unchanged, telemetry shows zero dropped")
  func afmKeptEmojiNoChange() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "Shipped it 🚀.", polished: "Shipped it 🚀."))
    #expect(out.polishedText == "Shipped it 🚀.")
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.emojiInInput == 1)
    #expect(s.lastRun?.dropped == 0)
    #expect(s.lastRun?.restored == 0)
  }

  @Test("AFM dictation with no emoji at all → no change, telemetry shows zero input")
  func afmNoEmojiAtAll() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "hello there", polished: "Hello there."))
    #expect(out.polishedText == "Hello there.")
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.emojiInInput == 0)
    #expect(s.lastRun?.dropped == 0)
  }

  // MARK: Telemetry clearing across dictations

  @Test("lastRun clears on a subsequent non-AFM dictation (no stale stamp)")
  func lastRunClearsOnNonAFM() async throws {
    let s = step()
    // First: an AFM run stamps lastRun.
    _ = try await s.process(afmContext(pre: "Yes 👍.", polished: "Yes."))
    #expect(s.lastRun != nil)
    // Then: a cloud dictation must clear it so no emoji telemetry rides along.
    var cloud = TextProcessingContext(text: "next one", language: nil)
    cloud.llmProvider = LLMProvider.openAI.rawValue
    cloud.polishedText = "Next one."
    _ = try await s.process(cloud)
    #expect(s.lastRun == nil)
  }

  // MARK: - Ollama restoration (#1948)

  /// #1948 routed every local Ollama model to one fixed prompt (L3), which measurably drops
  /// emoji: replaying this restorer over the 98 emoji-bearing corpus cases and the stored L3
  /// outputs, `qwen2.5:3b` kept every input emoji in only 53 of 98 cases and `llama3.2` in 6.
  /// With the restorer both reach 98/98, and zero already-complete cases are disturbed. These
  /// tests pin the wiring that makes that true; `EmojiRestorerTests` owns the algorithm.

  /// A LOCAL Ollama context: provider plus the family `LLMPolishStep` stamps from
  /// `PolishPlan.family`. Both are required — the gate keys on the family, because the
  /// provider alone cannot distinguish local from hosted or from EG-1-served-via-Ollama.
  private func ollamaContext(
    pre: String, polished: String?, family: PromptFamily = .localFixed
  ) -> TextProcessingContext {
    var c = TextProcessingContext(text: pre, language: nil)
    c.llmProvider = LLMProvider.ollama.rawValue
    c.promptFamily = family
    c.polishedText = polished
    return c
  }

  @Test("Ollama output has dropped emoji restored (#1948)")
  func ollamaRestoresDroppedEmoji() async throws {
    let s = step()
    let out = try await s.process(
      ollamaContext(pre: "well the appointment ran late but im on my way now 🙏", polished: "Well, the appointment ran late, but I'm on my way now."))
    #expect(out.polishedText?.contains("🙏") == true)
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.dropped == 1)
    #expect(s.lastRun?.restored == 1)
  }

  /// Two-way control. Without it, an implementation that rewrote every Ollama output would
  /// pass the test above while corrupting the majority of dictations that were already fine.
  @Test("Ollama output that KEPT its emoji is returned byte-for-byte (#1948)")
  func ollamaLeavesCompleteOutputAlone() async throws {
    let polished = "Well, the appointment ran late, but I'm on my way now. 🙏"
    let s = step()
    let out = try await s.process(
      ollamaContext(pre: "well the appointment ran late but im on my way now 🙏", polished: polished))
    #expect(out.polishedText == polished)
    #expect(s.lastRun?.dropped == 0)
  }

  /// Cloud review caught that gating on `provider == .ollama` silently included HOSTED
  /// Ollama and EG-1-served-through-Ollama, because `LLMPolishStep` stamps all three with the
  /// same provider rawValue — the code included two paths its own comment excluded. The gate
  /// keys on the prompt FAMILY now, and this pins every Ollama sub-path separately so the
  /// distinction cannot silently collapse back to the provider.
  @Test(
    "only the LOCAL Ollama family restores; hosted and EG-1-via-Ollama do not (#1948)",
    arguments: [
      (PromptFamily.localFixed, true),
      (PromptFamily.cloudFixed, false),  // hosted Ollama — takes the fixed v6 prompt
      (PromptFamily.egOneFixed, false),  // EG-1 served through Ollama — training prompt
    ])
  func ollamaFamilyGate(family: PromptFamily, shouldRestore: Bool) async throws {
    let s = step()
    let out = try await s.process(
      ollamaContext(pre: "shipped it 🚀", polished: "Shipped it.", family: family))
    #expect((out.polishedText?.contains("🚀") ?? false) == shouldRestore)
    #expect((s.lastRun != nil) == shouldRestore)
  }

  /// Every non-Ollama provider except Apple Intelligence stays untouched, whatever family
  /// happens to be stamped. A future widening past measured evidence has to change this test
  /// and bring numbers with it.
  @Test(
    "cloud providers and EG-1 native are untouched (#1948)",
    arguments: [
      LLMProvider.openAI.rawValue,
      LLMProvider.gemini.rawValue,
      LLMProvider.claude.rawValue,
      LLMProvider.egOne.rawValue,
      LLMProvider.none.rawValue,
    ])
  func nonRestoringProviders(provider: String) async throws {
    var c = TextProcessingContext(text: "shipped it 🚀", language: nil)
    c.llmProvider = provider
    c.promptFamily = .cloudFixed
    c.polishedText = "Shipped it."
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText == "Shipped it.")
    #expect(s.lastRun == nil)
  }

  /// Apple Intelligence returns before the family stamp, so it must still be matched by
  /// provider with a nil family. Without this, moving the gate to the family would have
  /// silently switched AFM restoration off — the regression that motivated #761.
  @Test("Apple Intelligence still restores with NO family stamped (#1948)")
  func appleIntelligenceRestoresWithoutFamily() async throws {
    var c = TextProcessingContext(text: "shipped it 🚀", language: nil)
    c.llmProvider = LLMProvider.appleIntelligence.rawValue
    c.promptFamily = nil
    c.polishedText = "Shipped it."
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText?.contains("🚀") == true)
    #expect(s.lastRun?.restored == 1)
  }

  /// Cross-product of provider and family (design review Q2). The gate requires BOTH, so a
  /// `.localFixed` receipt arriving with a non-Ollama provider must NOT restore. Without
  /// this, a gate trusting one field to imply the other passes for the wrong reason.
  @Test(
    "provider x family: only Ollama+localFixed and Apple Intelligence restore",
    arguments: [
      (LLMProvider.ollama, PromptFamily?.some(.localFixed), true),
      (LLMProvider.ollama, .some(.cloudFixed), false),
      (LLMProvider.ollama, .some(.egOneFixed), false),
      (LLMProvider.ollama, .none, false),
      (LLMProvider.openAI, .some(.localFixed), false),
      (LLMProvider.gemini, .some(.localFixed), false),
      (LLMProvider.egOne, .some(.localFixed), false),
      (LLMProvider.appleIntelligence, .none, true),
      (LLMProvider.appleIntelligence, .some(.localFixed), true),
    ])
  func providerFamilyCrossProduct(
    provider: LLMProvider, family: PromptFamily?, shouldRestore: Bool
  ) async throws {
    var c = TextProcessingContext(text: "shipped it 🚀", language: nil)
    c.llmProvider = provider.rawValue
    c.promptFamily = family
    c.polishedText = "Shipped it."
    let s = step()
    let out = try await s.process(c)
    #expect((out.polishedText?.contains("🚀") ?? false) == shouldRestore)
    #expect((s.lastRun != nil) == shouldRestore)
  }

  /// A bypassed polish must not leave a family behind for this step to act on
  /// (design review Q2: `bypassedContext` cleared every other AI field but not this one).
  @Test("a cleared route receipt stops restoration (#1948 stale-field guard)")
  func clearedReceiptStopsRestoration() async throws {
    var c = TextProcessingContext(text: "shipped it 🚀", language: nil)
    c.llmProvider = nil  // bypass clears provider too
    c.promptFamily = nil
    c.polishedText = "Shipped it."
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText == "Shipped it.")
    #expect(s.lastRun == nil)
  }

  // MARK: - Length cap (#1948, cloud review r7)

  /// `EmojiRestorer.alignWords` is quadratic in dictation length and runs on the main actor.
  /// Measured on the real restorer: 1,000 words 54 ms, 3,000 words 484 ms / 69 MB, 9,000
  /// words 4.3 s / 618 MB. The AFM path was bounded incidentally by Apple's 4096-token
  /// context; local Ollama is not, so the step declines above its own 50 ms budget.
  @Test("restoration is skipped above the word cap, leaving the polish untouched")
  func longDictationSkipsRestoration() async throws {
    let long = (0..<(EmojiRestoreStep.maxAlignmentTokens + 1))
      .map { "word\($0 % 97)" }.joined(separator: " ")
    let s = step()
    let out = try await s.process(
      ollamaContext(pre: long + " 🙏", polished: long + "."))
    #expect(out.polishedText == long + ".")
    #expect(out.polishedText?.contains("🙏") == false)
    // No restore happened, so no telemetry may claim one.
    #expect(s.lastRun == nil)
  }

  /// The case that proved the FIRST version of this cap was hollow (cloud review r7). A
  /// comma-separated list is ONE whitespace chunk and many alignment tokens, so a guard
  /// counting whitespace passes exactly the input it exists to reject. Counted with the
  /// restorer's own tokenizer, this must be refused.
  @Test("comma-separated input with no whitespace is still bounded (#1948 r7)")
  func noWhitespaceStillBounded() async throws {
    let dense = (0..<(EmojiRestoreStep.maxAlignmentTokens + 50))
      .map { "w\($0 % 89)" }.joined(separator: ",")
    // Precondition of the test itself: one whitespace chunk, many alignment tokens.
    #expect(dense.split(whereSeparator: \.isWhitespace).count == 1)
    #expect(
      EmojiRestorer.alignmentTokenCount(dense) > EmojiRestoreStep.maxAlignmentTokens,
      "fixture must exceed the token cap or the test asserts nothing")

    let s = step()
    let out = try await s.process(ollamaContext(pre: dense + " 🙏", polished: dense))
    #expect(out.polishedText == dense)
    #expect(s.lastRun == nil)
  }

  /// The cap must NOT apply to Apple Intelligence (cloud review r8). AFM restored emoji for
  /// every successful polish before #1948, bounded only by Apple's own 4096-token preflight
  /// (~3,000 words). Capping it here would silently withdraw restoration from long AFM
  /// dictations — a behaviour change on a path this change is not about.
  @Test("a long Apple Intelligence dictation still restores, uncapped (#1948 r8)")
  func longAppleIntelligenceStillRestores() async throws {
    let long = (0..<(EmojiRestoreStep.maxAlignmentTokens + 200))
      .map { "word\($0 % 97)" }.joined(separator: " ")
    var c = TextProcessingContext(text: long + " 🙏", language: nil)
    c.llmProvider = LLMProvider.appleIntelligence.rawValue
    c.promptFamily = nil
    c.polishedText = long + "."
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText?.contains("🙏") == true, "AFM restoration must not be capped")
    #expect(s.lastRun?.restored == 1)
  }

  /// Two-way control at the boundary: just UNDER the cap must still restore, so the guard
  /// cannot be satisfied by disabling restoration outright.
  @Test("a dictation just under the cap still restores")
  func justUnderCapStillRestores() async throws {
    let body = (0..<(EmojiRestoreStep.maxAlignmentTokens - 5))
      .map { "word\($0 % 97)" }.joined(separator: " ")
    let s = step()
    let out = try await s.process(
      ollamaContext(pre: body + " 🙏", polished: body + "."))
    #expect(out.polishedText?.contains("🙏") == true)
    #expect(s.lastRun?.restored == 1)
  }

  // MARK: - Blank polish must reach the empty-output recovery floor (#1948, cloud review r6)

  /// `KernelFinalizationWiring` treats an EMPTY `polishedText` as the trigger for its
  /// empty-output recovery floor, which delivers the intact deterministic text. If this step
  /// writes a lone emoji into that empty string the result becomes non-empty, the floor never
  /// fires, and the user receives the emoji INSTEAD OF THEIR WHOLE SENTENCE. Verified against
  /// the real `EmojiRestorer`: `restore(polished: "", prePolish: "on my way now 🙏")` returns
  /// exactly `"🙏"`.
  ///
  /// Reachable in production: `OllamaConnector` accepts a whitespace response as success and
  /// trims it to `""`, and `validatePolishOutput` has no empty guard below 10 input words.
  @Test(
    "blank polish is left untouched so the recovery floor still fires (#1948)",
    arguments: ["", "   ", "\n", " \n "])
  func blankPolishUntouched(polished: String) async throws {
    for provider in [LLMProvider.ollama, .appleIntelligence] {
      var c = TextProcessingContext(text: "on my way now 🙏", language: nil)
      c.llmProvider = provider.rawValue
      c.promptFamily = .localFixed
      c.polishedText = polished
      let s = step()
      let out = try await s.process(c)
      // Byte-for-byte unchanged: the emptiness must survive to finalization.
      #expect(out.polishedText == polished)
      // And no telemetry claiming a restore that did not happen.
      #expect(s.lastRun == nil)
    }
  }

  /// Two-way control: a non-blank polish on the same input still restores, so the guard above
  /// cannot be satisfied by simply disabling restoration.
  @Test("a non-blank polish on the same input still restores (#1948 control)")
  func nonBlankStillRestores() async throws {
    let s = step()
    let out = try await s.process(
      ollamaContext(pre: "on my way now 🙏", polished: "On my way now."))
    #expect(out.polishedText?.contains("🙏") == true)
    #expect(s.lastRun?.restored == 1)
  }

  /// A nil provider AND a nil family must restore nothing — the state a skipped or failed
  /// polish leaves behind, where `polishedText` came from somewhere other than a model.
  @Test("nil provider and nil family restore nothing (#1948)")
  func nilProviderUntouched() async throws {
    var c = TextProcessingContext(text: "shipped it 🚀", language: nil)
    c.llmProvider = nil
    c.promptFamily = nil
    c.polishedText = "Shipped it."
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText == "Shipped it.")
    #expect(s.lastRun == nil)
  }
  // MARK: - The real handoff, end to end (#1948, design review Q4)

  /// Every test above SEEDS `promptFamily` by hand, so all of them would still pass if
  /// `LLMPolishStep` stopped stamping it and emoji restoration silently died for every real
  /// user. This drives the actual producers instead: the shipped planner selects the family,
  /// the real stamp site records it, and the step restores off that value.
  ///
  /// It deliberately does NOT call the network. `LLMPolishStep.process` needs a live model,
  /// so the seam under test is the contract between the two: what `DefaultPromptPlanner`
  /// decides for a local Ollama model must be exactly what `EmojiRestoreStep` accepts.
  @Test("planner decision and restore gate agree for a local Ollama model")
  func plannerAndGateAgree() async throws {
    let planner = DefaultPromptPlanner()
    let plan = planner.plan(
      input: PromptBuildInput(
        transcript: "on my way now 🙏",
        provider: .ollama,
        modelID: "llama3.2",
        appName: nil,
        language: nil,
        polishVocabulary: PolishVocabulary(terms: [], generation: 0),
        ollamaIsRemote: false))

    // What the production stamp site writes, taken from the planner rather than assumed.
    var c = TextProcessingContext(text: "on my way now 🙏", language: nil)
    c.llmProvider = LLMProvider.ollama.rawValue
    c.promptFamily = plan.family
    c.polishedText = "On my way now."

    let s = step()
    let out = try await s.process(c)
    #expect(plan.family == .localFixed, "planner must still route local Ollama to localFixed")
    #expect(out.polishedText?.contains("🙏") == true, "the gate must accept the planner's own value")
    #expect(s.lastRun?.restored == 1)
  }

  /// The same seam in the other direction: a HOSTED model's planner decision must NOT open
  /// the gate. Together these two fail if either side of the contract drifts.
  @Test("planner decision and restore gate agree that hosted Ollama does not restore")
  func plannerAndGateAgreeHosted() async throws {
    let planner = DefaultPromptPlanner()
    let plan = planner.plan(
      input: PromptBuildInput(
        transcript: "on my way now 🙏",
        provider: .ollama,
        modelID: "gemma4:31b-cloud",
        appName: nil,
        language: nil,
        polishVocabulary: PolishVocabulary(terms: [], generation: 0),
        ollamaIsRemote: true))

    var c = TextProcessingContext(text: "on my way now 🙏", language: nil)
    c.llmProvider = LLMProvider.ollama.rawValue
    c.promptFamily = plan.family
    c.polishedText = "On my way now."

    let s = step()
    let out = try await s.process(c)
    #expect(plan.family == .cloudFixed)
    #expect(out.polishedText == "On my way now.")
    #expect(s.lastRun == nil)
  }

}
