import SwiftUI
import EnviousWisprCore

/// Microphone and Accessibility permission status.
struct PermissionsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsContentView {
            BrandedSection(header: "Microphone") {
                BrandedRow(showDivider: false) {
                    BrandedStatusRow(
                        isGranted: appState.permissions.hasMicrophonePermission,
                        grantedText: "Microphone access granted",
                        deniedText: "Microphone access denied",
                        actionLabel: "Request Access",
                        action: {
                            Task {
                                _ = await appState.permissions.requestMicrophoneAccess()
                            }
                        }
                    )
                }
            }

            BrandedSection(header: "Accessibility") {
                BrandedRow(showDivider: false) {
                    BrandedStatusRow(
                        isGranted: appState.permissions.hasAccessibilityPermission,
                        grantedText: "Accessibility access granted",
                        deniedText: "Accessibility access required for paste",
                        helperText: "After rebuilding the app you may need to re-grant this permission.",
                        actionLabel: "Open System Settings",
                        action: {
                            _ = appState.permissions.requestAccessibilityAccess()
                        }
                    )
                }
            }
        }
    }
}
