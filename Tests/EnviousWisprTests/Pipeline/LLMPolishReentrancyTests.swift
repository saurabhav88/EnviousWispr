import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprPipeline

/// #827 PR-8 (text-processing concurrency isolation): regression for the
/// settings torn-read in `LLMPolishStep.process()`.
///
/// `LLMPolishStep` is `@MainActor` with mutable `llmProvider`/`llmModel`. The
/// method suspends at the polish `await`; on the saved-transcript re-polish
/// path `PipelineSettingsSync` can rewrite those properties on the SAME
/// instance during that suspension (user switches provider mid-re-polish).
/// Before the fix, the post-await reads (`ctx.llmProvider`, the family label,
/// the two telemetry helpers) observe the mutated value, mis-attributing the
/// result. After the fix, `process()` snapshots provider/model at entry and
/// uses the snapshot everywhere, so the recorded provider is the one that
/// actually polished.
///
/// Determinism: the mock polisher signals entry via an `AsyncStream` (the same
/// pattern as `TextProcessingChainRacesTests`) and suspends on an actor gate
/// the test releases AFTER mutating, so the mutation is guaranteed to land
/// while `process()` is parked at the polish await. No `Task.sleep`, no
/// real-clock dependency (`tests-no-real-time-scheduling-precision`); the test
/// observes entry through a synchronous stream value, not a raw continuation
/// (`tests-no-unconditional-continuation-await`).
@MainActor
@Suite("LLMPolishStep reentrancy")
struct LLMPolishReentrancyTests {

  /// Release gate the mock awaits; the test releases it after mutating.
  private actor ReleaseGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func release() {
      released = true
      waiter?.resume()
      waiter = nil
    }
    func wait() async {
      if released { return }
      await withCheckedContinuation { waiter = $0 }
    }
  }

  /// Controllable polisher. Nonisolated + Sendable so `await polisher.polish`
  /// genuinely suspends the MainActor (the reentrancy window). Implements only
  /// the legacy `text:` method; the planner path reaches it via the protocol's
  /// default `envelope:` bridge.
  private struct GatePolisher: TranscriptPolisher {
    let onStart: @Sendable () -> Void
    let gate: ReleaseGate
    let result: String

    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      onStart()
      await gate.wait()
      return LLMResult(polishedText: result)
    }
  }

  /// A sentence long enough to clear the short-transcript short-circuit and
  /// pass the polish validator (similar length in / out).
  private static let inputSentence =
    "so i was thinking we could maybe ship the new thing some time next week or so"
  private static let polishedSentence =
    "So I was thinking we could maybe ship the new thing some time next week."

  /// Runs `process()` with the polisher parked, mutates provider/model
  /// mid-await, then completes. Returns the finalized context.
  private func runTornReadScenario(
    initialProvider: LLMProvider,
    initialModel: String,
    mutateTo mutatedProvider: LLMProvider,
    mutatedModel: String
  ) async throws -> TextProcessingContext {
    let step = LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    step.llmProvider = initialProvider
    step.llmModel = initialModel

    let started = AsyncStream.makeStream(of: Void.self)
    let cont = started.continuation
    let gate = ReleaseGate()
    step.makePolisher = { _, _, _, _ in
      GatePolisher(
        onStart: {
          cont.yield(())
          cont.finish()
        },
        gate: gate,
        result: Self.polishedSentence
      )
    }

    let context = TextProcessingContext(text: Self.inputSentence, language: "en")
    let task = Task { @MainActor in try await step.process(context) }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // polisher entered; process() parked at the await, MainActor free

    step.llmProvider = mutatedProvider  // reentrant mutation during the polish suspension
    step.llmModel = mutatedModel
    await gate.release()

    return try await task.value
  }

  @Test("planner path: a provider switch mid-polish does not tear the recorded provider/model")
  func plannerPathTornRead() async throws {
    let ctx = try await runTornReadScenario(
      initialProvider: .openAI,
      initialModel: "gpt-4o-mini",
      mutateTo: .gemini,
      mutatedModel: "gemini-2.0-flash"
    )
    // RED before the snapshot fix (records the mutated .gemini); GREEN after.
    #expect(ctx.llmProvider == LLMProvider.openAI.rawValue)
    #expect(ctx.llmModel == "gpt-4o-mini")
  }

  @Test("AFM path: a provider switch mid-polish does not tear the recorded provider/model")
  func afmPathTornRead() async throws {
    let ctx = try await runTornReadScenario(
      initialProvider: .appleIntelligence,
      initialModel: "apple-intelligence",
      mutateTo: .gemini,
      mutatedModel: "gemini-2.0-flash"
    )
    #expect(ctx.llmProvider == LLMProvider.appleIntelligence.rawValue)
    #expect(ctx.llmModel == "apple-intelligence")
  }

  @Test("control: with no mid-polish mutation, the actual provider/model is recorded")
  func noMutationControl() async throws {
    let step = LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"

    let gate = ReleaseGate()
    await gate.release()  // no mutation: let polish run straight through
    step.makePolisher = { _, _, _, _ in
      GatePolisher(onStart: {}, gate: gate, result: Self.polishedSentence)
    }

    let context = TextProcessingContext(text: Self.inputSentence, language: "en")
    let ctx = try await step.process(context)

    #expect(ctx.llmProvider == LLMProvider.openAI.rawValue)
    #expect(ctx.llmModel == "gpt-4o-mini")
  }

  /// #4353 D6: what the step's polisher received for one process() call.
  @MainActor private final class ListSeen {
    var factoryLists: [String?] = []
    /// Written by the polisher off the main actor, before the polish returns.
    let thinking = OSAllocatedUnfairLock<[ResolvedThinking?]>(initialState: [])
  }

  private struct ConfigRecordingPolisher: TranscriptPolisher {
    let record: @Sendable (LLMProviderConfig) -> Void
    let onStart: @Sendable () -> Void
    let gate: ReleaseGate
    let result: String
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      record(config)
      onStart()
      await gate.wait()
      return LLMResult(polishedText: result)
    }
  }

  private static func geminiList(_ thinking: String) throws -> CloudModelList {
    try CloudModelList.validated(
      from: Data(
        #"{"schema":1,"updated":"2026-11-04","models":[{"provider":"gemini","id":"gemini-x","recommended":false,"hidden":false,"request":{"geminiThinking":\#(thinking)},"supportsChatCompletions":false,"allowsFileBatch":true}]}"#
          .utf8)
    ).get()
  }

  @Test("a list refresh during a polish never reaches that request; the next one uses it")
  func heldOperationKeepsItsCloudModelList() async throws {
    let held = try Self.geminiList(#"{"level":"low"}"#)
    let refreshed = try Self.geminiList(#"{"budget":0}"#)
    let step = LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    step.llmProvider = .gemini
    step.llmModel = "gemini-x"
    step.cloudModelList = held

    let seen = ListSeen()
    let started = AsyncStream.makeStream(of: Void.self)
    let gate = ReleaseGate()
    step.makePolisher = { _, _, _, list in
      seen.factoryLists.append(list?.revision)
      return ConfigRecordingPolisher(
        record: { [thinking = seen.thinking] config in
          thinking.withLock { $0.append(config.thinking) }
        },
        onStart: { started.continuation.yield(()) }, gate: gate,
        result: Self.polishedSentence)
    }

    let context = TextProcessingContext(text: Self.inputSentence, language: "en")
    let task = Task { @MainActor in try await step.process(context) }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    step.cloudModelList = refreshed  // the holder refreshed while the request is in flight
    await gate.release()
    _ = try await task.value
    _ = try await step.process(context)

    #expect(seen.factoryLists == [held.revision, refreshed.revision])
    #expect(seen.thinking.withLock { $0 } == [.level("low"), .budget(0)])
  }

  @Test("nil polisher factory throws providerUnavailable (so the runner keeps raw text)")
  func nilFactoryThrowsProviderUnavailable() async throws {
    let step = LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.makePolisher = { _, _, _, _ in nil }

    let context = TextProcessingContext(text: Self.inputSentence, language: "en")
    do {
      _ = try await step.process(context)
      Issue.record("expected LLMError.providerUnavailable, got success")
    } catch let error as LLMError {
      #expect(error == .providerUnavailable)
    } catch {
      Issue.record("expected LLMError.providerUnavailable, got \(error)")
    }
  }
}
