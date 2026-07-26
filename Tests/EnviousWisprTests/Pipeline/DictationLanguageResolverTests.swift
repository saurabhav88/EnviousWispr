import Testing

@testable import EnviousWisprPipeline

// What language a finished dictation is in (#1785, cloud review on PR #1802).
//
// The repair only recases languages whose rules it knows, so a WRONG answer here
// lowercases a correctly capitalised German noun. Everything below exists to
// pin one property: the resolver answers from positive evidence and abstains
// when it has none.
@Suite("DictationLanguageResolver")
struct DictationLanguageResolverTests {

  /// Long enough to clear the recognizer's length floor, and unambiguous.
  static let germanText = "Ich gehe heute Abend zum See und danach in die Stadt zurück."
  static let englishText = "I went to the store this afternoon and then walked back home again."

  @Test("An engine that hard-codes a language is not evidence")
  func hardCodedEngineLanguageIsIgnored() {
    // `ParakeetBackend` stamps `"en"` on every result while transcribing 25
    // European languages, and it is the DEFAULT engine. Believing that field
    // recased German dictations with English rules.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: Self.germanText)
    #expect(resolved == "de", "the text itself settles it, not the engine's constant")
  }

  @Test("An engine that really detects is believed")
  func detectingEngineIsAuthoritative() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: true,
      engineReportedLanguage: "fr",
      text: Self.englishText)
    #expect(resolved == "fr", "a detected language outranks anything inferred from the text")
  }

  @Test("A locked language outranks every inference")
  func lockedLanguageWins() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: "de",
      engineDetectsLanguage: true,
      engineReportedLanguage: "en",
      text: Self.englishText)
    #expect(resolved == "de", "the user told us; that is not ours to second-guess")
  }

  @Test("English on a hard-coding engine still resolves to English")
  func englishStillWorksOnTheDefaultEngine() {
    // The fix must not cost the majority case its feature.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: Self.englishText)
    #expect(resolved == "en")
  }

  @Test(
    "Text too short to identify, with nothing around it, returns nothing",
    arguments: ["Store today.", "Yes.", "Okay then", ""])
  func shortTextAloneAbstains(_ text: String) {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: text)
    #expect(resolved == nil, "\(text.debugDescription)")
  }

  @Test("A short continuation is identified from the document around it")
  func shortTextUsesTheSurroundingDocument() {
    // "Store is closed today" is 18 alphabetic scalars — under the floor. On the
    // default engine that meant the feature never fired for exactly the short
    // mid-sentence insertions it was built for (cloud review, PR #1802).
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Store is closed today",
      surroundingText: "I went to the shop this morning and then walked back")
    #expect(resolved == "en")
  }

  @Test("A short insertion into a German document is not called English")
  func shortTextInAGermanDocumentIsGerman() {
    // The case that matters: the dictation is too short to identify, the
    // document says German, so casing is skipped rather than applied wrongly.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Start ist heute",
      surroundingText: "Ich gehe heute Abend zum See und danach in die Stadt")
    #expect(resolved == "de")
  }

  @Test("An unidentifiable dictation in an unidentifiable document still abstains")
  func shortTextWithShortSurroundingsAbstains() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Yes.",
      surroundingText: "Ok, ")
    #expect(resolved == nil)
  }

  @Test("A detecting engine that reported nothing falls through to the text")
  func detectingEngineWithNoAnswerFallsThrough() {
    // WhisperKit streaming with language on auto reports no language at all.
    // Previously that meant "unknown" and no casing; now the text is asked.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: true,
      engineReportedLanguage: nil,
      text: Self.englishText)
    #expect(resolved == "en")
  }

  @Test("An empty locked code is not a lock")
  func emptyLockIsIgnored() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: "",
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: Self.germanText)
    #expect(resolved == "de")
  }
}
