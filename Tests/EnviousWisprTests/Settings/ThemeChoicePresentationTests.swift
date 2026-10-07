import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A: the Theme picker's choices have one owner that the Settings Map will reuse.
/// Expected values and English are typed from the picker as it shipped before #3482
/// (System, Light, Dark), not read from the code under test.
@Suite("Theme choice presentation (#3482)", .tags(.driftGuard))
struct ThemeChoicePresentationTests {
  @Test("choices are System, Light, Dark in that order and cover every theme")
  func orderAndCoverage() {
    let values = ThemeChoicePresentation.choices.map(\.value)
    #expect(values == [.system, .light, .dark])
    #expect(Set(values).count == values.count)
    #expect(Set(values) == Set(AppearancePreference.allCases))
  }

  @Test("each choice keeps its shipped English")
  func shippedEnglish() {
    let english = ThemeChoicePresentation.choices.map { Array(String(localized: $0.label).utf8) }
    #expect(english == [Array("System".utf8), Array("Light".utf8), Array("Dark".utf8)])
  }

  @Test("each choice keeps its catalog key")
  func catalogKeys() {
    let keys = ThemeChoicePresentation.choices.map(\.label.key)
    #expect(keys == ["System", "Light", "Dark"])
  }
}
