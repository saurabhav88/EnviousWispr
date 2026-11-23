import Foundation

/// The pause-duration ("stop on silence") slider's offered values: the one owner the
/// Speech Engine screen's slider and the dev control door's checked write both read
/// (#3765 PR-C). The range, the step and the two end labels live here (#4671); the screen
/// reads all four, so none can drift from the others.
enum SilenceTimeoutSlider {
  static let range: ClosedRange<Double> = 0.5...5.0
  static let step: Double = 0.25

  /// The slider's end labels, formatted from the range with the screen's one-decimal style.
  static var lowLabel: String { label(range.lowerBound) }
  static var highLabel: String { label(range.upperBound) }

  private static func label(_ seconds: Double) -> String {
    String(format: "%.1fs", locale: .current, seconds)
  }

  /// Whether `seconds` is a value the slider can land on: inside the range and on a step
  /// from its lower end. Off-step values are refused, never rounded.
  static func offers(_ seconds: Double) -> Bool {
    guard range.contains(seconds) else { return false }
    let steps = (seconds - range.lowerBound) / step
    return steps == steps.rounded()
  }
}
