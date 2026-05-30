import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Audio input device selection and noise processing settings.
struct AudioSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(AudioDeviceList.self) private var audioDeviceList

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      BrandedSection(header: "Input Device") {
        BrandedRow {
          Picker("Input Device", selection: $settings.preferredInputDeviceIDOverride) {
            Text("Auto").tag("")
            ForEach(audioDeviceList.availableInputDevices) { device in
              Text(device.name).tag(device.uid)
            }
          }
        }
        BrandedRow(showDivider: false) {
          if settings.preferredInputDeviceIDOverride.isEmpty,
            let outputID = AudioDeviceEnumerator.defaultOutputDeviceID(),
            AudioDeviceEnumerator.isBluetoothDevice(outputID)
          {
            Text(
              "Built-in microphone selected automatically. Bluetooth headphones cannot record and play audio simultaneously — using the built-in mic avoids degrading your audio playback."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
          } else {
            Text(
              "Select which microphone to use for recording. \"Auto\" prefers the built-in mic when Bluetooth audio output is active."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
          }
        }
      } footer: {
        FrozenPerRecordingFootnote()
      }

      BrandedSection(header: "Microphone Readiness") {
        BrandedRow {
          Picker("Keep microphone ready", selection: $settings.warmEnginePolicy) {
            Text("Off").tag(WarmEnginePolicy.off)
            Text("10 seconds").tag(WarmEnginePolicy.seconds10)
            Text("30 seconds").tag(WarmEnginePolicy.seconds30)
            Text("60 seconds").tag(WarmEnginePolicy.seconds60)
            Text("Always").tag(WarmEnginePolicy.always)
          }
        }
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              "Keeps the microphone engine active after dictation so the next recording starts instantly and captures your first words."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
            if settings.warmEnginePolicy == .always {
              Text(
                "Always keeps the microphone engine active. The macOS microphone indicator may remain visible and power usage may increase."
              )
              .font(.stHelper)
              .foregroundStyle(.orange)
            }
          }
        }
      }
    }
  }
}
