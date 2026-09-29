import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite("Checker selection paths (#3105)", .tags(.productOutcome))
struct CheckerSelectionPathTests {
  private struct Approver: LearnedWordChecking {
    let armName = "test_ready"
    let scoresAreComparable = false
    func decide(_ questions: [LearnedWordCheckQuestion]) async throws
      -> [LearnedWordCheckDecision]
    {
      questions.map { .init(questionID: $0.id, approved: true) }
    }
  }

  private let spoken = "The day toast regenerated my project."
  private var vocabulary: CorrectorVocabulary {
    .init(
      terms: [
        .init(
          canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
          learnedAt: Date(timeIntervalSince1970: 1_790_000_000))
      ], generation: 1)
  }

  private var choices: [LearnedWordCheckerSelection] {
    [
      .init(checker: Approver(), identity: "test_ready"),
      .init(absence: .adapterDownloading),
      .init(absence: .baseMismatch("prompt_template")),
      .init(absence: .serverUnavailable),
      .init(absence: .selectionTimedOut),
    ]
  }

  private func snapshot(
    backend: ASRBackendType = .parakeet, languageMode: LanguageMode = .locked("en"),
    engineDetectsLanguage: Bool = false
  ) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: backend, backendSupportsLanguageDetection: engineDetectsLanguage,
      languageMode: languageMode, wordCorrectionEnabled: true,
      fillerRemovalEnabled: false, emojiFormatterEnabled: false,
      spokenPunctuationEnabled: false, llmProvider: LLMProvider.egOne.rawValue,
      llmModel: "none", s1Control: nil, englishSpelling: nil)
  }

  @Test("recovery asks its frozen provider with the replay language")
  func recovery() async {
    for choice in choices {
      var calls: [(LLMProvider, String?)] = []
      let processor = RecoveryTextProcessor(
        keychainManager: KeychainManager(),
        checkerSelectionProvider: { provider, language in
          calls.append((provider, language))
          return choice
        })
      processor.applySettings(snapshot())
      processor.applyCustomWordsVocabulary(corrector: vocabulary, polish: .empty)
      let result = await processor.process(rawText: spoken)
      #expect(result.text.contains("Tuist") == (choice.checker != nil))
      #expect(calls.count == 1)
      #expect(calls.first?.0 == .egOne && calls.first?.1 == "en")
    }
  }

  @Test("file import asks once per part using the frozen import provider")
  func fileImport() async throws {
    for choice in choices {
      var calls: [(LLMProvider, String?)] = []
      let runner = FileImportRunner(
        keychainManager: KeychainManager(),
        checkerSelectionProvider: { provider, language in
          calls.append((provider, language))
          return choice
        })
      runner.freeze(settings: snapshot(backend: .whisperKit), vocabulary: vocabulary)
      let result = try await runner.process(part: spoken)
      #expect(result.text.contains("Tuist") == (choice.checker != nil))
      #expect(calls.count == 1)
      #expect(calls.first?.0 == .egOne && calls.first?.1 == "en")
    }
  }

  @Test("later import parts keep the first part's absent decision")
  func importDoesNotPromoteMidRun() async throws {
    var calls = 0
    let runner = FileImportRunner(
      keychainManager: KeychainManager(),
      checkerSelectionProvider: { _, _ in
        calls += 1
        return calls == 1
          ? .init(absence: .adapterDownloading)
          : .init(checker: Approver(), identity: "test_ready")
      })
    runner.freeze(settings: snapshot(), vocabulary: vocabulary)
    let first = try await runner.process(part: spoken)
    let second = try await runner.process(part: spoken)
    #expect(first.text == second.text)
    #expect(second.text.contains("Tuist") == false)
    #expect(calls == 1)
  }

  @Test("an import asks again when a later part's engine language differs")
  func importKeysSelectionByLanguage() async throws {
    var calls: [String?] = []
    let runner = FileImportRunner(
      keychainManager: KeychainManager(),
      checkerSelectionProvider: { _, language in
        calls.append(language)
        return language == "en"
          ? .init(checker: Approver(), identity: "test_ready")
          : .init(absence: .serverUnavailable)
      })
    runner.freeze(
      settings: snapshot(backend: .whisperKit, languageMode: .auto, engineDetectsLanguage: true),
      vocabulary: vocabulary)
    let english = try await runner.process(part: spoken, engineLanguage: "en")
    let spanish = try await runner.process(part: spoken, engineLanguage: "es")
    let englishAgain = try await runner.process(part: spoken, engineLanguage: "en")
    #expect(english.text.contains("Tuist"))
    #expect(spanish.text.contains("Tuist") == false)
    #expect(englishAgain.text.contains("Tuist"))
    #expect(calls == ["en", "es"])
  }

  @Test("both live language evidence shapes freeze their selection before the chain")
  func liveRunner() async throws {
    for evidence in [LanguageEvidence.locked("en"), LanguageEvidence.none] {
      for choice in choices {
        var calls = 0
        let learned = LearnedWordCheckStep()
        learned.wordCorrectionEnabled = true
        learned.correctorVocabulary = vocabulary
        learned.selectionProvider = { provider, _ in
          calls += 1
          #expect(provider == .egOne)
          return choice
        }
        let polish = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
        polish.llmProvider = .egOne
        let result = try await TextProcessingRunner(telemetry: .silent).run(
          rawText: spoken, evidence: evidence,
          targetAppName: nil, steps: [learned, polish])
        #expect(result.context.text.contains("Tuist") == (choice.checker != nil))
        #expect(calls == 1)
      }
    }
  }

  // MARK: - #3289: an import stops holding the word check when its job ends

  /// Holds a checker's answer until the test opens it.
  private actor AnswerGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func hold() async {
      if isOpen { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      isOpen = true
      let held = waiters
      waiters = []
      for waiter in held { waiter.resume() }
    }
  }

  /// A checker whose lifetime the test can watch: `onDeinit` is the subject's own signal that its
  /// last holder let go.
  private final class TrackedChecker: LearnedWordChecking {
    let armName = "test_tracked"
    let scoresAreComparable = false
    let gate: AnswerGate?
    let onDeinit: @Sendable () -> Void
    init(gate: AnswerGate? = nil, onDeinit: @escaping @Sendable () -> Void = {}) {
      self.gate = gate
      self.onDeinit = onDeinit
    }
    deinit { onDeinit() }
    func decide(_ questions: [LearnedWordCheckQuestion]) async throws
      -> [LearnedWordCheckDecision]
    {
      if let gate { await gate.hold() }
      return questions.map { .init(questionID: $0.id, approved: true) }
    }
  }

  /// True when `stream` yields before `seconds` pass. The bound only keeps a broken build from
  /// hanging; nothing asserts on it.
  private func arrives(_ stream: AsyncStream<Void>, within seconds: Double) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in stream { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(seconds))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  @Test("the runner reports the engine it was frozen with")
  func frozenProvider() {
    let runner = FileImportRunner(keychainManager: KeychainManager())
    #expect(runner.frozenLLMProvider == nil)
    runner.freeze(settings: snapshot(), vocabulary: vocabulary)
    #expect(runner.frozenLLMProvider == .egOne)
  }

  @Test("releasing a finished import drops its cached checker, and the next run asks again")
  func releaseDropsTheCachedChecker() async throws {
    weak var held: TrackedChecker?
    var calls = 0
    let runner = FileImportRunner(
      keychainManager: KeychainManager(),
      checkerSelectionProvider: { _, _ in
        calls += 1
        let checker = TrackedChecker()
        held = checker
        return .init(checker: checker, identity: "test_tracked")
      })
    runner.freeze(settings: snapshot(), vocabulary: vocabulary)
    let first = try await runner.process(part: spoken)
    #expect(first.text.contains("Tuist"))
    #expect(held != nil, "fixture: between parts the run's cache holds the checker")
    runner.releaseCheckerSelections()
    #expect(held == nil, "the released import still holds the checker")
    _ = try await runner.process(part: spoken)
    #expect(calls == 2, "after release the next part must ask for a fresh selection")
  }

  @Test(
    "a selection that returns after a release or a newer freeze does not refill the cache",
    arguments: [false, true])
  func lateSelectionDoesNotRefill(newerFreeze: Bool) async throws {
    let gate = AnswerGate()
    let (entered, enteredSignal) = AsyncStream.makeStream(of: Void.self)
    let (staleGone, staleGoneSignal) = AsyncStream.makeStream(of: Void.self)
    var calls = 0
    let runner = FileImportRunner(
      keychainManager: KeychainManager(),
      checkerSelectionProvider: { _, _ in
        calls += 1
        if calls == 1 {
          enteredSignal.yield()
          await gate.hold()
          // The stale selection's checker: if the late write refilled the cache, it stays alive.
          return .init(
            checker: TrackedChecker(onDeinit: { staleGoneSignal.yield() }), identity: "test_tracked")
        }
        return .init(checker: Approver(), identity: "test_ready")
      })
    runner.freeze(settings: snapshot(), vocabulary: vocabulary)
    let part = Task { try await runner.process(part: spoken) }
    #expect(await arrives(entered, within: 5), "fixture: the first selection never started")
    if newerFreeze {
      runner.freeze(settings: snapshot(), vocabulary: vocabulary)
    } else {
      runner.releaseCheckerSelections()
    }
    await gate.open()
    _ = try await part.value
    // The part can return at its deadline before the late selection lands, so wait for the stale
    // checker itself to go: a refilled cache would keep it alive.
    #expect(
      await arrives(staleGone, within: 5),
      "the stale selection was cached for a run that no longer owned it")
    _ = try await runner.process(part: spoken)
    #expect(calls == 2, "after the stale selection, the next part must ask again")
  }

  @Test("a late checker answer lets go of its checker once it returns, after the job released it")
  func lateAnswerReleasesItsChecker() async throws {
    let gate = AnswerGate()
    let (gone, goneSignal) = AsyncStream.makeStream(of: Void.self)
    let runner = FileImportRunner(
      keychainManager: KeychainManager(),
      checkerSelectionProvider: { _, _ in
        .init(
          checker: TrackedChecker(gate: gate, onDeinit: { goneSignal.yield() }),
          identity: "test_tracked")
      })
    runner.freeze(settings: snapshot(), vocabulary: vocabulary)
    // The answer is held past the step's deadline, so the part finishes unchanged.
    let result = try await runner.process(part: spoken)
    #expect(result.text.contains("Tuist") == false, "fixture: the held answer must miss its deadline")
    runner.releaseCheckerSelections()
    await gate.open()
    #expect(await arrives(gone, within: 5), "the checker outlived its late answer")
  }
}
