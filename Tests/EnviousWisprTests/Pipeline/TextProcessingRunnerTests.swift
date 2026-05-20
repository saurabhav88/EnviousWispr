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
    let runner = deterministicRunner()

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
    let runner = deterministicRunner()

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
    let runner = deterministicRunner()

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
    let runner = deterministicRunner()

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
    let runner = deterministicRunner()

    let first = RecordingStep(name: "Word Correction") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let llm = RecordingStep(name: "LLM Polish", errorSurfacePolicy: .surface) { _ in
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
    #expect(
      result.polishError == LLMError.requestFailed("service unavailable").localizedDescription)
  }

  @Test("suppresses polishError for unsupported input language skips from LLM Polish")
  func suppressesPolishErrorForUnsupportedInputLanguage() async throws {
    let runner = deterministicRunner()

    let llm = RecordingStep(name: "LLM Polish", errorSurfacePolicy: .surface) { _ in
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
    let runner = deterministicRunner()

    let llm = RecordingStep(name: "LLM Polish", errorSurfacePolicy: .surface) { _ in
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
    // #784 (2026-05-18): migrated from real `Task.sleep(300ms)` racing a
    // 50ms `withThrowingTimeout` deadline to a deterministic
    // `FakeTimeoutExecutor`. The fake runs normal-budget steps and throws
    // `TimeoutError` for budgets below 0.1s — sitting between the 50ms
    // slow-step budget and the 5s default budget.
    let fakeTimeout = FakeTimeoutExecutor(throwBelowSeconds: 0.1)
    let runner = TextProcessingRunner(timeoutExecutor: fakeTimeout.run)

    let first = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let slow = RecordingStep(name: "Filler Removal", maxDuration: .milliseconds(50)) { context in
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
    #expect(slow.runCount == 0)  // executor short-circuited before invoking op()
    #expect(third.runCount == 1)
    #expect(third.seenInputs.count == 1)
    #expect(third.seenInputs[0].text == "start-A")
    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == nil)
    #expect(fakeTimeout.callCount == 3)
    #expect(fakeTimeout.capturedBudgets == [5.0, 0.05, 5.0])
  }

  @Test("records polishError when LLM Polish times out and continues with prior text")
  func recordsPolishErrorWhenLLMPolishTimesOut() async throws {
    // #784 (2026-05-18): see `skipsTimedOutNonLLMStep` for migration shape.
    let fakeTimeout = FakeTimeoutExecutor(throwBelowSeconds: 0.1)
    let runner = TextProcessingRunner(timeoutExecutor: fakeTimeout.run)

    let first = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    let slowLLM = RecordingStep(
      name: "LLM Polish", maxDuration: .milliseconds(50), errorSurfacePolicy: .surface
    ) { context in
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

    #expect(first.runCount == 1)
    #expect(slowLLM.runCount == 0)  // executor short-circuited before invoking op()
    #expect(third.runCount == 1)
    #expect(third.seenInputs.count == 1)
    #expect(third.seenInputs[0].text == "start-A")
    #expect(result.context.text == "start-A-C")
    #expect(result.polishError == TimeoutError(seconds: 0.05).localizedDescription)
    #expect(fakeTimeout.callCount == 3)
    #expect(fakeTimeout.capturedBudgets == [5.0, 0.05, 5.0])
  }

  @Test("rethrows CancellationError and does not run later steps")
  func rethrowsCancellationError() async {
    let runner = deterministicRunner()

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

  // MARK: - Phase G1 — error-surface policy contract tests

  @Test(
    "Renaming the polish step does NOT affect polishError when the policy stays .surface"
  )
  func policyDispatchSurvivesRename() async throws {
    let runner = deterministicRunner()

    let renamed = RecordingStep(
      name: "Polish",  // intentionally NOT "LLM Polish"
      errorSurfacePolicy: .surface
    ) { _ in
      throw StepFailure(message: "renamed surface step exploded")
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [renamed]
    )

    #expect(result.polishError == "renamed surface step exploded")
  }

  @Test(".swallow policy never sets polishError, even for a step named 'LLM Polish'")
  func swallowPolicyHidesErrorEvenForCollidingName() async throws {
    let runner = deterministicRunner()

    // Same legacy name but explicit .swallow policy: the runner must read the
    // policy, not the name. This is the symmetric guarantee for
    // policyDispatchSurvivesRename.
    let collide = RecordingStep(
      name: "LLM Polish",
      errorSurfacePolicy: .swallow
    ) { _ in
      throw StepFailure(message: "should be swallowed")
    }

    let result = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [collide]
    )

    #expect(result.polishError == nil)
  }

  @Test("LLMPolishStep declares .surface error policy")
  func llmPolishStepDeclaresSurfacePolicy() async throws {
    let llmStep = LLMPolishStep(keychainManager: KeychainManager())
    #expect(llmStep.errorSurfacePolicy == .surface)
  }

  // MARK: - Phase G2 — injectable logger contract tests

  @Test("Step success emits a PipelineTiming entry into the injected logger")
  func successLogsPipelineTimingEntry() async throws {
    let signalLogger = SignalPipelineLogger()
    let runner = deterministicRunner(logger: signalLogger)

    let step = RecordingStep(name: "A") { context in
      var next = context
      next.text += "-A"
      return next
    }

    _ = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [step]
    )

    // Logger work runs in fire-and-forget Task envelopes; await the exact
    // entry instead of polling — resolves the instant the envelope fires.
    let entry = try await signalLogger.waitForEntry {
      $0.category == "PipelineTiming" && $0.message.hasPrefix("A completed in")
    }
    #expect(entry.category == "PipelineTiming")
  }

  @Test("Step that mutates text emits CorrectionDebug IN/OUT lines via injected logger")
  func mutatingStepLogsCorrectionDebug() async throws {
    let signalLogger = SignalPipelineLogger()
    let runner = deterministicRunner(logger: signalLogger)

    let step = RecordingStep(name: "Renamer") { context in
      var next = context
      next.text = "polished"
      return next
    }

    _ = try await runner.run(
      rawText: "raw",
      language: "en",
      targetAppName: nil,
      steps: [step]
    )

    // OUT is emitted right after IN inside the same Task envelope, so once
    // OUT has been signalled IN is already in `entries`.
    let out = try await signalLogger.waitForEntry {
      $0.category == "CorrectionDebug" && $0.message.contains("[Renamer] OUT: polished")
    }
    #expect(out.message.contains("[Renamer] OUT: polished"))
    #expect(
      signalLogger.entries.contains {
        $0.category == "CorrectionDebug" && $0.message.contains("[Renamer] IN:  raw")
      }
    )
  }

  @Test("Step timeout emits a TextProcessing 'timed out' entry via injected logger")
  func timeoutLogsTextProcessingWarning() async throws {
    // #784 (2026-05-18): see `skipsTimedOutNonLLMStep` for migration shape.
    let signalLogger = SignalPipelineLogger()
    let fakeTimeout = FakeTimeoutExecutor(throwBelowSeconds: 0.1)
    let runner = TextProcessingRunner(logger: signalLogger, timeoutExecutor: fakeTimeout.run)

    let slow = RecordingStep(name: "Slow", maxDuration: .milliseconds(50)) { context in
      return context
    }

    _ = try await runner.run(
      rawText: "start",
      language: "en",
      targetAppName: nil,
      steps: [slow]
    )

    let entry = try await signalLogger.waitForEntry {
      $0.category == "TextProcessing" && $0.message.contains("Slow timed out")
    }
    #expect(entry.message.contains("Slow timed out"))
    #expect(slow.runCount == 0)  // executor short-circuited before invoking op()
    #expect(fakeTimeout.callCount == 1)
    #expect(fakeTimeout.capturedBudgets == [0.05])
  }
}

@MainActor
private final class RecordingStep: TextProcessingStep {
  let name: String
  let isEnabled: Bool
  let maxDuration: Duration
  let errorSurfacePolicy: ErrorSurfacePolicy

  private let transform: @MainActor (TextProcessingContext) async throws -> TextProcessingContext

  private(set) var runCount = 0
  private(set) var seenInputs: [TextProcessingContext] = []

  init(
    name: String,
    isEnabled: Bool = true,
    maxDuration: Duration = .seconds(5),
    errorSurfacePolicy: ErrorSurfacePolicy = .swallow,
    transform: @escaping @MainActor (TextProcessingContext) async throws -> TextProcessingContext
  ) {
    self.name = name
    self.isEnabled = isEnabled
    self.maxDuration = maxDuration
    self.errorSurfacePolicy = errorSurfacePolicy
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

/// Builds a runner whose timeout executor never throws — every step runs to
/// completion regardless of how long the CI scheduler takes.
///
/// #794 (2026-05-19): replaces bare `TextProcessingRunner()` across this
/// suite. The default `TextProcessingRunner()` delegates to the real
/// `withThrowingTimeout`, which races a wall clock; on a contended CI runner
/// a step's 5s budget can expire and the runner silently degrades to prior
/// input. Tests that ARE about timeout behavior keep their own explicit
/// `FakeTimeoutExecutor(throwBelowSeconds: 0.1)` discriminator.
@MainActor
private func deterministicRunner(
  logger: SignalPipelineLogger? = nil
) -> TextProcessingRunner {
  let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
  if let logger {
    return TextProcessingRunner(logger: logger, timeoutExecutor: executor.run)
  }
  return TextProcessingRunner(timeoutExecutor: executor.run)
}
