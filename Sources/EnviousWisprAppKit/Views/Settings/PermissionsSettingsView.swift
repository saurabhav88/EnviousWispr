import EnviousWisprServices
import SwiftUI

/// Microphone and Accessibility permission status.
struct PermissionsSettingsView: View {
  @Environment(PermissionsService.self) private var permissions

  var body: some View {
    SettingsContentView {
      BrandedSection(header: "Microphone") {
        BrandedRow(showDivider: false) {
          BrandedStatusRow(
            isGranted: permissions.hasMicrophonePermission,
            grantedText: "Microphone access granted",
            deniedText: "Microphone access denied",
            actionLabel: "Request Access",
            action: {
              Task {
                // #2549: `requestMicrophoneAccess()` is a guaranteed no-op once
                // already denied — Apple never re-shows the system dialog after
                // an explicit deny. This shared method sends the user to System
                // Settings instead when that is the case.
                await permissions.requestMicrophoneAccessOrOpenSettings()
              }
            }
          )
        }
      }

      BrandedSection(header: "Accessibility") {
        BrandedRow(showDivider: false) {
          BrandedStatusRow(
            isGranted: permissions.hasAccessibilityPermission,
            grantedText: "Accessibility access granted",
            deniedText: "Accessibility access required for paste",
            helperText: "After rebuilding the app you may need to re-grant this permission.",
            actionLabel: "Open System Settings",
            action: {
              _ = permissions.requestAccessibilityAccess()
            }
          )
        }
      }
    }
  }
}
