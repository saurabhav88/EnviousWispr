import SwiftUI

/// Microphone permission status.
struct PermissionsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Microphone") {
                HStack {
                    Image(systemName: appState.permissions.hasMicrophonePermission
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(appState.permissions.hasMicrophonePermission ? .green : .red)
                    Text(appState.permissions.hasMicrophonePermission
                         ? "Microphone access granted"
                         : "Microphone access denied")

                    Spacer()

                    if !appState.permissions.hasMicrophonePermission {
                        Button("Request Access") {
                            Task {
                                _ = await appState.permissions.requestMicrophoneAccess()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
