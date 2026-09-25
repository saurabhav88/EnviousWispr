import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprModelDelivery

/// #3142: speech-engine and language Settings copy that is localized where it is authored keeps
/// its English bytes, checked against literals taken from the pre-localization source. Unit tests
/// run outside the app bundle, so they always read English.
@Suite("Speech settings copy", .tags(.productOutcome))
struct SpeechSettingsCopyTests {

  @Test("Faster Transcription's toggle, footnote and both help panels keep their English")
  func fasterTranscription() {
    #expect(LiveTranscriptionCopy.toggleLabel == "Faster Transcription")
    #expect(
      LiveTranscriptionCopy.helpButtonAccessibilityLabel == "What does Faster Transcription change?"
    )
    #expect(
      LiveTranscriptionCopy.autoLanguageFootnote
        == "Faster Transcription needs a selected language. With Auto-detect, EnviousWispr uses clean batch transcription for accuracy."
    )
    #expect(
      LiveTranscriptionCopy.parakeetToggleDescription
        == "Transcribes while you speak instead of once when you stop. Nothing looks different while you record; this only changes when the work happens. It does not save time you can notice on most dictations, and it can drop your last few words."
    )
    #expect(
      LiveTranscriptionCopy.whisperKitToggleDescription
        == "Transcribes while you speak instead of once when you stop. Nothing looks different while you record; this only changes when the work happens. It mainly helps on long recordings, and it needs a language selected."
    )
    #expect(LiveTranscriptionCopy.parakeet.title == "What Faster Transcription changes")
    #expect(LiveTranscriptionCopy.parakeet.speedHeading == "Speed")
    #expect(
      LiveTranscriptionCopy.parakeet.speedBody
        == "On dictations under a minute, both settings finish at about the same moment. The difference is smaller than you can feel. It only pulls ahead on recordings of roughly five minutes or longer."
    )
    #expect(LiveTranscriptionCopy.parakeet.accuracyHeading == "Accuracy, measured")
    #expect(
      LiveTranscriptionCopy.parakeet.accuracyBody
        == "About 1 in 24 dictations lost its final words with this on, compared with the same recording transcribed after stopping."
    )
    #expect(LiveTranscriptionCopy.parakeet.whyHeading == "Why this happens")
    #expect(
      LiveTranscriptionCopy.parakeet.whyBody
        == "With this on, EnviousWispr transcribes overlapping chunks of audio while you talk and joins them together. When two chunks disagree about the same moment of speech, nothing can tell which reading was right. The longer you talk, the more joins there are, so the problem grows with length."
    )
    #expect(LiveTranscriptionCopy.parakeet.recommendationHeading == "What we recommend")
    #expect(
      LiveTranscriptionCopy.parakeet.recommendationBody
        == "Leave this off. If you regularly dictate for five minutes or more in one go it may be worth the trade, and the risk of a lost ending is highest there too."
    )
    #expect(
      LiveTranscriptionCopy.parakeet.footnote
        == "Measured on 28 test recordings and a replay of 500 real dictations, comparing both settings on the same audio."
    )
    #expect(
      LiveTranscriptionCopy.parakeet.comparisons.map(\.metric) == [
        "Word errors", "Repeated or invented words",
      ])
    #expect(LiveTranscriptionCopy.whisperKit.title == "What Faster Transcription changes")
    #expect(LiveTranscriptionCopy.whisperKit.speedHeading == "Speed")
    #expect(
      LiveTranscriptionCopy.whisperKit.speedBody
        == "On short dictations you will not notice a difference. On long ones it helps clearly: transcribing after you stop gets slower the longer you spoke, while transcribing as you go stays about the same however long the recording is."
    )
    #expect(LiveTranscriptionCopy.whisperKit.accuracyHeading == "Accuracy")
    #expect(
      LiveTranscriptionCopy.whisperKit.accuracyBody
        == "On this engine, transcribing as you go is about as accurate as waiting until you stop. It can still occasionally drop a final word or two, which we are working on."
    )
    #expect(LiveTranscriptionCopy.whisperKit.whyHeading == "One thing to know")
    #expect(
      LiveTranscriptionCopy.whisperKit.whyBody
        == "This engine has to commit to a language before it can start. If your language is set to Auto-detect, EnviousWispr ignores this setting and transcribes after you stop instead, because guessing the language early gets it wrong too often."
    )
    #expect(LiveTranscriptionCopy.whisperKit.recommendationHeading == "What we recommend")
    #expect(
      LiveTranscriptionCopy.whisperKit.recommendationBody
        == "If you pick a specific language and often dictate for more than a minute, turn this on. Otherwise it makes little difference either way."
    )
    #expect(
      LiveTranscriptionCopy.whisperKit.footnote
        == "This engine transcribes differently from the Fast engine, so its behaviour and the advice here are not the same."
    )
    #expect(LiveTranscriptionCopy.whisperKit.comparisons.isEmpty)
    #expect(LiveTranscriptionCopy.parakeet.comparisons.map(\.off) == ["2.0%", "17"])
    #expect(LiveTranscriptionCopy.parakeet.comparisons.map(\.on) == ["3.7%", "51"])
  }

  @Test("the spoken-punctuation setting keeps its English, and spoken phrases stay as spoken")
  func spokenPunctuation() {
    #expect(SpokenPunctuationCopy.toggleLabel == "Convert spoken punctuation")
    #expect(
      SpokenPunctuationCopy.toggleDescription
        == "Say punctuation out loud to insert it. EnviousWispr already adds punctuation for you, so this can compete with it."
    )
    #expect(SpokenPunctuationCopy.helpButtonAccessibilityLabel == "What can I say?")
    #expect(SpokenPunctuationCopy.helpTitle == "Words you can say")
    #expect(SpokenPunctuationCopy.helpSayColumn == "Say this")
    #expect(SpokenPunctuationCopy.helpGetColumn == "You get")
    #expect(
      SpokenPunctuationCopy.helpFootnote
        == "These words become marks even when you meant the word itself, like \"the grace period expires\". Slash works with this setting off: \"slash clear\" becomes /clear, \"command is slash wfp\" becomes command is /wfp, \"pros slash cons\" becomes pros/cons, and \"slash the budget\" stays words. Some verb uses, like \"slash prices\", can still become a symbol."
    )
    let lineBreaks = SpokenPunctuationCopy.phrases.filter { $0.spoken.hasPrefix("new ") }
    #expect(lineBreaks.map(\.spoken) == ["new line", "new paragraph"])
    #expect(lineBreaks.map(\.result) == ["a line break", "a blank line"])
  }

  @Test("every speech-model download failure keeps its English")
  func deliveryFailures() {
    #expect(
      ModelDeliveryCopy.message(reason: .sourceUnreachable, detail: nil)
        == "Can't reach the download server. Check your connection and try again.")
    #expect(
      ModelDeliveryCopy.message(reason: .insufficientDisk, detail: nil)
        == "Not enough free space to install the speech model. Free up about 1 GB and try again.")
    #expect(
      ModelDeliveryCopy.message(reason: .integrityMismatch, detail: "intercepted_network")
        == "If you are on hotel or public Wi-Fi, finish signing in to the network, then try again.")
    #expect(
      ModelDeliveryCopy.message(reason: .integrityMismatch, detail: nil)
        == "The download couldn't be verified. Try again, and if this keeps happening, contact support."
    )
    #expect(
      ModelDeliveryCopy.message(reason: .cancelled, detail: nil)
        == "Download paused. Resume anytime.")
    #expect(
      ModelDeliveryCopy.message(reason: .unknown, detail: nil)
        == "The download couldn't finish. Try again, and if this keeps happening, contact support.")
  }

  @Test("model unload choices keep their English names")
  func unloadPolicyNames() {
    #expect(
      ModelUnloadPolicy.allCases.map(\.displayName) == [
        "Never", "Immediately", "After 2 minutes", "After 5 minutes", "After 10 minutes",
        "After 15 minutes", "After 1 hour",
      ])
  }

  @Test("the model row keeps its two labels")
  func modelPreparing() {
    #expect(
      ModelPreparingCopy.preparing
        == "Getting the model ready. This usually takes about 30 seconds.")
    #expect(ModelPreparingCopy.ready == "Model Ready")
  }

  /// In English the shown name IS the English name, so the display order is exactly the old
  /// English order, and English (UK) still sits right after English.
  @Test("in English, language names and their order are unchanged")
  func languageDisplayInEnglish() throws {
    for entry in LanguageCatalog.all + [LanguageCatalog.englishUK] {
      #expect(entry.displayName == entry.englishName, Comment(rawValue: entry.code))
    }
    #expect(
      LanguageCatalog.sortedForDisplay.map(\.code)
        == LanguageCatalog.sortedByEnglishName.map(\.code))
    let codes = LanguageCatalog.pickerEntries.map(\.code)
    let english = try #require(codes.firstIndex(of: "en"))
    #expect(codes[english + 1] == "en-gb")
  }

  @Test("a code the catalog does not know reads as itself")
  func unknownCodeFallback() {
    let entry = LanguageCatalog.entry(for: "zz")
    #expect(entry.englishName == "ZZ")
    #expect(entry.displayName == "ZZ")
    #expect(entry.nativeName == "ZZ")
  }

  @Test("the English rows describe their spelling")
  func spellingSubtitles() {
    #expect(
      LanguageCatalog.pickerSubtitle(for: LanguageCatalog.englishUK)
        == "British spelling: colour, organise, centre")
    #expect(
      LanguageCatalog.pickerSubtitle(for: LanguageCatalog.entry(for: "en"))
        == "American spelling: color, organize, center")
  }
}
