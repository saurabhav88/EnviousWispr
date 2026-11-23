import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4565 guided tour card copy: when these fail, a card tells the user to use a control by a
/// name the screen does not show (so in German it would quote an English label), or a stop has
/// no sentence.
@Suite("Guided tour card copy", .tags(.productOutcome))
struct GuidedTourCardTests {
  /// The control each sentence names, resolved from the resource the page itself uses.
  private static let namedControls: [GuidedTourStop: LocalizedStringResource] = [
    .keybinds: KeybindsSettingsCopy.recordTitle,
    .aiPolish: SettingsItemCopy.AIPolish.enable,
    .dictionary: SettingsItemCopy.Dictionary.addWord,
    .snippets: SettingsItemCopy.Snippets.add,
    .recordings: RecordingsSettingsCopy.saveTitle,
  ]

  @Test("a sentence that names a control quotes it exactly as its page labels it")
  func namedControlsComeFromThePagesOwnLabel() {
    for (stop, label) in Self.namedControls {
      let name = String(localized: label)
      let sentence = String(localized: GuidedTourCard.sentence(for: stop))
      #expect(!name.isEmpty)
      #expect(sentence.contains(name), "\(stop): \(sentence) should contain \(name)")
    }
  }

  @Test("every stop has a sentence and a page title")
  func everyStopHasWords() {
    for stop in GuidedTourStop.allCases {
      #expect(!String(localized: GuidedTourCard.sentence(for: stop)).isEmpty, "\(stop)")
      #expect(!String(localized: stop.pageTitle).isEmpty, "\(stop)")
    }
  }
}
