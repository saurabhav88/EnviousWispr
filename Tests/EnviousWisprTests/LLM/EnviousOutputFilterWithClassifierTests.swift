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
}
