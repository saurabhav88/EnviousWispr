import EnviousWisprServices
import SwiftUI

/// Microphone and Accessibility status. Privacy has its own App Settings tab.
struct PermissionsSettingsView: View {
  @Environment(PermissionsService.self) private var permissions

  var body: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 10) {
        SettingsSectionHeading(title: "PERMISSIONS")
        BrandedSection {
          BrandedRow {
            SettingsRow(
              icon: "mic", title: "Microphone", short: "Needed to record your voice.",
              help: "Allow microphone access so EnviousWispr can record your voice. If access was denied, Request Access opens System Settings."
            ) {
              if permissions.hasMicrophonePermission {
                allowedStatus
              } else {
                SettingsActionButton(title: "Request Access", isEnabled: true, action: requestMicrophone)
              }
            }
            .rowStatus {
              if !permissions.hasMicrophonePermission {
                Text("Microphone access denied").settingsHelperCopy()
              }
            }
          }
          BrandedRow(showDivider: false) {
            SettingsRow(
              icon: "hand.raised", title: "Accessibility",
              short: "Needed to paste text into other apps.",
              help: "Allow Accessibility access so EnviousWispr can paste your dictation into other apps."
            ) {
              if permissions.hasAccessibilityPermission {
                allowedStatus
              } else {
                SettingsActionButton(title: "Open System Settings", isEnabled: true) {
                  _ = permissions.requestAccessibilityAccess()
                }
              }
            }
            .rowStatus {
              if !permissions.hasAccessibilityPermission {
                Text("Accessibility access required for paste").settingsHelperCopy()
                Text("After rebuilding the app you may need to re-grant this permission.")
                  .font(.stRowHelper)
                  .foregroundStyle(.stTextSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }
  }

  private var allowedStatus: some View {
    Label("Allowed", systemImage: "checkmark.circle.fill")
      .font(.stRowHelper)
      .foregroundStyle(.stSuccess)
      .fixedSize()
  }

  private func requestMicrophone() {
    Task {
      // #2549: `requestMicrophoneAccess()` is a guaranteed no-op once
      // already denied — Apple never re-shows the system dialog after
      // an explicit deny. This shared method sends the user to System
      // Settings instead when that is the case.
      await permissions.requestMicrophoneAccessOrOpenSettings()
    }
  }
}
