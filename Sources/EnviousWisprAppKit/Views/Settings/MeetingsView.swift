import EnviousWisprCore
import SwiftUI

/// The EnviousMeet page (#3972 §3.8): start and stop a meeting recording, see it record,
/// follow the transcript work, and open past meetings. It reads `MeetingCoordinator`, which
/// owns every recording and pass; leaving the page never stops either. Decisions about copy,
/// status and actions live in `MeetingsPresentation`.
struct MeetingsView: View {
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow

  /// The open meeting. Window-local; cleared when that meeting leaves the list.
  @State private var selectedID: UUID?

  var body: some View {
    SettingsContentView {
      MeetingRecordingControls()
      if let notice = meetings.notice {
        noticeBanner(notice)
      }
      if let processing = meetings.processing {
        processingPanel(processing)
      }
      MeetingListView(selectedID: $selectedID)
      if let selectedID, meetings.record(id: selectedID) != nil {
        MeetingDetailView(meetingID: selectedID, onClose: { self.selectedID = nil })
          .id(selectedID)
      }
    }
    .onChange(of: meetings.meetings.map(\.id)) { _, ids in
      if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
    }
  }

  private func noticeBanner(_ notice: MeetingCoordinator.Notice) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)
      Text(MeetingsPresentation.notice(notice))
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if MeetingsPresentation.offersMicrophoneFix(notice) {
        Button {
          Task { await startFlow.fixMicrophone() }
        } label: {
          Text(
            "Allow Microphone",
            comment:
              "EnviousMeet: asks macOS for microphone access, or opens System Settings if it was refused.")
        }
        .accessibilityIdentifier("meetings.allowMicrophone")
      }
      Button {
        meetings.dismissNotice()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(
        Text("Dismiss", comment: "EnviousMeet: closes a notice about the last recording."))
    }
    .padding(12)
    .background(Color.stWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }

  private func processingPanel(_ processing: MeetingCoordinator.Processing) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(MeetingsPresentation.stage(processing))
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
      if let fraction = MeetingsPresentation.progress(processing) {
        ProgressView(value: fraction)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      Text(
        "Meeting work never slows your dictation: it waits while you dictate.",
        comment: "EnviousMeet: under the transcript progress bar."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    .padding(14)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
  }
}

/// EnviousMeet copy that the Settings Map also reads, so the page and its search entries share
/// one owner (#3482 title ownership).
enum MeetingsCopy {
  static let pageDescription = LocalizedStringResource(
    "Record a meeting on your Mac and get a transcript with who said what.",
    comment: "EnviousMeet page: the line under the title.")
  static let startRecording = LocalizedStringResource(
    "Start Recording", comment: "EnviousMeet page: the button that starts a meeting recording.")
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
