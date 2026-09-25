import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #3142: Settings shell and everyday-control copy that is localized where it is authored keeps its
/// English bytes. Expected strings were taken from the pre-localization source, not from the code
/// under test. Unit tests run outside the app bundle, so they read English.
@Suite("Settings shell English", .tags(.productOutcome))
struct SettingsShellEnglishTests {

  @Test("every Settings page keeps its sidebar name and description")
  func pages() {
    #expect(SettingsSection.history.label == "History")
    #expect(SettingsSection.whatsNew.label == "What's New")
    #expect(SettingsSection.appearance.label == "Appearance")
    #expect(SettingsSection.speechEngine.label == "Transcription")
    #expect(SettingsSection.transcribeFile.label == "Transcribe a File")
    #expect(SettingsSection.livePreview.label == "Live Preview")
    #expect(SettingsSection.audio.label == "Microphone")
    #expect(SettingsSection.recordingSounds.label == "Sounds")
    #expect(SettingsSection.keybinds.label == "Keybinds")
    #expect(SettingsSection.aiPolish.label == "AI Polish")
    #expect(SettingsSection.wordCorrection.label == "Dictionary")
    #expect(SettingsSection.snippets.label == "Snippets")
    #expect(SettingsSection.clipboard.label == "Clipboard")
    #expect(SettingsSection.permissions.label == "Permissions")
    #expect(SettingsSection.sendFeedback.label == "Send Feedback")
    #expect(SettingsSection.checkForUpdates.label == "Check for Updates")
    #expect(SettingsSection.openSourceLicenses.label == "Open Source Licenses")
    #expect(
      SettingsSection.history.subtitle == "Your past dictations, searchable and ready to reuse.")
    #expect(
      SettingsSection.whatsNew.subtitle == "The latest improvements and fixes in this release.")
    #expect(
      SettingsSection.appearance.subtitle
        == "How the app looks, and the pill you see while dictating.")
    #expect(
      SettingsSection.speechEngine.subtitle == "The speech engine that turns your voice into text.")
    #expect(
      SettingsSection.transcribeFile.subtitle
        == "Turn a recording you already have into clean text.")
    #expect(
      SettingsSection.livePreview.subtitle
        == "See your words on screen while you are still speaking.")
    #expect(SettingsSection.audio.subtitle == "Choose your input source and readiness behavior.")
    #expect(
      SettingsSection.recordingSounds.subtitle
        == "Play a short sound when recording starts and stops.")
    #expect(
      SettingsSection.keybinds.subtitle
        == "Set the keybinds that start, stop, and cancel dictation.")
    #expect(SettingsSection.aiPolish.subtitle == "Clean up and rewrite your dictation with AI.")
    #expect(
      SettingsSection.wordCorrection.subtitle
        == "Improve recognition with your words and vocabulary.")
    #expect(
      SettingsSection.snippets.subtitle
        == "Say your keyword, then a snippet. The saved text lands for you.")
    #expect(
      SettingsSection.clipboard.subtitle
        == "How your dictation reaches the clipboard and the app you're in.")
    #expect(
      SettingsSection.permissions.subtitle
        == "The microphone and accessibility access EnviousWispr needs.")
    #expect(SettingsSection.sendFeedback.subtitle == "")
    #expect(SettingsSection.checkForUpdates.subtitle == "")
    #expect(
      SettingsSection.openSourceLicenses.subtitle
        == "EnviousWispr is GPLv3 open source. The license and third-party notices.")
    #expect(SettingsSection.sendFeedback.subtitle == "")
    #expect(SettingsSection.checkForUpdates.subtitle == "")
    #expect(SettingsGroup.allCases.map(\.heading) == SettingsGroup.allCases.map(\.rawValue))
  }

  @Test("the shared notices and the spoken selected value keep their English")
  func sharedCopy() {
    #expect(
      SettingsCopy.frozenPerRecording
        == "Changes made during a recording apply to the next recording.")
    #expect(SettingsCopy.frozenPerImport == "Changes made during a cleanup apply to the next file.")
    #expect(SettingsCopy.selectedValue == "Selected")
  }

  @Test("media-during-dictation choices keep their English")
  func mediaDuringDictation() {
    #expect(
      OtherAudioSettingsPanel.footnote(for: .nothing)
        == "Music and other audio keep playing as they are.")
    #expect(
      OtherAudioSettingsPanel.footnote(for: .turnDown)
        == "Lowers what plays through your current speakers or headphones to about half while you dictate, then puts it back. If you change the volume during a take, your new level stays."
    )
    #expect(
      OtherAudioSettingsPanel.footnote(for: .mute)
        == "Silences your current speakers or headphones while you dictate, including calls and spoken feedback, then puts the volume back. If you change the volume during a take, your new level stays."
    )
    #expect(
      OtherAudioSettingsPanel.footnote(for: .pauseMusic)
        == "Pauses whatever is playing (music, a video, a podcast), then resumes it when you stop. If you switch to something else during a take, what we paused stays paused."
    )
    #expect(
      OtherAudioSettingsPanel.pauseAnythingUnavailableNote
        == "On this Mac only Music and Spotify can be paused. macOS may ask for permission the first time; a take that needs permission is not paused."
    )
  }

  @Test("the Globe key tip keeps its English")
  func globeKeyTip() {
    #expect(GlobeKeyCopy.title == "Free up the Globe key")
    #expect(
      GlobeKeyCopy.body
        == "macOS may already use the Globe key to switch keyboard languages, open the emoji picker, or start its own dictation. If that happens while you dictate, you can turn it off:"
    )
    #expect(
      GlobeKeyCopy.reassurance
        == "Your Globe key is set as your dictation keybind either way. This only stops macOS doing its own thing at the same time."
    )
    #expect(GlobeKeyCopy.dismissButton == "Got it")
    #expect(GlobeKeyCopy.accessibilityLabel == "Free up the Globe key. Setup tip.")
    #expect(
      GlobeKeyCopy.steps == [
        "Open System Settings, then Keyboard", "Click the \"Press 🌐 key to\" menu",
        "Choose \"Do Nothing\"",
      ])
  }

  /// The old warning spliced `HotkeyRecorderView.title(of:)` into a frame; each role now has its own
  /// sentence. The oracle rebuilds the OLD composition, so the English must match it byte for byte.
  @Test("each keybind conflict warning is the sentence the old frame produced")
  func keybindConflicts() {
    for role in ShortcutRole.allCases {
      let who = HotkeyRecorderView.title(of: role)
      let expected =
        role == .cancel
        ? "Works only when you are not recording: \(who) (Right ⌘) uses these keys while you record."
        : "Not active: \(who) (Right ⌘) uses these keys. Choose another."
      #expect(KeybindConflictCopy.notActive(taker: role, keys: "Right ⌘") == expected, "\(role)")
    }
  }

  @Test("the input socket control keeps its English")
  func inputSocket() {
    #expect(InputSocketCopy.label == "Mic is on")
    #expect(InputSocketCopy.optionLabel(index: 0) == "Input 1")
    #expect(InputSocketCopy.helper(deviceName: "Studio") == "Remembered for Studio.")
  }
}
