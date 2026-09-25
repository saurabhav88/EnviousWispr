import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3142: Live Preview Settings copy that is localized where it is authored keeps its English
/// bytes. Every expected string below was taken from the pre-localization source (literal chains
/// joined), not from the code under test. Unit tests run outside the app bundle, so they read English.
@Suite("Live Preview settings English", .tags(.productOutcome))
struct LivePreviewSettingsEnglishTests {

  @Test("every Live Preview copy entry keeps its English")
  func copyEntries() {
    #expect(LivePreviewSettingsCopy.sectionHeader == "Live Preview")
    #expect(LivePreviewSettingsCopy.toggleLabel == "Show words while I speak")
    #expect(LivePreviewSettingsCopy.packsHeader == "Languages")
    #expect(
      LivePreviewSettingsCopy.packsDescription
        == "Apple provides the speech for the on-screen preview. Your Mac already has some languages; the rest are about 140 MB each and download only when you ask. Nothing downloads on its own."
    )
    #expect(LivePreviewSettingsCopy.packInstall == "Download")
    #expect(LivePreviewSettingsCopy.packInstalling == "Downloading")
    #expect(LivePreviewSettingsCopy.packRetry == "Try again")
    #expect(LivePreviewSettingsCopy.packsSearchPlaceholder == "Search by name or code")
    #expect(LivePreviewSettingsCopy.packsNoSearchMatch == "No language matches your search.")
    #expect(LivePreviewSettingsCopy.packsLoading == "Checking which languages are on this Mac")
    #expect(
      LivePreviewSettingsCopy.packsUnavailable
        == "Could not read the language list from macOS. Reopen this page to try again.")
    #expect(
      LivePreviewSettingsCopy.packInstallFailed
        == "That download did not finish. Check your connection and try again.")
    #expect(LivePreviewSettingsCopy.statusActiveLabel == "Activated")
    #expect(
      LivePreviewSettingsCopy.statusActiveDetail == "Ready to show your words while you speak.")
    #expect(LivePreviewSettingsCopy.statusOffLabel == "Off")
    #expect(
      LivePreviewSettingsCopy.statusOffDetail
        == "Switch it on and this bar will show whether anything else is needed.")
    #expect(LivePreviewSettingsCopy.statusNeedsMacOS26Label == "Apple's engine needs macOS 26")
    #expect(
      LivePreviewSettingsCopy.statusNeedsMacOS26Detail
        == "Pick the Universal engine below, which works on macOS 14 and later.")
    #expect(
      LivePreviewSettingsCopy.statusNeedsMacOS26DetailNoAlternative
        == "Dictation itself works normally. Only the on-screen preview is unavailable.")
    #expect(LivePreviewSettingsCopy.statusCheckingLabel == "Checking")
    #expect(
      LivePreviewSettingsCopy.statusCheckingDetail == "Reading which languages are on this Mac.")
    #expect(
      LivePreviewSettingsCopy.statusInstallInFlightDetail
        == "A language download is in progress. This updates when it finishes.")
    #expect(
      LivePreviewSettingsCopy.statusLanguageChangedDetail
        == "Working out what your new language needs. This updates when the download finishes.")
    #expect(
      LivePreviewSettingsCopy.statusNeedsLanguageDetail
        == "Use Browse downloads below to get it and start the preview.")
    #expect(
      LivePreviewSettingsCopy.statusUnsupportedLanguageLabel == "Apple can't preview this language")
    #expect(
      LivePreviewSettingsCopy.statusUnsupportedLanguageDetail
        == "Dictation still works normally. Try the Universal engine instead.")
    #expect(
      LivePreviewSettingsCopy.statusUnsupportedLanguageDetailNoAlternative
        == "Dictation still works normally. Only the on-screen preview is unavailable for it.")
    #expect(LivePreviewSettingsCopy.statusNeedsDownloadLabel == "Needs a download")
    #expect(
      LivePreviewSettingsCopy.statusNeedsDownloadDetail
        == "Get the Universal engine from the card below.")
    #expect(LivePreviewSettingsCopy.statusGettingReadyLabel == "Getting ready")
    #expect(
      LivePreviewSettingsCopy.statusGettingReadyDetail == "The Universal engine is being prepared.")
    #expect(LivePreviewSettingsCopy.statusDownloadFailedLabel == "Download did not finish")
    #expect(LivePreviewSettingsCopy.statusBuildCannotRunLabel == "Can't run that engine")
    #expect(
      LivePreviewSettingsCopy.statusBuildCannotRunDetail
        == "This version of EnviousWispr is missing that engine's files. Pick Apple instead.")
    #expect(
      LivePreviewSettingsCopy.statusBuildCannotRunDetailNoAlternative
        == "This version of EnviousWispr is missing that engine's files. Updating the app should restore it."
    )
    #expect(
      LivePreviewSettingsCopy.pausedForFasterTranscription
        == "Paused while Faster Transcription is on")
    #expect(
      LivePreviewSettingsCopy.statusPausedDetail
        == "Your dictation keeps its full speed. Turn Faster Transcription off to see the preview.")
    #expect(
      LivePreviewSettingsCopy.previewPrivacyFooter
        == "It stays on your Mac, is discarded when the recording ends, and never changes a character of what gets pasted."
    )
    #expect(
      LivePreviewSettingsCopy.catalogNothingToInstall
        == "Every language Apple offers is already on this Mac.")
    #expect(LivePreviewSettingsCopy.browseDownloadsButton == "Browse downloads")
    #expect(LivePreviewSettingsCopy.packsInstallRowTitle == "Install new languages")
    #expect(LivePreviewSettingsCopy.catalogDoneButton == "Done")
    #expect(LivePreviewSettingsCopy.catalogCloseLabel == "Close")
    #expect(LivePreviewSettingsCopy.languageAnyLanguage == "Automatic")
    #expect(LivePreviewSettingsCopy.languageProvenanceFromMac == "from your Mac")
    #expect(LivePreviewSettingsCopy.languageProvenanceUserPicked == "you picked this")
    #expect(LivePreviewSettingsCopy.languageProvenanceDetected == "no language pinned")
    #expect(
      LivePreviewSettingsCopy.universalAuto == "The preview detects your language as you speak.")
    #expect(
      LivePreviewSettingsCopy.universalAutoPaused
        == "The preview is set to detect your language as you speak.")
    #expect(
      LivePreviewSettingsCopy.pickerAppleCaveat
        == "This changes dictation too, not just the preview. On Automatic, dictation follows what you speak, but the preview must pick one language up front and uses your Mac's."
    )
    #expect(
      LivePreviewSettingsCopy.pickerUniversalCaveat
        == "This changes dictation too, not just the preview. On Automatic, this engine works the language out as you speak."
    )
    #expect(
      LivePreviewSettingsCopy.previewNeedsLanguagePack("German")
        == "German isn't downloaded yet. Open Settings to download it.")
    #expect(
      LivePreviewSettingsCopy.statusNeedsLanguageLabel("German") == "German isn't downloaded yet")
    #expect(
      LivePreviewSettingsCopy.universalLocked("German") == "Your words will appear in German.")
    #expect(
      LivePreviewSettingsCopy.universalLockedPaused("German") == "The preview is set to German.")
  }

  @Test("every preview-engine entry keeps its English")
  func engineCopy() {
    #expect(LivePreviewEngineCopy.sectionHeader == "Preview engine")
    #expect(LivePreviewEngineCopy.learnMoreLabel == "Learn more about engines")
    #expect(
      LivePreviewEngineCopy.learnMoreURL
        == "https://enviouswispr.com/help/live-preview-words-on-screen/")
    #expect(LivePreviewEngineCopy.appleTitle == "Apple")
    #expect(
      LivePreviewEngineCopy.appleDescription
        == "Uses Apple's speech recognition. No separate preview-model download; some languages may need an Apple language download. Needs macOS 26."
    )
    #expect(LivePreviewEngineCopy.appleNeedsNewerMacOS == "Needs macOS 26 or later.")
    #expect(LivePreviewEngineCopy.universalTitle == "Universal")
    #expect(
      LivePreviewEngineCopy.universalDescription
        == "Works on macOS 14 and later, in more languages. Needs one optional 217 MB download.")
    #expect(LivePreviewEngineCopy.notDownloadedYet == "Not downloaded yet.")
    #expect(LivePreviewEngineCopy.downloadFailed == "The download did not finish.")
    #expect(
      LivePreviewEngineCopy.downloadCancelled
        == "Download paused. It will pick up where it stopped.")
    #expect(LivePreviewEngineCopy.downloadStopped == "Download stopped.")
    #expect(
      LivePreviewEngineCopy.unavailableInThisBuild
        == "This version of EnviousWispr cannot run that preview engine.")
  }

  @Test("the language list keeps its two group headings")
  func packGroups() {
    #expect(LivePreviewPackPresentation.installedGroupTitle == "On this Mac")
    #expect(LivePreviewPackPresentation.availableGroupTitle == "Available to download")
  }
}
