import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #2450: what a user may type into the "Start word" field, and the settings value that carries it.
///
/// **Product Outcome.** When these fail, a user either cannot enter a start word they should be allowed
/// to use, or saves one that breaks their dictation (two words, a digit, or a word that is itself one of
/// the commands). Expectations are literal; `SpokenPunctuationRules` only supplies the forms the validator
/// is handed, as the settings boundary will.
@Suite(.tags(.productOutcome))
struct SpokenPunctuationStartWordTests {

  private static func validate(_ raw: String, _ language: String = "de")
    -> SpokenPunctuationStartWord
    .Outcome
  {
    SpokenPunctuationStartWord.validate(
      raw, language: language, spokenForms: SpokenPunctuationRules.spokenForms(for: language) ?? [])
  }

  private static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

  // MARK: - The shipped defaults are acceptable

  @Test(
    "Every shipped default start word passes its own validator",
    arguments: [("de", "Diktiere"), ("fr", "Place"), ("es", "Añade"), ("it", "Metti")])
  func defaultsAreAccepted(language: String, word: String) {
    #expect(SpokenPunctuationRules.defaultStartWord(for: language) == word)
    #expect(Self.validate(word, language) == .accepted(word))
  }

  // MARK: - Trimming and normalisation

  @Test("Outer whitespace is trimmed, inner case is kept")
  func trimsOuterWhitespace() {
    #expect(Self.validate("  Diktiere \n") == .accepted("Diktiere"))
    #expect(Self.validate("diktiere") == .accepted("diktiere"))
  }

  @Test("A decomposed spelling is stored in NFC, compared as scalars")
  func decomposedInputIsStoredNFC() throws {
    let decomposed = "Inse\u{0300}re"
    #expect(Self.scalars(decomposed) != Self.scalars("Insère"))
    guard case .accepted(let stored) = Self.validate(decomposed, "fr") else {
      Issue.record("a decomposed start word was refused")
      return
    }
    #expect(Self.scalars(stored) == Self.scalars("Insère"))
  }

  // MARK: - Refusals, one per class

  @Test("Empty input is refused", arguments: ["", "   ", "\t\n"])
  func emptyIsRefused(raw: String) {
    #expect(Self.validate(raw) == .refused(.empty))
  }

  @Test("Two tokens are refused, not joined", arguments: ["setze dich", "mach\tdas"])
  func twoTokensAreRefused(raw: String) {
    #expect(Self.validate(raw) == .refused(.notOneToken))
  }

  @Test(
    "Digits, punctuation and misplaced separators are refused",
    arguments: [
      "set3", "setze!", "-setze", "setze-", "'setze", "setze'", "se--tze", "se'-tze", "setze.x",
    ]
  )
  func invalidCharactersAreRefused(raw: String) {
    #expect(Self.validate(raw) == .refused(.invalidCharacters))
  }

  @Test("An apostrophe or hyphen strictly inside a word is accepted")
  func innerSeparatorsAreAccepted() {
    #expect(Self.validate("mets-moi", "fr") == .accepted("mets-moi"))
    #expect(Self.validate("l'ordre", "fr") == .accepted("l'ordre"))
  }

  @Test("Length is 2 to 20 scalars after normalisation, both edges")
  func lengthBounds() {
    #expect(Self.validate("a") == .refused(.tooShort))
    #expect(Self.validate("ab") == .accepted("ab"))
    #expect(
      Self.validate(String(repeating: "a", count: 20))
        == .accepted(String(repeating: "a", count: 20)))
    #expect(Self.validate(String(repeating: "a", count: 21)) == .refused(.tooLong))
  }

  @Test("The bound counts scalars of the NFC form, so an accented letter counts once")
  func lengthIsCountedAfterNormalisation() {
    // 10 decomposed "e" + grave pairs are 20 scalars NFD but only 10 in NFC.
    let decomposed = String(repeating: "e\u{0300}", count: 10)
    #expect(Self.scalars(decomposed).count == 20)
    guard case .accepted(let stored) = Self.validate(decomposed, "fr") else {
      Issue.record("a ten-letter decomposed start word was refused")
      return
    }
    #expect(Self.scalars(stored) == Array(repeating: UInt32(0x00E8), count: 10))
  }

  // MARK: - Collisions with the language's own commands

  @Test(
    "A start word equal to a command form, or to its first word, is refused",
    arguments: [
      ("de", "Punkt"), ("de", "KOMMA"), ("de", "neue"), ("de", "Neuabsatz"),
      ("fr", "point"), ("fr", "virgule"), ("fr", "nouvelle"), ("fr", "deux"),
      ("es", "punto"), ("es", "coma"), ("es", "signo"), ("es", "nuevo"),
      ("it", "punto"), ("it", "virgola"), ("it", "nuova"), ("it", "due"),
    ])
  func collisionsAreRefused(language: String, word: String) {
    #expect(Self.validate(word, language) == .refused(.collidesWithCommand))
  }

  @Test("Case folding follows the language tag, including a regional one")
  func collisionIgnoresCaseAndRegion() {
    #expect(Self.validate("PUNKT", "de-DE") == .refused(.collidesWithCommand))
    #expect(Self.validate("Point", "fr_FR") == .refused(.collidesWithCommand))
  }

  @Test("A word that only CONTAINS a command is not a collision")
  func containingIsNotColliding() {
    #expect(Self.validate("Punktuation") == .accepted("Punktuation"))
    #expect(Self.validate("pointe", "fr") == .accepted("pointe"))
  }

  @Test("Forms are data: an unknown language with no forms accepts any valid word")
  func noFormsMeansNoCollisions() {
    #expect(
      SpokenPunctuationStartWord.validate("Punkt", language: "xx", spokenForms: [])
        == .accepted("Punkt"))
  }

  // MARK: - The settings value

  @Test("The default settings value is off with nothing customised")
  func offIsTheDefault() {
    #expect(SpokenPunctuationSettings.off.enabled == false)
    #expect(SpokenPunctuationSettings.off.startWordOverrides.isEmpty)
    #expect(
      SpokenPunctuationSettings.off
        == SpokenPunctuationSettings(enabled: false, startWordOverrides: [:]))
  }

  @Test("Two values differ by enablement and by overrides")
  func equalityTracksBothFields() {
    let base = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Sprich"])
    #expect(
      base != SpokenPunctuationSettings(enabled: false, startWordOverrides: ["de": "Sprich"]))
    #expect(base != SpokenPunctuationSettings(enabled: true, startWordOverrides: [:]))
    #expect(
      base == SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Sprich"]))
  }
}
