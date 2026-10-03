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

  @Test("every Settings page keeps its sidebar name")
  func pages() {
    #expect(SettingsSection.history.label == "History")
    #expect(SettingsSection.whatsNew.label == "What's New")
    #expect(SettingsSection.appearance.label == "Appearance")
    #expect(SettingsSection.dictation.label == "Dictation Settings")
    #expect(SettingsSection.transcribeFile.label == "Transcribe a File")
    #expect(SettingsSection.keybinds.label == "Keybinds")
    #expect(SettingsSection.aiPolish.label == "AI Polish")
    #expect(SettingsSection.wordCorrection.label == "Dictionary")
    #expect(SettingsSection.snippets.label == "Snippets")
    #expect(SettingsSection.permissions.label == "Permissions")
    #expect(SettingsSection.checkForUpdates.label == "Check for Updates")
    #expect(SettingsSection.openSourceLicenses.label == "Open Source Licenses")
    // #3385: the per-page description lines went with the page headers (tracker A5);
    // Dictionary's moved to its Enable row's "?" (`dictionaryHeading`).
    #expect(SettingsGroup.allCases.map(\.rawValue) == ["APP", "RECORD", "PROCESS", "SYSTEM"])
    #expect(SettingsGroup.allCases.map(\.heading) == SettingsGroup.allCases.map(\.rawValue))
    #expect(SettingsGroup.record.sections == [.dictation, .keybinds, .transcribeFile])
  }

  /// #3385: the six Dictation Settings tabs, in order, with the founder's 2026-10-02 names.
  @Test("the Dictation Settings tabs keep their names and order")
  func dictationTabs() {
    #expect(
      DictationTab.allCases.map { String(localized: $0.label) } == [
        "Engine", "Microphone & Media", "Live Preview", "Recording Pill", "Chimes", "Clipboard",
      ])
    #expect(SettingsCopy.notSelectedValue == "Not selected")
  }

  /// #3385: the Dictionary page's heading row replaced its banner. The "?" keeps the sentence
  /// the page header showed under "Dictionary", typed here from the pre-#3385 source.
  @Test("the Dictionary heading row keeps its approved English")
  func dictionaryHeading() {
    typealias Copy = SettingsShellCopy.Dictionary
    #expect(String(localized: Copy.heading) == "Dictionary")
    #expect(String(localized: Copy.enableTitle) == "Enable Dictionary")
    #expect(String(localized: Copy.enableShort) == "Use your words and vocabulary to improve recognition.")
    #expect(String(localized: Copy.enableHelp) == "Improve recognition with your words and vocabulary.")
    #expect(String(localized: Copy.enableShort).count <= 60)
  }

  /// #3385: a sidebar row says whether it is selected AND what is running there, from one
  /// activity value, so a Dictionary dot is never announced as a file import.
  @Test("a sidebar row's spoken value covers all six states")
  func sidebarValues() {
    typealias Copy = SettingsShellCopy
    let cases: [(Bool, Copy.SidebarActivity, String)] = [
      (false, .none, "Not selected"),
      (true, .none, "Selected"),
      (false, .dictionaryEnrichment, "Not selected. Dictionary enrichment in progress"),
      (true, .dictionaryEnrichment, "Selected. Dictionary enrichment in progress"),
      (false, .fileImport, "Not selected. Importing in progress"),
      (true, .fileImport, "Selected. Importing in progress"),
    ]
    for (selected, activity, english) in cases {
      #expect(Copy.sidebarValue(isSelected: selected, activity: activity) == english)
    }
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

  /// #3385: each Microphone row gains one short line; its full explanation moves behind "?"
  /// with the English it had before. Expected strings typed from the pre-#3385 source.
  @Test("Microphone rows keep their explanations and gain a short line")
  func microphoneRowCopy() {
    typealias Copy = DictationSettingsCopy.Microphone
    #expect(String(localized: Copy.sectionHeading) == "INPUT & BEHAVIOR")
    #expect(String(localized: Copy.inputDeviceTitle) == "Input device")
    #expect(
      String(localized: Copy.inputDeviceShort) == "Choose the microphone used for recording.")
    #expect(
      String(localized: Copy.inputDeviceHelp)
        == "Select which microphone to use for recording. \"Auto\" follows the input device selected in macOS. If that device turns out not to be a real microphone, recording uses an available microphone instead."
    )
    #expect(String(localized: Copy.mediaTitle) == "Media during dictation")
    #expect(
      String(localized: Copy.mediaShort) == "What music and video do while you dictate.")
    #expect(String(localized: Copy.readinessTitle) == "Microphone readiness")
    #expect(
      String(localized: Copy.readinessShort) == "How long the mic stays ready after recording.")
    #expect(
      String(localized: Copy.readinessHelp)
        == "Keep the microphone engine active for a short time after dictation so the next recording starts instantly and captures your first words."
    )
    // #3385 chunk 5: the socket and Bluetooth rows.
    #expect(
      String(localized: Copy.socketShort) == "Choose the socket your microphone is plugged into.")
    #expect(
      String(localized: Copy.socketHelp)
        == "Pick the input your microphone uses. The choice is remembered for this device.")
    #expect(
      String(localized: Copy.bluetoothShort)
        == "Keeping your mic ready reduces Bluetooth startup delay.")
    #expect(
      String(localized: Copy.bluetoothTipsShort) == "Show the Bluetooth reminder once per launch.")
    #expect(
      String(localized: Copy.bluetoothTipsHelp)
        == "Shows the reminder popover once per launch. This guide always stays.")
    #expect(InputSocketCopy.label == "Mic is on")
    for short in [
      Copy.inputDeviceShort, Copy.mediaShort, Copy.readinessShort, Copy.socketShort,
      Copy.bluetoothShort, Copy.bluetoothTipsShort,
    ] {
      #expect(String(localized: short).count <= 60)
    }
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

  /// The old warning spliced a keybind name into a frame; each role now has its own sentence. The
  /// oracle rebuilds the OLD composition from the names that frame used, typed out here, so the
  /// English must match it byte for byte.
  @Test("each keybind conflict warning is the sentence the old frame produced")
  func keybindConflicts() {
    let names: [ShortcutRole: String] = [
      .record: "the recording keybind", .cancel: "the cancel keybind",
      .quickAdd: "the add-a-word keybind", .pasteLast: "Paste last dictation",
      .copyLast: "Copy last dictation",
    ]
    #expect(Set(names.keys) == Set(ShortcutRole.allCases))
    for role in ShortcutRole.allCases {
      let who = names[role] ?? "missing"
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
