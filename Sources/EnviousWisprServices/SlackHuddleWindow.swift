import Foundation

/// Slack 4.52.182's Leave button has this class in English, German and French (#4036).
/// Live AX evidence: docs/audits/2026-10-26-4036-slack-ax/. Labels and titles vary;
/// the generated class may change in another Slack version, so retain a narrow English fallback.
enum SlackHuddleWindow {
  static let leaveClass = "leaveButton__wzISw"

  enum Read: Equatable {
    case value(String)
    case missing
    case failed
  }

  enum Verdict: Equatable { case call, none, unknown }

  /// AXDOMClassList is a native array, never its printed description. Bad data is uncertainty.
  static func classRead(_ value: Any) -> Read {
    guard let classes = value as? [String] else { return .failed }
    return classes.contains(leaveClass) ? .value(leaveClass) : .missing
  }

  /// As with Zoom, a proven window wins; otherwise any failed read leaves the answer unknown.
  static func classify(
    windowCount: Int, identifier: (Int) -> Read, title: (Int) -> Read
  ) -> Verdict {
    var failed = false
    for index in 0..<windowCount {
      switch identifier(index) {
      case .value(let value) where value == leaveClass: return .call
      case .failed: failed = true
      case .value, .missing: break
      }
      switch title(index) {
      case .value(let value) where
        (value == "Huddle" || value.hasPrefix("Huddle ")) && !value.contains(" ("):
        return .call
      case .failed: failed = true
      case .value, .missing: break
      }
    }
    return failed ? .unknown : .none
  }
}
