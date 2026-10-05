import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The language route's text entry (#1677, chunk 2)
//
// With ZERO language passes the package entry `normalize(_:language:)` must equal today's neutral
// subset and must never reach the English lexicon. Expectations are literal.
//
// When this fails, a foreign take either loses address/code cleanup it gets today, or an English
// rule rewrites foreign words (German "um 7 am Abend" becoming "7:00 AM").

@Suite("InverseTextNormalizer language entry (#1677)", .tags(.productOutcome))
struct InverseTextNormalizerLanguageTests {

  private let engine = InverseTextNormalizer()
  private var de: LanguageRuleSet { LanguageRuleSet(language: "de")! }
  private var es: LanguageRuleSet { LanguageRuleSet(language: "es")! }

  @Test("neutral conversions still happen through the language entry")
  func neutralConversionsHappen() {
    #expect(
      engine.normalize("mandalo a marco arroba esempio punto com", language: es)
        == "mandalo a marco@esempio.com")
    #expect(
      engine.normalize("Frage B Bindestrich 2, Code zwei null drei", language: de)
        == "Frage B-2, Code zwei null drei")
  }

  @Test("the English lexicon never runs: German 'um 7 am Abend' and English number words stay")
  func englishLexiconNeverRuns() {
    let german = "Ruf mich bitte um 7 am Abend an."
    #expect(engine.normalize(german, language: de) == german)
    let english = "the code is two zero three and the room is thirty five"
    #expect(engine.normalize(english, language: de) == english)
    // Controls: the English entry WOULD have changed both.
    #expect(engine.normalize(german) != german)
    #expect(engine.normalize(english) != english)
  }

  @Test("it equals the neutral subset on a battery of inputs")
  func equalsNeutralSubset() {
    let inputs = [
      "mandalo a marco arroba esempio punto com",
      "Schick das an thomas punkt mueller at beispiel punkt de",
      "Frage B Bindestrich 2, Code zwei null drei",
      "ejemplo punto es barra ayuda",
      "plain prose with nothing to convert",
      "",
    ]
    for input in inputs {
      #expect(
        engine.normalize(input, language: de) == engine.normalizeLanguageNeutral(input),
        "\(input.debugDescription)")
    }
  }

  @Test("untouched input returns byte for byte, including whitespace and decomposed Unicode")
  func noOpIsByteIdentical() {
    let input = "  Ruhe\u{0301} bitte,\r\num sieben am Abend.\n  "
    let out = engine.normalize(input, language: de)
    #expect(Array(out.utf8) == Array(input.utf8))
  }

  @Test("already-formatted input is unchanged and a second pass changes nothing")
  func idempotent() {
    let written = "mandalo a marco@esempio.com"
    #expect(engine.normalize(written, language: es) == written)
    let once = engine.normalize("mandalo a marco arroba esempio punto com", language: es)
    #expect(engine.normalize(once, language: es) == once)
  }
}
