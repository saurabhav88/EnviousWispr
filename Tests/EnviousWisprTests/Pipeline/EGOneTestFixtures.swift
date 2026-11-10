import EnviousWisprCore
import EnviousWisprLlamaEngine
import EnviousWisprLocalPolish
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

// #3111 fixtures shared by FileImportRunnerTests, FileImportBatchTests,
// FileImportCoordinatorTests and LLMPolishResultFinisherTests. #4243: moved
// unchanged out of FileImportRunnerTests.swift so the cloud critical bundle can
// compile LLMPolishResultFinisherTests without that suite.

extension BundledLocalPolisherFactories {
  /// #4473: the two connectors the polish step built for itself before the factories became
  /// required. Tests that construct a step, or anything that owns one, pass this pair so they
  /// behave as before. Test-only: the app gets its pair from the composition root and there is
  /// no default in the pipeline.
  static var llamaForTests: BundledLocalPolisherFactories {
    BundledLocalPolisherFactories(
      egOne: { EGOneConnector(endpoint: $0) },
      s1Mini: { S1MiniConnector(endpoint: $0) })
  }

  /// The same pair with another EG-1 factory: what the import runner's optional EG-1 override
  /// used to be for.
  func replacingEGOne(_ egOne: @escaping Factory) -> BundledLocalPolisherFactories {
    BundledLocalPolisherFactories(egOne: egOne, s1Mini: s1Mini)
  }
}

/// #4473: two DIFFERENT spy connector factories, for tests that prove a constructed path uses
/// the pair it was given. Each records the endpoint it was asked to serve and answers with its
/// own text, so a path that reaches the other model's factory, or builds a connector of its
/// own, shows in both the record and the polished text.
@MainActor
final class LocalPolisherFactorySpy {
  /// Long enough to clear the polish step's short-transcript short-circuit.
  static let transcript =
    "so i was thinking we could maybe ship the new thing some time next week or so"
  /// Two plausible rewrites that differ in one word: the output check accepts both.
  static let egOneAnswer = "I was thinking we could ship the new thing sometime next week."
  static let s1MiniAnswer = "I was thinking we could ship the new thing next week."
  /// The endpoint `ReadyEGOneRuntime` reports.
  static let endpoint = EGOneEndpoint(port: 1, authToken: "t", contextTokens: 32768)

  private struct FixedAnswerPolisher: TranscriptPolisher {
    let answer: String
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: answer)
    }
  }

  private(set) var egOneEndpoints: [EGOneEndpoint] = []
  private(set) var s1MiniEndpoints: [EGOneEndpoint] = []

  var factories: BundledLocalPolisherFactories {
    BundledLocalPolisherFactories(
      egOne: { [self] endpoint in
        egOneEndpoints.append(endpoint)
        return FixedAnswerPolisher(answer: Self.egOneAnswer)
      },
      s1Mini: { [self] endpoint in
        s1MiniEndpoints.append(endpoint)
        return FixedAnswerPolisher(answer: Self.s1MiniAnswer)
      })
  }

  static func answer(for provider: LLMProvider) -> String {
    provider == .s1Mini ? s1MiniAnswer : egOneAnswer
  }

  /// A take frozen on `provider` (one of the two bundled models), every other limb off.
  static func snapshot(for provider: LLMProvider) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .parakeet, backendSupportsLanguageDetection: false,
      languageMode: .locked("en"), wordCorrectionEnabled: false, fillerRemovalEnabled: false,
      emojiFormatterEnabled: false, spokenPunctuationEnabled: false,
      spokenPunctuationStartWords: nil, spokenPunctuationEnglishPeriodWord: nil,
      llmProvider: provider.rawValue,
      llmModel: LLMProvider.localModel(for: provider, ollamaModel: "") ?? "", s1Control: nil,
      englishSpelling: nil, casualModeEnabled: nil)
  }

  /// Exactly one call reached `provider`'s factory, on the ready endpoint, and none reached the
  /// other model's.
  func expectOnlyFactory(
    of provider: LLMProvider, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let own = provider == .s1Mini ? s1MiniEndpoints : egOneEndpoints
    let other = provider == .s1Mini ? egOneEndpoints : s1MiniEndpoints
    #expect(own == [Self.endpoint], sourceLocation: sourceLocation)
    #expect(other.isEmpty, sourceLocation: sourceLocation)
  }
}

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
