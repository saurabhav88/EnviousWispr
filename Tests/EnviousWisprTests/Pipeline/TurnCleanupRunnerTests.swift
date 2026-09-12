import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #2810 addendum §3 D: the background turn-safe cleanup pass. What fails when these fail is
/// a stored turn showing the wrong text, silently dropping a part's cleaned output, or
/// running a part after the caller was told to stop.
@MainActor
@Suite("TurnCleanupRunner", .tags(.productOutcome))
struct TurnCleanupRunnerTests {

  private func turn(_ id: String, _ speaker: String, _ range: Range<Int>) -> Turn {
    Turn(id: id, speakerId: speaker, startMs: 0, endMs: 100, originalTextRange: range)
  }

  @Test("a single-part turn's processedText is the part's displayText, wasPolished true")
  func singlePartTurnJoinsCleanly() async {
    let runner = TurnCleanupRunner(
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: "CLEANED: \(part)", polishError: nil)
      })
    let turns = [turn("0-5", "A", 0..<5)]
    let (result, fallbackCount) = await runner.run(turns: turns, rawText: "hello", engineLanguage: nil)
    #expect(result.count == 1)
    #expect(fallbackCount == 0)
    #expect(result[0].processedText == "CLEANED: hello")
    #expect(result[0].wasPolished == true)
  }

  @Test("a turn split into multiple parts joins them in order with a blank-line separator")
  func multiPartTurnJoinsInOrder() async {
    let runner = TurnCleanupRunner(
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: "[\(part)]", polishError: nil)
      },
      split: { text in text.split(separator: " ").map(String.init) })
    let turns = [turn("0-11", "A", 0..<11)]
    let (result, fallbackCount) = await runner.run(turns: turns, rawText: "hello world", engineLanguage: nil)
    #expect(result[0].processedText == "[hello]\n\n[world]")
    #expect(result[0].wasPolished == true)
    #expect(fallbackCount == 0)
  }

  @Test(
    "mixed success: one part polished, one fell back — joins both, wasPolished true, counts as fallback"
  )
  func mixedSuccessJoin() async {
    let runner = TurnCleanupRunner(
      processPart: { part, _ in
        if part == "good" {
          return FileImportRunner.PartOutcome(text: part, polishedText: "GOOD", polishError: nil)
        }
        // The deterministic floor: no polishedText, matching a real polish failure.
        return FileImportRunner.PartOutcome(text: part, polishedText: nil, polishError: "boom")
      },
      split: { text in text.split(separator: " ").map(String.init) })
    let turns = [turn("0-8", "A", 0..<8)]
    let (result, fallbackCount) = await runner.run(turns: turns, rawText: "good bad", engineLanguage: nil)
    #expect(result[0].processedText == "GOOD\n\nbad")
    #expect(result[0].wasPolished == true, "any part polishing makes the whole turn wasPolished")
    #expect(fallbackCount == 1, "a turn with any fallback part counts, even if it also has a polished part")
  }

  @Test("every part failing to polish leaves wasPolished false")
  func everyPartFailingLeavesUnpolished() async {
    let runner = TurnCleanupRunner(
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: nil, polishError: "boom")
      })
    let turns = [turn("0-5", "A", 0..<5)]
    let (result, fallbackCount) = await runner.run(turns: turns, rawText: "hello", engineLanguage: nil)
    #expect(result[0].processedText == "hello")
    #expect(result[0].wasPolished == false)
    #expect(fallbackCount == 1)
  }

  @Test("multiple turns are processed in order, each independently")
  func multipleTurnsProcessedInOrder() async {
    let runner = TurnCleanupRunner(
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: part.uppercased(), polishError: nil)
      })
    let turns = [turn("0-5", "A", 0..<5), turn("6-11", "B", 6..<11)]
    let (result, _) = await runner.run(turns: turns, rawText: "hello world", engineLanguage: nil)
    #expect(result.map(\.processedText) == ["HELLO", "WORLD"])
    #expect(result.map(\.id) == ["0-5", "6-11"])
  }

  @Test("cancellation between turns leaves the remaining turns untouched, never mid-part")
  func cancellationBetweenTurnsNeverMidPart() async {
    // A gate that deterministically holds the first part's call open until the test has
    // cancelled the task, ruling out any race between "turn 1 finished" and "turn 2 started."
    actor Gate {
      private(set) var calls: [String] = []
      private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
      private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
      private var isReleased = false

      func recordAndWaitForRelease(_ part: String) async {
        calls.append(part)
        for waiter in arrivalWaiters { waiter.resume() }
        arrivalWaiters = []
        if isReleased { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
      }

      func waitForFirstArrival() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
      }

      func release() {
        isReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
      }
    }
    let gate = Gate()
    let runner = TurnCleanupRunner(
      processPart: { part, _ in
        await gate.recordAndWaitForRelease(part)
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    let task = Task { @MainActor in
      await runner.run(
        turns: [turn("0-5", "A", 0..<5), turn("6-11", "B", 6..<11)], rawText: "hello world",
        engineLanguage: nil)
    }
    // The first part is confirmed in flight and BLOCKED before turn 2 can possibly start.
    await gate.waitForFirstArrival()
    task.cancel()
    // Only now let the first part's call return — `run()`'s cancellation check happens at
    // the TOP of the next loop iteration, after this call completes, so cancelling first
    // guarantees turn 2 is never reached.
    await gate.release()
    let (result, _) = await task.value

    let calls = await gate.calls
    #expect(calls == ["hello"], "only the first turn's part should have run before cancellation")
    #expect(result.count == 2, "the result still contains every turn, even uncleaned ones")
    #expect(result[0].processedText == "hello", "the turn already processed keeps its result")
    #expect(
      result[1].processedText == nil, "the turn never reached stays unprocessed, not half-written")
  }

  @Test(
    "a range mismatch against the supplied rawText leaves the turn untouched rather than crashing")
  func rangeMismatchLeavesTurnUntouched() async {
    let runner = TurnCleanupRunner(processPart: { part, _ in
      FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
    })
    // originalTextRange far beyond the supplied rawText's own length.
    let turns = [turn("100-200", "A", 100..<200)]
    let (result, fallbackCount) = await runner.run(turns: turns, rawText: "short", engineLanguage: nil)
    #expect(result == turns, "an out-of-bounds range must not crash or fabricate text")
    #expect(fallbackCount == 0)
  }
}
