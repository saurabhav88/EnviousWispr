import SwiftUI

/// Microphone and Accessibility permission status.
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

            Section("Accessibility") {
                HStack {
                    Image(systemName: appState.permissions.hasAccessibilityPermission
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(appState.permissions.hasAccessibilityPermission ? .green : .red)
                    Text(appState.permissions.hasAccessibilityPermission
                         ? "Accessibility access granted"
                         : "Accessibility access required for paste")

                    Spacer()

                    if !appState.permissions.hasAccessibilityPermission {
                        Button("Open System Settings") {
                            _ = appState.permissions.requestAccessibilityAccess()
                        }
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    appState.permissions.refreshAccessibilityStatus()
                }
            }
        }
        .formStyle(.grouped)
    }
}
