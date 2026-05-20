import EnviousWisprServices
import SwiftUI

/// Global hotkey configuration.
struct ShortcutsSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      BrandedSection(header: "Transcribe Shortcut") {
        BrandedRow {
          HotkeyRecorderView(
            keyCode: $settings.toggleKeyCode,
            modifiers: $settings.toggleModifiers,
            defaultKeyCode: ModifierKeyCodes.rightOption,
            defaultModifiers: [],
            label: "Shortcut"
          )
        }
        BrandedRow {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(
              settings.isPushToTalk ? "Push to Talk" : "Toggle",
              isOn: $settings.isPushToTalk
            )
            .toggleStyle(BrandedToggleStyle())
            Text(
              settings.isPushToTalk
                ? "Hold the hotkey to record, release to stop."
                : "Press the hotkey to start recording, press again to stop."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
            if settings.isPushToTalk {
              Text("Double-press to go hands-free. Triple-press to cancel.")
                .font(.stHelper)
                .foregroundStyle(.stTextTertiary.opacity(0.72))
            }
          }
        }
        BrandedRow {
          HotkeyRecorderView(
            keyCode: $settings.cancelKeyCode,
            modifiers: $settings.cancelModifiers,
            defaultKeyCode: 53,
            defaultModifiers: [],
            label: "Cancel recording"
          )
        }
        BrandedRow(showDivider: false) {
          Text("Press this to discard the current recording and return to idle.")
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
        }
      }
    }
  }
}
