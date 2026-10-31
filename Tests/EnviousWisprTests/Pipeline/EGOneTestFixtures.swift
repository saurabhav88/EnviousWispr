import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

// #3111 fixtures shared by FileImportRunnerTests, FileImportBatchTests,
// FileImportCoordinatorTests and LLMPolishResultFinisherTests. #4243: moved
// unchanged out of FileImportRunnerTests.swift so the cloud critical bundle can
// compile LLMPolishResultFinisherTests without that suite.

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
