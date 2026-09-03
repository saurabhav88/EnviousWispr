import EnviousWisprCore
import SwiftUI

/// Add or edit one snippet (#628), to the approved design's sheet.
///
/// The live preview is the reason this sheet is worth its size. The keyword rule is easy to
/// state and easy to misread, and a user typing a trigger cannot otherwise tell what they will
/// have to say. Showing "You say" and "You get" as they type answers that without a manual.
struct SnippetEditSheet: View {
  @Environment(SnippetsCoordinator.self) private var coordinator
  @Environment(\.dismiss) private var dismiss

  let draft: SnippetDraft
  /// Passed in rather than read from the coordinator inside `body`: the preview must show the
  /// keyword as it was when the sheet opened, so it cannot change under the user mid-edit.
  let keyword: String

  @State private var trigger = ""
  @State private var expansion = ""
  @State private var error: String?
  @State private var didLoad = false

  private var isEditing: Bool { draft.snippet != nil }

  private var canSave: Bool {
    !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isEditing ? "Edit snippet" : "New snippet")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.stTextPrimary)

      triggerField
      expansionField
      preview

      Spacer(minLength: 0)
      footer
    }
    .padding(20)
    .frame(width: 480, height: 600)
    .background(Color.stPageBg)
    .onAppear(perform: load)
  }

  private func load() {
    guard !didLoad else { return }
    didLoad = true
    trigger = draft.snippet?.trigger ?? ""
    expansion = draft.snippet?.expansion ?? ""
  }

  // MARK: - Fields

  private var triggerField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Snippet").settingsRowLabel()
      HStack(spacing: 8) {
        // The keyword is shown, not editable here: it belongs to every snippet, so editing it
        // in one snippet's sheet would silently change all of them.
        Text(keyword)
          .font(.stRowLabel)
          .foregroundStyle(.stAccent)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.stAccentLight, in: Capsule())
          .overlay(Capsule().strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1))
        TextField("my email address", text: $trigger)
          .textFieldStyle(.roundedBorder)
      }
      Text("Matched word for word, and only after you say \u{201C}\(keyword)\u{201D}.")
        .settingsHelperCopy()
    }
  }

  private var expansionField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Expands to").settingsRowLabel()
      TextEditor(text: $expansion)
        .font(.stBody)
        .frame(height: 110)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1))
      Text("Pasted exactly as written. AI Polish never rewrites it.").settingsHelperCopy()
    }
  }

  // MARK: - Preview

  private var preview: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("PREVIEW")
        .font(.stSectionHeader)
        .tracking(0.6)
        .foregroundStyle(.stAccent)

      VStack(alignment: .leading, spacing: 3) {
        Text("You say").settingsHelperCopy()
        Text("\(keyword) \(trigger)")
          .font(.stRowLabel)
          .foregroundStyle(.stAccent)
      }
      Divider().overlay(Color.stDivider)
      VStack(alignment: .leading, spacing: 3) {
        Text("You get").settingsHelperCopy()
        Text(expansion.isEmpty ? " " : expansion)
          .font(.stRowLabel)
          .foregroundStyle(.stSuccess)
          // The expansion's line breaks are its point, so the preview must show them rather
          // than collapsing them into one line the way the list row deliberately does.
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.stDivider, lineWidth: 1))
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error {
        Text(error)
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        if let existing = draft.snippet {
          SettingsActionButton(title: "Delete", isEnabled: true, emphasis: .destructive) {
            if coordinator.delete(existing) { dismiss() } else { error = coordinator.errorMessage }
          }
        }
        Spacer(minLength: 0)
        SettingsActionButton(
          title: "Cancel", isEnabled: true, emphasis: .outlined, shortcut: .cancelAction
        ) { dismiss() }
        SettingsActionButton(title: "Save", isEnabled: canSave, emphasis: .filled) { save() }
      }
    }
  }

  private func save() {
    let snippet = Snippet(
      id: draft.snippet?.id ?? UUID(),
      trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
      // The expansion is NOT trimmed. Leading or trailing whitespace can be deliberate — a
      // snippet that starts with a newline, or ends with a space before the next word — and
      // "exactly as written" has to mean exactly.
      expansion: expansion,
      createdAt: draft.snippet?.createdAt ?? Date())

    if coordinator.save(snippet) {
      dismiss()
    } else {
      // Held locally as well as on the coordinator: the sheet stays open on a refusal, and the
      // message has to be visible where the user is looking rather than behind it.
      error = coordinator.errorMessage
    }
  }
}
