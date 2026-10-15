import Foundation

/// The pause-duration ("stop on silence") slider's offered values: the one owner the
/// Speech Engine screen's slider and the dev control door's checked write both read
/// (#3765 PR-C). Labels and formatting stay with the screen.
enum SilenceTimeoutSlider {
  static let range: ClosedRange<Double> = 0.5...3.0
  static let step: Double = 0.25

  /// Whether `seconds` is a value the slider can land on: inside the range and on a step
  /// from its lower end. Off-step values are refused, never rounded.
  static func offers(_ seconds: Double) -> Bool {
    guard range.contains(seconds) else { return false }
    let steps = (seconds - range.lowerBound) / step
    return steps == steps.rounded()
  }
}
