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
    let step = LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    step.setPolish(provider: .appleIntelligence)
    step.llmModel = "apple-intelligence"
    step.polishInstructions = instructions
    step.makePolisher = { _, _, _, _ in TextRecordingPolisher(box: box) }
    let transcript = "so i was thinking we could maybe ship the new thing some time next week or so"

    _ = try await step.process(TextProcessingContext(text: transcript, language: "en"))

    #expect(box.text == transcript)
  }

  /// A call that ignores cancellation, as Apple's does on macOS 26 (#5026): it returns only
  /// when `gate` is finished. Awaiting an unstructured task's value does not observe cancellation.
  struct StubbornPolisher: TranscriptPolisher {
    let gate = AsyncStream<Void>.makeStream()
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      let stream = gate.stream
      await Task { for await _ in stream {} }.value
      return LLMResult(polishedText: text)
    }
  }

  // When this fails, a dictation's paste waits for Apple's model instead of the polish budget.
  @Test("an Apple call that ignores cancellation is left at the deadline and reports nothing")
  func stubbornAppleCallIsAbandonedAtTheDeadline() async throws {
    let polisher = StubbornPolisher()
    var completions = 0
    let quiet = LLMPolishStep.TelemetrySeams.silent()
    let step = LLMPolishStep(
      keychainManager: KeychainManager(), localPolishers: .llamaForTests,
      telemetry: .init(
        limbFailureObserved: quiet.limbFailureObserved, breadcrumbStarted: quiet.breadcrumbStarted,
        captureProviderInitError: quiet.captureProviderInitError,
        captureAFMPolishError: { _ in completions += 1 },
        breadcrumbCompleted: { _, _ in completions += 1 },
        recordPolishSkipped: quiet.recordPolishSkipped,
        recordPolishLanguageHint: quiet.recordPolishLanguageHint))
    step.setPolish(provider: .appleIntelligence)
    step.llmModel = "apple-intelligence"
    step.appleDeadlineSecondsForTesting = 0.05
    step.makePolisher = { _, _, _, _ in polisher }
    defer { polisher.gate.continuation.finish() }

    let run = Task { @MainActor () -> Bool in
      do {
        _ = try await step.process(
          TextProcessingContext(
            text: "so i was thinking we could ship the new thing next week", language: "en"))
        return false
      } catch { return error is TimeoutError }
    }
    // deadline-fallback: a hang guard far above the 0.05 s deadline under test.
    let timedOut = await withDeadline(seconds: 10) { await run.value }
    #expect(timedOut == true, "did not return within 10 s with a TimeoutError")
    // Nothing below waits on the abandoned call: all reporting runs inside `process`, which has
    // returned. Whether the 50 ms deadline beat the call's start, the outcome is the same, so no
    // wait here depends on scheduling.
    polisher.gate.continuation.finish()
    _ = await run.value
    #expect(completions == 0, "the abandoned call reported no completion and no failure")
  }
}
