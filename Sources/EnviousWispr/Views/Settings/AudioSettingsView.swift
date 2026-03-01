import SwiftUI

/// Audio input device selection and noise processing settings.
struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Input Device") {
                Picker("Input Device", selection: $state.settings.selectedInputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Text("Select which microphone to use for recording. Changes take effect on the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
