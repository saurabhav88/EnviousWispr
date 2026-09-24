import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3124 English (UK): the American to British converter over the SHIPPED table.
///
/// Every expected string is written out by hand. None is derived from the table or the converter,
/// so a wrong mapping or a wrong token rule fails here rather than agreeing with itself.
/// When one of these fails, a British user sees American spelling, or a name or a piece of code
/// respelled.
@Suite("BritishSpellingConverter — shipped table", .tags(.productOutcome))
struct BritishSpellingConverterTests {
  static let converter: BritishSpellingConverter = {
    do {
      return try BritishSpellingConverter.load()
    } catch {
      fatalError("british-spelling.json failed to load from Bundle.module: \(error)")
    }
  }()

  struct Case: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String
    /// Tokens that change between input and expected, counted by hand.
    let swaps: Int
    var testDescription: String { input }
  }

  /// Labelled corpus. Persona-style dictation plus the known hazards: sense-dependent words, names
  /// mid-sentence and at a sentence start, quotations, hyphen compounds, code, possessives.
  static let corpus: [Case] = [
    // Persona-style prose.
    Case(
      input: "the organization needs to prioritize the review",
      expected: "the organisation needs to prioritise the review", swaps: 2),
    Case(
      input: "can you center the logo and change the color to gray",
      expected: "can you centre the logo and change the colour to grey", swaps: 3),
    Case(
      input: "I realized the analysis was favorable",
      expected: "I realised the analysis was favourable", swaps: 2),
    Case(
      input: "we traveled to the theater on Tuesday",
      expected: "we travelled to the theatre on Tuesday", swaps: 2),
    Case(input: "my mom's neighbor", expected: "my mum's neighbour", swaps: 2),
    Case(
      input: "The organization moved its color printer to the center of the room.",
      expected: "The organisation moved its colour printer to the centre of the room.", swaps: 3),
    Case(
      input: "quick note the defense team apologized for the delay",
      expected: "quick note the defence team apologised for the delay", swaps: 2),
    Case(
      input: "session notes patient reports behavior changes and elevated anxiety",
      expected: "session notes patient reports behaviour changes and elevated anxiety", swaps: 1),
    Case(
      input: "the pediatric ward uses aluminum trays",
      expected: "the paediatric ward uses aluminium trays", swaps: 2),
    Case(
      input: "we canceled the catalog order and labeled the boxes",
      expected: "we cancelled the catalogue order and labelled the boxes", swaps: 3),
    Case(
      input: "that was a humorous rumor about the harbor",
      expected: "that was a humorous rumour about the harbour", swaps: 2),
    Case(input: "my favorite flavors", expected: "my favourite flavours", swaps: 2),
    Case(
      input: "standardize on the hook version in the next refactor",
      expected: "standardise on the hook version in the next refactor", swaps: 1),
    Case(
      input: "the jewelry was in the gray drawer",
      expected: "the jewellery was in the grey drawer", swaps: 2),
    // Sense-dependent words stay as transcribed: the table excludes them.
    Case(
      input: "please check the program and practice the license test",
      expected: "please check the program and practice the license test", swaps: 0),
    Case(
      input: "the meter on the tire and the story of the draft",
      expected: "the meter on the tire and the story of the draft", swaps: 0),
    Case(
      input: "among the things I learned and spelled",
      expected: "among the things I learned and spelled", swaps: 0),
    // Names in mid-sentence stay; the same word at a sentence start converts.
    Case(
      input: "We met at the Kennedy Center on Labor Day.",
      expected: "We met at the Kennedy Center on Labor Day.", swaps: 0),
    Case(
      input: "Color me impressed. Center stage!", expected: "Colour me impressed. Centre stage!",
      swaps: 2),
    Case(
      input: "hello there\nColor matters here",
      expected: "hello there\nColour matters here", swaps: 1),
    Case(input: "Is it Gray or gray?", expected: "Is it Gray or grey?", swaps: 1),
    // Quotations and brackets.
    Case(
      input: "\"Color\" she said. (Center)", expected: "\"Colour\" she said. (Centre)", swaps: 2),
    Case(input: "she said “color” twice", expected: "she said “colour” twice", swaps: 1),
    Case(input: "I love the color.", expected: "I love the colour.", swaps: 1),
    Case(input: "what color? that color!", expected: "what colour? that colour!", swaps: 2),
    Case(input: "it said \"the color.\" then", expected: "it said \"the colour.\" then", swaps: 1),
    // Hyphen compounds are prose.
    Case(
      input: "it's color-coded and well-organized",
      expected: "it's colour-coded and well-organised", swaps: 2),
    Case(input: "the gray-blue sky", expected: "the grey-blue sky", swaps: 1),
    // Possessives and apostrophes.
    Case(input: "the organization's plans", expected: "the organisation's plans", swaps: 1),
    Case(
      input: "The neighbor’s favorite colors.", expected: "The neighbour’s favourite colours.",
      swaps: 3),
    // List items and headings start a sentence (polish writes lists with a capital first word).
    Case(
      input: "Plan:\n- Color choices\n* Center the logo\n+ Favorite fonts\n\u{2022} Gray tones",
      expected: "Plan:\n- Colour choices\n* Centre the logo\n+ Favourite fonts\n\u{2022} Grey tones",
      swaps: 4),
    Case(input: "1) Color first\n2. Center next", expected: "1) Colour first\n2. Centre next", swaps: 2),
    Case(input: "## Color guide", expected: "## Colour guide", swaps: 1),
    // A dash or bracket INSIDE a line is not a list marker: the name stays.
    Case(input: "we met - Kennedy Center staff", expected: "we met - Kennedy Center staff", swaps: 0),
    Case(input: "see (a) Color Street", expected: "see (a) Color Street", swaps: 0),
    // Case the converter must refuse.
    Case(input: "COLOR and CoLoR stay", expected: "COLOR and CoLoR stay", swaps: 0),
    // Code, paths, addresses, numbers.
    Case(
      input: "open color.js and self.color and my_color",
      expected: "open color.js and self.color and my_color", swaps: 0),
    Case(
      input: "see https://center.io/color for details",
      expected: "see https://center.io/color for details", swaps: 0),
    Case(
      input: "20colors #color $color a=color <color> user@color",
      expected: "20colors #color $color a=color <color> user@color", swaps: 0),
    Case(input: "set color:red then", expected: "set color:red then", swaps: 0),
    Case(input: "the color: here it is", expected: "the colour: here it is", swaps: 1),
    Case(input: "caféColor stays", expected: "caféColor stays", swaps: 0),
    // Nothing to convert: identical output.
    Case(
      input: "running fifteen minutes late got stuck on the client call",
      expected: "running fifteen minutes late got stuck on the client call", swaps: 0),
    Case(input: "", expected: "", swaps: 0),
    Case(input: "   ", expected: "   ", swaps: 0),
  ]

  @Test("labelled corpus: exact British output, no harmful change", arguments: corpus)
  func corpusCase(_ testCase: Case) {
    let result = Self.converter.convert(testCase.input)
    #expect(result.text == testCase.expected)
    #expect(result.swaps == testCase.swaps)
  }

  @Test("corpus covers conversions and protections in real numbers")
  func corpusCounts() {
    let converting = Self.corpus.filter { $0.swaps > 0 }
    let untouched = Self.corpus.filter { $0.swaps == 0 }
    #expect(Self.corpus.count >= 40)
    #expect(converting.count >= 20)
    #expect(untouched.count >= 10)
    var harmful = 0
    for testCase in Self.corpus
    where Self.converter.convert(testCase.input).text != testCase.expected {
      harmful += 1
    }
    #expect(harmful == 0)
  }

  @Test("an unchanged text comes back byte for byte")
  func unchangedIsIdentical() {
    let input = "Plain words, nothing to convert.\n\tTabs  and  spaces stay."
    let result = Self.converter.convert(input)
    #expect(result.swaps == 0)
    #expect(Array(result.text.utf8) == Array(input.utf8))
  }

  @Test("British text is left as it is")
  func idempotentOnBritish() {
    let input = "The organisation moved its colour printer to the centre."
    let result = Self.converter.convert(input)
    #expect(result.swaps == 0)
    #expect(result.text == input)
  }

  @Test("Custom Words are never respelled")
  func customWordsProtected() {
    let result = Self.converter.convert(
      "the color of Center Parcs and the center", protectedWords: ["color", "center"])
    #expect(result.text == "the color of Center Parcs and the center")
    #expect(result.swaps == 0)
  }

  @Test("a snippet sentinel survives byte for byte, and the words around it still convert")
  func sentinelProtected() {
    let sentinel = "EWSNIPcolorab12cd34"
    let result = Self.converter.convert(
      "the color \(sentinel) color", protectedSpans: [sentinel])
    #expect(result.text == "the colour \(sentinel) colour")
    #expect(result.swaps == 2)
  }

  @Test("a protected span holding a convertible word keeps it; the same word outside converts")
  func protectedSpanWithConvertibleWord() {
    let span = "[[color]]"
    let result = Self.converter.convert(
      "the color \(span) and \(span) color", protectedSpans: [span, "unused"])
    #expect(result.text == "the colour \(span) and \(span) colour")
    #expect(result.swaps == 2)
  }

  @Test("overlapping protected spans are all honoured")
  func overlappingSpans() {
    let result = Self.converter.convert("x color and color", protectedSpans: ["x ", " color"])
    #expect(result.text == "x color and color")
    #expect(result.swaps == 0)
  }

  @Test("the shipped table maps the core words and excludes sense-dependent and name entries")
  func tableSanity() throws {
    let expectedMappings: [(String, String)] = [
      ("color", "colour"), ("center", "centre"), ("organization", "organisation"),
      ("analyze", "analyse"), ("traveled", "travelled"), ("gray", "grey"),
      ("defense", "defence"), ("theater", "theatre"),
    ]
    for (american, british) in expectedMappings {
      #expect(Self.converter.convert(american).text == british)
    }
    let excluded = [
      "program", "check", "practice", "license", "meter", "tire", "story", "among", "learned",
      "spelled", "draft", "curb",
    ]
    for word in excluded {
      #expect(Self.converter.convert(word).text == word)
    }
    #expect(Self.converter.entryCount > 5_000)
  }

  @Test("10,000 words with 50 protected sentinels convert inside the computed budget")
  func tenThousandWordsWithSentinelsWithinBudget() {
    let sentinels = (0..<50).map { "EWSNIP\(String(format: "%08x", $0 * 7919))" }
    var text = ""
    for index in 0..<1_000 {
      text += "The organization analyzed ten color samples at the center today. "
      if index % 20 == 0 { text += sentinels[index / 20] + " " }
    }
    let clock = ContinuousClock()
    var result: BritishSpellingConverter.Result?
    let elapsed = clock.measure {
      result = Self.converter.convert(text, protectedSpans: sentinels)
    }
    #expect(result?.swaps == 4_000)
    for sentinel in sentinels {
      #expect(result?.text.contains(sentinel) == true)
    }
    // Budget for this input: 50 ms plus 10 ms per 1,000 words (about 10,050 words) = 150 ms.
    #expect(elapsed < .milliseconds(150), "10,000 words with sentinels took \(elapsed)")
  }

  @Test("10,000 words convert inside the step's computed budget for that input")
  func tenThousandWordsWithinBudget() {
    let sentence = "The organization analyzed ten color samples at the center today. "
    let text = String(repeating: sentence, count: 1_000)
    let clock = ContinuousClock()
    var result: BritishSpellingConverter.Result?
    let elapsed = clock.measure { result = Self.converter.convert(text) }
    #expect(result?.swaps == 4_000)
    // Budget for this input: 50 ms plus 10 ms per 1,000 words = 150 ms.
    #expect(elapsed < .milliseconds(150), "10,000 words took \(elapsed)")
  }
}
