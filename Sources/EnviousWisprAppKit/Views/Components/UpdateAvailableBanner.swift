import EnviousWisprServices
import SwiftUI

/// In-app banner shown at the bottom of the Settings sidebar when Sparkle has
/// downloaded a non-critical update (issue #343). Click-anywhere installs.
/// Stays visible until the bundle version on disk catches up to the pending
/// version (issue #739). 3pt rainbow stripe along the top edge matches the
/// EnviousWispr brand mark.
struct UpdateAvailableBanner: View {
  @Environment(UpdateCoordinatorHolder.self) private var coordinatorHolder
  private var coordinator: UpdateCoordinator? { coordinatorHolder.coordinator }
  let update: UpdateAvailabilityService.AvailableUpdate

  // Telemetry: track when the banner first appeared (for `seconds_visible`
  // on click and dismiss).
  @State private var appearedAt: Date?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(Color.stToggleOn)
        .frame(width: 8, height: 8)
        .padding(.top, 6)

      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringResource("Update available"))
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundStyle(.primary)

        Text(
          LocalizedStringResource(
            "Version \(update.displayVersion) is ready. Click to restart."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      coordinator?.handleBannerClicked(
        version: update.versionString,
        isCritical: update.isCriticalUpdate,
        secondsVisible: secondsVisible())
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.stSectionBg)
        .overlay(alignment: .top) {
          Rectangle()
            .fill(Color.obRainbow)
            .frame(height: 3)
            .clipShape(
              UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12
              )
            )
        }
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    )
    .onAppear {
      appearedAt = Date()
      coordinator?.handleBannerShown(
        version: update.versionString,
        isCritical: update.isCriticalUpdate,
        dismissedPreviously: false)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(
      LocalizedStringResource("Update available, version \(update.displayVersion)")
    )
    .accessibilityHint(LocalizedStringResource("Activate to install and restart"))
  }

  private func secondsVisible() -> Int {
    guard let appearedAt else { return 0 }
    return Int(Date().timeIntervalSince(appearedAt))
  }
}
