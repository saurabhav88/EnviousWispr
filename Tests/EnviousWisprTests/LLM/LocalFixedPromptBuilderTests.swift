import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

@Suite("LocalFixedPromptBuilder (#1948)")
struct LocalFixedPromptBuilderTests {
  let planner = DefaultPromptPlanner()

  func localInput(
    transcript: String = "um so i think we should ship it",
    modelID: String = "llama3.2",
    appName: String? = nil,
    language: String? = nil,
    terms: [CustomWord] = []
  ) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: .ollama,
      modelID: modelID,
      appName: appName,
      language: language,
      polishVocabulary: PolishVocabulary(terms: terms, generation: terms.isEmpty ? 0 : 1),
      ollamaIsRemote: false
    )
  }

  // MARK: - The shipped prompt and the eval artifact are one contract

  /// The Swift literal and `scripts/eval/prompts/ollama-local-polish-prompt-L3.txt` must not
  /// drift: the benchmark that justified this prompt was run against the FILE, so if the app
  /// ships different text, every quality number stops describing the app. Same contract
  /// `CloudFixedPromptBuilder` has with its own v6 artifact.
  ///
  /// Locating the repo from `#filePath` rather than a bundle resource keeps the artifact out
  /// of the shipped app while still failing the suite on drift.
  @Test("Swift literal is byte-identical to the tracked L3 artifact")
  func literalMatchesArtifact() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    // Tests/EnviousWisprTests/LLM/<this file> -> repo root
    let repoRoot =
      testFile
      .deletingLastPathComponent()  // LLM
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    let artifact =
      repoRoot
      .appendingPathComponent("scripts/eval/prompts/ollama-local-polish-prompt-L3.txt")

    // Fail loudly if the artifact is missing rather than silently passing — a check that
    // cannot reach its subject is not a check.
    #expect(
      FileManager.default.fileExists(atPath: artifact.path),
      "L3 artifact not found at \(artifact.path)")

    let fileText = try String(contentsOf: artifact, encoding: .utf8)
    // The file ends with a trailing newline; a Swift multiline literal does not.
    #expect(
      fileText.hasSuffix("\n"),
      "artifact should end with exactly one trailing newline")
    #expect(String(fileText.dropLast()) == LocalFixedPromptBuilder.localFixedSystemPrompt)
  }

  // MARK: - Fidelity to the measured benchmark arm

  /// The measured arm sent the system text verbatim with no additions and
  /// `Transcript to clean:\n\n<transcript>` as the user message. On the corpus condition
  /// (no app name, no locked language, no custom words) the shipped builder must reproduce
  /// that exactly, or the quality numbers do not transfer to the app.
  @Test("corpus condition reproduces the benchmarked prompt exactly")
  func corpusConditionIsByteIdentical() {
    let plan = planner.plan(input: localInput(transcript: "loop in jamal actually priya"))
    #expect(plan.envelope.messages.count == 2)
    #expect(plan.envelope.messages[0].content == LocalFixedPromptBuilder.localFixedSystemPrompt)
    #expect(
      plan.envelope.messages[1].content == "Transcript to clean:\n\nloop in jamal actually priya")
  }

  /// `CloudFixedPromptBuilder` appends "IMPORTANT: Very short input..." at ten words or
  /// fewer. That guard fires on 417 of the 1,690 benchmark cases (24.7%), so inheriting it
  /// would change the prompt on a quarter of the cases the numbers came from. Excluded
  /// deliberately — this test freezes that decision so a future "parity with cloud" tidy-up
  /// has to argue with it.
  @Test("short input gets no extra guard clause, unlike the cloud builder")
  func shortInputAddsNothing() {
    let plan = planner.plan(input: localInput(transcript: "call me back"))
    #expect(plan.envelope.messages[0].content == LocalFixedPromptBuilder.localFixedSystemPrompt)
    #expect(!plan.envelope.messages[0].content.contains("Very short input"))
  }

  /// Also excluded: the unconditional language-preservation preamble the cloud builder
  /// prepends. The prompt's own first line carries it, and prepending would diverge from the
  /// measured artifact on every case.
  @Test("no unconditional language preamble is prepended")
  func noLanguagePreamble() {
    let system = planner.plan(input: localInput()).envelope.messages[0].content
    #expect(system.hasPrefix("Clean dictated speech for direct paste."))
    #expect(!system.contains("Keep the cleaned text in the same language(s)"))
  }

  // MARK: - Conditional enrichments are kept

  @Test("locked language adds a hint after the fixed prompt")
  func lockedLanguageHint() {
    let system = planner.plan(input: localInput(language: "German")).envelope.messages[0].content
    #expect(system.hasPrefix("Clean dictated speech for direct paste."))
    #expect(system.contains("LANGUAGE: This transcript is in German. Clean it in German."))
  }

  @Test("app name is carried through, matching the builder this replaces")
  func appNameHint() {
    let system = planner.plan(input: localInput(appName: "Slack")).envelope.messages[0].content
    #expect(system.contains("The user is dictating in Slack."))
  }

  @Test("custom vocabulary is appended as an explicit exception to the no-substitution rule")
  func customVocabulary() {
    let system = planner.plan(
      input: localInput(terms: [CustomWord(canonical: "FooFlux")])
    ).envelope.messages[0].content
    #expect(system.contains("FooFlux"))
    #expect(system.contains("This is the one exception to leaving the wording unchanged."))
  }

  @Test("no enrichment fires when none is configured (two-way control)")
  func noEnrichmentsByDefault() {
    let system = planner.plan(input: localInput()).envelope.messages[0].content
    #expect(!system.contains("LANGUAGE:"))
    #expect(!system.contains("The user is dictating in"))
    #expect(!system.contains("preferred spellings"))
  }

  // MARK: - Mode is ignored

  @Test(
    "mode does not change the prompt", arguments: [PolishMode.inline, .message, .structured, .edit])
  func modeIgnored(mode: PolishMode) {
    let builder = LocalFixedPromptBuilder()
    let envelope = builder.build(input: localInput(), mode: mode)
    #expect(envelope.messages[0].content == LocalFixedPromptBuilder.localFixedSystemPrompt)
  }

  // MARK: - The builder is reached from the production path

  /// A builder nothing routes to is not shipped. This drives the planner rather than
  /// constructing the builder directly, so the routing and the prompt are proven together.
  @Test("production planner path reaches this builder for a local Ollama model")
  func reachedFromProductionPath() {
    let plan = planner.plan(input: localInput())
    #expect(plan.family == .localFixed)
    #expect(plan.envelope.messages[0].content.hasPrefix("Clean dictated speech for direct paste."))
  }
}
