import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #3147 PR1 App Settings > Recordings: when these fail, the switch stops controlling new
/// recordings, a shorter keep period applies without its preview, the page shows an unknown or
/// partial size as a complete one, or a deletion result claims more than happened.
@MainActor
@Suite("Recordings settings page", .tags(.productOutcome))
struct RecordingsSettingsTests {
  private func settings() -> SettingsManager {
    let name = "ew.recordingsSettingsTest." + UUID().uuidString
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return SettingsManager(defaults: defaults)
  }

  @Test("the recording switch is what both dictation kernels read, live")
  func switchDrivesTheTakeStartPreference() {
    let settings = settings()
    let preference = DictationRecordings.livePreference(settings)
    #expect(preference(), "on by default (D1)")
    settings.saveDictationRecordings = false
    #expect(preference() == false, "the next take sees the change")
    settings.saveDictationRecordings = true
    #expect(preference())
  }

  @Test("only a shorter keep period needs a preview; longer and until-deleted apply at once")
  func shorteningIsClassified() {
    #expect(RecordingRetention.shortens(from: nil, to: 7), "until deleted to 7 days")
    #expect(RecordingRetention.shortens(from: 30, to: 7))
    #expect(!RecordingRetention.shortens(from: 7, to: 30))
    #expect(!RecordingRetention.shortens(from: 7, to: nil), "until deleted removes nothing")
    #expect(!RecordingRetention.shortens(from: 7, to: 7))
  }

  @Test("the page shows measuring, sizes, lower bounds and failures, never a guess")
  func usageLines() {
    #expect(RecordingsSettingsCopy.usageLines(nil) == ["Measuring…"])
    let complete = RecordingUsageSnapshot(
      dictations: .measured(committedBytes: 2_000_000, temporaryBytes: 0),
      meetings: .measured(committedBytes: 50_000_000, temporaryBytes: 0),
      unmeasuredMeetingFolders: 0)
    let lines = RecordingsSettingsCopy.usageLines(complete)
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("Dictation recordings: about "))
    #expect(lines[1].hasPrefix("Meeting audio: about "))

    let partial = RecordingUsageSnapshot(
      dictations: .failed,
      meetings: .measured(committedBytes: 1_000, temporaryBytes: 500),
      unmeasuredMeetingFolders: 2)
    let partialLines = RecordingsSettingsCopy.usageLines(partial)
    #expect(partialLines[0] == "Dictation recordings: couldn't be measured")
    #expect(partialLines[1].hasPrefix("Meeting audio: at least "), "a lower bound says so")
    #expect(partialLines[2].hasPrefix("Includes about "), "bytes still being saved are named")
    #expect(!partialLines.joined().contains("Zero KB"), "unknown is never zero")
    #expect(RecordingsSettingsCopy.usageSummary(nil) == "Measuring…")
    #expect(RecordingsSettingsCopy.usageSummary(complete).hasPrefix("About "))
    #expect(RecordingsSettingsCopy.usageSummary(partial) == "Couldn't be fully measured", "a failed part has no total")
    let lowerBound = RecordingUsageSnapshot(
      dictations: .measured(committedBytes: 10, temporaryBytes: 0),
      meetings: .measured(committedBytes: 10, temporaryBytes: 0), unmeasuredMeetingFolders: 1)
    #expect(RecordingsSettingsCopy.usageSummary(lowerBound).hasPrefix("At least "))
  }

  @Test("a shorter keep period's preview names the period and the real count")
  func previewText() {
    func preview(_ count: Int?) -> String {
      RecordingsSettingsCopy.preview(
        .init(change: .dictations(.day7), recordingsToRemove: count))
    }
    #expect(
      preview(nil) == "Keep for 7 days? The recordings this removes can't be counted right now.")
    #expect(preview(0) == "Keep for 7 days? No recording is old enough to be removed now.")
    #expect(
      preview(1) == "Keep for 7 days? 1 recording is older and will be removed. Its text stays.")
    #expect(
      preview(12)
        == "Keep for 7 days? 12 recordings are older and will be removed. Their text stays.")
  }

  @Test("deletion results never claim more than happened")
  func deletionResults() {
    #expect(
      RecordingsSettingsCopy.dictationDeletionResult(.init(removed: 3, remaining: 0, failed: false))
        == "Deleted 3 dictation recordings. The text stays.")
    #expect(
      RecordingsSettingsCopy.dictationDeletionResult(.init(removed: 1, remaining: 0, failed: false))
        == "Deleted 1 dictation recording. The text stays.")
    #expect(
      RecordingsSettingsCopy.dictationDeletionResult(.init(removed: 1, remaining: 2, failed: true))
        == "2 dictation recordings couldn't be deleted. Try again.")
    #expect(
      RecordingsSettingsCopy.dictationDeletionResult(.init(removed: 3, remaining: 0, failed: true))
        == "Some dictation recordings couldn't be deleted completely. Try again.",
      "a failure with no audio left is still a failure")
    #expect(
      RecordingsSettingsCopy.dictationDeletionResult(.init(removed: nil, remaining: nil, failed: true))
        == "Some dictation recordings couldn't be deleted completely. Try again.")
    let meetings = RecordingsSettingsCopy.meetingDeletionResult(
      .init(removed: 2, skipped: 1, failed: 1))
    #expect(meetings.contains("2 meetings"))
    #expect(meetings.contains("Meetings in use kept their audio: 1."))
    #expect(meetings.contains("Meeting audio that couldn't be deleted: 1. Try again."))
    #expect(
      RecordingsSettingsCopy.meetingDeletionResult(.init(removed: 1, skipped: 0, failed: 0))
        == "Deleted the audio of 1 meeting.")
  }

  @Test("every storage warning has its own words, and none says limit")
  func warningText() {
    let texts = [
      RecordingStorageWarningCopy.text(
        .overThreshold(totalBytes: 3_000_000_000, thresholdBytes: 2_000_000_000)),
      RecordingStorageWarningCopy.text(
        .cannotReachThreshold(totalBytes: 3_000_000_000, thresholdBytes: 2_000_000_000)),
      RecordingStorageWarningCopy.text(.usageUnknown(thresholdBytes: 2_000_000_000)),
    ]
    #expect(Set(texts).count == 3)
    for text in texts { #expect(!text.localizedCaseInsensitiveContains("limit")) }
    #expect(texts[1].contains("never removed to free space"))
    #expect(texts[2].contains("paused"))
  }

  @Test("Recordings is an App Settings tab that search can open")
  func tabAndDestination() {
    #expect(AppSettingsTab.allCases.contains(.recordings))
    #expect(AppSettingsTab.recordings.mapID == .appSettingsTabRecordings)
    #expect(SettingsDestination.appSettings(.recordings).page == .appSettings)
    let ids = SettingsMap.nodes.map(\.id)
    for id in [
      SettingsMapID.saveDictationRecordings, .dictationRecordingRetention,
      .meetingRecordingRetention, .recordingStorageUsage, .recordingStorageWarningThreshold,
      .recordingThresholdBehavior, .deleteRecordings, .deleteAllDictationRecordings,
      .deleteAllMeetingAudio,
    ] {
      #expect(ids.contains(id), "\(id.rawValue) is on the map")
    }
  }
}
