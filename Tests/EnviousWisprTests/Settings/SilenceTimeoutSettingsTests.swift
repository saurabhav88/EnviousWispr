import Testing

@testable import EnviousWisprAppKit

/// #3765 PR-C: the pause-duration slider's offered values, which the dev control door now
/// checks against too.
///
/// When this fails, the user sees a pause-duration slider with a different range or step.
@Suite(.tags(.productOutcome))
struct SilenceTimeoutSettingsTests {
  @Test("the slider offers 0.5 to 5.0 seconds in quarter-second steps")
  func sliderRangeAndStep() {
    #expect(SilenceTimeoutSlider.range == 0.5...5.0)
    #expect(SilenceTimeoutSlider.step == 0.25)
  }

  @Test("the values the slider can land on are exactly the nineteen quarter-second stops")
  func offeredValues() {
    let stops = stride(from: 0.5, through: 5.0, by: 0.25).map { $0 }
    #expect(stops.count == 19)
    #expect(stops.allSatisfy(SilenceTimeoutSlider.offers))
    for value in [0.25, 0.49, 0.6, 1.1, 2.9, 3.01, 4.99, 5.01, 5.25, -1, .infinity, .nan] {
      #expect(SilenceTimeoutSlider.offers(value) == false, "\(value)")
    }
  }
}
