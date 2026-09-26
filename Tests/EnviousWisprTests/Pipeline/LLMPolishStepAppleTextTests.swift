import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3195: the Apple connector builds its whole on-device prompt itself and reads no
/// caller prompt text, so the dictation must always reach it as `text`. Before this,
/// a `${transcript}` template was substituted into the instructions and `text` was
/// emptied, which on the Apple path means the model polishes an empty transcript.
@MainActor
@Suite("LLMPolishStep sends the dictation to Apple Intelligence as text (#3195)", .tags(.productOutcome))
struct LLMPolishStepAppleTextTests {

  final class TextBox: @unchecked Sendable { var text: String? }

  struct TextRecordingPolisher: TranscriptPolisher {
    let box: TextBox
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      box.text = text
      return LLMResult(polishedText: text)
    }
  }

  @Test(
    "the transcript reaches the Apple polisher even when the instructions carry a template",
    arguments: [PolishInstructions.default, PolishInstructions(systemPrompt: "Fix this: ${transcript}")])
  func transcriptAlwaysSentAsText(instructions: PolishInstructions) async throws {
    let box = TextBox()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .appleIntelligence
    step.llmModel = "apple-intelligence"
    step.polishInstructions = instructions
    step.makePolisher = { _, _, _ in TextRecordingPolisher(box: box) }
    let transcript = "so i was thinking we could maybe ship the new thing some time next week or so"

    _ = try await step.process(TextProcessingContext(text: transcript, language: "en"))

    #expect(box.text == transcript)
  }
}
