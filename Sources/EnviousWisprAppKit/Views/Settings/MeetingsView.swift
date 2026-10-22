import AVFoundation
import EnviousWisprCore
import EnviousWisprServices
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
  @Environment(PermissionsService.self) private var permissions

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
          microphonePermissionRow
          callSoundPermissionRow
          Text(MeetingsCopy.keptUntilDeleted)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
    }
  }
}

extension MeetingsView {
  /// What macOS lets EnviousMeet record from the microphone, with the fix when it is not
  /// allowed. A status line (R34), not a setting: search does not land on it.
  fileprivate var microphonePermissionRow: some View {
    SettingsRow(
      notInSettingsMap: .statusLine, icon: "mic",
      title: LocalizedStringResource(
        "Microphone", comment: "EnviousMeet page: the microphone permission row's title."),
      short: Self.microphoneStatusLine(permissions.microphoneStatus),
      help: LocalizedStringResource(
        "EnviousMeet records your voice with the microphone you dictate with.",
        comment: "EnviousMeet page: help for the microphone permission row.")
    ) {
      if permissions.microphoneStatus != .authorized {
        Button {
          Task { await startFlow.fixMicrophone() }
        } label: {
          Text(
            "Allow Microphone",
            comment:
              "EnviousMeet: asks macOS for microphone access, or opens System Settings if it was refused."
          )
        }
        .accessibilityIdentifier("meetings.settings.allowMicrophone")
      }
    }
  }

  static func microphoneStatusLine(_ status: AVAuthorizationStatus) -> LocalizedStringResource {
    switch status {
    case .authorized:
      return LocalizedStringResource(
        "Allowed", comment: "EnviousMeet page: macOS lets EnviousWispr use the microphone.")
    case .notDetermined:
      return LocalizedStringResource(
        "macOS asks when you start your first recording.",
        comment: "EnviousMeet page: the microphone was never asked for yet.")
    default:
      return LocalizedStringResource(
        "Not allowed. Allow it to record meetings.",
        comment: "EnviousMeet page: macOS does not let EnviousWispr use the microphone.")
    }
  }

  /// The call sound needs macOS's permission to record what the Mac plays. macOS gives no way to
  /// read that permission before a recording asks, so this row explains it and offers the
  /// System Settings page; the last recording's own result shows in its detail.
  fileprivate var callSoundPermissionRow: some View {
    SettingsRow(
      notInSettingsMap: .statusLine, icon: "speaker.wave.2.circle",
      title: LocalizedStringResource(
        "Call sound permission",
        comment: "EnviousMeet page: the permission row for recording the sound the Mac plays."),
      short: LocalizedStringResource(
        "macOS asks the first time you record the call sound. If you said no, allow it in System Settings.",
        comment: "EnviousMeet page: how the permission to record the Mac's sound works."),
      help: LocalizedStringResource(
        "Only the sound is recorded, never your screen.",
        comment: "EnviousMeet page: help for the call sound permission row.")
    ) {
      Button {
        permissions.openSystemAudioRecordingSettings()
      } label: {
        Text(
          "Open System Settings",
          comment: "EnviousMeet: opens the macOS privacy setting for recording the Mac's sound.")
      }
      .accessibilityIdentifier("meetings.settings.callSoundSettings")
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
  static let keptUntilDeleted = LocalizedStringResource(
    "Each recording keeps its audio until you delete it. Delete the audio alone to keep the transcript.",
    comment: "EnviousMeet page: how long recordings and their audio are kept.")
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
