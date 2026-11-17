import SwiftUI

/// History banner for an unfinished AI polish setup (#3438, plan §17 C5). Shown while the
/// warning monitor says the banner may show; Finish setup opens AI Polish through the window's
/// navigation request, and the close button answers only the episode this banner was showing.
struct PolishSetupBanner: View {
  @Environment(PolishSetupMonitor.self) private var monitor
  @Environment(NavigationCoordinator.self) private var navigationCoordinator

  var body: some View {
    if monitor.shows(.banner), let subject = monitor.promptSubject,
      let episode = monitor.currentEpisode
    {
      content(subject: subject, episode: episode)
    }
  }

  /// `subject` and `episode` are what this banner was drawn with; both buttons answer about
  /// them, never about whatever is true when the button is pressed.
  private func content(subject: PolishSetupPromptSubject, episode: PolishSetupEpisodeToken)
    -> some View
  {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.lg) {
      Image(systemName: "sparkles")
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)

      Text(PolishSetupSurfaceCopy.banner(reason: PolishSetupSurfaceCopy.shortReason(subject.problem, egOneSize: subject.egOneSize)))
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      Button {
        // Through the window's request path, which the leave guard also covers. Not an
        // answer: the banner stays until the setup is finished or it is closed.
        monitor.recordPrompt(.banner, .finishSetup, subject: subject)
        navigationCoordinator.request(.aiPolish)
      } label: {
        EnviousButtonLabel(verbatim: PolishSetupLeaveDialogContent.Copy.finishSetup, size: .medium)
      }
      .settingsButton(.outlined, size: .medium, isEnabled: true)

      Button {
        // The episode captured when this banner was drawn; an old close never answers a newer
        // problem.
        monitor.recordPrompt(.banner, .closed, subject: subject)
        monitor.acknowledge(.banner, in: episode)
      } label: {
        EnviousCloseGlyph()
      }
      .buttonStyle(.plain)
      .help(PolishSetupSurfaceCopy.bannerClose)
      .accessibilityLabel(PolishSetupSurfaceCopy.bannerClose)
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
