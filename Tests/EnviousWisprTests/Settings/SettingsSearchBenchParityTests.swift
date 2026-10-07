import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The app's word matching IS the Phase 0 winner's word leg (#3482 plan §3.7). When this fails,
/// Settings search ranks differently from the version that was measured and chosen, so the
/// measured quality no longer describes what ships.
///
/// The oracle is the bench's own output: `Tests/Fixtures/settings-search/bench-parity.json.deflate`
/// holds the bench inventory, its multilingual vocabulary and stop lists, the winner's knobs and
/// the top five ids the bench program returned for each of the 699 practice searches (never the
/// sealed final sets). It was produced by `settings-search-bench run` (see the fixture's
/// `producedBy` and `sourceSHA256`), never by this matcher. Here the app index is built from the
/// same inputs exactly as the bench builds them, and every search must return the same top five.
@Suite("Settings search matches the Phase 0 bench (#3482)", .tags(.productOutcome))
struct SettingsSearchBenchParityTests {
  struct Fixture: Decodable {
    struct Entry: Decodable {
      let id: String
      let kind: String
      let page: String
      let tab: String?
      let parent: String?
      let enTitle: String
      let deTitle: String?
      let enDescription: String?
      let deDescription: String?

      enum CodingKeys: String, CodingKey {
        case id, kind, page, tab, parent
        case enTitle = "en_title"
        case deTitle = "de_title"
        case enDescription = "en_description"
        case deDescription = "de_description"
      }
    }
    struct Block: Decodable {
      let title: String?
      let words: [String]
      let phrases: [String]
    }
    struct Weights: Decodable {
      let exactTitleBonus: Double
      let typoIncludesContext: Bool
      let pageBias: [String: Double]
    }
    struct Golden: Decodable {
      let lang: String
      let q: String
      let results: [String]
    }
    let weights: Weights
    let entries: [Entry]
    let stop: [String: [String]]
    let vocabulary: [String: [String: Block]]
    let golden: [Golden]
  }

  static func fixture() throws -> Fixture {
    let packed = try Data(
      contentsOf: RepoRoot.sourceURL("Tests/Fixtures/settings-search/bench-parity.json.deflate"))
    let json = try (packed as NSData).decompressed(using: .zlib) as Data
    return try JSONDecoder().decode(Fixture.self, from: json)
  }

  /// The bench's intent markers (its `LexicalMatcher.intentMarkers`), folded the bench's way.
  static let benchMarkers: Set<String> = Set(
    [
      "stop", "change", "off", "not", "no", "never", "without", "aus", "ändern", "nicht", "niemals",
      "ohne", "kein", "keine", "keinen", "keinem", "keiner", "keines",
    ].map(SearchText.normalize))

  /// The index the bench builds for one search: a German query runs on a German interface that
  /// also matches English; any other non-English query runs on an English interface with that
  /// language's keywords and filler added (`userLanguages`).
  static func index(for language: String, _ fixture: Fixture) throws -> SettingsSearchIndex {
    let app = language == "de" ? "de" : "en"
    let interface = app == "de" ? ["de", "en"] : ["en"]
    let extra = ["en", "de"].contains(language) ? [] : [language]
    let byID = Dictionary(uniqueKeysWithValues: fixture.entries.map { ($0.id, $0) })
    func title(_ entry: Fixture.Entry, _ language: String) -> String? {
      language == "de" ? entry.deTitle : entry.enTitle
    }
    // The bench's knobs are this index's constants; a changed constant must fail here first.
    #expect(fixture.weights.exactTitleBonus == SettingsSearchIndex.Weight.exactTitleBonus)
    #expect(fixture.weights.typoIncludesContext)
    #expect(
      fixture.weights.pageBias == [
        "Transcribe a File": SettingsSearchIndex.Weight.transcribeFilePage
      ])
    let documents = try fixture.entries.map { entry in
      var titles: [String: String] = [:]
      var descriptions: [String: String] = [:]
      var context: [String: [String]] = [:]
      for language in interface {
        titles[language] = title(entry, language)
        descriptions[language] = language == "de" ? entry.deDescription : entry.enDescription
        let parent = entry.parent.flatMap { byID[$0] }.flatMap { title($0, language) }
        context[language] = [parent, entry.page, entry.tab].compactMap { $0 }
      }
      return SettingsSearchIndex.Document(
        id: entry.id, kind: try #require(SettingsMapItemKind(rawValue: entry.kind)),
        parentID: entry.parent, titles: titles, descriptions: descriptions, context: context,
        bias: fixture.weights.pageBias[entry.page] ?? 0)
    }
    let blocks = fixture.vocabulary.mapValues { languages in
      languages.mapValues {
        SettingsSearchVocabulary.Block(
          title: $0.title, words: $0.words, phrases: $0.phrases, phraseExemption: nil)
      }
    }
    var stop: Set<String> = []
    for code in interface + extra {
      stop.formUnion((fixture.stop[code] ?? []).map(SearchText.normalize))
    }
    return SettingsSearchIndex(
      documents: documents, blocks: blocks, appLanguage: app, interface: interface,
      languages: interface + extra, stop: stop.subtracting(benchMarkers), markers: benchMarkers)
  }

  @Test("every practice search returns the bench's top five, in the bench's order")
  func practiceSetMatchesTheBench() throws {
    let fixture = try Self.fixture()
    try #require(fixture.golden.count == 699, "the fixture lost practice searches")
    var indexes: [String: SettingsSearchIndex] = [:]
    var differing: [String] = []
    for row in fixture.golden {
      if indexes[row.lang] == nil { indexes[row.lang] = try Self.index(for: row.lang, fixture) }
      let index = try #require(indexes[row.lang])
      // The bench kept its top five; fewer means it found fewer, and so must the app.
      let got = index.results(for: row.q).prefix(5).map(\.entryID)
      if got != row.results {
        differing.append("\(row.lang) \"\(row.q)\": bench \(row.results), app \(Array(got))")
      }
    }
    #expect(
      differing.isEmpty, "\(differing.count) of 699 differ:\n\(differing.joined(separator: "\n"))")
  }
}
