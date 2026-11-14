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
        Button {
          Task { await startFlow.continueAfterExplainer() }
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Continue",
              comment: "EnviousMeet: starts the recording after the call-sound explanation."))
        }
        .settingsButton(.filled, isEnabled: true, shortcut: .defaultAction)
        .accessibilityIdentifier("meetings.explainer.continue")
        Button {
          startFlow.cancelExplainer()
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Cancel",
              comment: "EnviousMeet: closes the call-sound explanation without recording."))
        }
        .settingsButton(.quiet, isEnabled: true, shortcut: .cancelAction)
        .accessibilityIdentifier("meetings.explainer.cancel")
      }
    }
    .padding(12)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 10))
  }
}

/// The recording as it happens: elapsed time, input status, recovery controls and Stop.
struct MeetingLivePanel: View {
  let meetingID: UUID
  let startedAt: Date
  let callApp: CallAppFamily?
  let microphoneAvailable: Bool
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(PermissionsService.self) private var permissions
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DesignSpacing.md) {
          recordingLabel
          Spacer(minLength: DesignSpacing.md)
          HStack(spacing: DesignSpacing.md) { inputStatus }
            .fixedSize()
          stopButton
        }
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          HStack {
            recordingLabel
            Spacer(minLength: DesignSpacing.md)
            stopButton
          }
          WrappingHStack(spacing: DesignSpacing.md) { inputStatus }
        }
      }
      if let line = MeetingsPresentation.muteLine(meetings.muteState, callApp: meetings.muteCallApp) {
        Text(line)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("meetings.muteLine")
      }
      if let line = MeetingsPresentation.callSoundLine(meetings.callSoundStatus) {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
          Text(line)
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
        .font(.stHelper)
      }
      if settings.meetingTurnsOffDictation {
        Text(DictationNarrator.copy(for: .dictationOffDuringMeeting))
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      } else {
        Text(
          "You can keep dictating while EnviousMeet records.",
          comment: "EnviousMeet: while a meeting records."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      }
    }
    .padding(SettingsLayout.rowPaddingH)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
    .overlay {
      RoundedRectangle(cornerRadius: DesignRadius.xl)
        .strokeBorder(Color.stError.opacity(0.45))
        .allowsHitTesting(false)
    }
  }

  private var recordingLabel: some View {
    HStack(spacing: DesignSpacing.md) {
      Image(systemName: "record.circle.fill")
        .foregroundStyle(.stError)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
          let elapsed = MeetingsPresentation.elapsed(from: startedAt, to: context.date)
          Text("Recording · \(elapsed)", comment: "Meeting recording status with elapsed time.")
            .font(.stRowLabel.monospacedDigit())
            .accessibilityLabel(
              Text(
                "Recording for \(elapsed)",
                comment: "EnviousMeet, VoiceOver: how long the meeting has been recording."))
        }
        if let callApp {
          Text(verbatim: callApp.displayName)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      }
    }
  }

  private var stopButton: some View {
    Button(role: .destructive) {
      Task {
        guard case .recording(let id, _) = meetings.phase, id == meetingID else { return }
        await meetings.stop(reason: .user)
      }
    } label: {
      EnviousButtonLabel(
        LocalizedStringResource(
          "Stop Recording",
          comment: "EnviousMeet: the button that stops the meeting recording."),
        size: .medium, systemImage: "stop.circle")
    }
    .settingsButton(size: .medium, isEnabled: true)
    .accessibilityIdentifier("meetings.stop")
  }

  @ViewBuilder private var inputStatus: some View {
    if !microphoneAvailable {
      Label("Microphone unavailable", systemImage: "mic.slash")
        .font(.stHelper)
        .foregroundStyle(.stError)
    } else if meetings.muteState != .muted {
      Label("Microphone on", systemImage: "mic")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    }
    if meetings.callSoundStatus == .captured {
      Label("Call audio on", systemImage: "speaker.wave.2")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .help(Text("Call sound", comment: "EnviousMeet: the level meter for the sound the Mac plays."))
    }
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
        MeetingsPresentation.stage(processing, waitingOnSummary: meetings.passWaitsOnSummary)
      )
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
          EnviousButtonLabel(LocalizedStringResource(
            "Allow Microphone",
            comment:
              "EnviousMeet: asks macOS for microphone access, or opens System Settings if it was refused."
          ))
        }
        .settingsButton(isEnabled: true)
        .settingsArrivalWithoutInheritedPlace()
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
          set: { settings.meetingCaptureCallSound = !$0 })
      )
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

/// The recording meeting's live words (#3973): blocks headed You, Speaker N or Speaker (#4355 PR C) as people speak, words
/// still changing and words the engine was unsure of shown lighter. The status lines say when
/// a track has no live words and why. The full transcript, with speakers, comes after the
/// meeting.
struct MeetingLiveWordsView: View {
  let transcript: MeetingLiveWords.Transcript
  /// After Stop, until the transcript replaces them: greyed, and the copy says the recording
  /// ended.
  var superseded = false
  var addQuote: ((MeetingsPresentation.LiveBlock.Run) -> Void)?
  @State private var followsLive = true
  @State private var liveEnd = UUID()
  @Environment(SettingsManager.self) private var settings
  @Environment(LiveRecordingState.self) private var dictation

  private var catchingUp: Bool {
    addQuote != nil && transcript.usesUniversal
      && transcript.tracks.values.contains { $0.status == .running }
      && WhisperPreviewDeliveryWiring.meetingDecodeMustWait(
        settings: settings, dictationActive: dictation.isDictationActive)
  }

  private func liveHeader(_ header: MeetingsPresentation.LiveRow.Header) -> String {
    "\(MeetingsPresentation.liveSpeakerHeader(header.speaker, names: transcript.speakerLabels.names)) · \(MeetingsPresentation.clock(ms: header.startMs))"
  }

  /// One line's text; a speaker change inside it starts a new paragraph under its own header.
  private func liveText(_ row: MeetingsPresentation.LiveRow) -> Text {
    row.segments.enumerated().reduce(Text(verbatim: "")) { text, item in
      let (index, segment) = item
      guard index > 0 else { return text + Text(segment.text) }
      guard let header = segment.header else { return text + Text(" " + segment.text) }
      return text + Text(verbatim: "\n\n")
          + Text(verbatim: liveHeader(header)).font(.stRowLabel)
          .foregroundColor(.stTextSecondary) + Text(verbatim: "\n") + Text(segment.text)
    }
  }

  var body: some View {
    let rows = MeetingsPresentation.liveRows(
      MeetingsPresentation.liveBlocks(transcript.lines, labels: transcript.speakerLabels))
    VStack(alignment: .leading, spacing: 8) {
      if addQuote != nil {
        HStack {
          Text("Live transcript")
            .font(.stRowTitle)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          if !followsLive {
            Button {
              followsLive = true
            } label: {
              EnviousButtonLabel("Jump to live", size: .medium, systemImage: "arrow.down")
            }
            .settingsButton(.quiet, size: .medium, isEnabled: true)
          }
        }
      }
      if catchingUp {
        Text("Live transcript catching up")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
      ForEach(
        MeetingsPresentation.liveStatusLines(
          transcript, recordingEnded: superseded),
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
        ScrollViewReader { proxy in
          ScrollView {
          LazyVStack(alignment: .leading, spacing: DesignSpacing.xxs) {
            // #4355 PR C: speaker blocks, after each piece was assigned, drawn as one row per
            // live line keyed by the line's identity. Regrouping changes headers only: a line's
            // text is never removed or reparented, so selection and focus stay with it. A
            // speaker change inside a line is a header inside that line's text.
            ForEach(rows) {
              row in
              VStack(alignment: .leading, spacing: 2) {
                if let header = row.header {
                  Text(verbatim: liveHeader(header))
                    .font(.stRowLabel)
                    .foregroundStyle(.stTextSecondary)
                    .accessibilityAddTraits(.isHeader)
                }
                if let addQuote {
                  ForEach(row.segments, id: \.run.id) { segment in
                    if let header = segment.header {
                      Text(verbatim: liveHeader(header))
                        .font(.stRowLabel)
                        .foregroundStyle(.stTextSecondary)
                        .accessibilityAddTraits(.isHeader)
                    }
                    styledLiveText(Text(verbatim: segment.text), kind: row.kind)
                    if let quote = segment.quote {
                      Button {
                        addQuote(quote)
                      } label: {
                        EnviousButtonLabel("Add quote", size: .medium, systemImage: "quote.bubble")
                      }
                      .settingsButton(.quiet, size: .medium, isEnabled: true)
                    }
                  }
                } else {
                  styledLiveText(liveText(row), kind: row.kind)
                }
              }
              // The gap between blocks the nested layout had (10 points around a 2-point run gap).
              .padding(.top, row.header != nil ? 8 : 0)
            }
            Color.clear.frame(height: 1).id(liveEnd).accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          }
          .meetingUserScroll {
            if addQuote != nil { followsLive = false }
          }
          .onChange(of: transcript.lines.last, initial: true) {
            if followsLive { proxy.scrollTo(liveEnd, anchor: .bottom) }
          }
          .onChange(of: followsLive) {
            if followsLive { proxy.scrollTo(liveEnd, anchor: .bottom) }
          }
        }
        .frame(minHeight: 160, maxHeight: addQuote == nil ? 420 : .infinity)
      }
    }
    .padding(14)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 12))
    // #4355 PR C: one announcement per applied batch that moved text under a speaker, never
    // per model update, and never a claim about who is talking now.
    .onChange(of: transcript.speakerLabels.revision) { old, new in
      guard new > old, !superseded else { return }
      AccessibilityNotification.Announcement(MeetingsPresentation.liveSpeakersUpdated).post()
    }
  }

  private func styledLiveText(
    _ text: Text, kind: LiveWordsAssembler.Line.Kind
  ) -> some View {
    text
      .font(.stBody)
      .italic(kind == .uncertain)
      .foregroundStyle(
        superseded || kind != .confirmed ? Color.stTextSecondary : Color.stTextPrimary
      )
      .textSelection(.enabled)
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
          || !CallMicrophoneWatcher.isSupported
      )
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
