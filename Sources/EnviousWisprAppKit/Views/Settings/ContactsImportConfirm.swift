import SwiftUI

/// Confirmation surface shown before any contact name is written (#636).
/// Shows an honest count and the on-device disclaimer. The import only happens
/// when the user taps the primary action here.
struct ContactsImportConfirm: View {
  let preview: ContactsImportCoordinator.ImportPreview
  let onConfirm: () -> Void
  let onCancel: () -> Void

  private var hasNewNames: Bool { preview.newContactCount > 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Import from Contacts")
        .font(.title3)
        .bold()

      if hasNewNames {
        Text(addCountMessage)
          .font(.body)
        Text(
          "EnviousWispr never uploads your address book. These names are added to your "
            + "word list on this Mac so dictation spells them right."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      } else {
        Text("All your contacts are already in your word list.")
          .font(.body)
      }

      HStack {
        Spacer()
        // #2447 finishes the sheet-dismissal class #2445 opened. The founder's
        // finding there was not any single button but the PAIR: "you improved
        // the 'done' button on the install pop up but then didn't fix the cancel
        // button on the language selector." Both halves of each pair move
        // together here for that reason.
        if hasNewNames {
          SettingsActionButton(
            title: "Cancel", isEnabled: true, shortcut: .cancelAction, action: onCancel)
          SettingsActionButton(
            verbatimTitle: addButtonTitle, isEnabled: true, emphasis: .filled,
            shortcut: .defaultAction, action: onConfirm)
        } else {
          SettingsActionButton(
            title: "Done", isEnabled: true, emphasis: .filled,
            shortcut: .defaultAction, action: onCancel)
        }
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private var addCountMessage: String {
    Self.addCountMessage(
      newCount: preview.newContactCount, alreadyCount: preview.alreadyPresentCount)
  }

  private var addButtonTitle: String {
    Self.addButtonTitle(newCount: preview.newContactCount)
  }

  /// Whole sentences chosen by the two counts, never "name"/"names" or "is"/"are" spliced in
  /// (#3142). The second sentence appears only when some names are already in the list.
  static func addCountMessage(newCount: Int, alreadyCount: Int) -> String {
    switch (newCount == 1, alreadyCount) {
    case (true, 0):
      return String(
        localized: "We'll add 1 name from your contacts.",
        comment: "Your Words, import from Contacts: one new name.")
    case (false, 0):
      return String(
        localized: "We'll add \(newCount) names from your contacts.",
        comment: "Your Words, import from Contacts: %lld is the number of new names, never 1.")
    case (true, 1):
      return String(
        localized: "We'll add 1 name from your contacts. 1 is already in your list.",
        comment: "Your Words, import from Contacts: one new name, and one already in the word list."
      )
    case (true, _):
      return String(
        localized: "We'll add 1 name from your contacts. \(alreadyCount) are already in your list.",
        comment:
          "Your Words, import from Contacts: one new name. %lld is the number already in the word list, never 1."
      )
    case (false, 1):
      return String(
        localized: "We'll add \(newCount) names from your contacts. 1 is already in your list.",
        comment:
          "Your Words, import from Contacts: %lld is the number of new names, never 1; one is already in the word list."
      )
    case (false, _):
      return String(
        localized:
          "We'll add \(newCount) names from your contacts. \(alreadyCount) are already in your list.",
        comment:
          "Your Words, import from Contacts: the first %lld is the number of new names, the second the number already in the word list; neither is 1."
      )
    }
  }

  static func addButtonTitle(newCount: Int) -> String {
    newCount == 1
      ? String(
        localized: "Add 1 name", comment: "Your Words, import from Contacts: button for one name.")
      : String(
        localized: "Add \(newCount) names",
        comment: "Your Words, import from Contacts: button. %lld is the number of names, never 1.")
  }
}
