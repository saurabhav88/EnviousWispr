import AppKit
import EnviousWisprServices
import SwiftUI

/// Learn from... tab of the Dictionary page. Two ways the app can pick up words
/// without being told each one: learn from the user's own edits (#996, live
/// since chunk 5g; the "Coming soon" pill of Phase 7 #629 is gone) and Contacts
/// import (Phase 6 #636, live). Bible §10.2.
///
/// **Two features, two cards, and that is the fix.** The first build put both
/// inside one `BrandedSection` as `BrandedRow`s separated by a hairline, so a
/// title, a paragraph, a status line, a button, a second toggle and a second
/// paragraph ran together as one column of text with nothing saying where one
/// feature ended (founder, 2026-08-29: "just blends together with no clear UX
/// design"). The approved mockup draws each as its own recessed card
/// (`.learn-row`). "Keep in sync on launch" is not
/// a peer of those two features — it is a setting BELONGING to Contacts, so it
/// sits inside that card under a divider, which is what the mockup's
/// `.sync-row` is.
struct LearningSection: View {
  @Environment(ContactsImportCoordinator.self) private var contactsImport
  @Environment(SettingsManager.self) private var settings
  /// #996 §3.9: the row's enabled state and its reason line come from the
  /// step 7 arm selection, injected once; this view never reads availability.
  @Environment(\.learnFromEditsPresentation) private var learnFromEdits

  var body: some View {
    @Bindable var settings = settings

    // The page says what it is for. `BrandedPanel` puts that header INSIDE the
    // card, so the tab opens with a sentence rather than with a control.
    BrandedPanel(
      icon: "sparkle.magnifyingglass",
      header: "Learn from...",
      description: "Let EnviousWispr pick up new words on its own, from things you already have."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        editsCard(settings: $settings)
        contactsCard(settings: $settings)
      }
    }
    .sheet(isPresented: confirmSheetBinding) {
      if let preview = contactsImport.pendingPreview {
        ContactsImportConfirm(
          preview: preview,
          onConfirm: { contactsImport.confirmImport() },
          onCancel: { contactsImport.cancelImport() })
      }
    }
  }

  /// Learn from my edits (#996 §3.9). The toggle is the stored choice; the
  /// injected presentation says whether this Mac can act on it and, when it
  /// cannot, why, on one line under the paragraph. A disabled row keeps
  /// showing the stored value rather than snapping it off: the choice
  /// survives an OS without a qualified judge and applies again on one with.
  private func editsCard(settings: Bindable<SettingsManager>) -> some View {
    learnCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 8) {
          Text("Learn from my edits")
            .settingsRowLabel()
          Spacer(minLength: 8)
          Toggle("", isOn: settings.learnFromEdits)
            .toggleStyle(BrandedToggleStyle())
            .disabled(!learnFromEdits.isEnabled)
            .labelsHidden()
            // BrandedToggleStyle wraps label-Spacer-track in a content shape so
            // a labelled row is clickable end to end. With the label hidden its
            // Spacer claims the whole remaining row, which would make the empty
            // middle of this card toggle the switch. `fixedSize` collapses it.
            .fixedSize()
            .accessibilityLabel("Learn from my edits")
        }
        Text(LearnFromEditsSettingsPresentation.rowCopy)
          .settingsReadingCopy()
          .fixedSize(horizontal: false, vertical: true)
        if let reason = learnFromEdits.secondaryLine {
          Text(reason)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// Contacts import, plus the one setting that belongs to it.
  private func contactsCard(settings: Bindable<SettingsManager>) -> some View {
    learnCard {
      VStack(alignment: .leading, spacing: 10) {
        // ViewThatFits: at the app's 750pt minimum window this card is narrow
        // enough that the imported-count pill and button cannot share a line
        // with the title (cloud review, PR #2499).
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 10) {
            contactsRowLabel
            Spacer(minLength: 8)
            importControl
          }
          VStack(alignment: .leading, spacing: 10) {
            contactsRowLabel
            importControl
          }
        }

        contactsStatus

        Divider().overlay(Color.stDivider)

        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Keep in sync on launch").settingsRowLabel()
            Text("Check for new contacts each time EnviousWispr starts. Off by default.")
              .settingsReadingCopy()
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Toggle("", isOn: settings.contactsSyncOnLaunchEnabled)
            .toggleStyle(BrandedToggleStyle())
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Keep in sync on launch")
        }
      }
    }
  }

  /// The import's own feedback, in one place rather than four sibling `if`s in
  /// the middle of the card's layout.
  @ViewBuilder private var contactsStatus: some View {
    if case .imported(let count) = contactsImport.phase {
      Label(addedFeedback(count), systemImage: "checkmark.circle.fill")
        .font(.stHelper)
        .foregroundStyle(.stSuccess)
    }
    if let progress = contactsImport.enrichmentProgress {
      Label(
        "Finding spoken variants… \(progress.done) of \(progress.total)",
        systemImage: "sparkles"
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    if case .failed(let message) = contactsImport.phase {
      Text(message)
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
    }
    if contactsImport.phase == .denied {
      Text("Contacts access is off. Turn it on in System Settings, then try again.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The recessed card each feature sits in. `stPageBg` is the page surface,
  /// which reads as inset against the panel's `stSectionBg` in both themes —
  /// the same pairing the search field on the Your Words tab uses.
  private func learnCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.stPageBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.stDivider, lineWidth: 1)
          // A decoration is never in the hit path — these cards contain
          // toggles and a button.
          .allowsHitTesting(false)
      )
  }

  private var contactsRowLabel: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Import from Contacts")
        .settingsRowLabel()
      Text(
        "Add the names of people you know to your word list, so dictation spells them right."
      )
      .settingsReadingCopy()
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Right-side control: spinner while working, Open Settings if denied, the
  /// "N imported ✕" pill plus an Import/Re-scan button otherwise.
  @ViewBuilder private var importControl: some View {
    HStack(spacing: 8) {
      if contactsImport.importedCount > 0 {
        importedPill
      }
      actionButton
    }
  }

  @ViewBuilder private var actionButton: some View {
    switch contactsImport.phase {
    case .requesting, .importing:
      ProgressView()
        .controlSize(.small)
    case .denied:
      SettingsActionButton(title: "Open Settings", isEnabled: true, emphasis: .filled) {
        openContactsSettings()
      }
    default:
      SettingsActionButton(
        title: contactsImport.importedCount > 0 ? "Re-scan" : "Import", isEnabled: true
      ) {
        Task { await contactsImport.prepareImport() }
      }
    }
  }

  private var importedPill: some View {
    HStack(spacing: 4) {
      Text("\(contactsImport.importedCount) imported")
        .font(.stHelper)
      Button {
        contactsImport.bulkRemoveImported()
      } label: {
        Image(systemName: "xmark.circle.fill")
          // Bulk-removes every imported name, from a glyph inside a status
          // pill -- the least button-shaped thing on the page doing the most.
          .settingsHoverQuiet(tint: .stError)
      }
      .buttonStyle(.plain)
      .help("Remove all imported names")
      .accessibilityLabel("Remove all imported names")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(Color.secondary.opacity(0.15)))
  }

  private var confirmSheetBinding: Binding<Bool> {
    Binding(
      get: { contactsImport.pendingPreview != nil },
      set: { presented in
        if !presented { contactsImport.cancelImport() }
      })
  }

  private func addedFeedback(_ count: Int) -> String {
    count == 1 ? "Added 1 name" : "Added \(count) names"
  }

  private func openContactsSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
    {
      NSWorkspace.shared.open(url)
    }
  }
}
