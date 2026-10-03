import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Engine tab's words. Each row gains one short line, the full explanation behind
/// "?" keeps the English it had before, and the headings follow the founder's Q5 decision:
/// the current engine's group explains how shared settings work HERE, and never claims a
/// setting belongs only to this engine. Expected strings typed from the approved copy table
/// and the pre-#3385 source, not read from the code under test.
@Suite("Engine settings copy (#3385)", .tags(.productOutcome))
struct EngineSettingsCopyTests {
  typealias Copy = DictationSettingsCopy.Engine

  @Test("compact readiness and real installed pack counts keep honest words")
  func summaryCopy() {
    #expect(EngineSummaryCopy.ready == "Ready")
    #expect(EngineSummaryCopy.off == "Off")
    #expect(String(localized: EngineSummaryCopy.recheckFast) == "Re-check Fast model status")
    #expect(EngineSummaryCopy.installedPacks(installed: 0, total: 0) == "0 of 0 installed on this Mac")
    #expect(EngineSummaryCopy.installedPacks(installed: 1, total: 3) == "1 of 3 installed on this Mac")
    #expect(EngineSummaryCopy.installedPacks(installed: 3, total: 3) == "3 of 3 installed on this Mac")
  }

  @Test("headings, notes and the Change labels keep their English")
  func headings() {
    #expect(String(localized: Copy.sectionHeading) == "TRANSCRIPTION ENGINE")
    #expect(String(localized: Copy.nextRecordingNote) == "Changes apply to the next recording")
    #expect(String(localized: Copy.sharedHeading) == "APPLIES TO BOTH ENGINES")
    #expect(String(localized: Copy.keepCurrent) == "Keep current engine")
    #expect(String(localized: Copy.changeEngine) == "Change speech engine")
    #expect(String(localized: Copy.changeLanguage) == "Change dictation language")
    #expect(String(localized: Copy.modelNotSetUp) == "Model not set up")
    #expect(String(localized: Copy.setUpModel) == "Set up model")
  }

  @Test("both engines' short lines are their own, and every short line fits")
  func shortLines() {
    let expected: [(LocalizedStringResource, String)] = [
      (Copy.fastSummary, "For everyday English and European dictation"),
      (Copy.allLanguagesSummary, "For other languages or the toughest audio"),
      (Copy.modelSetupShort, "Runs on your Mac after the model is set up."),
      (Copy.autoDetectFastShort, "Detects the language you speak. 25 European languages."),
      (Copy.autoDetectMultilingualShort, "Detects the language you speak. 99+ languages."),
      (Copy.lockedLanguageShort, "Choose the language for dictation and preview."),
      (Copy.fasterFastShort, "Works during recording; may miss the last words."),
      (Copy.fasterMultilingualShort, "Works during recording with a selected language."),
      (Copy.stopOnSilenceShort, "Ends recording after you stop speaking."),
      (Copy.pauseShort, "How long a pause ends the recording."),
      (Copy.fillerShort, "Strips common filler words from transcriptions."),
      (Copy.emojiShort, "Say a phrase followed by emoji to get its symbol."),
      (Copy.punctuationShort, "Say comma or new paragraph to insert it."),
      (Copy.unloadShort, "Frees memory when you are not dictating."),
    ]
    for (resource, english) in expected {
      let actual = String(localized: resource)
      #expect(actual == english)
      #expect(actual.count <= 60, "\(actual) is \(actual.count) characters")
    }
  }

  @Test("the full explanations moved behind \"?\" keep their English")
  func helpUnchanged() {
    #expect(
      String(localized: Copy.modelSetupHelp)
        == "WhisperKit requires a ~1.5 GB model download. It runs fully on your Mac, no internet needed after setup."
    )
    #expect(
      String(localized: Copy.suggestionsHelp)
        == "Reset to allow the app to suggest locking a detected language again.")
    #expect(
      String(localized: Copy.pauseHelp)
        == "How long to wait after you stop speaking before ending the recording.")
    #expect(
      String(localized: Copy.emojiHelp)
        == "Say \"<phrase> emoji\" to get the glyph. Bare words never convert.")
    #expect(
      String(localized: Copy.unloadHelp)
        == "The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2-5 s)."
    )
    #expect(
      String(localized: Copy.lockedLanguageHelp)
        == "Choose a language, or choose Automatic to clear the lock.")
    #expect(
      String(localized: Copy.stopOnSilenceHelp)
        == "Stops recording when the silence reaches your chosen pause duration.")
  }

  @Test("no heading or note says a shared setting belongs to one engine")
  func noOnlyForThisEngine() {
    let all = [
      Copy.sectionHeading, Copy.nextRecordingNote, Copy.sharedHeading, Copy.currentEngineNote,
    ].map { String(localized: $0).lowercased() }
    #expect(all.allSatisfy { $0.contains("only for this engine") == false })
  }
}
