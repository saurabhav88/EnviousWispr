import Foundation
import Testing

@testable import EnviousWisprLLM

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
    // A stuck synchronous inference (500ms thread block, ignores cancellation):
    // the 50ms deadline must return the sync result BEFORE the block ends —
    // proving withDeadline does not await the abandoned operation. The outcome
    // (fellBackToRaw == false) already proves the timed-out 0.99 discard was
    // never applied; `didFinishBlock == false` additionally proves the CALLER
    // was released before the 500ms block finished. This relative ordering is
    // robust at any runner speed — no wall-clock bound to flake on a slow CI
    // runner (#1283, replaces the prior `elapsed < 400ms` measurement).
    let classifier = StubOutputClassifier(.blockSync(seconds: 0.5, then: 0.99))
    let result = await EnviousOutputFilter.filterWithClassifier(
      input: Self.cleanInput, output: Self.cleanOutput, classifier: classifier)
    #expect(result.fellBackToRaw == false)
    #expect(result.tripped == nil)
    #expect(
      classifier.didFinishBlock == false,
      "deadline did not bound the caller: the 500ms block finished before filterWithClassifier returned"
    )
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
}
