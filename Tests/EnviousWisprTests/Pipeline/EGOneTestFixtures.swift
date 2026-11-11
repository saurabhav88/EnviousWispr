import EnviousWisprCore
import Foundation
import EnviousWisprLlamaEngine
import EnviousWisprLocalPolish
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

// #3111 fixtures shared by FileImportRunnerTests, FileImportBatchTests,
// FileImportCoordinatorTests and LLMPolishResultFinisherTests. #4243: moved
// unchanged out of FileImportRunnerTests.swift so the cloud critical bundle can
// compile LLMPolishResultFinisherTests without that suite.

/// Test convenience only (#4473). Production states the provider AND the exact model
/// (`setPolish(provider:model:)`). A test that is not about EG-1 sizes names the provider, and
/// gets the provider's one model: for EG-1 the FULL size, the EG-1 that existed before sizes.
/// (Here, not in a file of its own, because the fixed cloud test bundle compiles this file.)
extension LLMPolishStep {
  func setPolish(provider: LLMProvider) {
    setPolish(provider: provider, model: .singleModel(for: provider))
  }
}

/// #4473: a stand-in for EG-1's connector, for tests that are not about that connector. It
/// sends the chat request EG-1's own connector sends (model, a system and a user turn, the
/// output cap, temperature) over the same local transport and reads the answer text, and
/// every failure is EG-1's silent skip. It lives here, in test code, because this file is
/// compiled into the fixed cloud test bundle, which does not link EG-1's engine module; the
/// real connector has its own suites, which import that module.
struct FixtureEGOneConnector: TranscriptPolisher {
  let endpoint: LocalPolishEndpoint

  func polish(
    text: String, instructions: PolishInstructions, config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    guard case .capped(let maxTokens) = config.outputTokens else {
      throw LLMError.requestFailed("Local polish requires an explicit output-token cap")
    }
    let body: [String: Any] = [
      "model": config.model,
      "messages": [
        ["role": "system", "content": instructions.systemPrompt],
        ["role": "user", "content": text],
      ],
      "max_tokens": maxTokens, "temperature": config.temperature,
    ]
    let data: Data
    do {
      data = try await LocalPolishTransport.send(
        endpoint: endpoint, body: try JSONSerialization.data(withJSONObject: body))
    } catch LocalPolishTransportError.unavailable {
      throw LLMError.egOneSkipped(.crashed)
    }
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choice = (json?["choices"] as? [[String: Any]])?.first
    if (choice?["finish_reason"] as? String) == "length" {
      throw LLMError.egOneSkipped(.outputTruncated)
    }
    let content = ((choice?["message"] as? [String: Any])?["content"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let content, !content.isEmpty else { throw LLMError.egOneSkipped(.crashed) }
    return LLMResult(polishedText: content)
  }
}

extension BundledLocalPolisherFactories {
  /// #4473: the pair of connectors a test gets when it constructs a polish step, or anything
  /// that owns one, and is not about a connector: the stand-in above for EG-1 and S1-mini's
  /// own. Test-only: the app gets its pair from the composition root and there is no default
  /// in the pipeline. (The name is from when both models ran on llama-server.)
  static var llamaForTests: BundledLocalPolisherFactories {
    BundledLocalPolisherFactories(
      egOne: { FixtureEGOneConnector(endpoint: $0) },
      s1Mini: { S1MiniConnector(endpoint: $0) })
  }

  /// The same pair with another EG-1 factory: what the import runner's optional EG-1 override
  /// used to be for.
  func replacingEGOne(_ egOne: @escaping Factory) -> BundledLocalPolisherFactories {
    BundledLocalPolisherFactories(egOne: egOne, s1Mini: s1Mini)
  }
}

/// #4473: the engine of a runtime in a test that is about the RUNTIME (install state, leases,
/// holds, upgrade, telemetry), not about an engine. Its operations are the test's own: it
/// starts the test's fake server with the generic command line every fake server here reads
/// (model, host, port, context, bearer, and the adapter flag when one is asked for), and
/// probes it with the stand-in connector. No model's real flags are in it, so it serves an
/// EG-1 size or S1-mini alike. A test about llama-server itself uses `LlamaServerEngine()`.
/// Each operation can be replaced: `TestLocalPolishEngine(makeLaunchConfiguration: { … })`.
struct TestLocalPolishEngine: LocalPolishEngine {
  var makeLaunchConfiguration: LocalPolishLaunchConfigurationFactory = TestLocalPolishEngine.launch
  var makeHealthProbe: @Sendable (LocalPolishModelID, PromptFamily) -> LocalPolishHealthProbe =
    TestLocalPolishEngine.probe
  #if DEBUG
    var inspectSlots: LocalPolishSlotInspection = LlamaServerSlotReader.operation()
  #endif

  /// The fake server's command line. An adapter path holding `,` or `:` cannot be passed in
  /// the `path:scale` flag, so such a launch carries no adapter (the spec says so too).
  static let launch: LocalPolishLaunchConfigurationFactory = {
    modelID, artifactIdentity, serverBinaryURL, modelURL, contextTokens, adapterURL in
    let adapter = adapterURL.flatMap {
      $0.path.contains(",") || $0.path.contains(":") ? nil : $0
    }
    return LocalPolishProcessManager.Configuration(
      spec: LocalPolishLaunchSpec(
        engineKind: .llamaServer, modelID: modelID, artifactIdentity: artifactIdentity,
        serverBinaryURL: serverBinaryURL, modelURL: modelURL, contextTokens: contextTokens,
        learnedWordAdapterURL: adapter, extraArguments: [],
        learnedWordAdapterArguments: adapter.map { ["--lora-scaled", "\($0.path):0"] } ?? []),
      makeArguments: LlamaServerLaunchBuilder.arguments)
  }

  /// A model's real engine where it has one that a fake server can stand in for (S1-mini on
  /// llama-server), else this test engine.
  static func forModel(_ model: LocalPolishModelID) -> any LocalPolishEngine {
    model.provider == .s1Mini ? LlamaServerEngine() : TestLocalPolishEngine()
  }

  static let probe: @Sendable (LocalPolishModelID, PromptFamily) -> LocalPolishHealthProbe = {
    modelID, promptFamily in
    let isS1 = modelID.provider == .s1Mini
    return LlamaServerHealthProbe.operation(
      spec: .init(
        provider: modelID.provider,
        modelID: isS1 ? LLMProvider.s1MiniModelName : LLMProvider.egOneModelName,
        makeConnector: {
          isS1
            ? S1MiniConnector(endpoint: $0) as any TranscriptPolisher
            : FixtureEGOneConnector(endpoint: $0)
        }),
      promptFamily: promptFamily)
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
  static let endpoint = LocalPolishEndpoint(port: 1, authToken: "t", contextTokens: 32768)

  private struct FixedAnswerPolisher: TranscriptPolisher {
    let answer: String
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: answer)
    }
  }

  private(set) var egOneEndpoints: [LocalPolishEndpoint] = []
  private(set) var s1MiniEndpoints: [LocalPolishEndpoint] = []

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
      llmModel: LLMProvider.localModel(for: provider, ollamaModel: "") ?? "", egOneSize: nil, s1Control: nil,
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
  func activeEndpoint() async -> LocalPolishEndpoint? {
    LocalPolishEndpoint(port: 1, authToken: "t", contextTokens: 32768)
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
