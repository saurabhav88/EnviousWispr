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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.permissions.hasAccessibilityPermission
                             ? "Accessibility access granted"
                             : "Accessibility access required for paste")
                        if !appState.permissions.hasAccessibilityPermission {
                            Text("After rebuilding the app you may need to re-grant this permission.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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
                    try? await Task.sleep(for: .seconds(TimingConstants.accessibilityPollIntervalSec))
                    appState.permissions.refreshAccessibilityStatus()
                }
            }
        }
        .formStyle(.grouped)
    }
}
