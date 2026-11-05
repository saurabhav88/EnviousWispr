import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #4353 D9: Transcribe a File keeps every part's cleaned words when its cloud polish has no
/// model or the chosen model is gone, and says so with a typed outcome naming the model the run
/// asked for. No model chosen is a bypass, never a "could not be cleaned up" failure.
@MainActor
@Suite("Transcribe a File with a cloud model problem (#4353)", .tags(.productOutcome, .localParallel))
struct FileImportCloudSetupTests {
  /// Every switch that rewrites words is off and spelling is American, so the deterministic
  /// floor of each passage is the passage itself, written out here as literals.
  private static let passages = [
    "the color of the center is important to everyone on the design team",
    "please send the final report to the whole team before lunch tomorrow",
    "we should review the remaining changes with our colleagues before we publish",
  ]

  /// Records every request the polish step sends, and refuses the ones `refuse` matches with
  /// the provider's "this model does not exist" answer.
  @MainActor
  private final class Capture {
    var users: [String] = []
    var models: [String] = []
    var refuse: (String) -> Bool = { _ in false }
    var refusal: Error = LLMError.classified(.modelUnavailable)
    func answer(user: String, config: LLMProviderConfig) throws -> LLMResult {
      users.append(user)
      models.append(config.model)
      if refuse(user) { throw refusal }
      let prefix = "Transcript to clean:\n\n"
      let text = user.hasPrefix(prefix) ? String(user.dropFirst(prefix.count)) : user
      return LLMResult(polishedText: text.prefix(1).uppercased() + text.dropFirst() + ".")
    }
  }

  private struct Polisher: TranscriptPolisher {
    let capture: Capture
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      try await capture.answer(user: text, config: config)
    }
    func polish(
      envelope: PromptEnvelope, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      try await capture.answer(user: envelope.asSingleTurn()?.user ?? "", config: config)
    }
  }

  private func runner(_ capture: Capture, provider: LLMProvider, model: String) -> FileImportRunner
  {
    let subject = FileImportRunner(
      keychainManager: KeychainManager(), egOneRuntime: nil, s1MiniRuntime: nil,
      outputClassifierHolder: nil, languageIdentifier: { _ in ("en", 0.99) },
      makeEGOnePolisher: nil, promptPlanner: nil, checkerSelectionProvider: nil,
      makePolisher: { _, _, _, _ in Polisher(capture: capture) })
    subject.freeze(
      settings: RecordingSettingsSnapshot(
        backendType: .parakeet, backendSupportsLanguageDetection: false,
        languageMode: .locked("en"), wordCorrectionEnabled: false, fillerRemovalEnabled: false,
        emojiFormatterEnabled: false, spokenPunctuationEnabled: false,
        spokenPunctuationStartWords: nil, spokenPunctuationEnglishPeriodWord: nil,
        llmProvider: provider.rawValue, llmModel: model, s1Control: nil,
        englishSpelling: .american, casualModeEnabled: false),
      vocabulary: nil, cloudModelList: nil)
    return subject
  }

  private func run(_ subject: FileImportRunner) async throws -> [FileImportRunner.PartOutcome] {
    var indices: [Int] = []
    var outcomes: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: Self.passages) { index, outcome in
      indices.append(index)
      outcomes.append(outcome)
      return true
    }
    #expect(indices == [0, 1, 2])
    return outcomes
  }

  @Test("no model chosen: every passage kept whole, none marked failed, no request sent")
  func noModelChosen() async throws {
    let capture = Capture()
    let outcomes = try await run(runner(capture, provider: .openAI, model: ""))
    #expect(capture.users.isEmpty)
    #expect(outcomes.map(\.text) == Self.passages)
    #expect(outcomes.allSatisfy { $0.cloudSetup == .noModelChosen(provider: .openAI) })
    #expect(outcomes.allSatisfy { $0.polishedText == nil })
    #expect(outcomes.allSatisfy { $0.wasPolishAttempted == false })
    #expect(outcomes.allSatisfy { $0.isUnpolished == false }, "a bypass read as failed cleanup")

    // The one-passage route says the same.
    let single = try await runner(capture, provider: .claude, model: "").process(
      part: Self.passages[0])
    #expect(capture.users.isEmpty)
    #expect(single.cloudSetup == .noModelChosen(provider: .claude))
    #expect(single.text == Self.passages[0])
    #expect(single.isUnpolished == false)
  }

  @Test("one shared request to a gone model: every member names that model and keeps its words")
  func batchedModelGone() async throws {
    let capture = Capture()
    capture.refuse = { _ in true }
    // gpt-6.1-sol qualifies for the shared request (FileImportBatchTests.orderedBatch).
    let outcomes = try await run(runner(capture, provider: .openAI, model: "gpt-6.1-sol"))
    #expect(capture.users.count == 1, "the three passages did not share one request")
    #expect(capture.users.first?.contains("<s1>") == true)
    #expect(capture.users.first?.contains("<s3>") == true)
    #expect(capture.models == ["gpt-6.1-sol"])
    #expect(outcomes.map(\.text) == Self.passages)
    for outcome in outcomes {
      #expect(outcome.cloudSetup == .modelUnavailable(provider: .openAI, model: "gpt-6.1-sol"))
      #expect(outcome.polishedText == nil)
      #expect(outcome.wasPolishAttempted)
      #expect(outcome.isUnpolished, "a real failure must stay marked")
    }
  }

  @Test("one-passage requests: only the refused passage names the model; the others stay cleaned")
  func ordinaryMixed() async throws {
    let capture = Capture()
    capture.refuse = { $0.contains("final report") }
    // gpt-4o-mini does not qualify for the shared request (FileImportBatchTests parity rows).
    let outcomes = try await run(runner(capture, provider: .openAI, model: "gpt-4o-mini"))
    #expect(capture.users.count == 3)
    #expect(capture.users.allSatisfy { $0.contains("<s1>") == false })
    #expect(
      outcomes.map(\.cloudSetup) == [
        nil, .modelUnavailable(provider: .openAI, model: "gpt-4o-mini"), nil,
      ])
    #expect(outcomes.map(\.polishedText) == [
      "The color of the center is important to everyone on the design team.", nil,
      "We should review the remaining changes with our colleagues before we publish.",
    ])
    #expect(outcomes.map(\.text) == Self.passages)
    #expect(outcomes.map(\.isUnpolished) == [false, true, false])

    // The one-passage route carries the same typed outcome.
    let single = try await runner(capture, provider: .openAI, model: "gpt-4o-mini")
      .process(part: Self.passages[1])
    #expect(single.cloudSetup == .modelUnavailable(provider: .openAI, model: "gpt-4o-mini"))
    #expect(single.text == Self.passages[1])
  }

  @Test("#4353 G5 a leftover audio model's 400 names it on every part; an ordinary 400 does not")
  func audioModelRejection() async throws {
    let capture = Capture()
    capture.refuse = { _ in true }
    capture.refusal = LLMError.classified(.badRequest)
    let outcomes = try await run(runner(capture, provider: .gemini, model: "gemini-3.5-transcribe"))
    #expect(outcomes.map(\.text) == Self.passages)
    #expect(outcomes.allSatisfy {
      $0.cloudSetup == .modelUnavailable(provider: .gemini, model: "gemini-3.5-transcribe")
    })
    #expect(outcomes.allSatisfy { $0.isUnpolished })

    let plain = Capture()
    plain.refuse = { _ in true }
    plain.refusal = LLMError.classified(.badRequest)
    let ordinary = try await run(runner(plain, provider: .gemini, model: "gemini-3.7-flash"))
    #expect(ordinary.map(\.text) == Self.passages)
    #expect(ordinary.allSatisfy { $0.cloudSetup == nil })
    #expect(ordinary.allSatisfy { $0.isUnpolished }, "a failed request stays marked")
  }
}
