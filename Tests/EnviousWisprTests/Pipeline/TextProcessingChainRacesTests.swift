import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite("TextProcessingRunner Races")
struct TextProcessingChainRacesTests {

  @Test(
    "#1707 Phase 2 (Open Decision #9): cancelling the outer task while a step is suspended is silently absorbed and the chain continues to completion"
  )
  func cancellationMidStepIsSilentlyAbsorbedAndChainContinues() async {
    let runner = TextProcessingRunner()
    let started = AsyncStream.makeStream(of: Void.self)

    let suspending = GateStep(
      name: "Filler Removal",
      maxDuration: .seconds(120)
    ) { context, _ in
      started.continuation.yield(())
      started.continuation.finish()

      // Honest coverage: this is cooperative cancellation through a real
      // suspension point, not a fake step that throws CancellationError
      // immediately.
      try await Task.sleep(for: .seconds(60))
      return context
    }

    let after = GateStep(name: "After") { context, _ in
      var next = context
      next.text += "-after"
      return next
    }

    let task = Task { @MainActor in
      try await runner.run(
        rawText: "start",
        language: "en",
        targetAppName: nil,
        steps: [suspending, after]
      )
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    let outcome = await task.result
    switch outcome {
    case .success:
      break
    case .failure(let error):
      Issue.record("expected success (cancellation silently absorbed), got \(error)")
    }

    #expect(suspending.runCount == 1)
    // "After" is entered (the loop advances past the cancelled step instead
    // of aborting) — its OWN outcome, once entered, races the still-cancelled
    // ambient task against its own `withThrowingTimeout` wrapper (Swift does
    // not guarantee which finishes first when both are already-cancelled),
    // so its exact text contribution is not asserted here.
    #expect(after.runCount == 1)
  }

  @Test(
    "TextProcessingRunner is per-call stateless: two overlapping run() invocations each execute the chain through to completion"
  )
  func overlappingRunsEachExecuteChainToCompletion() async throws {
    // Adversarial-review note. This proves the runner has no shared
    // per-call state and cannot merge overlapping invocations — NOT that
    // there is an explicit anti-coalescing guarantee anywhere else in the
    // product. The claim here is only about the runner's statelessness
    // (see TextProcessingRunner.swift:15 "does not own step instances").
    let runner = TextProcessingRunner()
    let entered = AsyncStream.makeStream(of: Int.self)

    let blocking = GateStep(
      name: "Word Correction",
      maxDuration: .seconds(120)
    ) { context, invocation in
      entered.continuation.yield(invocation)
      if invocation == 2 {
        entered.continuation.finish()
      }

      // Keep the first run suspended long enough for the second run to enter.
      try await Task.sleep(for: .milliseconds(200))

      var next = context
      next.text += "-\(invocation)"
      return next
    }

    let firstTask = Task { @MainActor in
      try await runner.run(
        rawText: "start",
        language: "en",
        targetAppName: nil,
        steps: [blocking]
      )
    }

    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()

    let secondTask = Task { @MainActor in
      try await runner.run(
        rawText: "start",
        language: "en",
        targetAppName: nil,
        steps: [blocking]
      )
    }

    _ = await iterator.next()

    let first = try await firstTask.value
    let second = try await secondTask.value

    #expect(blocking.runCount == 2)
    #expect(blocking.seenInputs.count == 2)
    #expect(blocking.seenInputs[0].text == "start")
    #expect(blocking.seenInputs[1].text == "start")

    let outputs = Set([first.context.text, second.context.text])
    #expect(outputs == Set(["start-1", "start-2"]))

    #expect(first.polishError == nil)
    #expect(second.polishError == nil)
  }
}

@MainActor
private final class GateStep: TextProcessingStep {
  let name: String
  let isEnabled: Bool
  let maxDuration: Duration

  private let transform:
    @MainActor (TextProcessingContext, Int) async throws -> TextProcessingContext

  private(set) var runCount = 0
  private(set) var seenInputs: [TextProcessingContext] = []

  init(
    name: String,
    isEnabled: Bool = true,
    maxDuration: Duration = .seconds(5),
    transform: @escaping @MainActor (TextProcessingContext, Int) async throws ->
      TextProcessingContext
  ) {
    self.name = name
    self.isEnabled = isEnabled
    self.maxDuration = maxDuration
    self.transform = transform
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    runCount += 1
    let invocation = runCount
    seenInputs.append(context)
    return try await transform(context, invocation)
  }
}
