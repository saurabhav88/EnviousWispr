import SwiftUI

/// Audio input device selection and noise processing settings.
struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Input Device") {
                Picker("Input Device", selection: $state.settings.preferredInputDeviceIDOverride) {
                    Text("Auto").tag("")
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                // Show contextual note when Auto mode is active and Bluetooth output is detected
                if appState.settings.preferredInputDeviceIDOverride.isEmpty,
                   let outputID = AudioDeviceEnumerator.defaultOutputDeviceID(),
                   AudioDeviceEnumerator.isBluetoothDevice(outputID) {
                    Text("Built-in microphone selected automatically. Bluetooth headphones cannot record and play audio simultaneously — using the built-in mic avoids degrading your audio playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select which microphone to use for recording. \"Auto\" prefers the built-in mic when Bluetooth audio output is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Audio Processing") {
                Toggle("Noise suppression", isOn: $state.settings.noiseSuppression)
                Text("Reduces background noise during recording using Apple Voice Processing. May not work with all audio devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
