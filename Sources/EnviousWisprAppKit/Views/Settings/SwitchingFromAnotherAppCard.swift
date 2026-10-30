import EnviousWisprPostProcessing
import SwiftUI

/// The card at the top of Dictionary and Snippets that tells someone leaving another dictation
/// app that their words and snippets can come across (#3034). It opens the import's app picker
/// directly. It holds only names and a closure: it never asks the Mac which apps are installed,
/// because that check belongs to the picker, on screen, when the user has asked (see
/// `SmartImportRegistry` and `SnippetImportAppRegistry`).
struct SwitchingFromAnotherAppCard: View {
  let subtitle: String
  let action: () -> Void

  var body: some View {
    ImportMethodCard(
      icon: "arrow.left.arrow.right",
      title: SwitchingFromAnotherAppCopy.title,
      subtitle: subtitle,
      action: action
    )
    // A discovery card is hidden for nobody, but it carries no setting, and the import it opens
    // keeps its own map id (`yourWordsImport`, `snippetsImport`), which is the search target.
    .settingsMapRegistration(.exempt(.switchingHandoffCard))
  }
}

/// Whole localized sentences, one list argument, so a translator reorders freely.
enum SwitchingFromAnotherAppCopy {
  static var title: String {
    String(
      localized: "Switching from another dictation app?",
      comment: "Dictionary and Snippets: title of the card that opens import from another app.")
  }

  /// The Dictionary card line. `names` come from `SmartImportRegistry.displayNames`.
  static func wordsSubtitle(names: [String]) -> String {
    let list = SmartImportSupportedAppsCopy.sentence(joining: names)
    return String(
      localized: "switching.card.words.body",
      defaultValue: "Bring your words across from \(list).",
      comment: "Dictionary: line under the switching card title. %@ is a list of app names.")
  }

  /// The Snippets card line. `names` come from `SnippetImportAppRegistry.displayNames`.
  static func snippetsSubtitle(names: [String]) -> String {
    let list = SmartImportSupportedAppsCopy.sentence(joining: names)
    return String(
      localized: "switching.card.snippets.body",
      defaultValue: "Bring your snippets across from \(list).",
      comment: "Snippets: line under the switching card title. %@ is a list of app names.")
  }
}
