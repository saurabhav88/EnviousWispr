import EnviousWisprCore
import Foundation

/// The Theme picker's choices, in the order the Appearance page shows them. The picker renders
/// this list, and the Settings Map (#3482) derives its Theme choices from it, so the two can
/// never disagree about which themes exist or what they are called.
enum ThemeChoicePresentation {
  struct Choice: Sendable {
    let value: AppearancePreference
    let label: LocalizedStringResource
  }

  static let choices: [Choice] = [
    Choice(value: .system, label: "System"),
    Choice(value: .light, label: "Light"),
    Choice(value: .dark, label: "Dark"),
  ]
}
