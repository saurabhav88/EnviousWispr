import EnviousWisprServices
import SwiftUI

/// Microphone and Accessibility status. Privacy has its own App Settings tab.
struct PermissionsSettingsView: View {
  @Environment(PermissionsService.self) private var permissions

  var body: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 10) {
        SettingsSectionHeading(map: .id(.sectionPermissions))
        BrandedSection {
          BrandedRow {
            SettingsRow(
              map: .id(.permissionMicrophone),
              icon: "mic", help: "Allow microphone access so EnviousWispr can record your voice. If access was denied, Request Access opens System Settings."
            ) {
              if permissions.hasMicrophonePermission {
                grantedStatus(
                  LocalizedStringResource(
                    "Microphone access granted", comment: "Permissions settings: status when granted."))
              } else {
                SettingsActionButton(
                  title: SettingsItemCopy.AppSettings.requestAccess, isEnabled: true,
                  action: requestMicrophone
                )
                .settingsMapRegistration(.permissionMicrophoneRequest)
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
              map: .id(.permissionAccessibility),
              icon: "hand.raised",
              help: "Allow Accessibility access so a modifier key used on its own works as a keybind and EnviousWispr can paste your dictation into other apps."
            ) {
              if permissions.hasAccessibilityPermission {
                grantedStatus(
                  LocalizedStringResource(
                    "Accessibility access granted", comment: "Permissions settings: status when granted."))
              } else {
                SettingsActionButton(title: SettingsItemCopy.AppSettings.openSystemSettings, isEnabled: true) {
                  _ = permissions.requestAccessibilityAccess()
                }
                .settingsMapRegistration(.permissionAccessibilityOpenSettings)
              }
            }
            .rowStatus {
              if !permissions.hasAccessibilityPermission {
                Text("Accessibility needed for modifier keys used on their own and for pasting").settingsHelperCopy()
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

  /// The mockup's green "Allowed" pill (founder, 2026-10-03). VoiceOver keeps main's
  /// full sentence, `text`, so the spoken status still names the permission.
  private func grantedStatus(_ text: LocalizedStringResource) -> some View {
    HStack(spacing: 6) {
      Circle().fill(Color.stSuccess).frame(width: 6, height: 6)
      Text("Allowed", comment: "Permissions settings: the pill shown when a permission is granted.")
    }
    .font(.stHelper.weight(.semibold))
    .foregroundStyle(.stSuccess)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(Capsule().fill(Color.stSuccess.opacity(0.14)))
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(text))
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
