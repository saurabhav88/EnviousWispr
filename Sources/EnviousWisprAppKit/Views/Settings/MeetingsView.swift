import AVFoundation
import EnviousWisprCore
import EnviousWisprLLM
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
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    if settings.meetingOnboardingComplete {
      settingsPage
    } else {
      // #4017 O1: EnviousMeet is locked until its setup is finished.
      ScrollView { MeetingOnboardingView() }
    }
  }

  private var settingsPage: some View {
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
          MeetingWriteSummaryRow()
          summaryWriterRow
          MeetingCalendarNamesRow()
          microphonePermissionRow
          callSoundPermissionRow
          calendarPermissionRow
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
          MeetingConsentNote()
      } footnote: {
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
  static let writeSummaryTitle = LocalizedStringResource(
    "Write a summary when a meeting ends",
    comment: "EnviousMeet page: switch that writes a summary of each meeting automatically.")
  static let writeSummaryShort = LocalizedStringResource(
    "Your AI Polish provider writes a summary of each meeting.",
    comment: "EnviousMeet page: the short line under Write a summary when a meeting ends.")
  static let writeSummaryHelp = LocalizedStringResource(
    "The summary is written from the transcript and your notes by your AI Polish provider. OpenAI, Gemini and Claude receive them under your key. An Ollama hosted model sends them to Ollama's servers. Apple Intelligence and Ollama models on this Mac keep them on your Mac. Turning this off does not stop a summary that has already started. In History you can write a summary for any meeting that has a transcript.",
    comment: "EnviousMeet page: help for Write a summary when a meeting ends.")
  static let calendarNamesTitle = LocalizedStringResource(
    "Name meetings from my calendar",
    comment: "EnviousMeet page: switch that names a meeting after the calendar event at its start.")
  static let calendarNamesShort = LocalizedStringResource(
    "Uses the title of the calendar event at the time the meeting starts.",
    comment: "EnviousMeet page: the short line under Name meetings from my calendar.")
  static let calendarNamesHelp = LocalizedStringResource(
    "When a meeting starts, EnviousMeet looks for the calendar event at that time and uses its title. If several events overlap, it prefers one with a meeting link or a place, and otherwise keeps the date as the name. Your calendar is read on your Mac and never changed. You can rename any meeting in History.",
    comment: "EnviousMeet page: help for Name meetings from my calendar.")
  static let callSoundHelp = LocalizedStringResource(
    "With headphones, your microphone hears only you, and the call comes from the sound your Mac plays. Without headphones, your microphone also hears the call; EnviousMeet hides those repeated lines as probable echo. The choice applies to the next meeting you start.",
    comment: "EnviousMeet page: help for Also record the call sound.")
}
