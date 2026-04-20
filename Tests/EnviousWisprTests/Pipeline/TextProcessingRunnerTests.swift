
import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite("TextProcessingRunner")
struct TextProcessingRunnerTests {

  @Test("returns the seeded context unchanged when there are no steps")
  func returnsSeededContextWhenThereAreNoSteps() async throws {
    let runner = TextProcessingRunner()

    let result = try await runner.run(
      rawText: "hello world",
      language: "en",
      targetAppName: "Notes",
      steps: []
    )

    #expect(result.context.text == "hello world")
    #expect(result.context.polishedText == nil)
    #expect(result.context.language == "en")
    #expect(result.context.targetAppName == "Notes")
    #expect(result.context.llmProvider == nil)
    #expect(result.context.llmModel == nil)
    #expect(result.polishError == nil)
  }

  @Test("passes raw text, language, target app, and prior mutations through the real runner")
  func passesSeededAndMutatedContextThroughTheChain() async throws {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "Normalize") { context in
      var next = context
      next.text = "Zażółć gęślą jaźń 👩🏽‍💻"
      next.polishedText = "Zażółć gęślą jaźń 👩🏽‍💻"
      next.llmProvider = "openai"
      next.llmModel = "gpt-4.1"
      return next
    }

    let second = RecordingStep(name: "Suffix") { context in
      var next = context
      next.text += " done"
      next.polishedText = (context.polishedText ?? context.text) + " done"
      return next
    }

    let result = try await runner.run(
      rawText: "héllo 世界",
      language: "pl",
      targetAppName: "Notes",
      steps: [first, second]
    )

    #expect(first.runCount == 1)
    #expect(second.runCount == 1)

    #expect(first.seenInputs.count == 1)
    #expect(first.seenInputs[0].text == "héllo 世界")
    #expect(first.seenInputs[0].language == "pl")
    #expect(first.seenInputs[0].targetAppName == "Notes")
    #expect(first.seenInputs[0].polishedText == nil)

    #expect(second.seenInputs.count == 1)
    #expect(second.seenInputs[0].text == "Zażółć gęślą jaźń 👩🏽‍💻")
    #expect(second.seenInputs[0].polishedText == "Zażółć gęślą jaźń 👩🏽‍💻")
    #expect(second.seenInputs[0].language == "pl")
    #expect(second.seenInputs[0].targetAppName == "Notes")
    #expect(second.seenInputs[0].llmProvider == "openai")
    #expect(second.seenInputs[0].llmModel == "gpt-4.1")

    #expect(result.context.text == "Zażółć gęślą jaźń 👩🏽‍💻 done")
    #expect(result.context.polishedText == "Zażółć gęślą jaźń 👩🏽‍💻 done")
    #expect(result.context.language == "pl")
    #expect(result.context.targetAppName == "Notes")
    #expect(result.context.llmProvider == "openai")
    #expect(result.context.llmModel == "gpt-4.1")
    #expect(result.polishError == nil)
  }

  @Test("skips disabled steps and keeps running enabled ones in order")
  func skipsDisabledSteps() async throws {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let disabled = RecordingStep(name: "B", isEnabled: false) { context in
      var next = context
      next.text += "-B"
      return next
    }

    let third = RecordingStep(name: "C") { context in
      var next = context
      next.text += "-C"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [first, disabled, third]
    )

    #expect(first.runCount == 1)
    #expect(disabled.runCount == 0)
    #expect(third.runCount == 1)
    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == nil)
  }

  @Test("continues after a non-LLM step failure and does not set polishError")
  func continuesAfterNonLLMStepFailure() async throws {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "Word Correction") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let failing = RecordingStep(name: "Filler Removal") { _ in
      throw StepFailure(message: "step exploded")
    }

    let third = RecordingStep(name: "Suffix") { context in
      var next = context
      next.text += "-C"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [first, failing, third]
    )

    #expect(first.runCount == 1)
    #expect(failing.runCount == 1)
    #expect(third.runCount == 1)
    #expect(third.seenInputs.count == 1)
    #expect(third.seenInputs[0].text == "start-A")
    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == nil)
  }

  @Test("captures LLM polish failures in polishError and continues with prior text")
  func capturesLLMPolishFailures() async throws {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "Word Correction") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let llm = RecordingStep(name: "LLM Polish") { _ in
      throw LLMError.requestFailed("service unavailable")
    }

    let third = RecordingStep(name: "Suffix") { context in
      var next = context
      next.text += "-C"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [first, llm, third]
    )

    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == LLMError.requestFailed("service unavailable").localizedDescription)
  }

  @Test("suppresses polishError for unsupported input language skips from LLM Polish")
  func suppressesPolishErrorForUnsupportedInputLanguage() async throws {
    let runner = TextProcessingRunner()

    let llm = RecordingStep(name: "LLM Polish") { _ in
      throw LLMError.unsupportedInputLanguage("de")
    }

    let after = RecordingStep(name: "Suffix") { context in
      var next = context
      next.text += "-after"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "de",
      targetAppName: nil,
      steps: [llm, after]
    )

    #expect(llm.runCount == 1)
    #expect(after.runCount == 1)
    #expect(after.seenInputs.count == 1)
    #expect(after.seenInputs[0].text == "start")
    #expect(result.context.text == "start-after")
    #expect(result.polishError == nil)
  }

  @Test("suppresses polishError for output language drift skips from LLM Polish")
  func suppressesPolishErrorForOutputLanguageDrift() async throws {
    let runner = TextProcessingRunner()

    let llm = RecordingStep(name: "LLM Polish") { _ in
      throw LLMError.outputLanguageDrift(expected: "de", actual: "en")
    }

    let after = RecordingStep(name: "Suffix") { context in
      var next = context
      next.text += "-after"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "de",
      targetAppName: nil,
      steps: [llm, after]
    )

    #expect(llm.runCount == 1)
    #expect(after.runCount == 1)
    #expect(after.seenInputs.count == 1)
    #expect(after.seenInputs[0].text == "start")
    #expect(result.context.text == "start-after")
    #expect(result.polishError == nil)
  }

  @Test("skips a timed-out non-LLM step and continues without polishError")
  func skipsTimedOutNonLLMStep() async throws {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let slow = RecordingStep(name: "Filler Removal", maxDuration: .milliseconds(50)) { context in
      try await Task.sleep(for: .milliseconds(300))
      var next = context
      next.text += "-slow"
      return next
    }

    let third = RecordingStep(name: "C") { context in
      var next = context
      next.text += "-C"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [first, slow, third]
    )

    #expect(first.runCount == 1)
    #expect(slow.runCount == 1)
    #expect(third.runCount == 1)
    #expect(third.seenInputs.count == 1)
    #expect(third.seenInputs[0].text == "start-A")
    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == nil)
  }

  @Test("records polishError when LLM Polish times out and continues with prior text")
  func recordsPolishErrorWhenLLMPolishTimesOut() async throws {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let slowLLM = RecordingStep(name: "LLM Polish", maxDuration: .milliseconds(50)) { context in
      try await Task.sleep(for: .milliseconds(300))
      var next = context
      next.text += "-slow"
      return next
    }

    let third = RecordingStep(name: "C") { context in
      var next = context
      next.text += "-C"
      return next
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [first, slowLLM, third]
    )

    #expect(slowLLM.runCount == 1)
    #expect(third.runCount == 1)
    #expect(third.seenInputs.count == 1)
    #expect(third.seenInputs[0].text == "start-A")
    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == TimeoutError(seconds: 0.05).localizedDescription)
  }

  @Test("rethrows CancellationError and does not run later steps")
  func rethrowsCancellationError() async {
    let runner = TextProcessingRunner()

    let first = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let cancelling = RecordingStep(name: "Cancel") { _ in
      throw CancellationError()
    }

    let third = RecordingStep(name: "C") { context in
      var next = context
      next.text += "-C"
      return next
    }

    do {
      _ = try await runner.run(
        rawText: "start",
        language: "en",
        targetAppName: nil,
        steps: [first, cancelling, third]
      )
      Issue.record("Expected CancellationError to be thrown")
    } catch is CancellationError {
      #expect(first.runCount == 1)
      #expect(cancelling.runCount == 1)
      #expect(third.runCount == 0)
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }
  }

  // TODO: production bug — add a contract test once fixed.
  // `TextProcessingRunner` decides whether to surface `polishError` by matching
  // the literal step name "LLM Polish". That is brittle: renaming the polish step
  // silently changes user-visible error behavior.
}

@MainActor
private final class RecordingStep: TextProcessingStep {
  let name: String
  let isEnabled: Bool
  let maxDuration: Duration

  private let transform: @MainActor (TextProcessingContext) async throws -> TextProcessingContext

  private(set) var runCount = 0
  private(set) var seenInputs: [TextProcessingContext] = []

  init(
    name: String,
    isEnabled: Bool = true,
    maxDuration: Duration = .seconds(5),
    transform: @escaping @MainActor (TextProcessingContext) async throws -> TextProcessingContext
  ) {
    self.name = name
    self.isEnabled = isEnabled
    self.maxDuration = maxDuration
    self.transform = transform
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    runCount += 1
    seenInputs.append(context)
    return try await transform(context)
  }
}

private struct StepFailure: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}