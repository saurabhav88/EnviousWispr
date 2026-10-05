import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #2770: the ITN wall-clock budget scales with input length. A long dictation keeps its
/// number, date and address formatting instead of losing it at the old fixed 0.5 s.
@Suite("InverseTextNormalizationStep budget scales with length (#2770)", .tags(.productOutcome))
struct InverseTextNormalizationBudgetTests {

  @Test(
    "the budget is 0.5 s plus one second per 40,000 characters, capped at 5 s",
    arguments: [
      (0, 0.5), (300, 0.5075), (20_000, 1.0), (31_000, 1.275), (43_449, 1.586_225),
      (200_000, 5.0), (300_000, 5.0),
    ])
  func budgetByLength(count: Int, expected: Double) {
    let got = InverseTextNormalizationStep.deadlineSeconds(forCharacterCount: count)
    #expect(abs(got - expected) < 0.000_001, "\(count) chars -> \(got)")
  }

  @MainActor
  @Test("the runner backstop sits 1.5 s above the step's own budget for the same input")
  func backstopTracksTheBudget() {
    let step = InverseTextNormalizationStep()
    let long = TextProcessingContext(text: String(repeating: "x", count: 43_449), language: nil)
    #expect(step.maxDuration(for: long) == .seconds(1.586_225 + 1.5))  // ASCII: units == graphemes
    #expect(step.maxDuration == .seconds(2.0))
    let short = TextProcessingContext(text: "one two", language: nil)
    #expect(step.maxDuration(for: short) == .seconds(0.5 + 7.0 / 40_000 + 1.5))
  }

  /// Slow work that the OLD fixed 0.5 s deadline abandons and the length-scaled budget
  /// completes. 2.0 s sits 1.5 s above the floor and 3.0 s below the 200k-unit budget
  /// (the 5 s cap), so a contended runner cannot flip either verdict. The wait is a
  /// cooperative `Task.sleep`, not a blocked thread: the timeout branch cancels the
  /// operation task, so the short case releases its executor at the floor.
  private static let slowWorkSeconds: Double = 2.0

  private static func slowWork(_ text: String, _ spoken: Bool) async -> String {
    try? await Task.sleep(for: .seconds(slowWorkSeconds))  // test-fixture-timer: the deadline itself is under test
    return "CONVERTED:" + String(text.prefix(8))
  }

  @MainActor
  @Test("a 200k-unit take with 2 s of work completes under its 5 s budget and keeps the conversion")
  func longTakeCompletesUnderScaledBudget() async throws {
    var timeouts: [[String: Any]] = []
    let step = InverseTextNormalizationStep(
      work: Self.slowWork, onTimeoutForTesting: { timeouts.append($0) })
    let text = String(repeating: "one hundred twenty three ", count: 8_000)  // 200,000 units
    #expect(text.utf16.count == 200_000)
    let out = try await step.process(TextProcessingContext(text: text, language: "en"))
    #expect(out.text.hasPrefix("CONVERTED:"))
    #expect(step.lastRun?.ran == true)
    #expect(step.lastRun?.changed == true)
    #expect(timeouts.isEmpty)
  }

  @MainActor
  @Test("the same 2 s of work on a short take still hits the 0.5 s floor and returns the pre-ITN text with deadline_ms")
  func shortTakeStillTimesOutAtTheFloor() async throws {
    var timeouts: [[String: Any]] = []
    let step = InverseTextNormalizationStep(
      work: Self.slowWork, onTimeoutForTesting: { timeouts.append($0) })
    let text = "meet at three thirty"
    let out = try await step.process(TextProcessingContext(text: text, language: "en"))
    #expect(out.text == text)
    #expect(step.lastRun?.ran == true)
    #expect(step.lastRun?.changed == false)
    #expect(timeouts.count == 1)
    let extra = try #require(timeouts.first)
    let expectedDeadlineMs =
      InverseTextNormalizationStep.deadlineSeconds(forCharacterCount: text.utf16.count) * 1000
    #expect(abs((extra["deadline_ms"] as? Double ?? -1) - expectedDeadlineMs) < 0.001)
    #expect(extra["len_before"] as? Int == text.count)
  }

  @MainActor
  @Test("the budget counts UTF-16 units, so a grapheme-heavy input is never under-budgeted")
  func budgetCountsUTF16Units() {
    let step = InverseTextNormalizationStep()
    let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 20_000)
    #expect(family.count == 20_000)
    #expect(family.utf16.count == 220_000)
    let context = TextProcessingContext(text: family, language: "en")
    #expect(step.maxDuration(for: context) == .seconds(5.0 + 1.5))
  }
}
