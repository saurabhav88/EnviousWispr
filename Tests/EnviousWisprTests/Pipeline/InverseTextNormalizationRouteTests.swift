import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - Route characterization (#1677, chunk 1)
//
// Freezes TODAY'S language gate and neutral behaviour with literal, independently written
// expectations, so the routing foundation that follows (`route(...)`, the rule-set registry) can be
// proved equivalent instead of assumed. Every expectation below is typed by hand; none is computed
// from `skipReason`, `LanguageNormalizer.baseCode` or a copy of the production decision tree.
//
// When this fails, a user sees one of two things: a non-English take that loses its address/code
// cleanup, or an English rule rewriting foreign words (German "um 7 am Abend" becoming "7:00 AM").

@MainActor
@Suite("ITN route characterization (#1677)", .tags(.productOutcome))
struct InverseTextNormalizationRouteTests {

  /// One language value and the outcome the gate must give it, per backend, WITHOUT a veto.
  /// `nil` means "run the English engine".
  private struct LanguageRow {
    let label: String
    let language: String?
    let noLID: String?
    let withLID: String?
  }

  private static let nonEnglish = "non_english"
  private static let lidNil = "lid_backend_nil"
  private static let vetoed = "language_vetoed"

  private static let rows: [LanguageRow] = [
    // Raw nil and raw empty are the ONLY values that consult the backend.
    LanguageRow(label: "nil", language: nil, noLID: nil, withLID: lidNil),
    LanguageRow(label: "empty", language: "", noLID: nil, withLID: lidNil),
    // Whitespace is a non-empty string: it is NOT trimmed into "empty".
    LanguageRow(label: "space", language: " ", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "newline", language: "\n", noLID: nonEnglish, withLID: nonEnglish),
    // English: exactly `en`, `en-` prefix, `en_` prefix, compared lowercased.
    LanguageRow(label: "en", language: "en", noLID: nil, withLID: nil),
    LanguageRow(label: "EN", language: "EN", noLID: nil, withLID: nil),
    LanguageRow(label: "en-US", language: "en-US", noLID: nil, withLID: nil),
    LanguageRow(label: "en_GB", language: "en_GB", noLID: nil, withLID: nil),
    LanguageRow(label: "en-", language: "en-", noLID: nil, withLID: nil),
    LanguageRow(label: "en_", language: "en_", noLID: nil, withLID: nil),
    LanguageRow(label: "EN-gb", language: "EN-gb", noLID: nil, withLID: nil),
    // English-looking values that are NOT English, and a padded English value (no trimming).
    LanguageRow(label: " en", language: " en", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "en ", language: "en ", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "english", language: "english", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "enx", language: "enx", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "e", language: "e", noLID: nonEnglish, withLID: nonEnglish),
    // Non-English base, regional and mixed-case values.
    LanguageRow(label: "de", language: "de", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "DE", language: "DE", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "de-DE", language: "de-DE", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "pt-BR", language: "pt-BR", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "es", language: "es", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "ru_RU", language: "ru_RU", noLID: nonEnglish, withLID: nonEnglish),
    // Aliases `LanguageNormalizer.baseCode` collapses; the gate must not care.
    LanguageRow(label: "nb", language: "nb", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "nn", language: "nn", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "cmn", language: "cmn", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "yue", language: "yue", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "zh-Hans", language: "zh-Hans", noLID: nonEnglish, withLID: nonEnglish),
    // Values `baseCode` REJECTS must still be explicit non-English, never "unknown".
    LanguageRow(label: "und", language: "und", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "abcd", language: "abcd", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(
      label: "toolongcode", language: "toolongcode", noLID: nonEnglish, withLID: nonEnglish),
    LanguageRow(label: "x", language: "x", noLID: nonEnglish, withLID: nonEnglish),
  ]

  // MARK: Gate precedence matrix

  @Test("the language gate's precedence, every value crossed with veto and backend")
  func gatePrecedenceMatrix() {
    var checked = 0
    var mismatches: [String] = []
    var table: [String] = ["label | veto | LID | expected | legacy skipReason | route"]
    for row in Self.rows {
      for veto in [false, true] {
        for lid in [false, true] {
          let expected: String? = veto ? Self.vetoed : (lid ? row.withLID : row.noLID)
          let legacy = InverseTextNormalizationGate.skipReason(
            language: row.language, englishVetoed: veto, backendSupportsLID: lid)
          let route = InverseTextNormalizationGate.route(
            language: row.language, englishVetoed: veto, backendSupportsLID: lid)
          // The production registry lists de, fr, es, it and pt: the rows for those languages
          // (literal labels to literal codes, not the subject's canonicaliser) route to
          // `.language`; every other row is unchanged.
          let registeredRows: [String: String] = [
            "de": "de", "DE": "de", "de-DE": "de", "pt-BR": "pt", "es": "es",
          ]
          let expectedRoute: InverseTextNormalizationGate.Route =
            expected == Self.nonEnglish && registeredRows[row.label] != nil
            ? .language(registeredRows[row.label]!) : (expected.map { .neutral($0) } ?? .english)
          checked += 1
          table.append(
            "\(row.label.debugDescription) | \(veto) | \(lid) | \(expected ?? "run") | \(legacy ?? "run") | \(route)"
          )
          if legacy != expected || route != expectedRoute {
            mismatches.append("\(row.label.debugDescription) veto=\(veto) lid=\(lid)")
          }
        }
      }
    }
    print(table.joined(separator: "\n"))
    print(
      "ROUTE-CHARACTERIZATION rows=\(Self.rows.count) checked=\(checked) mismatches=\(mismatches.count)"
    )
    #expect(checked == Self.rows.count * 4)
    #expect(mismatches.isEmpty, "gate or route disagrees with the literal table: \(mismatches)")
  }

  // MARK: Injected registry

  /// A registry holding de, no (from `nb`), zh (from `cmn`) and pt, to prove the route's lookup
  /// without registering anything in production.
  private static let injected: LanguageRuleRegistry = {
    let sets = ["de", "nb", "cmn", "pt-BR"].compactMap { LanguageRuleSet(language: $0) }
    return try! LanguageRuleRegistry(sets)
  }()

  @Test("with a registered language the route selects it by canonical base code")
  func injectedRegistryRoutes() {
    func route(_ language: String?, veto: Bool = false, lid: Bool = false)
      -> InverseTextNormalizationGate.Route
    {
      InverseTextNormalizationGate.route(
        language: language, englishVetoed: veto, backendSupportsLID: lid, registry: Self.injected)
    }
    #expect(Self.injected.count == 4)
    // Canonical, regional, mixed-case and alias lookups.
    #expect(route("de") == .language("de"))
    #expect(route("de-DE") == .language("de"))
    #expect(route("DE") == .language("de"))
    #expect(route("pt_BR") == .language("pt"))
    #expect(route("nb") == .language("no"))
    #expect(route("nn") == .language("no"))
    #expect(route("cmn") == .language("zh"))
    #expect(route("zh-Hans") == .language("zh"))
    // Veto wins over a registered language, on either backend.
    #expect(route("de", veto: true) == .neutral("language_vetoed"))
    #expect(route("de", veto: true, lid: true) == .neutral("language_vetoed"))
    // Unregistered and rejected values stay neutral, never "unknown".
    #expect(route("es") == .neutral("non_english"))
    #expect(route("und") == .neutral("non_english"))
    #expect(route("abcd") == .neutral("non_english"))
    #expect(route(" ") == .neutral("non_english"))
    // English never becomes a language route, nor does a padded English value.
    #expect(route("en") == .english)
    #expect(route("en-US") == .english)
    #expect(route(" en") == .neutral("non_english"))
    // Only raw nil and empty consult the backend, and never reach the registry.
    #expect(route(nil) == .english)
    #expect(route("") == .english)
    #expect(route(nil, lid: true) == .neutral("lid_backend_nil"))
    #expect(route("", lid: true) == .neutral("lid_backend_nil"))
  }

  /// A drift guard, not product coverage: the shipped registry lists de, fr, es, it, pt (#1677).
  @Test("the production registry lists exactly de, fr, es, it and pt", .tags(.driftGuard))
  func productionRegistryMembers() {
    #expect(LanguageRuleRegistry.production.count == 5)
    for code in ["de", "fr", "es", "it", "pt"] {
      #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: code)?.baseCode == code, "\(code)")
    }
    for code in ["ru", "nl", "pl", "no", "zh"] {
      #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: code) == nil, "\(code)")
    }
  }

  /// The rows that claim "baseCode rejects this" must keep rejecting it, and the alias rows must
  /// keep collapsing, or the matrix above would silently stop testing what its labels say.
  @Test("baseCode preconditions behind the rejected and alias rows still hold")
  func baseCodePreconditions() {
    #expect(LanguageNormalizer.baseCode("und") == nil)
    #expect(LanguageNormalizer.baseCode("e") == nil)
    #expect(LanguageNormalizer.baseCode("abcd") == nil)
    #expect(LanguageNormalizer.baseCode("toolongcode") == nil)
    #expect(LanguageNormalizer.baseCode("english") == nil)
    #expect(LanguageNormalizer.baseCode(" ") == nil)
    #expect(LanguageNormalizer.baseCode("nb") == "no")
    #expect(LanguageNormalizer.baseCode("nn") == "no")
    #expect(LanguageNormalizer.baseCode("cmn") == "zh")
    #expect(LanguageNormalizer.baseCode("yue") == "zh")
    #expect(LanguageNormalizer.baseCode("zh-Hans") == "zh")
    #expect(LanguageNormalizer.baseCode("de-DE") == "de")
    // The gate's English test is NOT baseCode: `enx` is a valid-looking three-letter base code
    // and must still not be read as English.
    #expect(LanguageNormalizer.baseCode("enx") == "enx")
  }

  // MARK: What a skipped take still receives

  private func ctx(_ text: String, language: String?, vetoed: Bool = false) -> TextProcessingContext
  {
    var c = TextProcessingContext(text: text, language: language)
    c.englishRulesVetoed = vetoed
    return c
  }

  /// A German sentence carrying (1) a word the English engine misreads, `7 am`, and (2) a spoken
  /// dash code the neutral subset reads. Whatever skipped route a take takes, only the second may
  /// change, and the result must be exactly this literal.
  private static let mixed =
    "Ruf mich bitte um 7 am Abend an. Frage B Bindestrich 2, Code zwei null drei."
  private static let mixedNeutral =
    "Ruf mich bitte um 7 am Abend an. Frage B-2, Code zwei null drei."

  @Test("each skip bucket runs the neutral subset and never the English time rule")
  func everySkipBucketRunsNeutralOnly() async throws {
    let cases: [(String, String?, Bool, Bool, String)] = [
      // Dutch: a non-English language with no registered rule set (#1677 registers de/fr/es/it/pt).
      ("non_english", "nl", false, true, "non_english"),
      ("language_vetoed", nil, true, true, "language_vetoed"),
      ("lid_backend_nil", nil, false, true, "lid_backend_nil"),
    ]
    for (label, language, vetoed, lid, reason) in cases {
      let step = InverseTextNormalizationStep()
      step.backendSupportsLID = lid
      let out = try await step.process(ctx(Self.mixed, language: language, vetoed: vetoed))
      #expect(out.text == Self.mixedNeutral, "\(label): neutral subset only")
      #expect(step.lastRun?.ran == false, "\(label)")
      #expect(step.lastRun?.changed == true, "\(label)")
      #expect(step.lastRun?.skipReason == reason, "\(label)")
    }
    // Control: the English engine WOULD have rewritten the German `7 am`.
    #expect(InverseTextNormalizer().normalize(Self.mixed).contains("7:00 AM"))
  }

  @Test("a skipped take with nothing to convert returns the input byte for byte")
  func skippedNoOpIsByteIdentical() async throws {
    // Leading/trailing whitespace, CRLF and DECOMPOSED Unicode (e + U+0301), all untouched.
    let input = "  Ruhe\u{0301} bitte,\r\num sieben am Abend.\n  "
    for (language, vetoed, lid) in [("nl", false, true), (nil, true, true), (nil, false, true)]
      as [(String?, Bool, Bool)]
    {
      let step = InverseTextNormalizationStep()
      step.backendSupportsLID = lid
      let out = try await step.process(ctx(input, language: language, vetoed: vetoed))
      #expect(
        Array(out.text.utf8) == Array(input.utf8), "language=\(language ?? "nil") vetoed=\(vetoed)")
      #expect(step.lastRun?.changed == false)
      #expect(step.lastRun?.ran == false)
    }
  }

  // MARK: Positive controls

  @Test("neutral conversion still happens on a foreign take, English conversion on an English one")
  func positiveControls() async throws {
    let neutral = InverseTextNormalizationStep()
    neutral.backendSupportsLID = true
    let n = try await neutral.process(
      ctx("mandalo a marco arroba esempio punto com", language: "nl"))
    #expect(n.text == "mandalo a marco@esempio.com")
    #expect(neutral.lastRun?.ran == false)

    let english = InverseTextNormalizationStep()
    english.backendSupportsLID = true
    let e = try await english.process(ctx("the code is two zero three", language: "en"))
    #expect(e.text == "the code is 203")
    #expect(english.lastRun?.ran == true)
    #expect(english.lastRun?.skipReason == nil)
  }
}
