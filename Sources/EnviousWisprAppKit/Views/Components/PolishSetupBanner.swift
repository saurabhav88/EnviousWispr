import EnviousWisprServices
import SwiftUI

/// History banner for an unfinished AI polish setup (#3438, plan §17 C5). Shown while the
/// warning monitor says the banner may show; Finish setup opens AI Polish through the window's
/// navigation request, and the close button answers only the episode this banner was showing.
struct PolishSetupBanner: View {
  @Environment(PolishSetupMonitor.self) private var monitor
  @Environment(NavigationCoordinator.self) private var navigationCoordinator

  var body: some View {
    if monitor.shows(.banner), let problem = monitor.eligibleProblem,
      let episode = monitor.currentEpisode
    {
      content(problem: problem, episode: episode)
    }
  }

  private func content(problem: PolishSetupProblem, episode: PolishSetupEpisodeToken)
    -> some View
  {
    HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .foregroundStyle(.orange)
        .imageScale(.medium)
        .accessibilityHidden(true)

      Text(PolishSetupSurfaceCopy.banner(reason: PolishSetupSurfaceCopy.shortReason(problem)))
        .font(.callout)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button(PolishSetupLeaveDialogContent.Copy.finishSetup) {
        // Through the window's request path, which the leave guard also covers. Not an
        // answer: the banner stays until the setup is finished or it is closed.
        navigationCoordinator.request(.aiPolish)
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
      .controlSize(.small)

      Button {
        // The episode captured when this banner was drawn; an old close never answers a newer
        // problem.
        monitor.acknowledge(.banner, in: episode)
      } label: {
        Image(systemName: "xmark")
          .imageScale(.small)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(PolishSetupSurfaceCopy.bannerClose)
      .accessibilityLabel(PolishSetupSurfaceCopy.bannerClose)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(.orange.opacity(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
  }
}
