import SwiftUI

/// History banner for an unfinished AI polish setup (#3438, plan §17 C5), and since #4721 for the
/// EnviousMeet summary engine too: one banner, about dictation's engine, the summary engine, or
/// both. Shown while either warning monitor says its banner may show; Finish setup opens AI
/// Polish while dictation's engine needs it, otherwise the Summaries tab, through the window's
/// navigation request; the close button answers only the episodes this banner was showing.
struct PolishSetupBanner: View {
  @Environment(PolishSetupMonitor.self) private var monitor
  @Environment(SummarySetupMonitorHolder.self) private var summary
  @Environment(NavigationCoordinator.self) private var navigationCoordinator

  /// One monitor's part of the banner, captured when drawn.
  struct Shown: Equatable {
    let subject: PolishSetupPromptSubject
    let episode: PolishSetupEpisodeToken
  }

  static func shown(_ monitor: PolishSetupMonitor) -> Shown? {
    guard monitor.shows(.banner), let subject = monitor.promptSubject,
      let episode = monitor.currentEpisode
    else { return nil }
    return Shown(subject: subject, episode: episode)
  }

  var body: some View {
    let dictation = Self.shown(monitor)
    let summaryShown = Self.shown(summary.monitor)
    if let subjects = PolishSetupWarningSubjects(
      dictation: dictation?.subject, summary: summaryShown?.subject)
    {
      content(subjects: subjects, dictation: dictation, summary: summaryShown)
    }
  }

  /// `subjects` and the episodes are what this banner was drawn with; both buttons answer about
  /// them, never about whatever is true when the button is pressed.
  private func content(
    subjects: PolishSetupWarningSubjects, dictation: Shown?, summary summaryShown: Shown?
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.lg) {
      Image(systemName: "sparkles")
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)

      Text(PolishSetupSurfaceCopy.banner(subjects))
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      Button {
        // Through the window's request path, which the leave guard also covers. Not an
        // answer: the banner stays until the setup is finished or it is closed.
        subjects.finishSetup(
          dictationMonitor: monitor, summaryMonitor: summary.monitor, on: .banner,
          request: { navigationCoordinator.request($0) })
      } label: {
        EnviousButtonLabel(verbatim: PolishSetupLeaveDialogContent.Copy.finishSetup, size: .medium)
      }
      .settingsButton(.outlined, size: .medium, isEnabled: true)

      Button {
        Self.close(
          dictation: dictation, summary: summaryShown, dictationMonitor: monitor,
          summaryMonitor: summary.monitor)
      } label: {
        EnviousCloseGlyph()
      }
      .buttonStyle(.plain)
      .help(Self.closeLabel(subjects))
      .accessibilityLabel(Self.closeLabel(subjects))
    }
    .padding(DesignSpacing.xl)
    .background(
      Color.stWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.lg)
    )
    .accessibilityElement(children: .contain)
    .padding(.horizontal, DesignSpacing.xl)
    .padding(.top, DesignSpacing.md)
  }

  /// The close button: each monitor answers only the episode this banner showed for it, so an
  /// old close never answers a newer problem, and each monitor keeps its own answer.
  static func close(
    dictation: Shown?, summary: Shown?, dictationMonitor: PolishSetupMonitor,
    summaryMonitor: PolishSetupMonitor
  ) {
    if let dictation {
      dictationMonitor.recordPrompt(.banner, .closed, subject: dictation.subject)
      dictationMonitor.acknowledge(.banner, in: dictation.episode)
    }
    if let summary {
      summaryMonitor.recordPrompt(.summaryBanner, .closed, subject: summary.subject)
      summaryMonitor.acknowledge(.banner, in: summary.episode)
    }
  }

  /// Dictation alone keeps its own close label; a banner about the summary engine says "Close",
  /// never a name that would misstate what it is about.
  static func closeLabel(_ subjects: PolishSetupWarningSubjects) -> String {
    subjects.dictation != nil && subjects.summary == nil
      ? PolishSetupSurfaceCopy.bannerClose
      : String(
        localized: "Close",
        comment: "History page banner, VoiceOver and tooltip: closes the setup notice about meeting summaries.")
  }
}
