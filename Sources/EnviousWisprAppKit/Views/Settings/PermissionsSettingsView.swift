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
            grantedText: LocalizedStringResource(
              "Microphone access granted", comment: "Permissions settings: status when granted."),
            deniedText: LocalizedStringResource(
              "Microphone access denied", comment: "Permissions settings: status when denied."),
            actionLabel: LocalizedStringResource(
              "Request Access",
              comment: "Permissions settings: button that asks macOS for microphone access."),
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
            grantedText: LocalizedStringResource(
              "Accessibility access granted", comment: "Permissions settings: status when granted."),
            deniedText: LocalizedStringResource(
              "Accessibility access required for paste",
              comment:
                "Permissions settings: status when missing; pasting text needs Accessibility access."
            ),
            helperText: "After rebuilding the app you may need to re-grant this permission.",
            actionLabel: LocalizedStringResource(
              "Open System Settings",
              comment: "Permissions settings: button that opens macOS System Settings."),
            action: {
              _ = permissions.requestAccessibilityAccess()
            }
          )
        }
      }
    }
  }
}
