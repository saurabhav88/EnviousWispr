import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #341 EmojiFormatter — deterministic spoken-emoji → glyph conversion.
/// See `docs/feature-requests/issue-341-2026-05-16-emoji-formatter.md`.
@Suite("EmojiFormatter — trigger-word conversion + fuzzy fallback")
struct EmojiFormatterTests {

  // MARK: - Fixtures

  private static func makeFormatter(
    entries: [EmojiFormatter.Entry]? = nil,
    enablePhonetic: Bool = true
  ) -> EmojiFormatter {
    let defaultEntries: [EmojiFormatter.Entry] = [
      EmojiFormatter.Entry(phrase: "thumbs up", emoji: "👍", synonyms: ["thumb up"]),
      EmojiFormatter.Entry(phrase: "thumbs down", emoji: "👎", synonyms: []),
      EmojiFormatter.Entry(phrase: "red heart", emoji: "❤️", synonyms: ["heart"]),
      EmojiFormatter.Entry(phrase: "smiling face", emoji: "🙂", synonyms: ["happy face", "smile"]),
      EmojiFormatter.Entry(phrase: "sad face", emoji: "😢", synonyms: ["crying face"]),
      EmojiFormatter.Entry(phrase: "fire", emoji: "🔥", synonyms: ["flame"]),
      EmojiFormatter.Entry(phrase: "rocket", emoji: "🚀", synonyms: ["rocket ship"]),
      EmojiFormatter.Entry(phrase: "warning", emoji: "⚠️", synonyms: ["warning sign"]),
    ]
    return try! EmojiFormatter(entries: entries ?? defaultEntries, enablePhonetic: enablePhonetic)
  }

  // MARK: - Positive (Tier A: canonical phrase trigger)

  @Test("Positive: canonical phrase + emoji → glyph")
  func positiveCanonical() {
    let f = Self.makeFormatter()
    #expect(f.format("thumbs up emoji") == "👍")
    #expect(f.format("send a fire emoji") == "send a 🔥")
    #expect(f.format("rocket emoji we shipped it") == "🚀 we shipped it")
  }

  @Test("Positive: emoticon trigger word also works")
  func positiveEmoticonTrigger() {
    let f = Self.makeFormatter()
    #expect(f.format("smiling face emoticon thanks") == "🙂 thanks")
  }

  @Test("Positive: case-insensitive")
  func positiveCaseInsensitive() {
    let f = Self.makeFormatter()
    #expect(f.format("Thumbs Up Emoji") == "👍")
    #expect(f.format("THUMBS UP EMOJI!") == "👍!")
  }

  // MARK: - Multi-word phrase scoping (R1 critical fix — over-capture defense)

  @Test("Multi-word: regex anchors to the dictionary phrase, not preceding text")
  func multiWordPhraseScoping() {
    let f = Self.makeFormatter()
    #expect(f.format("send Mike a thumbs up emoji") == "send Mike a 👍")
    #expect(f.format("Can you send me the thumbs up emoji") == "Can you send me the 👍")
    #expect(f.format("happy birthday Emma red heart emoji") == "happy birthday Emma ❤️")
  }

  // MARK: - Synonym (Tier B)

  @Test("Synonym: variant phrase matches canonical entry")
  func synonymMatches() {
    let f = Self.makeFormatter()
    #expect(
      f.format("happy face emoji thanks for picking up the kids")
        == "🙂 thanks for picking up the kids")
    #expect(f.format("crying face emoji") == "😢")
    #expect(f.format("warning sign emoji") == "⚠️")
  }

  // MARK: - ASR punctuation tolerance

  @Test("Separator class tolerates ASR-injected punctuation")
  func punctuationSeparatorTolerance() {
    let f = Self.makeFormatter()
    #expect(f.format("thumbs up, emoji") == "👍")
    #expect(f.format("thumbs up. Emoji") == "👍")
    #expect(f.format("thumbs up — emoji") == "👍")
    #expect(f.format("thumbs up - emoji") == "👍")
  }

  // MARK: - Negative (bare nouns / no trigger word)

  @Test("Negative: bare noun without trigger does NOT convert")
  func negativeBareNoun() {
    let f = Self.makeFormatter()
    #expect(f.format("I want a rocket ride to the moon") == "I want a rocket ride to the moon")
    #expect(
      f.format("the heart of the issue is engineering capacity")
        == "the heart of the issue is engineering capacity")
    #expect(
      f.format("I got fired today thanks for the support")
        == "I got fired today thanks for the support")
  }

  @Test("Negative: plural emojis form does NOT fire (word-boundary)")
  func negativePluralTriggerForm() {
    let f = Self.makeFormatter()
    #expect(
      f.format("I sent three thumbs up emojis to the team")
        == "I sent three thumbs up emojis to the team")
  }

  // MARK: - Literal-discussion negative look-ahead

  @Test("Literal-discussion: trigger followed by category/feature/name/symbol declines")
  func literalDiscussionNegativeLookAhead() {
    let f = Self.makeFormatter()
    #expect(
      f.format("the red heart emoji category is confusing")
        == "the red heart emoji category is confusing")
    #expect(
      f.format("the fire emoji feature is great")
        == "the fire emoji feature is great")
    #expect(
      f.format("the smiling face emoji symbol")
        == "the smiling face emoji symbol")
    #expect(
      f.format("the red heart emoji meaning is universal")
        == "the red heart emoji meaning is universal")
    #expect(
      f.format("the rocket emoji icon")
        == "the rocket emoji icon")
    #expect(
      f.format("check the warning emoji description")
        == "check the warning emoji description")
  }

  // MARK: - Output spacing edge cases

  @Test("Output spacing: trigger at start of string")
  func outputSpacingAtStart() {
    let f = Self.makeFormatter()
    #expect(f.format("thumbs up emoji at the top") == "👍 at the top")
  }

  @Test("Output spacing: trigger followed by sentence-final punctuation")
  func outputSpacingPunctuation() {
    let f = Self.makeFormatter()
    #expect(f.format("great work thumbs up emoji!") == "great work 👍!")
    #expect(f.format("thumbs up emoji?") == "👍?")
    #expect(f.format("thumbs up emoji.") == "👍.")
    #expect(f.format("thumbs up emoji,") == "👍,")
  }

  @Test("Output spacing: trigger surrounded by quotes")
  func outputSpacingQuotes() {
    let f = Self.makeFormatter()
    #expect(f.format("\"thumbs up emoji\"") == "\"👍\"")
    #expect(
      f.format("she said \"thumbs up emoji\", then left")
        == "she said \"👍\", then left")
  }

  @Test("Output spacing: end of string")
  func outputSpacingEndOfString() {
    let f = Self.makeFormatter()
    #expect(f.format("send a thumbs up emoji") == "send a 👍")
  }

  // MARK: - Multiple non-overlapping triggers

  @Test("Multiple triggers in one input convert independently")
  func multipleTriggers() {
    let f = Self.makeFormatter()
    #expect(f.format("thumbs up emoji and rocket emoji") == "👍 and 🚀")
    #expect(
      f.format("fire emoji this is incredible rocket emoji we shipped")
        == "🔥 this is incredible 🚀 we shipped")
  }

  // MARK: - Idempotency

  @Test("Idempotent: format(format(text)) == format(text)")
  func idempotency() {
    let f = Self.makeFormatter()
    let inputs = [
      "send Mike a thumbs up emoji",
      "thumbs up emoji and rocket emoji",
      "the red heart emoji category is confusing",  // declined match
      "I want a rocket ride to the moon",  // no trigger
    ]
    for input in inputs {
      let once = f.format(input)
      let twice = f.format(once)
      #expect(once == twice, "idempotency failed for input '\(input)'")
    }
  }

  // MARK: - Edge inputs

  @Test("Edge: empty string")
  func edgeEmptyString() {
    let f = Self.makeFormatter()
    #expect(f.format("") == "")
  }

  @Test("Edge: single character")
  func edgeSingleChar() {
    let f = Self.makeFormatter()
    #expect(f.format("a") == "a")
  }

  @Test("Edge: 10 KB input with one valid trigger embedded")
  func edgeLargeInput() {
    let f = Self.makeFormatter()
    let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 400)  // ~10 KB
    let input = filler + "thumbs up emoji"
    let output = f.format(input)
    #expect(output.hasSuffix("👍"))
    #expect(output.contains("lorem"))
  }

  @Test("Edge: input already contains the target glyph — passthrough")
  func edgeAlreadyEmoji() {
    let f = Self.makeFormatter()
    #expect(f.format("👍 thanks") == "👍 thanks")
  }

  // MARK: - Phonetic fuzzy match (Tier C)

  @Test("Phonetic: ASR mistranscription matches via Soundex+Levenshtein")
  func phoneticMisheard() {
    let f = Self.makeFormatter()
    // "sod" mishearing of "sad" — soundex codes should match, Levenshtein ≤ 2
    let out = f.format("sod face emoji")
    #expect(out == "😢", "Expected fuzzy match to sad face; got '\(out)'")
  }

  @Test("Phonetic: single-token mistranscription via synonym surface (R1 contract)")
  func phoneticSingleTokenSynonym() {
    // The "sad face" entry has "sad" in its synonyms list. After R1 fix,
    // phoneticIndex stores BOTH the canonical phrase ("sad face") AND the
    // synonym ("sad") as separate surfaces. So "sod" routes to the sad-face
    // entry via the "sad" surface (Levenshtein 1), not the canonical (Lev 5).
    let f = Self.makeFormatter()
    let out = f.format("sod emoji")
    #expect(out == "😢", "Expected fuzzy match via 'sad' synonym surface; got '\(out)'")
  }

  @Test("Phonetic disabled: no fuzzy fallback")
  func phoneticDisabled() {
    let f = Self.makeFormatter(enablePhonetic: false)
    #expect(f.format("sod face emoji") == "sod face emoji")
  }

  // MARK: - Dictionary hygiene

  @Test("Dictionary hygiene: trigger word in phrase rejected at init")
  func dictionaryHygienePhrase() {
    #expect(throws: EmojiFormatter.LoadError.self) {
      _ = try EmojiFormatter(entries: [
        EmojiFormatter.Entry(phrase: "emoji thing", emoji: "👍", synonyms: [])
      ])
    }
  }

  @Test("Dictionary hygiene: trigger word in glyph rejected at init")
  func dictionaryHygieneGlyph() {
    #expect(throws: EmojiFormatter.LoadError.self) {
      _ = try EmojiFormatter(entries: [
        EmojiFormatter.Entry(phrase: "x", emoji: "emoji", synonyms: [])
      ])
    }
  }

  @Test("Dictionary hygiene: trigger word in synonym rejected at init")
  func dictionaryHygieneSynonym() {
    #expect(throws: EmojiFormatter.LoadError.self) {
      _ = try EmojiFormatter(entries: [
        EmojiFormatter.Entry(phrase: "foo", emoji: "👍", synonyms: ["bar emoticon baz"])
      ])
    }
  }

  // MARK: - Bundled dictionary

  @Test("Bundle: ships emoji-dictionary.json that loads cleanly")
  func bundledDictionaryLoads() throws {
    let f = try EmojiFormatter.load()
    #expect(f.format("thumbs up emoji") == "👍")
    #expect(f.format("red heart emoji") == "❤️")
  }

  // MARK: - Dictionary hygiene (R2 extensions)

  @Test("Dictionary hygiene: empty phrase rejected")
  func dictionaryHygieneEmptyPhrase() {
    #expect(throws: EmojiFormatter.LoadError.self) {
      _ = try EmojiFormatter(entries: [
        EmojiFormatter.Entry(phrase: "", emoji: "👍", synonyms: [])
      ])
    }
  }

  @Test("Dictionary hygiene: empty emoji rejected")
  func dictionaryHygieneEmptyEmoji() {
    #expect(throws: EmojiFormatter.LoadError.self) {
      _ = try EmojiFormatter(entries: [
        EmojiFormatter.Entry(phrase: "foo", emoji: "", synonyms: [])
      ])
    }
  }

  @Test("Dictionary hygiene: duplicate phrase across entries rejected")
  func dictionaryHygieneDuplicatePhrase() {
    #expect(throws: EmojiFormatter.LoadError.self) {
      _ = try EmojiFormatter(entries: [
        EmojiFormatter.Entry(phrase: "fire", emoji: "🔥", synonyms: []),
        EmojiFormatter.Entry(phrase: "fire", emoji: "🚒", synonyms: []),
      ])
    }
  }

  // MARK: - Ambiguity decline (R2 council finding)

  @Test("Ambiguity decline: when two phonetic candidates score within margin, no substitution")
  func phoneticAmbiguityDeclines() throws {
    // Construct an adversarial dictionary where two surfaces produce identical
    // soundex codes AND identical Levenshtein similarity from the user input,
    // so the ambiguity margin (0.05) cannot be cleared.
    let f = try EmojiFormatter(
      entries: [
        EmojiFormatter.Entry(phrase: "fool", emoji: "🤡", synonyms: []),
        EmojiFormatter.Entry(phrase: "feel", emoji: "💚", synonyms: []),
      ], enablePhonetic: true)
    // "ffil" - same soundex as both "fool" (F400) and "feel" (F400). Lev distance
    // to either canonical is 2 (substitute two vowels), so similarity is equal.
    let out = f.format("ffil emoji")
    #expect(out == "ffil emoji", "Ambiguous match should DECLINE — got '\(out)'")
  }
}
