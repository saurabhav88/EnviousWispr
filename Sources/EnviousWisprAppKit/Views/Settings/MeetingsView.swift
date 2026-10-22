import EnviousWisprCore
import SwiftUI

/// The EnviousMeet page (#3972 §3.8, R34, founder F18): EnviousMeet's settings. Recordings live
/// in History (Recordings), and recording is managed from the menu bar and History, so this
/// page never shows a recording. It still shows the call-sound explainer, because a first
/// call-sound Start from the menu brings this page forward to explain it.
struct MeetingsView: View {
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(NavigationCoordinator.self) private var navigation

  var body: some View {
    SettingsContentView {
      BrandedPanel(
        icon: "person.2.wave.2", header: "EnviousMeet", description: MeetingsCopy.pageDescription
      ) {
        VStack(alignment: .leading, spacing: 14) {
          if startFlow.pendingExplainer != nil {
            MeetingCallSoundExplainer()
          }
          if let notice = meetings.notice {
            MeetingNoticeBanner(notice: notice)
          }
          MeetingCallSoundRow()
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(MeetingsCopy.whereRecordingsLive)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
              transcripts.showRecordings()
              navigation.request(.history)
            } label: {
              Text(MeetingsCopy.showRecordings)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("meetings.showRecordings")
          }
        }
      } footnote: {
        Text(
          "Works with any headphones. Audio and transcripts stay on your Mac.",
          comment:
            "EnviousMeet page: the footnote. Recordings and their transcripts are kept on the Mac."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      }
      .settingsMapRegistration(.meetingsRecorder)
    }
  }
}

/// EnviousMeet copy that the Settings Map also reads, so the page and its search entries share
/// one owner (#3482 title ownership).
enum MeetingsCopy {
  static let pageDescription = LocalizedStringResource(
    "Record a meeting on your Mac and get a transcript with who said what.",
    comment: "EnviousMeet page: the line under the title.")
  static let startRecording = LocalizedStringResource(
    "Start Recording", comment: "EnviousMeet: the button that starts a meeting recording.")
  static let whereRecordingsLive = LocalizedStringResource(
    "Start and stop a recording from the menu bar. Your recordings are in History.",
    comment: "EnviousMeet page: where recording is controlled and where recordings are.")
  static let showRecordings = LocalizedStringResource(
    "Show recordings",
    comment: "EnviousMeet page: opens History with the Recordings filter.")
  static let callSoundTitle = LocalizedStringResource(
    "Also record the call sound",
    comment: "EnviousMeet page: switch that records what the Mac plays, like a call.")
  static let callSoundShort = LocalizedStringResource(
    "Records what your Mac plays, like the other people on a call.",
    comment: "EnviousMeet page: the short line under Also record the call sound.")
  static let callSoundHelp = LocalizedStringResource(
    "With headphones, your microphone hears only you, and the call comes from the sound your Mac plays. Without headphones, your microphone also hears the call; EnviousMeet hides those repeated lines as probable echo. The choice applies to the next meeting you start.",
    comment: "EnviousMeet page: help for Also record the call sound.")
}
