import SwiftUI
import EnviousWisprCore
import EnviousWisprAudio

/// Audio input device selection and noise processing settings.
struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            BrandedSection(header: "Input Device") {
                BrandedRow {
                    Picker("Input Device", selection: $state.settings.preferredInputDeviceIDOverride) {
                        Text("Auto").tag("")
                        ForEach(appState.availableInputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                BrandedRow(showDivider: false) {
                    if appState.settings.preferredInputDeviceIDOverride.isEmpty,
                       let outputID = AudioDeviceEnumerator.defaultOutputDeviceID(),
                       AudioDeviceEnumerator.isBluetoothDevice(outputID) {
                        Text("Built-in microphone selected automatically. Bluetooth headphones cannot record and play audio simultaneously — using the built-in mic avoids degrading your audio playback.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    } else {
                        Text("Select which microphone to use for recording. \"Auto\" prefers the built-in mic when Bluetooth audio output is active.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
            }

            BrandedSection(header: "Audio Processing") {
                BrandedRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Noise suppression", isOn: $state.settings.noiseSuppression)
                            .toggleStyle(BrandedToggleStyle())
                        Text("Reduces background noise during recording using Apple Voice Processing. May not work with all audio devices.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
            }
        }
    }
}
