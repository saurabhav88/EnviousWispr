import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Unified single-window view: History + all settings tabs in one sidebar.
struct UnifiedWindowView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(UpdateCoordinatorHolder.self) private var updateCoordinatorHolder
  @State private var selectedSection: SettingsSection = .history

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: $selectedSection) {
          ForEach(SettingsGroup.allCases, id: \.self) { group in
            Section(group.rawValue) {
              ForEach(group.sections) { section in
                if section == .whatsNew {
                  WhatsNewSidebarRow(isUnread: settings.hasUnreadWhatsNew)
                    .tag(section)
                } else if section == .checkForUpdates {
                  // Issue #958: action row (D1), NOT a navigation tag — fires the
                  // attended check on tap and never becomes `selectedSection`.
                  // Sparkle's own UI is the feedback.
                  Button {
                    updateCoordinatorHolder.coordinator?.checkForUpdatesFromSettings()
                  } label: {
                    Label(section.label, systemImage: section.icon)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
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

        // Issue #343: in-app update banner. Fixed sibling of the sidebar List
        // (NOT a list-footer row, which would scroll). Bottom-leading mount
        // per Saurabh's mockup v2.
        if let coordinator = updateCoordinatorHolder.coordinator,
          coordinator.service.shouldShowBanner,
          case .available(let u) = coordinator.service.state
        {
          UpdateAvailableBanner(update: u)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .background(Color.stSidebarBg)
      .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 260)
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
    .onChange(of: navigationCoordinator.pendingSection) { _, newSection in
      if let section = newSection {
        selectedSection = section
        navigationCoordinator.consume()
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
      YourWordsView()
    case .clipboard:
      ClipboardSettingsView()
    case .memory:
      MemorySettingsView()
    case .permissions:
      PermissionsSettingsView()
    case .checkForUpdates:
      // Issue #958: D1 action row never selects this case (no `.tag`), but the
      // exhaustive switch requires an arm.
      EmptyView()
    #if DEBUG
      case .diagnostics:
        DiagnosticsSettingsView()
    #endif
    }
  }
}
