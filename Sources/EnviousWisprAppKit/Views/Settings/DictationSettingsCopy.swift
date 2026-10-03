import EnviousWisprCore
import Foundation

/// Copy home for the Dictation Settings rows (#3385): each row's short grey
/// line and, where the row owns it, its full "?" explanation. The full
/// explanations are today's sentences, moved behind "?" unchanged; only the
/// short lines are new. Dynamic explanations stay with the view that chooses
/// them (`OtherAudioSettingsPanel.footnote(for:)`).
enum DictationSettingsCopy {
  enum Microphone {
    static let sectionHeading = LocalizedStringResource(
      "INPUT & BEHAVIOR",
      comment: "Microphone settings: section heading above the microphone rows, shown in capitals."
    )

    static let inputDeviceTitle = LocalizedStringResource(
      "Input device", comment: "Microphone settings: row title.")
    static let inputDeviceShort = LocalizedStringResource(
      "Choose the microphone used for recording.",
      comment: "Microphone settings: short line under the Input device row title.")
    static let inputDeviceHelp = LocalizedStringResource(
      "Select which microphone to use for recording. \"Auto\" follows the input device selected in macOS. If that device turns out not to be a real microphone, recording uses an available microphone instead.",
      comment:
        "Microphone settings: explains the input device choice. Auto is the name of the first option."
    )

    static let mediaTitle = LocalizedStringResource(
      "Media during dictation",
      comment:
        "Microphone settings, media during dictation: row title for what happens to music and other audio."
    )
    static let mediaShort = LocalizedStringResource(
      "What music and video do while you dictate.",
      comment: "Microphone settings: short line under the Media during dictation row title.")

    static let readinessTitle = LocalizedStringResource(
      "Microphone readiness", comment: "Microphone settings: row title.")
    static let readinessShort = LocalizedStringResource(
      "How long the mic stays ready after recording.",
      comment: "Microphone settings: short line under the Microphone readiness row title.")
    static let socketShort = LocalizedStringResource(
      "Choose the socket your microphone is plugged into.",
      comment: "Microphone settings: short line under the input socket row.")
    static let socketHelp = LocalizedStringResource(
      "Pick the input your microphone uses. The choice is remembered for this device.",
      comment: "Microphone settings: explains the input socket choice.")
    static let bluetoothShort = LocalizedStringResource(
      "Keeping your mic ready reduces Bluetooth startup delay.",
      comment: "Microphone settings: short line under the Bluetooth guide row.")
    static let bluetoothTipsShort = LocalizedStringResource(
      "Show the Bluetooth reminder once per launch.",
      comment: "Microphone settings, Bluetooth guide: short line under Show Bluetooth tips.")
    static let bluetoothTipsHelp = LocalizedStringResource(
      "Shows the reminder popover once per launch. This guide always stays.")

    static let readinessHelp = LocalizedStringResource(
      "Keep the microphone engine active for a short time after dictation so the next recording starts instantly and captures your first words.",
      comment: "Microphone settings: explains microphone readiness.")
  }

  /// The Engine tab (#3385). Short lines from the approved copy table; every
  /// full explanation behind "?" is the sentence the page showed before.
  enum Engine {
    static let sectionHeading = LocalizedStringResource(
      "TRANSCRIPTION ENGINE",
      comment: "Speech engine settings: section heading above the engine summary, in capitals.")
    static let nextRecordingNote = LocalizedStringResource(
      "Changes apply to the next recording",
      comment:
        "Speech engine settings: note beside the heading; a change made while recording applies next time."
    )
    static let sharedHeading = LocalizedStringResource(
      "APPLIES TO BOTH ENGINES",
      comment:
        "Speech engine settings: heading over settings that work the same on both engines, in capitals."
    )
    static let currentEngineNote = LocalizedStringResource(
      "How these work on this engine",
      comment:
        "Speech engine settings: note beside the current engine's heading. The settings below are shared by both engines; their explanations describe the current one."
    )
    static let keepCurrent = LocalizedStringResource(
      "Keep current engine",
      comment: "Speech engine settings: closes the engine choices without changing the engine.")
    static let changeEngine = LocalizedStringResource(
      "Change speech engine",
      comment: "Speech engine settings: VoiceOver name of the Change button for the engine.")
    static let changeLanguage = LocalizedStringResource(
      "Change dictation language",
      comment: "Speech engine settings: VoiceOver name of the Change button for the locked language.")

    static let fastSummary = LocalizedStringResource(
      "For everyday English and European dictation",
      comment: "Speech engine settings: short line under the fast engine's name.")
    static let allLanguagesSummary = LocalizedStringResource(
      "For other languages or the toughest audio",
      comment: "Speech engine settings: short line under the multilingual engine's name.")

    static let modelNotSetUp = LocalizedStringResource(
      "Model not set up",
      comment: "Speech engine settings: row title when the multilingual engine's model is not downloaded.")
    static let setUpModel = LocalizedStringResource(
      "Set up model",
      comment: "Speech engine settings: button that downloads the multilingual engine's model.")
    static let modelSetupShort = LocalizedStringResource(
      "Runs on your Mac after the model is set up.",
      comment: "Speech engine settings: short line under the model setup row.")
    static let modelSetupHelp = LocalizedStringResource(
      "WhisperKit requires a ~1.5 GB model download. It runs fully on your Mac, no internet needed after setup."
    )

    static let autoDetectTitle = LocalizedStringResource("Auto-detect language")
    static let autoDetectFastShort = LocalizedStringResource(
      "Detects the language you speak. 25 European languages.",
      comment: "Speech engine settings: short line under Auto-detect language on the fast engine.")
    static let autoDetectMultilingualShort = LocalizedStringResource(
      "Detects the language you speak. 99+ languages.",
      comment:
        "Speech engine settings: short line under Auto-detect language on the multilingual engine.")

    static let lockedLanguageShort = LocalizedStringResource(
      "Choose the language for dictation and preview.",
      comment: "Speech engine settings: short line under the locked language row.")
    static let lockedLanguageHelp = LocalizedStringResource(
      "Choose a language, or choose Automatic to clear the lock.",
      comment: "Speech engine settings: explains the locked language row's Change button.")

    static let suggestionsTitle = LocalizedStringResource("Language suggestions")
    static let suggestionsShort = LocalizedStringResource(
      "Allow language suggestions to appear again.",
      comment: "Speech engine settings: short line under the Language suggestions row.")
    static let suggestionsHelp = LocalizedStringResource(
      "Reset to allow the app to suggest locking a detected language again.")

    static let fasterFastShort = LocalizedStringResource(
      "Works during recording; may miss the last words.",
      comment: "Speech engine settings: short line under Faster Transcription on the fast engine.")
    static let fasterMultilingualShort = LocalizedStringResource(
      "Works during recording with a selected language.",
      comment:
        "Speech engine settings: short line under Faster Transcription on the multilingual engine.")

    static let stopOnSilenceTitle = LocalizedStringResource("Stop recording on silence")
    static let stopOnSilenceShort = LocalizedStringResource(
      "Ends recording after you stop speaking.",
      comment: "Speech engine settings: short line under Stop recording on silence.")
    static let stopOnSilenceHelp = LocalizedStringResource(
      "Stops recording when the silence reaches your chosen pause duration.",
      comment: "Speech engine settings: explains Stop recording on silence.")

    static let pauseShort = LocalizedStringResource(
      "How long a pause ends the recording.",
      comment: "Speech engine settings: short line under Pause duration.")
    static let pauseHelp = LocalizedStringResource(
      "How long to wait after you stop speaking before ending the recording.")

    static let fillerTitle = LocalizedStringResource("Remove filler words (um, uh, hmm...)")
    static let fillerShort = LocalizedStringResource(
      "Strips common filler words from transcriptions.")

    static let emojiTitle = LocalizedStringResource(
      "Convert spoken emoji (e.g. \"thumbs up emoji\" → 👍)")
    static let emojiShort = LocalizedStringResource(
      "Say a phrase followed by emoji to get its symbol.",
      comment: "Speech engine settings: short line under the spoken emoji row.")
    static let emojiHelp = LocalizedStringResource(
      "Say \"<phrase> emoji\" to get the glyph. Bare words never convert.")

    static let punctuationShort = LocalizedStringResource(
      "Say comma or new paragraph to insert it.",
      comment: "Speech engine settings: short line under the spoken punctuation row.")

    static let unloadTitle = LocalizedStringResource("Unload model after")
    static let unloadShort = LocalizedStringResource(
      "Frees memory when you are not dictating.",
      comment: "Speech engine settings: short line under the unload model row.")
    static let unloadHelp = LocalizedStringResource(
      "The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2-5 s)."
    )
  }

  /// The Live Preview tab (#3385). Short lines from the approved copy table; the
  /// full explanations are the sentences the page already carried.
  enum Preview {
    static let privacyNote = LocalizedStringResource(
      "Runs on this Mac. Nothing you say is sent anywhere.",
      comment:
        "Live Preview settings: note beside the Live Preview heading. Describes the on-screen preview only, not dictation or AI Polish."
    )
    static let toggleShort = LocalizedStringResource(
      "See words before you finish your dictation.",
      comment: "Live Preview settings: short line under Show words while you speak.")
    static let toggleHelp = LocalizedStringResource(
      "The preview stays on your Mac, disappears when recording ends, and does not change pasted text.",
      comment: "Live Preview settings: explains Show words while you speak.")
    static let languageShort = LocalizedStringResource(
      "This changes dictation too, not just the preview.",
      comment: "Live Preview settings: hover text on the language button.")
    static let appleSummary = LocalizedStringResource(
      "Uses language packs supplied by macOS.",
      comment: "Live Preview settings: short line under the Apple preview engine's name.")
    static let universalSummary = LocalizedStringResource(
      "Uses one downloaded model for supported languages.",
      comment: "Live Preview settings: short line under the Universal preview engine's name.")
    static let engineShort = LocalizedStringResource(
      "Choose which engine shows words while you speak.",
      comment: "Live Preview settings: short line under the Preview engine heading.")
    static let engineHelp = LocalizedStringResource(
      "Choosing an engine does not start a download.",
      comment: "Live Preview settings: explains the preview engine choice.")
    static let installShort = LocalizedStringResource(
      "Download a language from macOS to preview it.",
      comment: "Live Preview settings: short line under Install new languages.")
    static let changeEngine = LocalizedStringResource(
      "Change preview engine",
      comment: "Live Preview settings: VoiceOver name of the Change button for the preview engine.")
    static let keepCurrent = LocalizedStringResource(
      "Keep current preview engine",
      comment: "Live Preview settings: closes the preview engine choices without changing them.")
  }

  /// The Recording Pill tab (#3385). The design names, the refusal sentences,
  /// Configure Live Preview and the Top / Bottom labels already exist and are
  /// reused; these are the two rows' lines and each design's short visible line.
  /// `RecordingPillDesign.summary` stays the longer sentence a screen reader hears.
  enum Pill {
    static let positionTitle = LocalizedStringResource(
      "Position on screen",
      comment: "Recording Pill settings: row title for where the recording pill appears.")
    static let positionShort = LocalizedStringResource(
      "Where the pill floats while you dictate.",
      comment: "Recording Pill settings: short line under Position on screen.")
    static let positionHelp = LocalizedStringResource(
      "Choose Top or Bottom for the recording pill.",
      comment:
        "Recording Pill settings: explains Position on screen. Top and Bottom are the two choices.")

    static let styleTitle = LocalizedStringResource(
      "Style", comment: "Recording Pill settings: row title above the recording pill designs.")
    static let styleShort = LocalizedStringResource(
      "What the floating pill shows while you record.",
      comment: "Recording Pill settings: short line under Style.")
    static let styleHelp = LocalizedStringResource(
      "Capsule and Level Rail show volume. Reading Well shows words and turns Live Preview on.",
      comment:
        "Recording Pill settings: explains Style. Capsule, Level Rail and Reading Well are the design names; Live Preview is a setting."
    )

    static let capsuleShort = LocalizedStringResource(
      "A compact pill with a dot and level meter.",
      comment: "Recording Pill settings: short line under the Capsule design's name.")
    static let levelRailShort = LocalizedStringResource(
      "A slim rail that follows your volume.",
      comment: "Recording Pill settings: short line under the Level Rail design's name.")
    static let readingWellShort = LocalizedStringResource(
      "Shows words as you speak. Turns Live Preview on.",
      comment:
        "Recording Pill settings: short line under the Reading Well design's name. Live Preview is a setting."
    )

    /// One short line per design, exhaustive so a new design cannot ship without one.
    static func shortDescription(for design: RecordingPillDesign) -> LocalizedStringResource {
      switch design {
      case .classic: return capsuleShort
      case .levelRail: return levelRailShort
      case .readingWell: return readingWellShort
      }
    }
  }

  /// The Chimes tab (#3385). The twelve chime names and descriptions, "Preview"
  /// and its VoiceOver template stay with `RecordingChimeCatalog` and the card.
  enum Chimes {
    static let sectionHeading = LocalizedStringResource(
      "RECORDING CHIMES",
      comment: "Chimes settings: section heading above the chime switch and cards, in capitals.")
    static let toggleTitle = LocalizedStringResource(
      "Play recording chimes",
      comment: "Chimes settings: switch that plays a short sound when recording starts and stops.")
    static let toggleShort = LocalizedStringResource(
      "Plays a short chime when recording starts and stops.",
      comment: "Chimes settings: short line under Play recording chimes.")
    /// The sentence the page showed before #3385, unchanged; it is the "?" now.
    static let toggleHelp = LocalizedStringResource(
      "Plays a short sound when recording starts and stops. People nearby may hear it.",
      comment: "Chimes settings: explains Play recording chimes.")
    static let previewExplanation = LocalizedStringResource(
      "Hear this chime without changing your choice.",
      comment:
        "Chimes settings: line above the chime cards. Each card's play button previews that chime without selecting it."
    )
    /// Unchanged sentence; now also shown under the explanation while Preview is off.
    static let previewUnavailable = LocalizedStringResource(
      "Preview is unavailable while a recording is in progress.",
      comment: "Chimes settings: why the play buttons are disabled while dictating.")
    static let inUse = LocalizedStringResource(
      "IN USE",
      comment: "Chimes settings: small badge on the chime that recordings use, in capitals.")
  }
}
