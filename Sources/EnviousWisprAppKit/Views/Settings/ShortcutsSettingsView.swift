import EnviousWisprCore
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
            // #917: both modes visible side by side. The old single Toggle
            // labeled itself with the ACTIVE mode, so switching it "off" to
            // leave toggle mode kept you in toggle mode — observed live as
            // "the switch is broken."
            BrandedSegmentedPicker(
              options: [
                ("Push to Talk", RecordingMode.pushToTalk),
                ("Toggle", RecordingMode.toggle),
              ],
              selection: $settings.recordingMode
            )
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
