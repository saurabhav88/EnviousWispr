import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// App Settings > Recordings (#3147 PR1 §3.1): save new dictation recordings, how long dictation
/// and meeting audio stay, how much disk recordings use, the storage warning threshold, and
/// deleting audio while keeping text. Audio never leaves this Mac.
///
/// A shorter keep period is never written by the picker: it is staged through
/// `RecordingRetention.stage`, shown with its count, and applied only by Apply (Cancel or leaving
/// the page drops it). Usage and warnings come from `RecordingUsage.latest` and
/// `RecordingRetention.warning`, refreshed when the page opens and after each action; the page
/// reads no files itself.
struct RecordingsSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(RecordingRetention.self) private var retention: RecordingRetention?
  @Environment(RecordingUsage.self) private var usage: RecordingUsage?
  @Environment(TranscriptCoordinator.self) private var transcripts: TranscriptCoordinator?
  @Environment(MeetingCoordinator.self) private var meetings: MeetingCoordinator?

  @State private var confirmingDictationDeletion = false
  @State private var confirmingMeetingDeletion = false
  @State private var deletionResult: String?
  @State private var deleting = false
  @State private var preview = RetentionPreviewRequest()

  var body: some View {
    @Bindable var settings = settings
    SettingsContentView {
      VStack(alignment: .leading, spacing: DesignSpacing.lg) {
        SettingsSectionHeading(map: .id(.sectionRecordings))
        BrandedSection {
          BrandedRow {
            SettingsRow(
              map: .id(.saveDictationRecordings), icon: "waveform",
              resolvedHelp: RecordingsSettingsCopy.saveHelp
            ) {
              Toggle("", isOn: $settings.saveDictationRecordings)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(Text(RecordingsSettingsCopy.saveTitle))
            }
          }
          BrandedRow {
            SettingsRow(
              map: .id(.dictationRecordingRetention), icon: "clock.arrow.circlepath",
              resolvedHelp: RecordingsSettingsCopy.keepHelp
            ) {
              Picker(
                RecordingsSettingsCopy.keepDictationsTitle,
                selection: Binding(
                  get: { settings.dictationRecordingRetention },
                  set: { choose(.dictations($0)) })
              ) {
                ForEach(DictationRecordingRetention.allCases, id: \.self) { value in
                  Text(RecordingsSettingsCopy.label(value)).tag(value)
                }
              }
              .labelsHidden()
              .settingsArrivalFocusControl()
              .accessibilityLabel(Text(RecordingsSettingsCopy.keepDictationsTitle))
              .tint(.stAccent)
              .controlSize(.large)
              .fixedSize()
            }
            .rowStatus { stagedStatus(for: .dictations) }
          }
          BrandedRow(showDivider: false) {
            SettingsRow(
              map: .id(.meetingRecordingRetention), icon: "person.2.wave.2",
              resolvedHelp: RecordingsSettingsCopy.keepMeetingsHelp
            ) {
              Picker(
                RecordingsSettingsCopy.keepMeetingsTitle,
                selection: Binding(
                  get: { settings.meetingRecordingRetention },
                  set: { choose(.meetings($0)) })
              ) {
                ForEach(MeetingRecordingRetention.allCases, id: \.self) { value in
                  Text(RecordingsSettingsCopy.label(value)).tag(value)
                }
              }
              .labelsHidden()
              .settingsArrivalFocusControl()
              .accessibilityLabel(Text(RecordingsSettingsCopy.keepMeetingsTitle))
              .tint(.stAccent)
              .controlSize(.large)
              .fixedSize()
            }
            .rowStatus { stagedStatus(for: .meetings) }
          }
        }

        SettingsSectionHeading(map: .id(.sectionRecordingStorage))
        BrandedSection {
          BrandedRow {
            SettingsRow(
              map: .id(.recordingStorageUsage), icon: "internaldrive",
              runtimeShort: RecordingsSettingsCopy.usageSummary(usage?.latest),
              resolvedHelp: RecordingsSettingsCopy.usageHelp
            ) {
              EmptyView()
            }
            .rowStatus {
              VStack(alignment: .leading, spacing: DesignSpacing.sm) {
                ForEach(RecordingsSettingsCopy.usageLines(usage?.latest), id: \.self) { line in
                  Text(verbatim: line)
                    .font(.stRowHelper)
                    .foregroundStyle(.stTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = retention?.warning {
                  InsetNotice(
                    verbatim: RecordingStorageWarningCopy.text(warning),
                    systemImage: "exclamationmark.triangle", tint: .stWarning)
                }
              }
            }
          }
          BrandedRow {
            SettingsRow(
              map: .id(.recordingStorageWarningThreshold), icon: "gauge.with.dots.needle.50percent",
              resolvedHelp: RecordingsSettingsCopy.thresholdHelp
            ) {
              Picker(
                RecordingsSettingsCopy.thresholdTitle,
                selection: $settings.recordingStorageWarningThreshold
              ) {
                ForEach(RecordingStorageWarningThreshold.allCases, id: \.self) { value in
                  Text(RecordingsSettingsCopy.label(value)).tag(value)
                }
              }
              .labelsHidden()
              .settingsArrivalFocusControl()
              .accessibilityLabel(Text(RecordingsSettingsCopy.thresholdTitle))
              .tint(.stAccent)
              .controlSize(.large)
              .fixedSize()
            }
          }
          BrandedRow {
            SettingsRow(
              map: .id(.recordingThresholdBehavior), icon: "arrow.uturn.down.circle",
              resolvedHelp: RecordingsSettingsCopy.behaviorHelp
            ) {
              Picker(
                RecordingsSettingsCopy.behaviorTitle,
                selection: $settings.recordingThresholdBehavior
              ) {
                ForEach(RecordingThresholdBehavior.allCases, id: \.self) { value in
                  Text(RecordingsSettingsCopy.label(value)).tag(value)
                }
              }
              .labelsHidden()
              .settingsArrivalFocusControl()
              .accessibilityLabel(Text(RecordingsSettingsCopy.behaviorTitle))
              .tint(.stAccent)
              .controlSize(.large)
              .fixedSize()
              .disabled(settings.recordingStorageWarningThreshold == .none)
            }
          }
          BrandedRow(showDivider: false) {
            SettingsRow(
              map: .id(.deleteRecordings), icon: "trash",
              resolvedHelp: RecordingsSettingsCopy.deleteHelp
            ) {
              EmptyView()
            }
            .rowStatus {
              VStack(alignment: .leading, spacing: DesignSpacing.md) {
                ViewThatFits(in: .horizontal) {
                  HStack(spacing: DesignSpacing.md) { deleteButtons }
                  VStack(alignment: .leading, spacing: DesignSpacing.md) { deleteButtons }
                }
                if let deletionResult {
                  Text(verbatim: deletionResult)
                    .font(.stRowHelper)
                    .foregroundStyle(.stTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
          }
        }
      }
    }
    .onAppear { retention?.refresh() }
    .onDisappear { preview.cancel(on: retention) }
    .confirmationDialog(
      Text(RecordingsSettingsCopy.confirmDictationsTitle),
      isPresented: $confirmingDictationDeletion, titleVisibility: .visible
    ) {
      Button(role: .destructive) {
        deleteAllDictationRecordings()
      } label: {
        Text(RecordingsSettingsCopy.deleteDictationsAction)
      }
    } message: {
      Text(RecordingsSettingsCopy.confirmDictationsMessage)
    }
    .confirmationDialog(
      Text(RecordingsSettingsCopy.confirmMeetingsTitle),
      isPresented: $confirmingMeetingDeletion, titleVisibility: .visible
    ) {
      Button(role: .destructive) {
        deleteAllMeetingAudio()
      } label: {
        Text(RecordingsSettingsCopy.deleteMeetingsAction)
      }
    } message: {
      Text(RecordingsSettingsCopy.confirmMeetingsMessage)
    }
  }

  @ViewBuilder
  private var deleteButtons: some View {
    Button(role: .destructive) {
      confirmingDictationDeletion = true
    } label: {
      EnviousButtonLabel(RecordingsSettingsCopy.deleteDictationsAction, size: .medium)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: !deleting && transcripts?.recordings != nil)
    .settingsMapRegistration(.deleteAllDictationRecordings)
    Button(role: .destructive) {
      confirmingMeetingDeletion = true
    } label: {
      EnviousButtonLabel(RecordingsSettingsCopy.deleteMeetingsAction, size: .medium)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: !deleting && meetings != nil)
    .settingsMapRegistration(.deleteAllMeetingAudio)
  }

  /// The staged shorter keep period for one picker: its count, then Apply or Cancel.
  @ViewBuilder
  private func stagedStatus(for kind: RetentionKind) -> some View {
    if let staged = retention?.staged, kind.matches(staged.change) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        Text(verbatim: RecordingsSettingsCopy.preview(staged))
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: DesignSpacing.md) {
          Button(role: .destructive) {
            retention?.commitStaged()
          } label: {
            EnviousButtonLabel(RecordingsSettingsCopy.apply, size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
          Button {
            preview.cancel(on: retention)
          } label: {
            EnviousButtonLabel(RecordingsSettingsCopy.cancel, size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
    }
  }

  enum RetentionKind {
    case dictations
    case meetings

    func matches(_ change: RecordingRetention.RetentionChange) -> Bool {
      switch (self, change) {
      case (.dictations, .dictations), (.meetings, .meetings): true
      default: false
      }
    }
  }

  /// A longer period or "until I delete" applies at once; a shorter one is staged for Apply.
  private func choose(_ change: RecordingRetention.RetentionChange) {
    guard let retention else { return }
    preview.choose(change, on: retention)
  }

  private func deleteAllDictationRecordings() {
    guard let recordings = transcripts?.recordings else { return }
    deleting = true
    deletionResult = nil
    Task {
      let result = await recordings.deleteAllRecordingsKeepingText()
      deletionResult = RecordingsSettingsCopy.dictationDeletionResult(result)
      deleting = false
      retention?.refresh()
    }
  }

  private func deleteAllMeetingAudio() {
    guard let meetings else { return }
    deleting = true
    deletionResult = nil
    Task {
      let result = await meetings.deleteAllAudio()
      deletionResult = RecordingsSettingsCopy.meetingDeletionResult(result)
      deleting = false
      retention?.refresh()
    }
  }
}

/// The page's one pending keep-period preview. Every new choice, Cancel and leaving the page
/// cancel the previous request and drop any staged change at once, so a count that had not
/// started yet, or is still running, can never bring an abandoned preview back.
@MainActor
final class RetentionPreviewRequest {
  private var task: Task<Void, Never>?

  /// Returns the earlier request this choice cancelled, so a caller (a test) can await it.
  @discardableResult
  func choose(
    _ change: RecordingRetention.RetentionChange, on retention: RecordingRetention
  ) -> Task<Void, Never>? {
    let cancelled = cancel(on: retention)
    guard retention.isShortening(change) else {
      retention.applyWithoutPreview(change)
      return cancelled
    }
    task = Task { [weak retention] in
      guard !Task.isCancelled, let retention else { return }
      await retention.stage(change)
    }
    return cancelled
  }

  /// Cancels the pending request and drops any staged change. Returns the cancelled request.
  @discardableResult
  func cancel(on retention: RecordingRetention?) -> Task<Void, Never>? {
    let cancelled = task
    cancelled?.cancel()
    task = nil
    retention?.undoStaged()
    return cancelled
  }
}

/// The Recordings page's words, one owner for the view, the Settings Map and tests.
enum RecordingsSettingsCopy {
  static let recordingsSection = LocalizedStringResource(
    "Recordings",
    comment: "App Settings, Recordings: section heading for saving and keeping recordings.")
  static let storageSection = LocalizedStringResource(
    "Storage", comment: "App Settings, Recordings: section heading for disk use and deletion.")

  static let saveTitle = LocalizedStringResource(
    "Save dictation recordings", comment: "App Settings, Recordings: switch title.")
  static let saveShort = LocalizedStringResource(
    "Keep the audio of each new dictation on this Mac, so you can play it back.",
    comment: "App Settings, Recordings: short line under Save dictation recordings.")
  static var saveHelp: String {
    String(
      localized:
        "Recordings stay on this Mac and are never sent anywhere. Turning this off stops saving new dictations. Existing recordings still follow your keep period and storage settings.",
      comment: "App Settings, Recordings: help for Save dictation recordings.")
  }

  static let keepDictationsTitle = LocalizedStringResource(
    "Keep dictation recordings", comment: "App Settings, Recordings: picker title.")
  static let keepDictationsShort = LocalizedStringResource(
    "Choose how long to keep recordings. The text always stays.",
    comment: "App Settings, Recordings: short line under Keep dictation recordings.")
  static var keepHelp: String {
    String(
      localized:
        "A recording you mark Keep this recording in History is never removed automatically. Choosing a shorter period shows how many recordings it removes before anything changes.",
      comment: "App Settings, Recordings: help for Keep dictation recordings.")
  }

  static let keepMeetingsTitle = LocalizedStringResource(
    "Keep meeting audio", comment: "App Settings, Recordings: picker title.")
  static let keepMeetingsShort = LocalizedStringResource(
    "Meeting text, notes and summaries always stay.",
    comment: "App Settings, Recordings: short line under Keep meeting audio.")
  static var keepMeetingsHelp: String {
    String(
      localized:
        "Audio of a meeting that is recording or being transcribed is never removed. Without its audio, a meeting can't be transcribed again.",
      comment: "App Settings, Recordings: help for Keep meeting audio.")
  }

  static let usageTitle = LocalizedStringResource(
    "Storage used", comment: "App Settings, Recordings: row title for how much disk recordings use."
  )
  static var usageHelp: String {
    String(
      localized:
        "Counts dictation recordings and meeting audio on this Mac. Text, notes, summaries and crash recovery audio are not included.",
      comment: "App Settings, Recordings: help for Storage used.")
  }

  static let thresholdTitle = LocalizedStringResource(
    "Storage warning threshold",
    comment: "App Settings, Recordings: picker title. A warning, never a limit.")
  static let thresholdShort = LocalizedStringResource(
    "Get a warning when recordings use more than this.",
    comment: "App Settings, Recordings: short line under Storage warning threshold.")
  static var thresholdHelp: String {
    String(
      localized:
        "This is a warning, not a limit: EnviousWispr keeps recording past it.",
      comment: "App Settings, Recordings: help for Storage warning threshold.")
  }

  static let behaviorTitle = LocalizedStringResource(
    "Past the threshold",
    comment:
      "App Settings, Recordings: picker title for what happens over the storage warning threshold.")
  static let behaviorShort = LocalizedStringResource(
    "Ask you, or remove the oldest dictation recordings.",
    comment: "App Settings, Recordings: short line under Past the threshold.")
  static var behaviorHelp: String {
    String(
      localized:
        "Removing automatically only removes dictation recordings you did not keep, oldest first. Kept recordings and meeting audio are never removed, so they can keep storage above the threshold.",
      comment: "App Settings, Recordings: help for Past the threshold.")
  }

  static let deleteTitle = LocalizedStringResource(
    "Delete recordings", comment: "App Settings, Recordings: row title for the delete-all buttons.")
  static let deleteShort = LocalizedStringResource(
    "Text, meeting notes and summaries stay.",
    comment: "App Settings, Recordings: short line under Delete recordings.")
  static var deleteHelp: String {
    String(
      localized:
        "Deleting removes audio only, including recordings you marked to keep. It can't be undone.",
      comment: "App Settings, Recordings: help for Delete recordings.")
  }
  static let deleteDictationsAction = LocalizedStringResource(
    "Delete all dictation recordings", comment: "App Settings, Recordings: button.")
  static let deleteMeetingsAction = LocalizedStringResource(
    "Delete all meeting audio", comment: "App Settings, Recordings: button.")
  static let confirmDictationsTitle = LocalizedStringResource(
    "Delete all dictation recordings?", comment: "App Settings, Recordings: confirmation title.")
  static let confirmDictationsMessage = LocalizedStringResource(
    "Every dictation's audio is deleted, including kept recordings. The text stays. This can't be undone.",
    comment: "App Settings, Recordings: confirmation message.")
  static let confirmMeetingsTitle = LocalizedStringResource(
    "Delete all meeting audio?", comment: "App Settings, Recordings: confirmation title.")
  static let confirmMeetingsMessage = LocalizedStringResource(
    "Every meeting's audio is deleted. Meetings, their text, notes and summaries stay. A meeting that is recording or being transcribed keeps its audio. This can't be undone.",
    comment: "App Settings, Recordings: confirmation message.")

  static let apply = LocalizedStringResource(
    "Apply", comment: "App Settings, Recordings: applies a shorter keep period after its preview.")
  static let cancel = LocalizedStringResource(
    "Cancel", comment: "App Settings, Recordings: keeps the current keep period.")

  // MARK: - Choices

  static func label(_ value: DictationRecordingRetention) -> String {
    switch value {
    case .day1: String(localized: "1 day", comment: "App Settings, Recordings: keep period choice.")
    case .day7:
      String(localized: "7 days", comment: "App Settings, Recordings: keep period choice.")
    case .day30:
      String(localized: "30 days", comment: "App Settings, Recordings: keep period choice.")
    case .forever: untilDeleted
    }
  }

  static func label(_ value: MeetingRecordingRetention) -> String {
    switch value {
    case .day30:
      String(localized: "30 days", comment: "App Settings, Recordings: keep period choice.")
    case .day90:
      String(localized: "90 days", comment: "App Settings, Recordings: keep period choice.")
    case .forever: untilDeleted
    }
  }

  static var untilDeleted: String {
    String(
      localized: "Until I delete them",
      comment: "App Settings, Recordings: keep period choice with no automatic removal.")
  }

  static func label(_ value: RecordingStorageWarningThreshold) -> String {
    switch value {
    case .gb1:
      String(
        localized: "1 GB", comment: "App Settings, Recordings: storage warning threshold choice.")
    case .gb2:
      String(
        localized: "2 GB", comment: "App Settings, Recordings: storage warning threshold choice.")
    case .gb5:
      String(
        localized: "5 GB", comment: "App Settings, Recordings: storage warning threshold choice.")
    case .none:
      String(
        localized: "No warning",
        comment: "App Settings, Recordings: storage warning threshold choice: never warn.")
    }
  }

  static func label(_ value: RecordingThresholdBehavior) -> String {
    switch value {
    case .ask:
      String(
        localized: "Ask me to free space",
        comment: "App Settings, Recordings: threshold behavior choice.")
    case .removeOldestDictations:
      String(
        localized: "Remove oldest dictation recordings",
        comment: "App Settings, Recordings: threshold behavior choice.")
    }
  }

  // MARK: - Preview, usage and results

  static func preview(_ staged: RecordingRetention.RetentionPreview) -> String {
    let period: String
    switch staged.change {
    case .dictations(let value): period = label(value)
    case .meetings(let value): period = label(value)
    }
    guard let count = staged.recordingsToRemove else {
      return String(
        localized: "Keep for \(period)? The recordings this removes can't be counted right now.",
        comment: "App Settings, Recordings: preview of a shorter keep period. %@ is the period.")
    }
    switch count {
    case 0:
      return String(
        localized: "Keep for \(period)? No recording is old enough to be removed now.",
        comment: "App Settings, Recordings: preview of a shorter keep period. %@ is the period.")
    case 1:
      return String(
        localized: "Keep for \(period)? 1 recording is older and will be removed. Its text stays.",
        comment: "App Settings, Recordings: preview of a shorter keep period. %@ is the period.")
    default:
      return String(
        localized:
          "Keep for \(period)? \(count) recordings are older and will be removed. Their text stays.",
        comment:
          "App Settings, Recordings: preview of a shorter keep period. %1$@ is the period, %2$lld how many recordings, more than one."
      )
    }
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// The usage row's short line: the total, a lower bound, or why there is none.
  static func usageSummary(_ snapshot: RecordingUsageSnapshot?) -> String {
    guard let snapshot else {
      return String(localized: "Measuring…", comment: "App Settings, Recordings: storage use is being measured.")
    }
    guard let total = snapshot.totalBytes else {
      return String(
        localized: "Couldn't be fully measured",
        comment: "App Settings, Recordings: short line when part of the storage use could not be measured.")
    }
    if snapshot.isComplete {
      return String(
        localized: "About \(size(total)) in total",
        comment: "App Settings, Recordings: short line with the total disk used by recordings. %@ is a size.")
    }
    return String(
      localized: "At least \(size(total)) in total",
      comment: "App Settings, Recordings: short line with a lower bound for the disk used by recordings. %@ is a size.")
  }

  /// What the usage row says. Loading, failed and partial measurements stay distinct; unknown
  /// bytes are never shown as zero, nor a partial total as complete.
  static func usageLines(_ snapshot: RecordingUsageSnapshot?) -> [String] {
    guard let snapshot else {
      return [
        String(
          localized: "Measuring…",
          comment: "App Settings, Recordings: storage use is being measured.")
      ]
    }
    var lines: [String] = []
    switch snapshot.dictations {
    case .measured:
      lines.append(
        String(
          localized: "Dictation recordings: about \(size(snapshot.dictations.bytes ?? 0))",
          comment: "App Settings, Recordings: disk used by dictation recordings. %@ is a size."))
    case .failed:
      lines.append(
        String(
          localized: "Dictation recordings: couldn't be measured",
          comment: "App Settings, Recordings: dictation storage could not be measured."))
    }
    switch snapshot.meetings {
    case .measured where snapshot.unmeasuredMeetingFolders > 0:
      lines.append(
        String(
          localized:
            "Meeting audio: at least \(size(snapshot.meetings.bytes ?? 0)); some meetings couldn't be measured",
          comment: "App Settings, Recordings: a lower bound for meeting audio. %@ is a size."))
    case .measured:
      lines.append(
        String(
          localized: "Meeting audio: about \(size(snapshot.meetings.bytes ?? 0))",
          comment: "App Settings, Recordings: disk used by meeting audio. %@ is a size."))
    case .failed:
      lines.append(
        String(
          localized: "Meeting audio: couldn't be measured",
          comment: "App Settings, Recordings: meeting storage could not be measured."))
    }
    var temporary: Int64 = 0
    for part in [snapshot.dictations, snapshot.meetings] {
      if case .measured(_, let bytes) = part { temporary += bytes }
    }
    if temporary > 0 {
      lines.append(
        String(
          localized: "Includes about \(size(temporary)) still being saved",
          comment:
            "App Settings, Recordings: part of the storage use is recordings still being written. %@ is a size."
        ))
    }
    return lines
  }

  static func dictationDeletionResult(_ result: DictationRecordings.BulkDeletion) -> String {
    guard result.failed else {
      return result.removed == 1
        ? String(
          localized: "Deleted 1 dictation recording. The text stays.",
          comment: "App Settings, Recordings: result of Delete all dictation recordings, one recording.")
        : String(
          localized: "Deleted \(result.removed ?? 0) dictation recordings. The text stays.",
          comment: "App Settings, Recordings: result of Delete all dictation recordings. %lld is how many, not one.")
    }
    if let remaining = result.remaining, remaining > 0 {
      return String(
        localized: "\(remaining) dictation recordings couldn't be deleted. Try again.",
        comment: "App Settings, Recordings: some recordings remain after Delete all. %lld is how many.")
    }
    return String(
      localized: "Some dictation recordings couldn't be deleted completely. Try again.",
      comment: "App Settings, Recordings: Delete all failed part-way, or what is left could not be counted.")
  }

  static func meetingDeletionResult(_ result: MeetingCoordinator.BulkAudioDeletion) -> String {
    var parts = [
      result.removed == 1
        ? String(
          localized: "Deleted the audio of 1 meeting.",
          comment: "App Settings, Recordings: result of Delete all meeting audio, one meeting.")
        : String(
          localized: "Deleted the audio of \(result.removed) meetings.",
          comment: "App Settings, Recordings: result of Delete all meeting audio. %lld is how many, not one.")
    ]
    if result.skipped > 0 {
      parts.append(
        String(
          localized: "\(result.skipped) can't be deleted right now and kept their audio.",
          comment: "App Settings, Recordings: meetings in use (recording, transcribing, saving) that Delete all meeting audio left alone. %lld is how many."))
    }
    if result.failed > 0 {
      parts.append(
        String(
          localized: "\(result.failed) couldn't be deleted. Try again.",
          comment: "App Settings, Recordings: meetings whose audio could not be deleted. %lld is how many."))
    }
    return parts.joined(separator: " ")
  }
}

/// The storage warning's words, shared by Settings and the History banner.
enum RecordingStorageWarningCopy {
  static func text(_ warning: RecordingRetention.StorageWarning) -> String {
    switch warning {
    case .overThreshold(let total, let threshold):
      String(
        localized:
          "Recordings use about \(RecordingsSettingsCopy.size(total)), more than your \(RecordingsSettingsCopy.size(threshold)) storage warning threshold.",
        comment: "Recordings storage warning (Ask mode). %1$@ is the size used, %2$@ the threshold."
      )
    case .cannotReachThreshold(let total, let threshold):
      String(
        localized:
          "Recordings still use about \(RecordingsSettingsCopy.size(total)), more than your \(RecordingsSettingsCopy.size(threshold)) storage warning threshold. Kept recordings and meeting audio are never removed to free space.",
        comment:
          "Recordings storage warning (automatic mode could not get below). %1$@ used, %2$@ threshold."
      )
    case .usageUnknown:
      String(
        localized:
          "Recording storage couldn't be fully measured. Automatic removal to free space is paused.",
        comment: "Recordings storage warning: usage could not be measured.")
    }
  }

  static let openSettings = LocalizedStringResource(
    "Open Recordings settings",
    comment: "History: button on the storage warning that opens App Settings > Recordings.")
}

/// History's compact storage warning, outside the transcript split (#3147 chunk 6). Shown while
/// `RecordingRetention.warning` is set; its button opens App Settings > Recordings.
struct RecordingStorageBanner: View {
  @Environment(RecordingRetention.self) private var retention: RecordingRetention?
  @Environment(NavigationCoordinator.self) private var navigation

  var body: some View {
    if let warning = retention?.warning {
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.lg) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .foregroundStyle(.stWarning)
          .accessibilityHidden(true)
        Text(verbatim: RecordingStorageWarningCopy.text(warning))
          .font(.stBody)
          .foregroundStyle(.stTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button {
          navigation.request(.appSettings(.recordings))
        } label: {
          EnviousButtonLabel(RecordingStorageWarningCopy.openSettings, size: .medium)
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
        .accessibilityIdentifier("history.recordingStorage.openSettings")
      }
      .padding(DesignSpacing.xl)
      .background(
        Color.stWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.lg)
      )
      .accessibilityElement(children: .contain)
      .padding(.horizontal, DesignSpacing.xl)
      .padding(.top, DesignSpacing.md)
    }
  }
}
