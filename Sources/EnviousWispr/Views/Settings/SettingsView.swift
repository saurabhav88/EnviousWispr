import EnviousWisprCore
import SwiftUI

/// Unified single-window view: History + all settings tabs in one sidebar.
struct UnifiedWindowView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedSection: SettingsSection = .history

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedSection) {
        ForEach(SettingsGroup.allCases, id: \.self) { group in
          Section(group.rawValue) {
            ForEach(group.sections) { section in
              if section == .whatsNew {
                WhatsNewSidebarRow(isUnread: appState.settings.hasUnreadWhatsNew)
                  .tag(section)
              } else {
                Label(section.label, systemImage: section.icon)
                  .tag(section)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color.stSidebarBg)
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
    } detail: {
      detailContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accentColor(.stAccent)
    .navigationTitle("\(AppConstants.appName) v\(AppConstants.appVersion)")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        RecordButton()
      }
      ToolbarItem(placement: .status) {
        StatusBadge()
      }
    }
    .preferredColorScheme(.light)
    .onChange(of: appState.pendingNavigationSection) { _, newSection in
      if let section = newSection {
        selectedSection = section
        appState.pendingNavigationSection = nil
      }
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    switch selectedSection {
    case .history:
      HistoryContentView()
    case .whatsNew:
      WhatsNewSettingsView()
    case .speechEngine:
      SpeechEngineSettingsView()
    case .audio:
      AudioSettingsView()
    case .shortcuts:
      ShortcutsSettingsView()
    case .aiPolish:
      AIPolishSettingsView()
    case .wordCorrection:
      WordFixSettingsView()
    case .clipboard:
      ClipboardSettingsView()
    case .memory:
      MemorySettingsView()
    case .permissions:
      PermissionsSettingsView()
    case .diagnostics:
      DiagnosticsSettingsView()
    }
  }
}
