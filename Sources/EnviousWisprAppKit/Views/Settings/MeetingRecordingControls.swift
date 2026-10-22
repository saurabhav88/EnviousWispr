import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// The EnviousMeet recorder panel (#3972 §3.8): Start, the call-sound explainer (coverage C5),
/// the recording itself and Stop. Every Start goes through `MeetingStartFlow`, the same route
/// the menu bar uses; Stop goes straight to `MeetingCoordinator`.
struct MeetingRecordingControls: View {
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow
  @Environment(SettingsManager.self) private var settings
  @Environment(PermissionsService.self) private var permissions

  var body: some View {
    BrandedPanel(
      icon: "person.2.wave.2", header: "EnviousMeet", description: MeetingsCopy.pageDescription
    ) {
      VStack(alignment: .leading, spacing: 14) {
        switch MeetingsPresentation.recorder(meetings.phase) {
        case .idle:
          if startFlow.pendingExplainer != nil {
            explainer
          } else {
            startButton
          }
        case .starting:
          busyLine(
            String(
              localized: "Starting the recording",
              comment: "EnviousMeet: a meeting recording is starting."))
        case .recording(let startedAt):
          recording(startedAt: startedAt)
        case .stopping:
          busyLine(
            String(
              localized: "Saving the recording",
              comment: "EnviousMeet: the meeting recording is being closed and saved."))
        }
        callSoundRow
      }
    } footnote: {
      Text(
        "Works with any headphones. Nothing leaves your Mac.",
        comment: "EnviousMeet page: under the recorder. Audio and transcripts stay on the Mac."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    .settingsMapRegistration(.meetingsRecorder)
  }

  // MARK: - Idle

  private var startButton: some View {
    SettingsActionButton(
      title: MeetingsCopy.startRecording, isEnabled: true, emphasis: .filled,
      size: .large, systemImage: "record.circle"
    ) {
      Task { await startFlow.requestStart(from: .page) }
    }
    .accessibilityIdentifier("meetings.start")
  }

  /// Shown before the first Start that records the call sound, before macOS asks.
  private var explainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "macOS will ask to let EnviousWispr record the sound your Mac plays. Only the sound is recorded, never your screen.",
        comment:
          "EnviousMeet: shown once before the first meeting that records the call sound, before the macOS permission prompt."
      )
      .font(.stBody)
      .foregroundStyle(.stTextPrimary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        SettingsActionButton(
          title: LocalizedStringResource(
            "Continue",
            comment: "EnviousMeet: starts the recording after the call-sound explanation."),
          isEnabled: true, emphasis: .filled, shortcut: .defaultAction
        ) {
          Task { await startFlow.continueAfterExplainer() }
        }
        .accessibilityIdentifier("meetings.explainer.continue")
        SettingsActionButton(
          title: LocalizedStringResource(
            "Cancel",
            comment: "EnviousMeet: closes the call-sound explanation without recording."),
          isEnabled: true, emphasis: .quiet, shortcut: .cancelAction
        ) {
          startFlow.cancelExplainer()
        }
        .accessibilityIdentifier("meetings.explainer.cancel")
      }
    }
    .padding(12)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 10))
  }

  private func busyLine(_ text: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Recording

  private func recording(startedAt: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "record.circle.fill")
          .foregroundStyle(.stError)
          .accessibilityHidden(true)
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
          let elapsed = MeetingsPresentation.elapsed(from: startedAt, to: context.date)
          Text(elapsed)
            .font(.system(.title2, design: .rounded).monospacedDigit())
            .foregroundStyle(.stTextPrimary)
            .accessibilityLabel(
              Text(
                "Recording for \(elapsed)",
                comment: "EnviousMeet, VoiceOver: how long the meeting has been recording."))
        }
        Spacer()
        SettingsActionButton(
          title: LocalizedStringResource(
            "Stop Recording",
            comment: "EnviousMeet: the button that stops the meeting recording."),
          isEnabled: true, emphasis: .destructive, size: .medium, systemImage: "stop.circle"
        ) {
          Task { await meetings.stop() }
        }
        .accessibilityIdentifier("meetings.stop")
      }
      meters
      if let line = MeetingsPresentation.callSoundLine(meetings.callSoundStatus) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(line)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if MeetingsPresentation.offersCallSoundFix(meetings.callSoundStatus) {
            Button {
              permissions.openSystemAudioRecordingSettings()
            } label: {
              Text(
                "Open System Settings",
                comment:
                  "EnviousMeet: opens the macOS privacy setting for recording the Mac's sound.")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("meetings.callSoundFix")
          }
        }
      }
      Text(
        "You can keep dictating while EnviousMeet records.",
        comment: "EnviousMeet: while a meeting records."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
  }

  /// One shared 10-per-second timeline for both meters, only while recording; reduced motion
  /// slows it to once a second.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var meters: some View {
    TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.1)) { _ in
      VStack(alignment: .leading, spacing: 8) {
        meterRow(
          label: String(
            localized: "You", comment: "EnviousMeet: the microphone level meter's label."),
          fraction: MeetingsPresentation.meterFraction(meetings.microphoneLevel))
        if meetings.callSoundStatus == .captured {
          meterRow(
            label: String(
              localized: "Call sound",
              comment: "EnviousMeet: the level meter for the sound the Mac plays."),
            fraction: MeetingsPresentation.meterFraction(meetings.callSoundLevel))
        }
      }
    }
  }

  private func meterRow(label: String, fraction: Double) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .frame(width: 80, alignment: .leading)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.stDivider)
          Capsule().fill(Color.stAccent)
            .frame(width: max(4, geometry.size.width * fraction))
        }
      }
      .frame(height: 6)
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(label))
    .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
  }

  // MARK: - Call sound choice

  /// Always shown, so search can always land on it; read when the next meeting starts.
  private var callSoundRow: some View {
    @Bindable var settings = settings
    return SettingsRow(
      map: .id(.meetingCaptureCallSound), icon: "speaker.wave.2",
      help: MeetingsCopy.callSoundHelp
    ) {
      Toggle("", isOn: $settings.meetingCaptureCallSound)
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(MeetingsCopy.callSoundTitle))
    }
  }
}
