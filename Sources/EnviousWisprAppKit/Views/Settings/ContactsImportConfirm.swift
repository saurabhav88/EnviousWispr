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
        if hasNewNames {
          Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
          Button(addButtonTitle, action: onConfirm)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        } else {
          Button("Done", action: onCancel)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private var addCountMessage: String {
    let names = Self.pluralizedNames(preview.newContactCount)
    if preview.alreadyPresentCount > 0 {
      let already = preview.alreadyPresentCount
      let verb = already == 1 ? "is" : "are"
      return "We'll add \(names) from your contacts. \(already) \(verb) already in your list."
    }
    return "We'll add \(names) from your contacts."
  }

  private var addButtonTitle: String {
    "Add \(Self.pluralizedNames(preview.newContactCount))"
  }

  private static func pluralizedNames(_ count: Int) -> String {
    count == 1 ? "1 name" : "\(count) names"
  }
}
