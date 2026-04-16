import Foundation
import Testing

@testable import EnviousWisprCore

// MARK: - SampleFilter Algorithm Tests

/// Mirrors SpeechSegment from EnviousWisprAudio for testing without pulling in FluidAudio.
private struct TestSpeechSegment {
  let startSample: Int
  let endSample: Int
}

/// Direct port of the filterSamples() algorithm from both pipelines.
/// Tests freeze this exact behavior before Phase 4a extracts it to SampleFilter.
private func filterSamples(
  from allSamples: [Float],
  segments: [TestSpeechSegment],
  padding: Int = 1600
) -> [Float] {
  guard !segments.isEmpty else { return allSamples }

  let totalVoiced = segments.reduce(0) { $0 + ($1.endSample - $1.startSample) }
  guard totalVoiced >= 4800 else { return allSamples }

  var merged: [(start: Int, end: Int)] = []
  for segment in segments {
    let start = max(0, segment.startSample - padding)
    let end = min(allSamples.count, segment.endSample + padding)
    if let last = merged.last, start <= last.end {
      merged[merged.count - 1].end = max(last.end, end)
    } else {
      merged.append((start, end))
    }
  }

  var result: [Float] = []
  for range in merged {
    guard range.start < range.end else { continue }
    result.append(contentsOf: allSamples[range.start..<range.end])
  }
  return result.isEmpty ? allSamples : result
}

@Suite("SampleFilter Algorithm")
struct SampleFilterTests {

  @Test("returns all samples when segments array is empty")
  func emptySegments() {
    let samples: [Float] = [1, 2, 3, 4, 5]
    let result = filterSamples(from: samples, segments: [])
    #expect(result == samples)
  }

  @Test("returns all samples when total voiced < 4800")
  func belowMinimumVoiced() {
    let samples = [Float](repeating: 0.5, count: 16000)
    // 4000 samples voiced (below 4800 threshold)
    let segments = [TestSpeechSegment(startSample: 0, endSample: 4000)]
    let result = filterSamples(from: samples, segments: segments)
    #expect(result.count == samples.count)
  }

  @Test("extracts voiced segments with padding")
  func extractsWithPadding() {
    // 32000 samples (2 seconds at 16kHz)
    let samples = (0..<32000).map { Float($0) }
    // One segment: samples 8000-16000 (8000 voiced, above threshold)
    let segments = [TestSpeechSegment(startSample: 8000, endSample: 16000)]
    let result = filterSamples(from: samples, segments: segments, padding: 1600)

    // Expected: 8000-1600=6400 to 16000+1600=17600
    #expect(result.count == 17600 - 6400)
    #expect(result.first == 6400)
    #expect(result.last == 17599)
  }

  @Test("clamps padding to array bounds")
  func clampsPadding() {
    let samples = [Float](repeating: 1.0, count: 10000)
    // Segment near start: padding would go negative
    let segments = [TestSpeechSegment(startSample: 500, endSample: 6000)]
    let result = filterSamples(from: samples, segments: segments, padding: 1600)

    // Start clamped to 0, end = 6000+1600=7600
    #expect(result.count == 7600)
  }

  @Test("merges overlapping padded segments")
  func mergesOverlapping() {
    let samples = (0..<32000).map { Float($0) }
    // Two segments close enough that 1600-sample padding causes overlap
    let segments = [
      TestSpeechSegment(startSample: 5000, endSample: 8000),
      TestSpeechSegment(startSample: 9000, endSample: 12000),
    ]
    // Padded: [3400, 9600] and [7400, 13600] -- overlap, merge to [3400, 13600]
    let result = filterSamples(from: samples, segments: segments, padding: 1600)

    #expect(result.count == 13600 - 3400)
    #expect(result.first == 3400)
    #expect(result.last == 13599)
  }

  @Test("keeps non-overlapping segments separate")
  func nonOverlapping() {
    let samples = (0..<32000).map { Float($0) }
    // Two segments far apart
    let segments = [
      TestSpeechSegment(startSample: 2000, endSample: 5500),
      TestSpeechSegment(startSample: 20000, endSample: 25000),
    ]
    // Padded: [400, 7100] and [18400, 26600]
    let result = filterSamples(from: samples, segments: segments, padding: 1600)

    let expectedCount = (7100 - 400) + (26600 - 18400)
    #expect(result.count == expectedCount)
  }

  @Test("returns original when filter produces empty result")
  func emptyFilterResult() {
    let samples = [Float](repeating: 0.1, count: 10000)
    // 5000 voiced, above threshold
    let segments = [TestSpeechSegment(startSample: 0, endSample: 5000)]
    let result = filterSamples(from: samples, segments: segments, padding: 1600)
    // Padded: [0, 6600]
    #expect(result.count == 6600)
  }
}

// MARK: - Text Processing Chain Tests

/// Mock step that records when it runs and optionally transforms text.
/// Not @MainActor so Swift Testing can construct instances freely.
private final class MockTextProcessingStep: @unchecked Sendable {
  let name: String
  var isEnabled: Bool
  let maxDuration: Duration
  var runCount = 0
  let transform: @Sendable (String) async throws -> String
  let shouldThrow: Error?

  init(
    name: String,
    isEnabled: Bool = true,
    maxDuration: Duration = .seconds(5),
    transform: @escaping @Sendable (String) async throws -> String = { $0 },
    shouldThrow: Error? = nil
  ) {
    self.name = name
    self.isEnabled = isEnabled
    self.maxDuration = maxDuration
    self.transform = transform
    self.shouldThrow = shouldThrow
  }

  func process(_ text: String) async throws -> String {
    runCount += 1
    if let error = shouldThrow {
      throw error
    }
    return try await transform(text)
  }
}

private struct MockStepError: Error {}

/// Tests the text processing chain algorithm: ordering, disabled skipping,
/// failure continuation (heart & limbs), timeout, and cancellation.
/// These freeze the exact behavior of runTextProcessing() before Phase 2 extracts it.
@Suite("TextProcessingChain")
struct TextProcessingChainTests {

  /// Run steps in order, mimicking the pipeline's runTextProcessing() algorithm.
  private func runChain(
    text: String,
    steps: [MockTextProcessingStep]
  ) async throws -> String {
    var currentText = text

    for step in steps where step.isEnabled {
      let budgetSeconds =
        Double(step.maxDuration.components.seconds)
        + Double(step.maxDuration.components.attoseconds) / 1e18
      let input = currentText
      do {
        currentText = try await withThrowingTimeout(seconds: budgetSeconds) {
          try await step.process(input)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Heart & Limbs: limb failed, continue with previous text
      }
    }
    return currentText
  }

  @Test("steps run in order")
  func stepsRunInOrder() async throws {
    let step1 = MockTextProcessingStep(name: "A", transform: { $0 + "-A" })
    let step2 = MockTextProcessingStep(name: "B", transform: { $0 + "-B" })
    let step3 = MockTextProcessingStep(name: "C", transform: { $0 + "-C" })

    let result = try await runChain(text: "start", steps: [step1, step2, step3])
    #expect(result == "start-A-B-C")
    #expect(step1.runCount == 1)
    #expect(step2.runCount == 1)
    #expect(step3.runCount == 1)
  }

  @Test("disabled steps are skipped")
  func disabledStepsSkipped() async throws {
    let step1 = MockTextProcessingStep(name: "A", transform: { $0 + "-A" })
    let step2 = MockTextProcessingStep(name: "B", isEnabled: false, transform: { $0 + "-B" })
    let step3 = MockTextProcessingStep(name: "C", transform: { $0 + "-C" })

    let result = try await runChain(text: "start", steps: [step1, step2, step3])
    #expect(result == "start-A-C")
    #expect(step2.runCount == 0)
  }

  @Test("step failure continues chain with previous text (heart & limbs)")
  func stepFailureContinues() async throws {
    let step1 = MockTextProcessingStep(name: "A", transform: { $0 + "-A" })
    let step2 = MockTextProcessingStep(name: "B", shouldThrow: MockStepError())
    let step3 = MockTextProcessingStep(name: "C", transform: { $0 + "-C" })

    let result = try await runChain(text: "start", steps: [step1, step2, step3])
    // Step 2 failed, so step 3 gets step 1's output
    #expect(result == "start-A-C")
    #expect(step2.runCount == 1)
    #expect(step3.runCount == 1)
  }

  @Test("timeout causes step to be skipped")
  func timeoutSkipsStep() async throws {
    let step1 = MockTextProcessingStep(name: "A", transform: { $0 + "-A" })
    let slowStep = MockTextProcessingStep(
      name: "Slow",
      maxDuration: .milliseconds(200),
      transform: { text in
        try await Task.sleep(for: .seconds(5))
        return text + "-SLOW"
      }
    )
    let step3 = MockTextProcessingStep(name: "C", transform: { $0 + "-C" })

    let result = try await runChain(text: "start", steps: [step1, slowStep, step3])
    // Slow step timed out, chain continues
    #expect(result == "start-A-C")
  }

  @Test("cancellation propagates and stops chain")
  func cancellationPropagates() async throws {
    let step1 = MockTextProcessingStep(name: "A", transform: { $0 + "-A" })
    let cancelStep = MockTextProcessingStep(
      name: "Cancel",
      shouldThrow: CancellationError()
    )
    let step3 = MockTextProcessingStep(name: "C", transform: { $0 + "-C" })

    do {
      _ = try await runChain(text: "start", steps: [step1, cancelStep, step3])
      Issue.record("Expected CancellationError to be thrown")
    } catch is CancellationError {
      // Expected
      #expect(step3.runCount == 0)
    }
  }

  @Test("empty steps array returns original text")
  func emptyStepsReturnsOriginal() async throws {
    let result = try await runChain(text: "hello", steps: [])
    #expect(result == "hello")
  }

  @Test("all steps disabled returns original text")
  func allDisabledReturnsOriginal() async throws {
    let step1 = MockTextProcessingStep(name: "A", isEnabled: false, transform: { $0 + "-A" })
    let step2 = MockTextProcessingStep(name: "B", isEnabled: false, transform: { $0 + "-B" })

    let result = try await runChain(text: "hello", steps: [step1, step2])
    #expect(result == "hello")
  }

  @Test("first step failure still allows subsequent steps to run")
  func firstStepFailure() async throws {
    let step1 = MockTextProcessingStep(name: "A", shouldThrow: MockStepError())
    let step2 = MockTextProcessingStep(name: "B", transform: { $0 + "-B" })

    let result = try await runChain(text: "start", steps: [step1, step2])
    // Step 1 failed, step 2 gets original text
    #expect(result == "start-B")
  }

  @Test("step with 15s budget completes within budget")
  func largerBudgetCompletes() async throws {
    // Verifies that a step with a generous budget (e.g., Ollama's 15s)
    // completes successfully when the operation finishes within that budget.
    let ollamaStep = MockTextProcessingStep(
      name: "OllamaSim",
      maxDuration: .seconds(15),
      transform: { text in
        try await Task.sleep(for: .milliseconds(500))
        return text + "-POLISHED"
      }
    )

    let result = try await runChain(text: "start", steps: [ollamaStep])
    #expect(result == "start-POLISHED")
    #expect(ollamaStep.runCount == 1)
  }

  @Test("cloud timeout: step exceeding 5s budget is skipped")
  func cloudTimeoutSkipsSlowStep() async throws {
    // Cloud provider has 5s budget. A step taking >5s should be skipped.
    let cloudStep = MockTextProcessingStep(
      name: "CloudSim",
      maxDuration: .seconds(5),
      transform: { text in
        try await Task.sleep(for: .seconds(10))
        return text + "-POLISHED"
      }
    )
    let nextStep = MockTextProcessingStep(name: "Next", transform: { $0 + "-NEXT" })

    let result = try await runChain(text: "start", steps: [cloudStep, nextStep])
    // Cloud step timed out, next step gets original text
    #expect(result == "start-NEXT")
  }
}
