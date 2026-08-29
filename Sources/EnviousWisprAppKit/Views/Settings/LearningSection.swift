import AppKit
import EnviousWisprServices
import SwiftUI

/// Learn from... tab of the Dictionary page. Two rows: auto-learn (Phase 7
/// #629, still "Coming soon") and contacts import (Phase 6 #636, live).
/// Bible §10.2. #2492: no section header here — the left sub-menu's selected
/// tab already says "Learn from...".
struct LearningSection: View {
  @Environment(ContactsImportCoordinator.self) private var contactsImport
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    BrandedSection {
      // Row 1: Auto-learn from transcripts (Phase 7 #629)
      BrandedRow(showDivider: true) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Learn from my transcripts")
                .settingsRowLabel()
              Text(
                "EnviousWispr will watch for edits to text it just pasted, to suggest new words. Edits stay on this Mac."
              )
              .settingsReadingCopy()
            }
            Spacer()
            Toggle("", isOn: .constant(false))
              .toggleStyle(BrandedToggleStyle())
              .disabled(true)
              .labelsHidden()
          }
          Text("Coming soon")
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .padding(.top, 2)
        }
      }

      // Row 2: Import from Contacts (Phase 6 #636)
      BrandedRow(showDivider: false) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Import from Contacts")
                .settingsRowLabel()
              Text(
                "Add the names of people you know to your word list, so dictation spells them right."
              )
              .settingsReadingCopy()
            }
            Spacer()
            importControl
          }

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
          }
          if contactsImport.phase == .denied {
            Text("Contacts access is off. Turn it on in System Settings, then try again.")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          }

          Toggle(isOn: $settings.contactsSyncOnLaunchEnabled) {
            Text("Keep in sync on launch").settingsRowLabel()
          }
          .toggleStyle(BrandedToggleStyle())
          .padding(.top, 2)
          Text("Check for new contacts each time EnviousWispr starts. Off by default.")
            .settingsReadingCopy()
        }
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
