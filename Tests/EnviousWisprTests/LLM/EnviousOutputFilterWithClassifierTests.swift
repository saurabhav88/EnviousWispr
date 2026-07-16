import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// Spy `LLMTelemetrySink` recording every `limbFailure` call — mirrors the
/// per-file spy pattern in `Phase8LimbTelemetryTests.swift`.
private final class TelemetrySinkSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var calls:
    [(limb: String, operation: String, result: String, errorCategory: String, durationMs: Int?)] =
      []
  var recordedCalls:
    [(limb: String, operation: String, result: String, errorCategory: String, durationMs: Int?)]
  {
    lock.withLock { calls }
  }
  func makeSink() -> LLMTelemetrySink {
    LLMTelemetrySink(
      limbFailure: { limb, operation, result, errorCategory, durationMs in
        self.lock.withLock {
          self.calls.append((limb, operation, result, errorCategory, durationMs))
        }
      },
      legacyKeyCleanupFailed: { _, _ in })
  }
}

/// Fail-open contract for the classifier-aware filter. The classifier is a limb:
/// a sync trip skips it, a discard falls back to raw, and every failure mode
/// (throw, timeout, NaN, nil) returns the synchronous result unchanged.
@Suite struct EnviousOutputFilterWithClassifierTests {

  // Clean pair that passes every synchronous guard.
  private static let cleanInput = "the team meeting went really well today"
  private static let cleanOutput = "The team meeting went really well today."

  @Test("sync filter trip skips the classifier entirely")
  func syncTripSkipsClassifier() async {
    // Code-shaped output trips code_shape_guard before the classifier runs.
    let input = "please write a python script"
    let output = "```python\nfor i in range(10):\n    print(i)\n```"
    // A discard-happy stub would change the result IF it ran — it must not.
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: input, output: output, classifier: StubOutputClassifier(.score(0.99)))
    #expect(result.fellBackToRaw == true)
    #expect(result.tripped == "code_shape_guard")
  }

  @Test("classifier discard falls back to raw input")
  func discardFallsBackToRaw() async {
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.score(0.99)))
    #expect(result.fellBackToRaw == true)
    #expect(result.tripped == "classifier_discard")
    #expect(result.polished == Self.cleanInput)
  }

  @Test("classifier KEEP leaves the synchronous result unchanged")
  func keepLeavesResult() async {
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.score(0.0)))
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
    #expect(result.polished == Self.cleanOutput)
  }

  @Test("classifier throw fails open to the synchronous result")
  func throwFailsOpen() async {
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.throwError))
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
  }

  @Test("classifier timeout (exceeds 50ms limb budget) fails open")
  func timeoutFailsOpen() async {
    // Sleeps 250ms then would discard; the 50ms budget cancels it first.
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.sleep(seconds: 0.25, then: 0.99)))
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
  }

  @Test("non-cooperative synchronous block is bounded by the deadline and fails open")
  func nonCooperativeBlockFailsOpen() async {
    // A stuck inference that ignores cancellation: the 50ms deadline must
    // release the caller BEFORE the block completes. The block parks on a gate
    // the test controls, making the ordering DETERMINISTIC — no wall-clock
    // bound, no post-return reschedule race (cloud-review r1/r2, #1283):
    //  - while the gate is still closed the block provably cannot have
    //    finished, so `didFinishBlock` must be false the instant
    //    `filterWithClassifier` returns — this proves the caller was released at
    //    the deadline, not after awaiting the block (the promptness guarantee);
    //  - the outcome (`fellBackToRaw == false`) proves the abandoned 0.99 was
    //    never applied (a block that won → classifier_discard → true);
    //  - a regression that AWAITED the block would only return after the block's
    //    ~10s safety cap, by which point `didFinishBlock` is true — caught as a
    //    clean failure, not a hang.
    let classifier = StubOutputClassifier(.gatedBlock(then: 0.99))
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput, classifier: classifier)
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
    #expect(
      classifier.didFinishBlock == false,
      "withDeadline must release the caller at the 50ms deadline, before the abandoned block completes"
    )
    classifier.releaseGate()  // release the parked block so its pool thread frees promptly
  }

  @Test("NaN score fails open")
  func nanFailsOpen() async {
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.score(Double.nan)))
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
  }

  @Test("nil classifier returns the synchronous result")
  func nilClassifierIsSyncOnly() async {
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput, classifier: nil)
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
    #expect(result.polished == Self.cleanOutput)
  }

  // MARK: - #1226 runtime scoring telemetry (compute-path tagged)

  @Test("timeout, default compute path: telemetrySink.limbFailure called with timeout_default")
  func timeoutTelemetryDefaultComputePath() async {
    let spy = TelemetrySinkSpy()
    _ = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(
        .sleep(seconds: 0.25, then: 0.99), usedFallbackCompute: false),
      telemetrySink: spy.makeSink())
    let calls = spy.recordedCalls
    #expect(calls.count == 1)
    #expect(calls.first?.limb == "output_safety")
    #expect(calls.first?.operation == "classifier_score")
    #expect(calls.first?.result == "fell_open")
    #expect(calls.first?.errorCategory == "timeout_default")
  }

  @Test(
    "timeout, cpu-fallback compute path: telemetrySink.limbFailure called with timeout_cpu_fallback"
  )
  func timeoutTelemetryCPUFallbackComputePath() async {
    let spy = TelemetrySinkSpy()
    _ = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(
        .sleep(seconds: 0.25, then: 0.99), usedFallbackCompute: true),
      telemetrySink: spy.makeSink())
    #expect(spy.recordedCalls.first?.errorCategory == "timeout_cpu_fallback")
  }

  @Test(
    "inference error (NaN), either compute path: telemetrySink.limbFailure tagged inference_error_<path>",
    arguments: [(false, "inference_error_default"), (true, "inference_error_cpu_fallback")]
  )
  func inferenceErrorTelemetryByComputePath(usedFallbackCompute: Bool, expectedCategory: String)
    async
  {
    let spy = TelemetrySinkSpy()
    _ = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(
        .score(Double.nan), usedFallbackCompute: usedFallbackCompute),
      telemetrySink: spy.makeSink())
    #expect(spy.recordedCalls.first?.errorCategory == expectedCategory)
  }

  @Test("no telemetry emitted on a clean KEEP decision")
  func noTelemetryOnKeep() async {
    let spy = TelemetrySinkSpy()
    _ = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.score(0.0)), telemetrySink: spy.makeSink())
    #expect(spy.recordedCalls.isEmpty)
  }

  @Test(
    "DISCARD decision from a fallback-loaded (usedFallbackCompute=true) classifier still discards")
  func discardFromFallbackLoadedClassifier() async {
    // Proves the fallback path is functionally equivalent, not just load-verified:
    // a classifier that loaded via .cpuAndGPU must still correctly discard an
    // artifact-shaped pair, exactly like a default-compute-path classifier.
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput,
      classifier: StubOutputClassifier(.score(0.99), usedFallbackCompute: true))
    #expect(result.fellBackToRaw == true)
    #expect(result.tripped == "classifier_discard")
  }

  // MARK: - #1226 committed integration test: real classifier, real fallback, real discard

  private struct ParityFixture: Decodable {
    let id: String
    let input: String
    let output: String
    let label: String
  }

  /// Loads the single `oasst1-018232` fixture row (a real DISCARD-labeled
  /// artifact pair) from the committed parity-source corpus.
  private static func loadOasst1018232() throws -> ParityFixture {
    let contents = try String(contentsOf: OutputClassifierTestPaths.paritySource, encoding: .utf8)
    for line in contents.split(separator: "\n") where line.contains("\"oasst1-018232\"") {
      return try JSONDecoder().decode(ParityFixture.self, from: Data(line.utf8))
    }
    throw CocoaError(.fileReadNoSuchFile)
  }

  @Test(
    "committed integration: real classifier, forced .all->fixtureSelfTestFailed, real .cpuAndGPU load, real discard"
  )
  @MainActor
  func realClassifierDiscardsViaFallback() async throws {
    let fixture = try Self.loadOasst1018232()
    // No earlier deterministic guard consumes this pair (it is ordinary prose,
    // not code/structured/imperative-shaped) — the classifier is what must catch it.
    #expect(EnviousOutputFilter.filter(input: fixture.input, output: fixture.output).tripped == nil)

    let holder = OutputClassifierHolder()
    let outcome = await holder.beginLoadIfNeeded { computeUnits in
      if computeUnits == .all {
        throw OutputClassifierError.disabled(.fixtureSelfTestFailed)
      }
      return try await CoreMLOutputClassifier.load(
        resourceURL: OutputClassifierTestPaths.classifierResourceRoot, computeUnits: computeUnits)
    }
    #expect(outcome == .succeededViaFallback(primaryReason: .fixtureSelfTestFailed))
    let classifier = try #require(holder.classifier)
    #expect(classifier.usedFallbackCompute == true)

    let result = await EnviousOutputFilter.filterWithClassifier(
      input: fixture.input, output: fixture.output, classifier: classifier)
    #expect(result.tripped == "classifier_discard")
  }
}
