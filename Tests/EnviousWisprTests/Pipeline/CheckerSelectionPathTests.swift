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
    .init(terms: [.init(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
      learnedAt: Date(timeIntervalSince1970: 1_790_000_000))], generation: 1)
  }

  private var choices: [LearnedWordCheckerSelection] {
    [.init(checker: Approver(), identity: "test_ready"),
      .init(absence: .adapterDownloading),
      .init(absence: .baseMismatch("prompt_template")),
      .init(absence: .serverUnavailable),
      .init(absence: .unqualifiedLanguage)]
  }

  private func snapshot(backend: ASRBackendType = .parakeet) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: backend, backendSupportsLanguageDetection: false,
      languageMode: .locked("en"), wordCorrectionEnabled: true,
      fillerRemovalEnabled: false, emojiFormatterEnabled: false,
      spokenPunctuationEnabled: false, llmProvider: LLMProvider.egOne.rawValue,
      llmModel: "none", s1Control: nil)
  }

  @Test("recovery asks its frozen provider with the replay language")
  func recovery() async {
    for choice in choices {
      var calls: [(LLMProvider, String?)] = []
      let processor = RecoveryTextProcessor(
        keychainManager: KeychainManager(), checkerSelectionProvider: { provider, language in
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
        keychainManager: KeychainManager(), checkerSelectionProvider: { provider, language in
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
      keychainManager: KeychainManager(), checkerSelectionProvider: { _, _ in
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
}
