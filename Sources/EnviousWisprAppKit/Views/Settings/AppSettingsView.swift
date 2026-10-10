import SwiftUI

/// Only the selected tab is mounted. Each page owns its one content scroll container.
struct AppSettingsView: View {
  @Binding var selection: AppSettingsTab

  var body: some View {
    GeometryReader { pane in
      VStack(spacing: 0) {
        SettingsTabStrip(
          items: AppSettingsTab.allCases.map {
            SettingsTabItem(id: $0, icon: $0.icon, label: $0.label, map: $0.mapID)
          }, selection: $selection
        )
        .frame(width: max(0, pane.size.width - 2 * (SettingsLayout.contentH - 4)))
        .padding(.horizontal, SettingsLayout.contentH - 4)
        .padding(.top, SettingsLayout.contentTop - 6)
        tabContent.frame(width: pane.size.width)
          // #3545: the tab drawn here, carried by every control inside it.
          .environment(
            \.settingsArrivalContent,
            SettingsArrivalContent(page: .appSettings, appSettingsTab: selection))
      }
      .frame(width: pane.size.width, height: pane.size.height)
    }
    .background(Color.stPageBg)
    .environment(\.settingsPR1Density, true)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selection {
    case .appearance: AppearanceSettingsView()
    case .permissions: PermissionsSettingsView()
    case .privacy: PrivacySettingsView()
    case .licenses: OpenSourceLicensesView()
    }
  }
}
