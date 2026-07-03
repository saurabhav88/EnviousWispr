import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Window appearance preference. Mirrors the menu-bar Appearance submenu — both
/// bind `settings.appearancePreference`, so they stay in sync.
struct AppearanceSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      BrandedSection(header: "Appearance") {
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 10) {
            BrandedSegmentedPicker(
              options: [
                (label: "System", value: AppearancePreference.system),
                (label: "Light", value: AppearancePreference.light),
                (label: "Dark", value: AppearancePreference.dark),
              ],
              selection: $settings.appearancePreference
            )
            Text("System follows your Mac and switches automatically. Light and Dark pin a look.")
              .settingsReadingCopy()
          }
        }
      }
    }
  }
}
