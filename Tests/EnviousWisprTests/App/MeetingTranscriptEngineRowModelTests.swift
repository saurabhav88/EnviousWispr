import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices
import EnviousWisprAppKitTestSupport

/// #3973 C3: when these fail, EnviousMeet's Transcript engine row lets the user pick a Whisper
/// that is not downloaded, starts a download during a meeting, warns about two engines when
/// there is one (or not when there are two), or offers languages the chosen engine cannot
/// transcribe.
@MainActor
@Suite("Meeting transcript engine row", .tags(.productOutcome))
struct MeetingTranscriptEngineRowModelTests {
  final class Downloads { var starts = 0 }

  struct Rig {
    let settings: SettingsManager
    let downloads: Downloads
    let setup: WhisperSetupService
    let model: MeetingTranscriptEngineRowModel

    @MainActor
    init(whisper: WhisperSetupState) {
      let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
      let downloads = Downloads()
      self.settings = settings
      self.downloads = downloads
      setup = WhisperSetupService(
        engineMutationScope: .alwaysAllowedForTesting, readAvailability: { whisper },
        startDownload: {
          downloads.starts += 1
          return true
        })
      model = MeetingTranscriptEngineRowModel(
        environment: .init(settings: settings, whisperSetup: setup))
    }
  }

  /// #4578: the uniform rule. When this fails, picking an engine that is not downloaded does
  /// nothing, unlike dictation's Engine tab.
  @Test("either engine is saved, downloaded or not")
  func anyEngineIsSaved() {
    for whisper in [WhisperSetupState.notDownloaded, .ready] {
      let rig = Rig(whisper: whisper)
      rig.model.select(.whisper)
      #expect(rig.settings.meetingTranscriptEngine == .whisper)
      rig.model.select(.parakeet)
      #expect(rig.settings.meetingTranscriptEngine == .parakeet)
    }
  }

  @Test("the two-engines warning shows exactly when meetings and dictation use different engines")
  func mismatchWarning() async {
    let rig = Rig(whisper: .ready)
    rig.settings.meetingTurnsOffDictation = false
    rig.settings.selectedBackend = .parakeet
    #expect(rig.model.engineMismatch == nil, "Parakeet and Parakeet")
    rig.model.select(.whisper)
    #expect(rig.model.engineMismatch == .whisper)
    rig.settings.selectedBackend = .whisper
    #expect(rig.model.engineMismatch == nil, "Whisper and Whisper")
    rig.model.select(.parakeet)
    #expect(rig.model.engineMismatch == .parakeet)
    rig.settings.meetingTurnsOffDictation = true
    #expect(rig.model.engineMismatch == nil, "no dictation during meetings, no warning")
  }

  @Test("the language list follows the engine; a language the engine cannot transcribe is named")
  func languagesFollowTheEngine() async {
    let rig = Rig(whisper: .ready)
    let parakeet = rig.model.transcriptLanguageOptions
    let expected = LanguageCatalog.pickerEntries.filter {
      ParakeetBackend.lockableLanguageCodes.contains($0.lockCode) && $0 != LanguageCatalog.englishUK
    }
    #expect(parakeet == expected, "Parakeet's languages, one row each")
    #expect(!parakeet.contains(LanguageCatalog.englishUK), "British spelling is dictation's choice")
    rig.model.select(.whisper)
    let whisper = rig.model.transcriptLanguageOptions
    #expect(whisper.count > parakeet.count)
    #expect(whisper.contains { $0.code == "haw" })

    rig.settings.meetingLanguageMode = .locked("haw")
    #expect(rig.model.unsupportedTranscriptLanguage == nil)
    rig.model.select(.parakeet)
    #expect(rig.model.unsupportedTranscriptLanguage == "haw")
  }
}
