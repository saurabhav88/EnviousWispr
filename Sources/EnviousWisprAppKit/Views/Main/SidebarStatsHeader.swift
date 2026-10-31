import EnviousWisprCore
import SwiftUI

/// Stats header shown above the transcript list in the sidebar.
struct SidebarStatsHeader: View {
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  // PR7 of #763: live phase + display labels resolve through the three new homes.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(BackendMetadata.self) private var backendMetadata
  @Environment(EngineCoordinator.self) private var engineCoordinator: EngineCoordinator?
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).

  private var isRecording: Bool {
    liveRecordingState.pipelineState == .recording
  }

  var body: some View {
    @Bindable var tc = transcriptCoordinator

    VStack(spacing: 10) {
      // Search bar + transcript count row
      HStack(spacing: 8) {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.stTextTertiary)
          // #2807: History holds dictations AND transcripts, so the box searches "history".
          TextField("Search history", text: $tc.searchQuery)
            .textFieldStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 6))

        // The rows the list shows right now, inside the filter and the search (#2807).
        Text("\(transcriptCoordinator.listedCount)")
          .font(.caption.bold())
          .foregroundStyle(.stTextSecondary)
          .monospacedDigit()
      }
      .opacity(isRecording ? 0.4 : 1.0)

      // #2807: which kind of row the list shows. A segmented control rather than chips: four
      // letters fit the sidebar at its narrowest (#4256), each carrying its full name as hover
      // text and as its VoiceOver name, and the control reads to VoiceOver as one choice.
      Picker("Show", selection: $tc.historyFilter) {
        ForEach(HistoryFilter.allCases, id: \.self) { filter in
          Text(filter.shortTitle)
            .help(filter.title)
            .accessibilityLabel(filter.title)
            .tag(filter)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .frame(maxWidth: .infinity)
      .accessibilityLabel("Show")
      .opacity(isRecording ? 0.4 : 1.0)

      // #3972 R34: the in-app place to start a meeting, under the Meetings filter only.
      if transcriptCoordinator.historyFilter == .recordings {
        recordingControl
        // Meetings a newer EnviousWispr saved stay on disk, untouched; this build cannot open
        // them, so they are counted here rather than listed (#3972 §4).
        if let line = Self.newerFormatLine(meetings.newerFormatMeetings.count) {
          Text(line)
            .font(.caption)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      // Model status bar
      ModelStatusBar(
        modelName: backendMetadata.modelLabel,
        statusText: backendMetadata.statusText(for: liveRecordingState.pipelineState),
        polishLabel: backendMetadata.polishLabel,
        isRecording: isRecording,
        isLoaded: engineCoordinator?.status.activeModelLoaded ?? false,
        hasError: {
          if case .error = liveRecordingState.pipelineState { return true }
          return false
        }()
      )
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .animation(.easeInOut(duration: 0.3), value: isRecording)
  }

  /// One whole sentence per count (#3142), or nil when every meeting opens.
  static func newerFormatLine(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    guard count != 1 else {
      return String(
        localized:
          "A recording was saved by a newer version of EnviousWispr. Update the app to open it.",
        comment:
          "History, Meetings: one meeting this version cannot open (a newer version saved it).")
    }
    return String(
      localized:
        "\(String(count)) recordings were saved by a newer version of EnviousWispr. Update the app to open them.",
      comment:
        "History, Meetings: how many meetings this version cannot open because a newer version saved them. Never 1."
    )
  }

  /// Start Recording when nothing records (the explainer first when it is due for this Start);
  /// while a meeting records, a way to its live detail. Stop lives in that detail and the menu.
  @ViewBuilder private var recordingControl: some View {
    if startFlow.pendingExplainer == .history {
      MeetingCallSoundExplainer()
    } else {
      switch meetings.phase {
      case .idle:
        SettingsActionButton(
          title: MeetingsCopy.startRecording, isEnabled: startFlow.waitingForMicrophone == nil,
          emphasis: .filled, systemImage: "record.circle"
        ) {
          Task {
            let outcome = await startFlow.requestStart(from: .history)
            if case .started(.recording(let meetingID)) = outcome {
              transcriptCoordinator.showRecordings(meetingID: meetingID)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history.meeting.start")
      case .starting, .stopping:
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, alignment: .leading)
      case .recording(let meetingID, _):
        Button {
          transcriptCoordinator.showRecordings(meetingID: meetingID)
        } label: {
          Label(
            String(
              localized: "Show the recording",
              comment: "History, Meetings: selects the meeting that is recording now."),
            systemImage: "record.circle")
        }
        .buttonStyle(.link)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history.meeting.showLive")
      }
    }
  }
}

/// Compact two-row status card: transcription engine + configured AI polish.
/// `polishLabel` is a settings readout (configured target), not a runtime
/// health signal — see `BackendMetadata.polishLabel`.
struct ModelStatusBar: View {
  let modelName: String
  let statusText: String
  let polishLabel: String
  let isRecording: Bool
  let isLoaded: Bool
  let hasError: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Circle()
          .fill(dotColor)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)

        Text("Engine")
          .font(.caption)
          .foregroundStyle(.stTextSecondary)
          .layoutPriority(1)

        Spacer(minLength: 8)

        Text(modelName)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(modelName)

        Text("·")
          .foregroundStyle(.stTextTertiary)

        Text(statusText)
          .font(.caption)
          .foregroundStyle(.stTextSecondary)
          .lineLimit(1)
          .layoutPriority(1)
      }

      HStack(spacing: 6) {
        Color.clear
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)

        Text("AI Polish")
          .font(.caption)
          .foregroundStyle(.stTextSecondary)
          .layoutPriority(1)

        Spacer(minLength: 8)

        Text(polishLabel)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(polishLabel)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isRecording
            ? AnyShapeStyle(Color.stError.opacity(0.1)) : AnyShapeStyle(Color.stSectionBg))
    )
    .accessibilityElement(children: .combine)
  }

  private var dotColor: Color {
    if isRecording { return .stError }
    if hasError { return .stError }
    return isLoaded ? .stSuccess : .stTextTertiary
  }
}
