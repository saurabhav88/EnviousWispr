import AVFoundation
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import SwiftUI

/// The EnviousMeet page (#3972 §3.8, R34, founder F18): EnviousMeet's settings, in tabs since
/// #4058. Recordings live in History (Meetings), and recording is managed from the menu bar and
/// History, so this page never shows a recording. It still shows the call-sound explainer, because a first
/// call-sound Start from the menu brings this page forward to explain it.
struct MeetingsView: View {
  @Binding var selection: MeetingsTab
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(PermissionsService.self) private var permissions
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    if settings.meetingOnboardingComplete {
      settingsPage
    } else {
      // #4017 O1: EnviousMeet is locked until its setup is finished. The setup sits in the
      // same page frame and header panel as every settings page.
      SettingsContentView {
        BrandedPanel(
          icon: "person.2.wave.2", header: "EnviousMeet", description: MeetingsCopy.pageDescription
        ) {
          MeetingOnboardingView()
        }
      }
    }
  }

  /// #4058: the settings in tabs (#3973 PR B added Models), drawn like Dictation Settings and App Settings. The
  /// call-sound explainer and the notice banner sit above the tab strip, so they show on every
  /// tab (the banner can carry the microphone fix).
  private var settingsPage: some View {
    GeometryReader { pane in
      VStack(spacing: 0) {
        if startFlow.pendingExplainer != nil || meetings.notice != nil {
          VStack(alignment: .leading, spacing: 10) {
            if startFlow.pendingExplainer != nil {
              MeetingCallSoundExplainer()
            }
            if let notice = meetings.notice {
              MeetingNoticeBanner(notice: notice)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, SettingsLayout.contentH)
          .padding(.top, SettingsLayout.contentTop)
        }
        SettingsTabStrip(
          items: MeetingsTab.allCases.map {
            SettingsTabItem(id: $0, icon: $0.icon, label: $0.label, map: $0.mapID)
          }, selection: $selection
        )
        .frame(width: max(0, pane.size.width - 2 * (SettingsLayout.contentH - 4)))
        .padding(.horizontal, SettingsLayout.contentH - 4)
        .padding(.top, SettingsLayout.contentTop - 6)
        // Each tab keeps its own scroll view, so no outer one here.
        tabContent.frame(width: pane.size.width)
          // #3545: the tab drawn here, carried by every control inside it.
          .environment(
            \.settingsArrivalContent,
            SettingsArrivalContent(page: .meetings, meetingsTab: selection))
      }
      .frame(width: pane.size.width, height: pane.size.height)
    }
    .background(Color.stPageBg)
    .environment(\.settingsPR1Density, true)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selection {
    case .general: generalTab
    case .models: modelsTab
    case .callApps: callAppsTab
    case .permissions: permissionsTab
    }
  }

  private var generalTab: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 16) {
        BrandedSection {
          BrandedRow { MeetingCallDetectionRow() }
          BrandedRow { MeetingCallSoundRow() }
          BrandedRow { MeetingWriteSummaryRow() }
          BrandedRow { MeetingTurnsOffDictationRow() }
          BrandedRow { MeetingFollowsCallMuteRow() }
          BrandedRow(showDivider: false) { MeetingCalendarNamesRow() }
        }
        VStack(alignment: .leading, spacing: 8) {
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
          MeetingConsentNote()
          // R48: true for every provider. Audio never leaves the Mac; a summary by a cloud model
          // (OpenAI, Gemini, Claude, or an Ollama hosted model) sends its provider the transcript
          // and notes.
          Text(
            "Works with any headphones. Recordings stay on your Mac. A summary written by a cloud model sends the transcript and your notes to its provider.",
            comment:
              "EnviousMeet page: the footnote. Recordings are kept on the Mac; a cloud model's provider receives the text of a summary."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
      }
    }
  }

  /// #3973 PR B: every model choice on one tab (founder 2026-10-27): live words and the
  /// transcript's language in one section (#4105), and who writes summaries.
  private var modelsTab: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 16) {
        BrandedSection {
          BrandedRow { MeetingLiveWordsRow() }
          BrandedRow { MeetingTranscriptEngineRow() }
          BrandedRow(showDivider: false) { MeetingTranscriptLanguageRow() }
        }
        BrandedSection {
          BrandedRow(showDivider: false) { summaryWriterRow }
        }
      }
    }
  }

  private var callAppsTab: some View {
    SettingsContentView {
      BrandedSection {
        BrandedRow(showDivider: false) { MeetingCallAppsRow() }
      }
    }
  }

  private var permissionsTab: some View {
    SettingsContentView {
      BrandedSection {
        BrandedRow { microphonePermissionRow }
        BrandedRow { callSoundPermissionRow }
        BrandedRow { calendarPermissionRow }
        BrandedRow(showDivider: false) { accessibilityPermissionRow }
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

  /// Who writes the summaries (R34), from the AI Polish provider and model, with the AI Polish
  /// settings link when none can. A status line, not a setting: search does not land on it.
  fileprivate var summaryWriterRow: some View {
    let status = Self.summaryWriter(settings.llmProvider, model: settings.effectiveLLMModel)
    return SettingsRow(
      notInSettingsMap: .statusLine, icon: "sparkles",
      title: LocalizedStringResource(
        "Summaries", comment: "EnviousMeet page: the row that says who writes meeting summaries."),
      short: Self.summaryWriterLine(status),
      help: LocalizedStringResource(
        "Summaries use the AI Polish provider and model chosen in AI Polish settings.",
        comment: "EnviousMeet page: help for the row that says who writes meeting summaries.")
    ) {
      if case .problem = status {
        Button {
          navigation.request(.aiPolish)
        } label: {
          Text(
            "Open AI Polish settings",
            comment: "Link button that opens the AI Polish settings page.")
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("meetings.settings.openAIPolish")
      }
    }
  }

  enum SummaryWriter: Equatable {
    /// This provider can write summaries (whether it is ready is known only when one is written).
    case provider(LLMProvider)
    /// No summary can be written: no provider, or a cleanup model.
    case problem(MeetingSummaryOwner.Problem)
  }

  static func summaryWriter(_ provider: LLMProvider, model: String) -> SummaryWriter {
    switch MeetingSummary.capability(provider, model: model, ollamaModelIsRemote: nil) {
    case .noProvider: return .problem(.noProvider)
    case .notForSummaries: return .problem(.notForSummaries)
    case .supported: return .provider(provider)
    }
  }

  static func summaryWriterLine(_ status: SummaryWriter) -> LocalizedStringResource {
    switch status {
    case .provider(let provider):
      return LocalizedStringResource(
        "Written by \(provider.displayName).",
        comment: "EnviousMeet page: the AI Polish provider that writes meeting summaries, e.g. Ollama.")
    case .problem(.noProvider):
      return LocalizedStringResource(
        "No AI Polish provider is chosen, so no summary is written.",
        comment: "EnviousMeet page: no AI Polish provider is selected, so meetings get no summary.")
    case .problem:
      return LocalizedStringResource(
        "The selected AI Polish model can't write summaries.",
        comment: "EnviousMeet page: the selected cleanup model (EG-1, S1-mini) cannot summarize.")
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

  /// #4017: what macOS lets EnviousMeet read from the calendar, with the fix when it is not
  /// allowed. A status line, not a setting.
  fileprivate var calendarPermissionRow: some View {
    SettingsRow(
      notInSettingsMap: .statusLine, icon: "calendar",
      title: LocalizedStringResource(
        "Calendar", comment: "EnviousMeet page: the calendar permission row's title."),
      short: Self.calendarStatusLine(permissions.calendarStatus),
      help: LocalizedStringResource(
        "macOS asks for full calendar access. EnviousMeet only reads event titles, times and meeting links to name your meetings, and never changes your calendar.",
        comment: "EnviousMeet page: help for the calendar permission row.")
    ) {
      if permissions.calendarStatus == .denied {
        Button {
          permissions.openCalendarSettings()
        } label: {
          Text(
            "Open System Settings",
            comment: "EnviousMeet: opens the macOS privacy setting for calendar access.")
        }
        .accessibilityIdentifier("meetings.settings.calendarSettings")
      }
    }
  }

  /// #4012: call detection reads which call or meeting page is open through Accessibility,
  /// the permission paste already uses. Without it no call is noticed. A status line.
  fileprivate var accessibilityPermissionRow: some View {
    SettingsRow(
      notInSettingsMap: .statusLine, icon: "accessibility",
      title: LocalizedStringResource(
        "Accessibility", comment: "EnviousMeet page: the Accessibility permission row's title."),
      short: permissions.accessibilityGranted
        ? LocalizedStringResource(
          "Allowed. EnviousMeet can notice when a call starts.",
          comment: "EnviousMeet page: Accessibility is allowed, so calls are noticed.")
        : LocalizedStringResource(
          "Not allowed. EnviousMeet can't notice calls until you allow it.",
          comment: "EnviousMeet page: without Accessibility, calls are not noticed."),
      help: LocalizedStringResource(
        "EnviousMeet uses Accessibility to see whether a call window or meeting page is open when an app starts using your microphone. In Zoom, Teams and Meet calls, it also reads who is talking, so a meeting can show people's names instead of numbered speakers when it can tell them apart. It also sees when you're muted in those calls. It reads this on your Mac and never sends it to Envious Labs. Allow it before a call starts. Pasting your dictation uses the same permission.",
        comment: "EnviousMeet page: help for the Accessibility permission row.")
    ) {
      if !permissions.accessibilityGranted {
        Button {
          _ = permissions.requestAccessibilityAccess()
        } label: {
          Text(
            "Allow Accessibility",
            comment: "EnviousMeet: asks macOS for Accessibility access for call detection.")
        }
        .accessibilityIdentifier("meetings.settings.allowAccessibility")
      }
    }
  }

  static func calendarStatusLine(_ status: CalendarAccess.Status) -> LocalizedStringResource {
    switch status {
    case .granted:
      return LocalizedStringResource("Allowed", comment: "EnviousMeet page: calendar access is allowed.")
    case .denied:
      return LocalizedStringResource(
        "Turned off. Allow it in System Settings.", comment: "EnviousMeet page: calendar access was refused.")
    case .notAsked:
      return LocalizedStringResource(
        "Not asked yet. Turn on Name meetings from my calendar to ask.",
        comment: "EnviousMeet page: macOS has not asked for calendar access yet.")
    case .unavailable:
      return LocalizedStringResource(
        "Not available on this Mac.", comment: "EnviousMeet page: calendar access is blocked by a device profile.")
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
    "Record a meeting", comment: "EnviousMeet: the button that starts a meeting recording.")
  static let whereRecordingsLive = LocalizedStringResource(
    "Start and stop a recording from the menu bar. Your recordings are in History.",
    comment: "EnviousMeet page: where recording is controlled and where recordings are.")
  static let keptUntilDeleted = LocalizedStringResource(
    "Each recording keeps its audio until you delete it. Delete the audio alone to keep the transcript.",
    comment: "EnviousMeet page: how long recordings and their audio are kept.")
  static let showRecordings = LocalizedStringResource(
    "Show recordings",
    comment: "EnviousMeet page: opens History with the Meetings filter.")
  static let callSoundTitle = LocalizedStringResource(
    "Record only my voice",
    comment: "EnviousMeet page: switch that leaves out what the Mac plays, like a call, and records only the microphone.")
  static let callSoundShort = LocalizedStringResource(
    "Leaves out the sound your Mac plays, like the other people on a call.",
    comment: "EnviousMeet page: the short line under Record only my voice.")
  static let writeSummaryTitle = LocalizedStringResource(
    "Write a summary when a meeting ends",
    comment: "EnviousMeet page: switch that writes a summary of each meeting automatically.")
  static let writeSummaryShort = LocalizedStringResource(
    "Your AI Polish provider writes a summary of each meeting.",
    comment: "EnviousMeet page: the short line under Write a summary when a meeting ends.")
  static let writeSummaryHelp = LocalizedStringResource(
    "The summary is written from the transcript and your notes by your AI Polish provider. OpenAI, Gemini and Claude receive them under your key. An Ollama hosted model sends them to Ollama's servers. Apple Intelligence and Ollama models on this Mac keep them on your Mac. Turning this off does not stop a summary that has already started. In History you can write a summary for any meeting that has a transcript.",
    comment: "EnviousMeet page: help for Write a summary when a meeting ends.")
  static let turnsOffDictationTitle = LocalizedStringResource(
    "Turn off dictation during meetings",
    comment: "EnviousMeet page: switch that makes the dictation key record nothing while a meeting records.")
  static let turnsOffDictationShort = LocalizedStringResource(
    "The dictation key records nothing while a meeting is recording.",
    comment: "EnviousMeet page: the short line under Turn off dictation during meetings.")
  static let turnsOffDictationHelp = LocalizedStringResource(
    "Dictation is off during meetings. Turn it back on in EnviousMeet settings. A dictation that already started before the meeting finishes normally.",
    comment: "EnviousMeet page: help for Turn off dictation during meetings. The founder's sentence (#4069).")
  // #4248: follow the call app's mute button.
  static let followsCallMuteTitle = LocalizedStringResource(
    "Leave my voice out when I'm muted",
    comment: "EnviousMeet page: switch that leaves the user's microphone out of the meeting while the call app shows them muted.")
  static let followsCallMuteShort = LocalizedStringResource(
    "Follows the mute button in supported Zoom, Teams and Google Meet calls.",
    comment: "EnviousMeet page: the short line under Leave my voice out when I'm muted.")
  static let followsCallMuteHelp = LocalizedStringResource(
    "Follows the mute button in supported Zoom, Teams and Google Meet calls. Brief audio around mute changes may be kept or omitted. While EnviousMeet checks your mute state, or cannot read it, your voice is recorded as usual.",
    comment: "EnviousMeet page: help for Leave my voice out when I'm muted (#4248 plan section 3.4).")
  // #4105: Live words and Transcript language.
  static let liveWordsTitle = LocalizedStringResource(
    "Live words",
    comment: "EnviousMeet page: row that picks the engine and language for the words shown while a meeting records. German: Live-Transkript.")
  static let liveWordsShort = LocalizedStringResource(
    "The engine and language for words shown while a meeting records.",
    comment: "EnviousMeet page: the short line under Live words.")
  static let liveWordsHelp = LocalizedStringResource(
    "Live words show what is said into your microphone and in the call while a meeting records. Apple uses this Mac's speech recognition and needs macOS 26 and a download for each language. Universal works on any supported Mac and needs one download. Nothing downloads until you press Download, and Download here is off while a meeting records or is being transcribed. The full transcript is written after the meeting and does not depend on live words.",
    comment: "EnviousMeet page: help for Live words.")
  static let chooseEngine = LocalizedStringResource(
    "Choose an engine",
    comment: "EnviousMeet page, Live words: the engine menu before an engine is chosen.")
  static let appleNotOnThisMac = LocalizedStringResource(
    "Apple (not on this Mac)",
    comment: "EnviousMeet page, Live words: the Apple engine in the engine menu when this Mac cannot run it (macOS 26 needed). Apple is a product name.")
  static let chooseLanguage = LocalizedStringResource(
    "Choose a language",
    comment: "EnviousMeet page, Live words: the language menu before a language is chosen.")
  static let liveWordsChecking = LocalizedStringResource(
    "Checking",
    comment: "EnviousMeet page, Live words: while the app reads which languages this Mac has.")
  static let liveWordsNotSetUp = LocalizedStringResource(
    "Not set up yet.",
    comment: "EnviousMeet page, Live words: no engine and language are chosen.")
  static func liveWordsSuggested(_ language: String) -> String {
    String(
      localized: "Not set up yet. Download \(language) to start.",
      comment: "EnviousMeet page, Live words: nothing chosen yet; the placeholder is the language the app suggests from dictation's language.")
  }
  static func liveWordsNotDownloaded(_ language: String) -> String {
    String(
      localized: "\(language) is not downloaded.",
      comment: "EnviousMeet page, Live words: the chosen language's model is not on this Mac. The placeholder is a language name.")
  }
  static func liveWordsDownloading(_ language: String) -> String {
    String(
      localized: "Downloading \(language)",
      comment: "EnviousMeet page, Live words: the chosen language's model is downloading. The placeholder is a language name.")
  }
  static let liveWordsFailed = LocalizedStringResource(
    "The download did not finish.",
    comment: "EnviousMeet page, Live words: the last download of the chosen language failed; Try Again is beside it.")
  static let liveWordsDownloadUnavailable = LocalizedStringResource(
    "Download is not available right now.",
    comment: "EnviousMeet page, Live words: the Universal engine download could not start (it is turned off for this version).")
  static let liveWordsAppleUnavailable = LocalizedStringResource(
    "Apple's meeting speech is not available on this Mac. Choose Universal.",
    comment: "EnviousMeet page, Live words: Apple was chosen but this Mac cannot run it (macOS 26 needed).")
  static let transcriptLanguageTitle = LocalizedStringResource(
    "Transcript language",
    comment: "EnviousMeet page: row that picks the language of the full meeting transcript.")
  static let transcriptLanguageShort = LocalizedStringResource(
    "The language of the full transcript written after a meeting.",
    comment: "EnviousMeet page: the short line under Transcript language.")
  static let transcriptLanguageHelp = LocalizedStringResource(
    "With Auto, no language is set and the engine transcribes as it does by default. Choose a language when your meetings are always in it. A change applies to the next meeting; a meeting already recorded keeps its language. Transcribe again uses the language chosen here at that moment.",
    comment: "EnviousMeet page: help for Transcript language. Auto sets no language; it does not detect one. Transcribe again is the button on a meeting's page that writes its transcript again.")
  /// #3973 C3: the language chosen here is one the transcript engine cannot decode.
  static func transcriptLanguageUnsupported(language: String, engine: String) -> String {
    String(
      localized:
        "\(language) is not supported by \(engine). The transcript uses Auto.",
      comment:
        "EnviousMeet page, Transcript language row: the chosen language (first value) is not one the chosen transcript engine (second value, Parakeet or Whisper) can transcribe, so meetings are transcribed with Auto (no language set).")
  }

  // MARK: #3973 C3: Transcript engine

  static let transcriptEngineTitle = LocalizedStringResource(
    "Transcript engine",
    comment: "EnviousMeet page, Models tab: row that picks the speech engine that writes the full meeting transcript.")
  static let transcriptEngineShort = LocalizedStringResource(
    "Chooses the engine that writes the full transcript after a meeting.",
    comment: "EnviousMeet page: the short line under Transcript engine.")
  static let transcriptEngineHelp = LocalizedStringResource(
    "Changes apply to new meetings. Use Transcribe again to replace a saved transcript.",
    comment: "EnviousMeet page: help for Transcript engine. Transcribe again is the button on a meeting's page that writes its transcript again.")
  static let engineParakeet = LocalizedStringResource(
    "Parakeet",
    comment: "EnviousMeet page, Transcript engine menu: the Parakeet speech engine. A product name; keep it.")
  static let engineWhisper = LocalizedStringResource(
    "Whisper Large v3 Turbo",
    comment: "EnviousMeet page, Transcript engine menu: the Whisper speech model. A product name; keep it.")
  static let whisperNotDownloaded = LocalizedStringResource(
    "Whisper Large v3 Turbo needs an 886 MB download before meetings can use it.",
    comment: "EnviousMeet page, Transcript engine row: Whisper is not downloaded yet. The same download serves dictation.")
  static let whisperDownloading = LocalizedStringResource(
    "Downloading Whisper Large v3 Turbo…",
    comment: "EnviousMeet page, Transcript engine row: the Whisper download is running.")
  static let whisperPaused = LocalizedStringResource(
    "Download paused. Resume anytime.",
    comment: "EnviousMeet page, Transcript engine row: the Whisper download was cancelled and can resume.")
  static let whisperFailed = LocalizedStringResource(
    "The Whisper download did not finish.",
    comment: "EnviousMeet page, Transcript engine row: the Whisper download failed.")
  static let whisperGone = LocalizedStringResource(
    "Whisper is no longer available. Choose another engine.",
    comment: "EnviousMeet page, Transcript engine row: Whisper is chosen but its model is gone; meetings use Parakeet until it is back.")
  static let warningWhisperMeeting = LocalizedStringResource(
    "EnviousMeet uses Whisper and dictation uses Parakeet. Dictating during a meeting can load both engines and slow down your Mac.",
    comment: "EnviousMeet page, Transcript engine row: warning when meetings and dictation use different speech engines.")
  static let warningParakeetMeeting = LocalizedStringResource(
    "EnviousMeet uses Parakeet and dictation uses Whisper. Dictating during a meeting can load both engines and slow down your Mac.",
    comment: "EnviousMeet page, Transcript engine row: warning when meetings and dictation use different speech engines.")
  static let usedParakeetFallback = LocalizedStringResource(
    "Used Parakeet because Whisper was unavailable.",
    comment: "EnviousMeet meeting page: the transcript was written by Parakeet because the chosen Whisper model was missing or turned off.")
  /// The transcript menu's Auto: no language is set (Parakeet's Auto sets no language hint; it
  /// does not detect the language), so the label never promises detection.
  static let transcriptLanguageAuto = LocalizedStringResource(
    "Auto",
    comment: "EnviousMeet page, Transcript language: the menu item that sets no language.")
  static let languagesDiffer = LocalizedStringResource(
    "Live words and the transcript use different languages.",
    comment: "EnviousMeet page: note under Transcript language when its language is not the live words language. It does not block either choice.")
  static let calendarNamesTitle = LocalizedStringResource(
    "Name meetings from my calendar",
    comment: "EnviousMeet page: switch that names a meeting after the calendar event at its start.")
  static let calendarNamesShort = LocalizedStringResource(
    "Uses the title of the calendar event at the time the meeting starts.",
    comment: "EnviousMeet page: the short line under Name meetings from my calendar.")
  static let calendarNamesHelp = LocalizedStringResource(
    "When a meeting starts, EnviousMeet looks for the calendar event at that time and uses its title. If several events overlap, it prefers one with a meeting link or a place, and otherwise keeps the date as the name. Your calendar is read on your Mac and never changed. You can rename any meeting in History.",
    comment: "EnviousMeet page: help for Name meetings from my calendar.")
  static let callDetectionTitle = LocalizedStringResource(
    "When a call starts",
    comment: "EnviousMeet page: the choice of what happens when a call app starts a call.")
  static let callDetectionShort = LocalizedStringResource(
    "EnviousMeet can ask to record when a call app starts using your microphone.",
    comment: "EnviousMeet page: the short line under When a call starts.")
  static let callDetectionHelp = LocalizedStringResource(
    "Ask offers to record when a call app uses the microphone. Start by itself can record without asking. Off disables call prompts and automatic recording. A recording you start manually can still be linked to an already detected call. Confirmed endings in the native Zoom or Teams app show a 10-second countdown with Keep recording. For uncertain browser endings, recording continues unless you choose Stop recording. Call detection never auto-stops an unlinked recording.",
    comment: "EnviousMeet page: help for When a call starts.")
  static func callDetectionChoice(_ mode: CallDetectionPolicy.Mode) -> LocalizedStringResource {
    switch mode {
    case .ask:
      LocalizedStringResource("Ask", comment: "EnviousMeet page: When a call starts, ask to record.")
    case .startByItself:
      LocalizedStringResource(
        "Start by itself",
        comment: "EnviousMeet page: When a call starts, start recording without asking.")
    case .off:
      LocalizedStringResource("Off", comment: "EnviousMeet page: When a call starts, do nothing.")
    }
  }
  static let callDetectionNeedsNewerMacOS = LocalizedStringResource(
    "Noticing calls needs macOS 14.2 or later. You can still start recordings from the menu bar.",
    comment: "EnviousMeet page: below macOS 14.2 call detection cannot run.")
  static let callAppsTitle = LocalizedStringResource(
    "Notice calls in",
    comment: "EnviousMeet page: the list of call apps EnviousMeet watches, each with a switch.")
  static let callAppsShort = LocalizedStringResource(
    "Turn off an app to never be asked about its calls.",
    comment: "EnviousMeet page: the short line under Notice calls in.")
  static let callAppsHelp = LocalizedStringResource(
    "EnviousMeet checks which app uses your microphone and whether a call window or meeting page is open. It checks on your Mac and never sends this anywhere. Meetings in a browser covers Google Meet, Zoom, Microsoft Teams, Webex, Whereby and Jitsi in Chrome, Safari, Arc, Dia, Edge, Brave, Opera, Vivaldi, Zen, Comet and ChatGPT Atlas.",
    comment: "EnviousMeet page: help for Notice calls in. App and browser names are not translated.")
  static let browserMeetings = LocalizedStringResource(
    "Meetings in a browser",
    comment: "EnviousMeet page: the switch for meetings in any web browser, like Google Meet in Chrome.")
  static let browserMeetingsDetail = LocalizedStringResource(
    "Google Meet, Zoom, Teams, Webex and more, in Chrome, Safari, Arc and other browsers.",
    comment: "EnviousMeet Call Apps tab: the grey line under Meetings in a browser. App and browser names are not translated.")
  static let callAppsPrivacy = LocalizedStringResource(
    "EnviousMeet checks for calls on your Mac and never sends this anywhere.",
    comment: "EnviousMeet Call Apps tab: the privacy line under the list of call apps.")
  static let callSoundHelp = LocalizedStringResource(
    "Off records your microphone and the sound your Mac plays, so the other people on a call are in the transcript. On records only your microphone. Without headphones, your microphone still hears the call through your speakers. The choice applies to the next meeting you start.",
    comment: "EnviousMeet page: help for Record only my voice.")
  /// #4058: the order the call choices are shown in. Display only; stored values keep the
  /// `CallDetectionPolicy.Mode` raw values.
  static let callDetectionDisplayOrder: [CallDetectionPolicy.Mode] = [.off, .ask, .startByItself]
}
