import EnviousWisprServices
import SwiftUI

/// Compact warning banner shown when Accessibility permission is missing.
///
/// Displayed above the history split view, drawn like `RecordingStorageBanner` (#4611). Provides
/// a "Fix Now" shortcut to the Permissions settings tab and a "Dismiss" button to hide it for the
/// session.
struct AccessibilityWarningBanner: View {
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigationCoordinator

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.lg) {
      Image(systemName: "exclamationmark.shield.fill")
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)

      Text(
        LocalizedStringResource(
          "Paste needs Accessibility permission.",
          comment:
            "History: banner shown while the app cannot paste because Accessibility permission is off."
        )
      )
      .font(.stBody)
      .foregroundStyle(.stTextPrimary)
      .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      Button {
        navigationCoordinator.request(.appSettings(.permissions))
      } label: {
        EnviousButtonLabel("Fix Now", size: .medium)
      }
      .settingsButton(.outlined, size: .medium, isEnabled: true)

      Button {
        permissions.dismissAccessibilityWarning()
      } label: {
        EnviousCloseGlyph()
      }
      .buttonStyle(.plain)
      .help(Text("Dismiss", comment: "Accessibility warning banner: hides the banner."))
      .accessibilityLabel(Text("Dismiss", comment: "Accessibility warning banner: hides the banner."))
    }
    .padding(DesignSpacing.xl)
    .background(
      Color.stWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.lg)
    )
    .accessibilityElement(children: .contain)
    .padding(.horizontal, DesignSpacing.xl)
    .padding(.top, DesignSpacing.md)
  }
}
