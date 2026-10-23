import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// EnviousMeet's shared controls (#3972 §3.8, R34): the call-sound explainer (coverage C5), the
/// live recording panel, the after-recording progress, the notice banner and the call-sound
/// switch. The EnviousMeet page (settings) and History's Recordings use the same views, so the
/// two can never say a recording differently. Every Start goes through `MeetingStartFlow`, the
/// route the menu bar uses; Stop goes straight to `MeetingCoordinator`.

/// Shown before the first Start that records the call sound, before macOS asks.
struct MeetingCallSoundExplainer: View {
  @Environment(MeetingStartFlow.self) private var startFlow

  var body: some View {
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
}

/// The recording as it happens: elapsed time, Stop, a level meter per track and the
/// call-sound line. Shown in History's live meeting.
struct MeetingLivePanel: View {
  let startedAt: Date
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(PermissionsService.self) private var permissions
  /// One shared 10-per-second timeline for both meters, only while recording; reduced motion
  /// slows it to once a second.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
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
    .padding(14)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 12))
  }

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
}

/// The after-recording work, the way Transcribe a File shows its own (#3972 R36, R40): the
/// stage, a progress bar, and why it waits when a dictation is running.
struct MeetingProcessingPanel: View {
  let processing: MeetingCoordinator.Processing
  @Environment(MeetingCoordinator.self) private var meetings

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        MeetingsPresentation.stage(processing, waitingOnSummary: meetings.passWaitsOnSummary))
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

/// Why the last Start or recording needs attention, with its fix where one exists.
struct MeetingNoticeBanner: View {
  let notice: MeetingCoordinator.Notice
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow

  var body: some View {
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
              "EnviousMeet: asks macOS for microphone access, or opens System Settings if it was refused."
          )
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
}

/// "Also record the call sound": always shown on the EnviousMeet page, so search can always land
/// on it; read when the next meeting starts.
struct MeetingCallSoundRow: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    SettingsRow(
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

/// The recording meeting's live words (#3972 R42, R52): provisional, about a minute behind,
/// one line per closed minute of each track, labelled by track. The status line says how fresh
/// they are from the last decoded stretch, and why they lag (dictation, a backlog, skipped
/// stretches). The full transcript, with speakers and echo hidden, comes after the meeting.
struct MeetingLiveWordsView: View {
  let transcript: MeetingCoordinator.LiveTranscript
  /// The call sound is recorded: echo is hidden only in the final transcript.
  let callSoundRecorded: Bool
  /// Greyed while the after-recording pass makes the real transcript.
  var superseded = false
  @Environment(MeetingCoordinator.self) private var meetings

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(
        MeetingsPresentation.liveStatusLines(
          transcript, callSoundRecorded: callSoundRecorded,
          waitingOnSummary: meetings.liveWaitsOnSummary),
        id: \.self
      ) {
        line in
        Text(line)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if transcript.lines.isEmpty {
        Text(
          "No words yet. The first minute shows when it has been recorded.",
          comment: "History, a recording meeting: no live words have been decoded yet."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(transcript.lines) { line in
              VStack(alignment: .leading, spacing: 2) {
                Text(
                  verbatim:
                    "\(MeetingsPresentation.liveSpeaker(line.track)) · \(MeetingsPresentation.clock(ms: line.startMs))"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.stTextSecondary)
                Text(line.text)
                  .font(.stBody)
                  .foregroundStyle(superseded ? Color.stTextSecondary : Color.stTextPrimary)
                  .textSelection(.enabled)
              }
              .id(line.id)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Follows the newest line as it arrives (R42).
        .defaultScrollAnchor(.bottom)
        .frame(minHeight: 160, maxHeight: 420)
      }
    }
    .padding(14)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 12))
  }
}
