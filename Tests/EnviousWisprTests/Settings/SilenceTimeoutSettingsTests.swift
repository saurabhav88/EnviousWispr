import Testing

@testable import EnviousWisprAppKit

/// #3765 PR-C: the pause-duration slider's offered values, which the dev control door now
/// checks against too.
///
/// When this fails, the user sees a pause-duration slider with a different range or step.
@Suite(.tags(.productOutcome))
struct SilenceTimeoutSettingsTests {
  @Test("the slider offers 0.5 to 3.0 seconds in quarter-second steps")
  func sliderRangeAndStep() {
    #expect(SilenceTimeoutSlider.range == 0.5...3.0)
    #expect(SilenceTimeoutSlider.step == 0.25)
  }

  @Test("the values the slider can land on are exactly the eleven quarter-second stops")
  func offeredValues() {
    let stops = stride(from: 0.5, through: 3.0, by: 0.25).map { $0 }
    #expect(stops.count == 11)
    #expect(stops.allSatisfy(SilenceTimeoutSlider.offers))
    for value in [0.25, 0.49, 0.6, 1.1, 2.9, 3.01, 3.25, -1, .infinity, .nan] {
      #expect(SilenceTimeoutSlider.offers(value) == false, "\(value)")
    }
  }
}
