import EnviousWisprCore
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #4578: what each engine card's status line offers, on both Settings tabs. When this fails, a
/// downloaded engine has no Remove, a missing one has no Set up model, a download in progress
/// is hidden behind "Not downloaded", or Remove asks (or fails to ask) before deleting an engine
/// in use.
@Suite(.tags(.productOutcome))
struct SpeechEngineStatusTests {
  typealias S = SpeechEngineStatus
  typealias Row = SpeechEngineSettingsView.ParakeetRow

  @Test("Parakeet: ready offers Remove, missing offers Set up model, leftovers add their button")
  func parakeetInstallStates() {
    let ready = S.parakeet(installed: true, removing: false, leftovers: false, row: nil)
    #expect(ready.offersRemove && !ready.offersSetUp)
    let missing = S.parakeet(installed: false, removing: false, leftovers: false, row: nil)
    #expect(missing.offersSetUp && !missing.offersRemove && !missing.offersLeftoverRemoval)
    let leftovers = S.parakeet(installed: false, removing: false, leftovers: true, row: nil)
    #expect(leftovers.offersSetUp && leftovers.offersLeftoverRemoval)
    #expect(S.parakeet(installed: nil, removing: false, leftovers: false, row: nil).install == .checking)
    let removing = S.parakeet(
      installed: true, removing: true, leftovers: false,
      row: Row(title: "t", detail: nil, showsCancel: true, action: nil, owner: .foreground))
    #expect(removing == S(install: .removing, operation: nil), "nothing else while removing")
  }

  @Test("Parakeet: a download keeps its owner; v3 serving while Ultra downloads stays removable")
  func parakeetOperations() {
    let upgrade = S.parakeet(
      installed: true, removing: false, leftovers: false,
      row: Row(title: "Downloading", detail: "1 of 2", showsCancel: true, action: nil,
        owner: .backgroundUpgrade))
    #expect(upgrade.offersRemove, "the installed copy stays removable")
    #expect(upgrade.operation == .working(title: "Downloading", detail: "1 of 2", fraction: nil, cancel: .parakeetUpgrade))
    let paused = S.parakeet(
      installed: false, removing: false, leftovers: false,
      row: Row(title: "Paused", detail: nil, showsCancel: false, action: .fastModelResume,
        owner: .foreground))
    #expect(paused.operation == .paused(title: "Paused", resume: .parakeetForeground, cancel: .parakeetForeground))
    #expect(!paused.offersSetUp, "Resume, not a second install")
    let retry = Row(title: "Couldn't load", detail: nil, showsCancel: false, action: .fastModelTryAgain, owner: .retry)
    #expect(
      S.parakeet(installed: true, removing: false, leftovers: false, row: retry).operation
        == .failed(title: "Couldn't load", detail: nil, retry: .parakeetRetry))
    let removedRetry = S.parakeet(installed: false, removing: false, leftovers: false, row: retry)
    #expect(removedRetry.operation == nil && removedRetry.offersSetUp, "nothing to load: Set up model")
    let pausedUpgrade = S.parakeet(
      installed: true, removing: false, leftovers: false,
      row: Row(title: "Paused", detail: nil, showsCancel: false, action: .fastModelResume,
        owner: .backgroundUpgrade))
    #expect(pausedUpgrade.operation == .paused(title: "Paused", resume: .parakeetUpgrade, cancel: .parakeetUpgrade))
  }

  @Test("Parakeet after a recorded removal: a failed or interrupted removal offers Set up model and the leftover removal, never Resume or Retry")
  func parakeetAfterRemovalRecorded() {
    for row in [
      Row(title: "Couldn't download", detail: nil, showsCancel: false, action: .fastModelTryAgain, owner: .foreground),
      Row(title: "Paused", detail: nil, showsCancel: false, action: .fastModelResume, owner: .foreground),
      Row(title: "Couldn't load", detail: nil, showsCancel: false, action: .fastModelTryAgain, owner: .retry),
    ] {
      let status = S.parakeet(installed: false, removing: false, leftovers: true, installWanted: false, row: row)
      #expect(status.operation == nil, "\(row.title): the refused action is not offered")
      #expect(status.offersSetUp && status.offersLeftoverRemoval, "\(row.title)")
    }
    let wanted = S.parakeet(
      installed: false, removing: false, leftovers: false, installWanted: true,
      row: Row(title: "Couldn't download", detail: nil, showsCancel: false, action: .fastModelTryAgain, owner: .foreground))
    #expect(wanted.operation == .failed(title: "Couldn't download", detail: nil, retry: .parakeetForeground), "a wanted download keeps its Retry")
  }

  @Test("Whisper: every setup state maps to one line and its action")
  func whisperStates() {
    #expect(S.whisper(.checking, removing: false).install == .checking)
    #expect(S.whisper(.notDownloaded, removing: false).offersSetUp)
    #expect(S.whisper(.ready, removing: false).offersRemove)
    for state: WhisperSetupState in [.ready, .notDownloaded, .paused, .checking, .error("x"), .downloading(progress: 0.1, status: "")] {
      #expect(S.whisper(state, removing: true) == S(install: .removing, operation: nil), "no action while removing: \(state)")
    }
    let leftovers = S.whisper(.notDownloaded, removing: false, leftovers: true)
    #expect(leftovers.offersSetUp && leftovers.offersLeftoverRemoval, "a failed removal's bytes can be removed")
    #expect(
      S.whisper(.downloading(progress: 0.4, status: "40%"), removing: false).operation
        == .working(title: SpeechEngineStatusCopy.downloading, detail: "40%", fraction: 0.4, cancel: .whisper))
    #expect(S.whisper(.paused, removing: false).operation == .paused(title: SpeechEngineStatusCopy.paused, resume: .whisper, cancel: .whisper))
    let failed = S.whisper(.error("disk"), removing: false)
    #expect(failed.operation == .failed(title: SpeechEngineStatusCopy.somethingWentWrong, detail: "disk", retry: .whisperDetect))
    #expect(!failed.offersSetUp)
  }

  @Test("the confirm box: every engine in use asks; its words follow what stays downloaded")
  func removalConfirmation() {
    #expect(
      S.removalConfirmation(engine: .parakeet, dictationEngine: .whisper, meetingEngine: .whisper, otherInstalled: true) == nil,
      "an unused engine is removed at once")
    let dictation = S.removalConfirmation(
      engine: .whisper, dictationEngine: .whisper, meetingEngine: .parakeet, otherInstalled: true)
    #expect(dictation?.title == "Remove Whisper?")
    #expect(dictation?.message == "Dictation won't work until you choose Parakeet or download Whisper again.")
    #expect(
      S.removalConfirmation(engine: .whisper, dictationEngine: .whisper, meetingEngine: .parakeet, otherInstalled: false)?.message
        == "Dictation won't work until you download a speech engine again.")
    let meetingOnly = S.removalConfirmation(
      engine: .parakeet, dictationEngine: .whisper, meetingEngine: .parakeet, otherInstalled: true)
    #expect(meetingOnly?.title == "Remove Parakeet?", "the meeting engine still asks")
    #expect(meetingOnly?.message == "", "meetings use the other downloaded engine on their own: no sentence")
    #expect(
      S.removalConfirmation(engine: .parakeet, dictationEngine: .whisper, meetingEngine: .parakeet, otherInstalled: false)?.message
        == "Meetings won't get a transcript until you download a speech engine again.")
    #expect(
      S.removalConfirmation(engine: .parakeet, dictationEngine: .parakeet, meetingEngine: .parakeet, otherInstalled: false)?.message
        == "Dictation won't work until you download a speech engine again. Meetings won't get a transcript until you download a speech engine again.")
  }
}
