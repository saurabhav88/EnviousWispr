import EnviousWisprCore
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #2648 — the chain one part of an imported transcript runs through.
///
/// **When this fails, an imported recording of somebody else's meeting comes back with the user's saved
/// snippet text substituted into it, or with a limb silently missing.** Product coverage.
@Suite(.tags(.productOutcome))
@MainActor
struct FileImportRunnerTests {

  private func makeSteps() -> LimbSteps {
    LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep())
  }

  /// **Snippet expansion must not run on an imported file.** A trigger word spoken by somebody in a
  /// recording would be replaced by the user's saved text, putting words the speaker never said into a
  /// transcript of their speech.
  ///
  /// Asserted STRUCTURALLY — by type, over the real chain — rather than by comparing against a list
  /// written here. A list written here would be a second opinion that can drift.
  @Test("the import chain contains no snippet expansion")
  func importChainExcludesSnippetExpansion() {
    let steps = makeSteps()

    #expect(!steps.orderedChainForFileImport.contains { $0 is SnippetExpansionStep })
    #expect(
      steps.orderedChain.contains { $0 is SnippetExpansionStep },
      "the control: the ordinary chain DOES include it, so the assertion above is about the filter")
  }

  /// **Every other limb must still run**, and the import chain must not be a hand-written list that
  /// drifts from the one place the order is declared.
  ///
  /// This is the row that fails when someone adds a limb to `orderedChain` and forgets imports: the
  /// counts stop agreeing. It is derived from the producer on both sides, so it cannot be satisfied by
  /// updating a literal.
  @Test("the import chain is the ordinary chain minus exactly one step, in the same order")
  func importChainIsDerivedFromTheOrderedChain() {
    let steps = makeSteps()
    let ordinary = steps.orderedChain
    let imported = steps.orderedChainForFileImport

    #expect(imported.count == ordinary.count - 1)
    let ordinaryWithoutSnippets = ordinary.filter { !($0 is SnippetExpansionStep) }
    #expect(
      zip(imported, ordinaryWithoutSnippets).allSatisfy {
        ObjectIdentifier(type(of: $0)) == ObjectIdentifier(type(of: $1))
      },
      "the import chain is not the ordinary chain's order with the snippet step removed")
  }

  /// #3124: an imported part is spelled under the choice frozen at Start, British or American.
  @Test("a part imported under English (UK) comes back British; American stays American")
  func importedPartFollowsFrozenSpelling() async throws {
    func snapshot(_ spelling: EnglishSpelling?) -> RecordingSettingsSnapshot {
      RecordingSettingsSnapshot(
        backendType: .parakeet, backendSupportsLanguageDetection: false,
        languageMode: .locked("en"), wordCorrectionEnabled: false, fillerRemovalEnabled: false,
        emojiFormatterEnabled: false, spokenPunctuationEnabled: false, llmProvider: "none",
        llmModel: "none", s1Control: nil, englishSpelling: spelling)
    }
    let british = FileImportRunner(keychainManager: KeychainManager())
    british.freeze(settings: snapshot(.british), vocabulary: nil)
    let britishPart = try await british.process(part: "the color of the center")
    #expect(britishPart.displayText == "the colour of the centre")
    #expect(britishPart.polishedText == nil)  // provider none: polish bypassed

    let american = FileImportRunner(keychainManager: KeychainManager())
    american.freeze(settings: snapshot(.american), vocabulary: nil)
    #expect(try await american.process(part: "the color of the center").displayText
      == "the color of the center")
  }

  /// #3111: an EG-1 import is told the language its text is in, exactly like a dictation, and so is
  /// a second pass over the same saved text (what "Clean it again" runs). When this fails, an imported
  /// Polish recording comes back translated into English.
  @Test("#3111 an EG-1 import names the text's language, and so does a second pass over the saved text")
  func egOneImportNamesTheLanguage() async throws {
    let capture = NamedPromptCapture()
    let runner = FileImportRunner(
      keychainManager: KeychainManager(), egOneRuntime: ReadyEGOneRuntime(), s1MiniRuntime: nil,
      outputClassifierHolder: nil, languageIdentifier: { _ in ("pl", 0.97) },
      makeEGOnePolisher: { _ in PromptCapturingPolisher(capture: capture) },
      promptPlanner: DefaultPromptPlanner(egOneFamily: .egOneEnvelopeNamedLanguage))
    runner.freeze(settings: Self.egOneSnapshot, vocabulary: nil)
    _ = try await runner.process(part: Self.polishPart)
    _ = try await runner.process(part: Self.polishPart)
    #expect(capture.systemPrompts == [Self.namedPolishPrompt, Self.namedPolishPrompt])
  }

  nonisolated static let polishPart =
    "daty płatności są późniejsze niż daty zakupu prawdopodobnie różnica w rejestracji transakcji"
  nonisolated static let namedPolishPrompt =
    EGOneEnvelopePromptBuilder.systemPrompt
    + " The transcript is in Polish; write the cleaned text in Polish."
  static let egOneSnapshot = RecordingSettingsSnapshot(
    backendType: .parakeet, backendSupportsLanguageDetection: false,
    languageMode: .auto, wordCorrectionEnabled: false, fillerRemovalEnabled: false,
    emojiFormatterEnabled: false, spokenPunctuationEnabled: false,
    llmProvider: LLMProvider.egOne.rawValue, llmModel: LLMProvider.egOneModelName, s1Control: nil,
    englishSpelling: nil)

  /// A part cannot run before the import's configuration is frozen. This is a programming error rather
  /// than a user-facing one, and it fails loudly instead of running under whatever the defaults happen
  /// to be — which would silently polish with the wrong provider.
  @Test("a part refuses to run before the import is configured")
  func partRefusesBeforeFreeze() async {
    let runner = FileImportRunner(keychainManager: KeychainManager())

    await #expect(throws: FileImportRunnerError.notConfigured) {
      _ = try await runner.process(part: "some words")
    }
  }

  /// The floor: a part whose polish did not land shows its deterministic text and is MARKED, never
  /// hidden and never dropped.
  @Test("an unpolished part reports itself as unpolished and still carries text")
  func unpolishedPartKeepsItsText() {
    let outcome = FileImportRunner.PartOutcome(
      text: "the deterministic floor", polishedText: nil, polishError: "provider unavailable")

    #expect(outcome.displayText == "the deterministic floor")
    #expect(outcome.isUnpolished)
  }

  @Test("a polished part shows the polished text")
  func polishedPartShowsPolish() {
    let outcome = FileImportRunner.PartOutcome(
      text: "the floor", polishedText: "The polished sentence.", polishError: nil)

    #expect(outcome.displayText == "The polished sentence.")
    #expect(!outcome.isUnpolished)
  }

  /// **A step that was never asked to run did not fail.**
  ///
  /// With the user's polisher set to None, every part comes back with no
  /// polished text — the same shape as a part whose polisher was asked and could
  /// not answer. One field carried both meanings, so a document the user
  /// deliberately chose not to have polished was marked, passage by passage,
  /// "This passage could not be cleaned up": the app accusing itself of failing
  /// at something nobody asked for. Found by Codex.
  ///
  /// The deterministic cleanup DID run and DID succeed, which is why the text is
  /// still worth showing without a warning over it.
  @Test("a part nobody asked to polish is not reported as a failure")
  func skippedPolishIsNotAFailure() {
    let skipped = FileImportRunner.PartOutcome(
      text: "the deterministic floor", polishedText: nil, polishError: nil,
      polishAttempted: false)

    #expect(skipped.displayText == "the deterministic floor")
    #expect(!skipped.isUnpolished, "a skipped polish was reported as a failed one")
    #expect(!skipped.wasPolishAttempted)
  }

  /// The other direction, so a rule that called everything "skipped" would fail
  /// too: an asked-for polish that did not answer IS a failure and stays marked.
  @Test("a polish that was asked for and did not answer is still a failure")
  func attemptedPolishThatFailedIsStillMarked() {
    let failed = FileImportRunner.PartOutcome(
      text: "the deterministic floor", polishedText: nil, polishError: "provider unavailable",
      polishAttempted: true)

    #expect(failed.isUnpolished, "a real polish failure stopped being marked")
    #expect(failed.wasPolishAttempted)
  }
}

// MARK: - #3111 fixtures shared with FileImportCoordinatorTests

/// An EG-1 server that is always ready. No server runs: the polisher below answers.
@MainActor
final class ReadyEGOneRuntime: EGOneEndpointProviding {
  func activeEndpoint() async -> EGOneEndpoint? {
    EGOneEndpoint(port: 1, authToken: "t", contextTokens: 32768)
  }
}

/// Every system prompt an EG-1 polish was sent, in order.
final class NamedPromptCapture: @unchecked Sendable {
  var systemPrompts: [String] = []
}

/// A fake EG-1 polisher that records the system prompt and returns its input, capitalised, so
/// the step accepts it.
struct PromptCapturingPolisher: TranscriptPolisher {
  let capture: NamedPromptCapture
  func polish(
    text: String, instructions: PolishInstructions, config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    capture.systemPrompts.append(instructions.systemPrompt)
    return LLMResult(polishedText: text.prefix(1).uppercased() + text.dropFirst() + ".")
  }
}
