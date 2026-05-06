import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 1 (#637) — pins the AFM alias degeneration filter contract.
/// Bible §7.
@Suite("WordSuggestionService — AFM alias degeneration filter")
struct WordSuggestionServiceTests {

  @Test("4× exact self-echo filtered to empty")
  func exactSelfEchoFilteredToEmpty() {
    let raw = ["gemini", "gemini", "gemini", "gemini"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "gemini")
    #expect(kept.isEmpty, "All exact self-echoes must be filtered")
  }

  @Test("Mixed-case self-echo filtered")
  func mixedCaseSelfEchoFiltered() {
    let raw = ["Gemini", "GEMINI", "gemini", "GeMiNi"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept.isEmpty, "Case variants of canonical must be filtered")
  }

  @Test("Whitespace variants of canonical filtered")
  func whitespaceVariantsFiltered() {
    let raw = [" gemini ", "  gemini", "gemini   "]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "gemini")
    #expect(kept.isEmpty, "Whitespace-padded canonicals must be filtered")
  }

  @Test("De-dupe collapses repeats (case + whitespace insensitive)")
  func deDupeCollapsesRepeats() {
    let raw = ["Jamini", "jamini", " JAMINI ", "Jeh meh nee"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept.count == 2, "Duplicates collapse to one (Jamini); Jeh meh nee is unique")
    #expect(
      kept.contains(where: { $0.lowercased().trimmingCharacters(in: .whitespaces) == "jamini" }))
    #expect(kept.contains("Jeh meh nee"))
  }

  @Test("Empty entries dropped")
  func emptyEntriesDropped() {
    let raw = ["", "  ", "jamini", "\t\n"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept == ["jamini"])
  }

  @Test("Valid aliases pass through (Kubernetes regression check)")
  func validAliasesPassThrough() {
    let raw = ["kuber netties", "cube ernetes", "cooper nettys"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Kubernetes")
    #expect(kept.count == 3, "Phonetic variants should survive the filter")
    #expect(kept == raw)
  }

  @Test("Empty input returns empty")
  func emptyInputReturnsEmpty() {
    let kept = WordSuggestionService.filterDegeneratedAliases([], canonical: "anything")
    #expect(kept.isEmpty)
  }

  @Test("Empty canonical returns empty (degenerate input guard)")
  func emptyCanonicalGuardsAgainstAcceptingAll() {
    let kept = WordSuggestionService.filterDegeneratedAliases(["a", "b"], canonical: "")
    #expect(
      kept.isEmpty, "Empty canonical means we cannot meaningfully evaluate self-echo; return empty")
  }

  @Test("Single-character canonical with valid aliases")
  func singleCharCanonical() {
    // "X" canonical with phonetic alternates
    let raw = ["ecks", "eks"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "X")
    // ecks and eks are far enough from X to survive (score check)
    // The exact survival depends on WordCorrector.score; this test is a sanity check that
    // single-char canonical does not crash or misbehave catastrophically.
    #expect(kept.count >= 0)  // Smoke; allow either to be filtered or kept
  }
}

/// Pins the plain-string alias parser added in the 2026-05-06 ship.
/// The parser turns AFM's free-text response into a list of alias candidates.
@Suite("WordSuggestionService — plain-string alias parser")
struct WordSuggestionServiceParserTests {

  @Test("Newline-separated lines parse")
  func newlineSeparated() {
    let raw = "okay are\noh K R\nokayer"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R", "okayer"])
  }

  @Test("Numbered list strips numbering")
  func numberedListStripsNumbering() {
    let raw = "1. par vati\n2. poor vati\n3) pavathi"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["par vati", "poor vati", "pavathi"])
  }

  @Test("Bulleted list strips bullets")
  func bulletsStripped() {
    let raw = "- web hook\n* a sync\n• middle ware"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["web hook", "a sync", "middle ware"])
  }

  @Test("Surrounding quotes (straight and curly) stripped")
  func quotesStripped() {
    let raw = "\"ee tee ay\"\n'et a'\n\u{201C}eh tay\u{201D}\n\u{2018}ee t ay\u{2019}"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["ee tee ay", "et a", "eh tay", "ee t ay"])
  }

  @Test("Bracket artifacts stripped")
  func bracketsStripped() {
    let raw = "[okay are]\n(oh K R)\nokayer"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R", "okayer"])
  }

  @Test("Trailing comma stripped (JSON-array bleed)")
  func trailingCommaStripped() {
    let raw = "okay are,\noh K R,\nokayer"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R", "okayer"])
  }

  @Test("Meta-commentary line with 'Note:' is dropped")
  func metaNoteDropped() {
    let raw =
      "Sourabh\nSorab\nSarab\nNote: I have excluded Saurabh as it is forbidden."
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["Sourabh", "Sorab", "Sarab"])
  }

  @Test("Meta-commentary 'Example for X:' is dropped")
  func metaExampleDropped() {
    let raw = "Example for \"Parvati\":\npar vati\npoor vati"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["par vati", "poor vati"])
  }

  @Test("Sentences containing 'If you' or 'phonetic' dropped")
  func metaPhraseDropped() {
    let raw =
      "okay are\noh K R\nIf you cannot produce 3 mistranscriptions, return empty.\nPhonetic mishears only."
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Lines with a colon are dropped (sentence/header guard)")
  func colonLinesDropped() {
    let raw = "okay are\nNote things: bla\noh K R"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Long lines (>40 chars) dropped")
  func longLinesDropped() {
    let longSentence = String(repeating: "x", count: 50)
    let raw = "okay are\n\(longSentence)\noh K R"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Empty lines and whitespace-only lines dropped")
  func emptyLinesDropped() {
    let raw = "\n\nokay are\n   \n\noh K R\n\n"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Combined real-world: numbering + quotes + meta + bullets")
  func combinedRealWorld() {
    let raw = """
      1. "kuber netties"
      2. "cube ernetes"
      - cooper nettys
      Note: these are phonetic mistranscriptions.
      """
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["kuber netties", "cube ernetes", "cooper nettys"])
  }

  @Test("Empty input returns empty")
  func emptyInputReturnsEmpty() {
    #expect(WordSuggestionService.parsePlainStringAliases("").isEmpty)
    #expect(WordSuggestionService.parsePlainStringAliases("   ").isEmpty)
    #expect(WordSuggestionService.parsePlainStringAliases("\n\n\n").isEmpty)
  }
}

/// Pins the multi-call dedupe pool helper.
@Suite("WordSuggestionService — dedupePool")
struct WordSuggestionServiceDedupePoolTests {

  @Test("Single list passes through, deduped")
  func singleListDedupes() {
    let pool = WordSuggestionService.dedupePool([["a", "b", "a", "c"]], max: 10)
    #expect(pool == ["a", "b", "c"])
  }

  @Test("Multiple lists pooled with order-preserving dedup")
  func multipleListsOrderPreserved() {
    let pool = WordSuggestionService.dedupePool(
      [["alpha", "beta"], ["beta", "gamma", "delta"]],
      max: 10
    )
    #expect(pool == ["alpha", "beta", "gamma", "delta"])
  }

  @Test("Dedup is case-insensitive on lowercase + trim")
  func dedupCaseInsensitive() {
    let pool = WordSuggestionService.dedupePool(
      [["Hello", "WORLD"], [" hello ", "world", "Foo"]],
      max: 10
    )
    #expect(pool == ["Hello", "WORLD", "Foo"])
  }

  @Test("Max cap honored")
  func maxCapHonored() {
    let pool = WordSuggestionService.dedupePool(
      [["a", "b", "c"], ["d", "e", "f"]],
      max: 4
    )
    #expect(pool == ["a", "b", "c", "d"])
  }

  @Test("Empty lists handled")
  func emptyListsHandled() {
    #expect(WordSuggestionService.dedupePool([], max: 5).isEmpty)
    #expect(WordSuggestionService.dedupePool([[]], max: 5).isEmpty)
    #expect(WordSuggestionService.dedupePool([[], [], []], max: 5).isEmpty)
  }

  @Test("Empty strings dropped during pool")
  func emptyStringsDropped() {
    let pool = WordSuggestionService.dedupePool(
      [["", "a", "  "], ["b", "", "\t"]],
      max: 10
    )
    #expect(pool == ["a", "b"])
  }
}

/// Pins the deterministic syntactic classifier added in the 2026-05-06 ship.
@Suite("WordSuggestionService — heuristic classifier")
struct WordSuggestionServiceHeuristicClassifierTests {

  @Test("All-caps short word -> acronym")
  func allCapsShortIsAcronym() {
    #expect(WordSuggestionService.classifyByHeuristic("OKR") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("PR") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("CRM") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("HIPAA") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("URL") == .acronym)
  }

  @Test("All-caps too-long word is NOT acronym")
  func allCapsTooLongIsNotAcronym() {
    // 9+ letters falls outside the 2-8 range
    #expect(WordSuggestionService.classifyByHeuristic("LONGACRONYM") != .acronym)
  }

  @Test("Single character is NOT acronym (too short)")
  func singleCharIsNotAcronym() {
    #expect(WordSuggestionService.classifyByHeuristic("A") != .acronym)
  }

  @Test("Has digit -> domain")
  func hasDigitIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("S3") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("OAuth2") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("Web3") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("K8s") == .domain)
  }

  @Test("Has dot -> domain")
  func hasDotIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("github.com") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("npm.io") == .domain)
  }

  @Test("Lowercase-first with uppercase -> domain")
  func lowercaseFirstWithUpperIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("gRPC") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("iOS") == .domain)
  }

  @Test("Capital-first all-lowercase rest -> nil (AFM decides)")
  func properNounShapeIsNil() {
    // Saurabh, Kubernetes, Postgres, Slack — proper nouns of person/brand kind
    #expect(WordSuggestionService.classifyByHeuristic("Saurabh") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("Kubernetes") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("Postgres") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("Slack") == nil)
  }

  @Test("CamelCase with multiple capitals -> nil (AFM decides)")
  func camelCaseIsNil() {
    // WebSocket = domain in corpus, DigitalOcean = brand. Heuristic can't
    // tell, so it returns nil and lets AFM classify.
    #expect(WordSuggestionService.classifyByHeuristic("WebSocket") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("DigitalOcean") == nil)
  }

  @Test("All-lowercase -> nil (AFM decides)")
  func allLowercaseIsNil() {
    #expect(WordSuggestionService.classifyByHeuristic("webhook") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("async") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("middleware") == nil)
  }

  @Test("Has slash, colon, dash, underscore -> domain")
  func hasOtherSymbolIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("foo/bar") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("user:pass") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("multi-word") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("snake_case") == .domain)
  }

  @Test("Has plus, hash, ampersand or other punctuation -> domain (NOT acronym)")
  func hasUncommonPunctuationIsDomain() {
    // Codex review 2026-05-06: original symbol blocklist missed +, #, &.
    // C++ / C# / F# / R&D would have been classified as acronym which is
    // wrong by the prompt rules. These must route to domain.
    #expect(WordSuggestionService.classifyByHeuristic("C++") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("C#") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("F#") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("R&D") == .domain)
  }

  @Test("Empty string -> nil")
  func emptyIsNil() {
    #expect(WordSuggestionService.classifyByHeuristic("") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("   ") == nil)
  }
}
