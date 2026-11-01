import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprServices
import SwiftUI

/// EnviousMeet's shared controls (#3972 §3.8, R34): the call-sound explainer (coverage C5), the
/// live recording panel, the after-recording progress, the notice banner and the call-sound
/// switch. The EnviousMeet page (settings) and History's Meetings tab use the same views, so the
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
  /// #4069: its host (`MeetingHistoryDetailView`) already reads this home.
  @Environment(SettingsManager.self) private var settings
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
      Group {
        // #4069: true to the switch, which is read at each dictation press.
        if settings.meetingTurnsOffDictation {
          Text(DictationNarrator.copy(for: .dictationOffDuringMeeting))
        } else {
          Text(
            "You can keep dictating while EnviousMeet records.",
            comment: "EnviousMeet: while a meeting records."
          )
        }
      }
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

/// "Record only my voice" (#4058): `meetingCaptureCallSound` shown the other way round, so on
/// means the call sound is left out. Always on the General tab, so search can always land on it;
/// read when the next meeting starts.
struct MeetingCallSoundRow: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    SettingsRow(
      map: .id(.meetingCaptureCallSound), icon: "speaker.wave.2",
      help: MeetingsCopy.callSoundHelp
    ) {
      Toggle(
        "",
        isOn: Binding(
          get: { !settings.meetingCaptureCallSound },
          set: { settings.meetingCaptureCallSound = !$0 }))
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(MeetingsCopy.callSoundTitle))
    }
  }
}

/// "Write a summary when a meeting ends" (#3972 R39): read when each meeting becomes ready.
struct MeetingWriteSummaryRow: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    SettingsRow(
      map: .id(.meetingWriteSummary), icon: "list.bullet.rectangle",
      help: MeetingsCopy.writeSummaryHelp
    ) {
      Toggle("", isOn: $settings.meetingWriteSummary)
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(MeetingsCopy.writeSummaryTitle))
    }
  }
}

/// "Leave my voice out when I'm muted" (#4248): applies to a recording in progress at once.
struct MeetingFollowsCallMuteRow: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    SettingsRow(
      map: .id(.meetingFollowsCallMute), icon: "mic.slash.circle",
      help: MeetingsCopy.followsCallMuteHelp
    ) {
      Toggle("", isOn: $settings.meetingFollowsCallMute)
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(MeetingsCopy.followsCallMuteTitle))
    }
  }
}

/// "Turn off dictation during meetings" (#4069): read at each dictation start press.
struct MeetingTurnsOffDictationRow: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    SettingsRow(
      map: .id(.meetingTurnsOffDictation), icon: "mic.slash",
      help: MeetingsCopy.turnsOffDictationHelp
    ) {
      Toggle("", isOn: $settings.meetingTurnsOffDictation)
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(MeetingsCopy.turnsOffDictationTitle))
    }
  }
}

/// "Name meetings from my calendar" (#4017 R5): read when a meeting starts. Turning it on asks
/// macOS for calendar access when it was never asked; a refusal leaves it off.
struct MeetingCalendarNamesRow: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(PermissionsService.self) private var permissions
  /// Optional: a screen without EnviousMeet's setup (a test render) still shows the switch.
  @Environment(MeetingOnboardingModel.self) private var onboarding: MeetingOnboardingModel?
  @State private var asking = false

  var body: some View {
    SettingsRow(
      map: .id(.meetingUseCalendarForNames), icon: "calendar.badge.clock",
      help: MeetingsCopy.calendarNamesHelp
    ) {
      Toggle(
        "",
        isOn: Binding(
          get: { settings.meetingUseCalendarForNames },
          set: { on in
            onboarding?.noteCalendarNamesChoice()
            guard on else {
              settings.meetingUseCalendarForNames = false
              return
            }
            guard !asking else { return }
            asking = true
            Task {
              let status = await CalendarAccess.request()
              // The page's Calendar row reads the shared status, so it shows the result too.
              permissions.refreshCalendarStatus()
              settings.meetingUseCalendarForNames = status == .granted
              asking = false
            }
          })
      )
      .labelsHidden()
      .toggleStyle(BrandedToggleStyle())
      .fixedSize()
      .disabled(asking)
      .accessibilityLabel(Text(MeetingsCopy.calendarNamesTitle))
    }
  }
}

/// The consent text on the EnviousMeet page (#4017 O4), the same words the setup shows.
struct MeetingConsentNote: View {
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.shield")
        .foregroundStyle(.stAccent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(MeetingConsentCopy.paragraphs.indices, id: \.self) { index in
          Text(MeetingConsentCopy.paragraphs[index])
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
  }
}

/// The recording meeting's live words (#3973): lines labelled by track as people speak, words
/// still changing and words the engine was unsure of shown lighter. The status lines say when
/// a track has no live words and why. The full transcript, with speakers and echo hidden, comes
/// after the meeting.
struct MeetingLiveWordsView: View {
  let transcript: MeetingLiveWords.Transcript
  /// The call sound is recorded: echo is hidden only in the final transcript.
  let callSoundRecorded: Bool
  /// After Stop, until the transcript replaces them: greyed, and the copy says the recording
  /// ended.
  var superseded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(
        MeetingsPresentation.liveStatusLines(
          transcript, callSoundRecorded: callSoundRecorded, recordingEnded: superseded),
        id: \.self
      ) {
        line in
        Text(line)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if transcript.lines.isEmpty {
        if let empty = MeetingsPresentation.emptyLiveWords(transcript, recordingEnded: superseded) {
          Text(empty)
            .font(.stBody)
            .foregroundStyle(.stTextSecondary)
        }
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
                  .italic(line.kind == .uncertain)
                  .foregroundStyle(
                    superseded || line.kind != .confirmed ? Color.stTextSecondary : Color.stTextPrimary)
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

/// #4012 D1: what EnviousMeet does when a call starts: ask, start by itself, or nothing.
struct MeetingCallDetectionRow: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    SettingsRow(
      map: .id(.meetingCallDetection), icon: "phone.badge.waveform",
      help: MeetingsCopy.callDetectionHelp
    ) {
      BrandedSegmentedPicker(
        options: MeetingsCopy.callDetectionDisplayOrder.map {
          (String(localized: MeetingsCopy.callDetectionChoice($0)), nil, $0)
        },
        selection: Binding(
          get: { CallDetectionPolicy.Mode(rawValue: settings.meetingCallDetection) ?? .ask },
          set: { settings.meetingCallDetection = $0.rawValue })
      )
      .fixedSize()
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text(MeetingsCopy.callDetectionTitle))
      // The watcher needs macOS 14.2 (r3 F8): below it the choice cannot do anything.
      .disabled(!CallMicrophoneWatcher.isSupported)
    }
    .rowStatus {
      if !CallMicrophoneWatcher.isSupported {
        Text(MeetingsCopy.callDetectionNeedsNewerMacOS)
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// #4012 D5: a switch per call app on this Mac, plus one for every browser, all on by default.
/// Switching one off stores its id in `meetingCallAppsOff`.
/// #4284: each switch sits in its own row with the app's real logo (`CallAppIdentityTile`, the
/// same pictures the call cards use), rows divided like the rest of Settings, and a privacy line.
/// The list sits under the title row rather than inside it, so the title row's icon stays
/// beside the title instead of centering on the whole list. Outside the row it no longer inherits
/// the row's arrival place, so it names the same place itself: a Settings search arrival still
/// focuses the first switch, as before (`BrandedToggleStyle` reads `settingsArrivalRegisteredID`).
struct MeetingCallAppsRow: View {
  @Environment(SettingsManager.self) private var settings
  @State private var installed: [CallAppFamily] = []
  /// The browser whose logo stands for "Meetings in a browser"; nil shows a globe.
  @State private var browserBundleID: String?

  private static let tileSize: CGFloat = 30

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SettingsRow(
        map: .id(.meetingCallApps), icon: "app.badge.checkmark", help: MeetingsCopy.callAppsHelp
      ) {
        EmptyView()
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(installed, id: \.self) { family in
          appSwitch(id: family.rawValue, name: family.displayName, detail: nil) {
            CallAppIdentityTile(identity: .app(family, bundleID: nil), size: Self.tileSize)
          }
          rowDivider
        }
        appSwitch(
          id: CallAppCatalog.browserSwitchID, name: String(localized: MeetingsCopy.browserMeetings),
          detail: MeetingsCopy.browserMeetingsDetail
        ) {
          browserTile
        }
      }
      .disabled(
        settings.meetingCallDetection == CallDetectionPolicy.Mode.off.rawValue
          || !CallMicrophoneWatcher.isSupported)
      .environment(\.settingsArrivalRegisteredID, SettingsMapID.meetingCallApps)
      Label {
        Text(MeetingsCopy.callAppsPrivacy)
      } icon: {
        Image(systemName: "lock")
      }
      .font(.stRowHelper)
      .foregroundStyle(.stTextSecondary)
      .padding(.top, 2)
    }
    .onAppear {
      installed = CallAppCatalog.installedNativeApps {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
      }
      browserBundleID = Self.browserForLogo()
    }
  }

  private var rowDivider: some View {
    Rectangle()
      .fill(Color.stDivider)
      .frame(height: 1)
      .padding(.leading, Self.tileSize + 12)
  }

  @ViewBuilder private var browserTile: some View {
    if let image = browserBundleID.flatMap(CallAppIcon.icon) {
      Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "globe")
        .font(.system(size: Self.tileSize * 0.5, weight: .medium))
        .foregroundStyle(Color.stAccent)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: Self.tileSize * 0.25))
        .accessibilityHidden(true)
    }
  }

  /// The default browser when EnviousMeet supports it, else the first supported browser on this
  /// Mac, so the logo never shows a browser whose meetings are not noticed (Firefox).
  private static func browserForLogo() -> String? {
    let supported = CallAppCatalog.Browser.allCases.flatMap(\.appBundleIDs)
    if let url = URL(string: "https://example.com"),
      let app = NSWorkspace.shared.urlForApplication(toOpen: url),
      let id = Bundle(url: app)?.bundleIdentifier?.lowercased(), supported.contains(id)
    {
      return id
    }
    return supported.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
  }

  private func appSwitch<Tile: View>(
    id: String, name: String, detail: LocalizedStringResource?, @ViewBuilder tile: () -> Tile
  ) -> some View {
    HStack(spacing: 12) {
      tile()
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: name)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
        if let detail {
          Text(detail)
            .font(.stRowHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Toggle(
        "",
        isOn: Binding(
          get: { !CallAppCatalog.appsOff(from: settings.meetingCallAppsOff).contains(id) },
          set: { on in
            var off = CallAppCatalog.appsOff(from: settings.meetingCallAppsOff)
            if on { off.remove(id) } else { off.insert(id) }
            settings.meetingCallAppsOff = CallAppCatalog.encodeAppsOff(off)
          })
      )
      .labelsHidden()
      .toggleStyle(BrandedToggleStyle())
      .fixedSize()
      .accessibilityLabel(Text(verbatim: name))
    }
    .padding(.vertical, 9)
    .accessibilityIdentifier("meetings.callApps.\(id)")
  }
}
