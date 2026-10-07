import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Settings search word matching (#3482 plan §3.2, §3.2a, §3.7a). When this fails, the user types
/// "mic" or "Tastenkürzel ändern" into Settings search and does not see the setting they meant.
///
/// The expectations are the plan's §18.1 and §18.1b tables, written before the matcher existed.
/// Plan ids that the Settings Map renamed are renamed here, never re-derived from search output:
/// openAIKey, geminiKey, claudeKey → apiKey.openAI, apiKey.gemini, apiKey.claude;
/// recordingKeybind → recordKeybind; removeFillerWords → fillerRemoval;
/// transcriptionEngine.parakeet / .whisperKit → transcriptionEngine.fast / .allLanguages;
/// learnFromEdits → selfLearningDictionary; aiPolishEngine.ollama → aiPolishProvider.ollama;
/// exportWords → yourWords.export; playRecordingSounds → recordingChimes.
@Suite("Settings search matching (#3482)", .tags(.productOutcome))
struct SettingsSearchMatchingTests {
  /// Interface text from the built app's compiled catalog, the copy users actually read; English
  /// and German resolve the same way the Settings Map export does.
  static let builtCatalog = SettingsSearchIndex.Copy(
    title: { title, language in
      switch title {
      case .resource(let resource): try? SettingsMapExportTests.resolve(resource, language)
      case .verbatim(let name): name
      case .dynamic: nil
      }
    },
    description: { description, language in
      switch description {
      case .resource(let resource): try? SettingsMapExportTests.resolve(resource, language)
      case .runtime: nil
      }
    })

  static func index(_ appLanguage: String, preferred: [String] = []) throws -> SettingsSearchIndex {
    try SettingsSearchIndex.load(
      appLanguage: appLanguage, preferredLanguages: preferred, copy: builtCatalog
    ).get()
  }

  static let english = Result { try index("en", preferred: ["en-US"]) }
  static let german = Result { try index("de", preferred: ["de-DE", "en-US"]) }

  static func search(_ query: String, _ language: String) throws -> [SettingsSearchResult] {
    try (language == "de" ? german : english).get().results(for: query)
  }

  struct Row: CustomTestStringConvertible, Sendable {
    let language: String
    let query: String
    let first: String?
    var alsoInTopFive: [String] = []
    var testDescription: String { "\(language): \(query)" }
  }

  /// Plan §18.1 rows the word leg answers on its own. Adjusted to the Settings Map, never to search
  /// output: Theme's choices are entries now, so "dark"/"dunkel" expect the Dark choice, which
  /// arrives on the same Theme row; the AI Polish provider list has one entry per provider, so
  /// "openai" expects the OpenAI provider first and its key in the top five; the plan's
  /// OpenAI-specific model entry has no subject (one shared polishModel setting).
  static let queryTable: [Row] = [
    Row(language: "en", query: "mic", first: "inputDevice", alsoInTopFive: ["micReadiness"]),
    Row(language: "en", query: "dark", first: "theme.dark", alsoInTopFive: ["theme.system"]),
    Row(language: "en", query: "silence", first: "stopOnSilence", alsoInTopFive: ["pauseDuration"]),
    Row(
      language: "en", query: "api key", first: "apiKey.openAI",
      alsoInTopFive: ["apiKey.gemini", "apiKey.claude"]),
    Row(language: "en", query: "filler", first: "fillerRemoval"),
    Row(language: "en", query: "dock", first: "showInDock"),
    Row(language: "en", query: "clipboard restore", first: "restoreClipboard"),
    Row(language: "en", query: "zzqx", first: nil),
    Row(language: "de", query: "mikro", first: "inputDevice", alsoInTopFive: ["micReadiness"]),
    Row(language: "de", query: "dunkel", first: "theme.dark"),
    Row(language: "de", query: "dark", first: "theme.dark"),
    Row(language: "de", query: "stille", first: "stopOnSilence"),
    Row(language: "de", query: "Bluetooth", first: "bluetoothGuide"),
    Row(
      language: "de", query: "openai", first: "aiPolishProvider.openAI",
      alsoInTopFive: ["apiKey.openAI"]),
    Row(language: "en", query: "parakeet", first: "transcriptionEngine.fast"),
    Row(language: "en", query: "parakeat", first: "transcriptionEngine.fast"),
    Row(language: "en", query: "self-learning", first: "selfLearningDictionary"),
    Row(language: "en", query: "ollama", first: "aiPolishProvider.ollama"),
    Row(language: "en", query: "microfone", first: "inputDevice"),
    Row(language: "de", query: "parakeet", first: "transcriptionEngine.fast"),
    Row(language: "de", query: "selbstlernend", first: "selfLearningDictionary"),
  ]

  /// Plan §18.1b sentences the word leg answers on its own. Known regressions, not held-out
  /// evidence.
  static let sentenceTable: [Row] = [
    Row(language: "en", query: "turn off the sound", first: "recordingChimes"),
    Row(language: "de", query: "bei einer Sprechpause aufhören", first: "stopOnSilence"),
  ]

  /// Plan §18.1 / §18.1b rows the measured winner answers with BOTH legs, words plus the meaning
  /// pass (§3.7a; the word leg alone put the right place first for 73% of the Phase 0 practice
  /// searches, both legs 82%). Word results here are the bench's own (see
  /// SettingsSearchBenchParityTests), so these rows are checked once the meaning pass is wired;
  /// if both legs still miss one, that is a ranking decision for the founder, not a tuning edit.
  /// Word-leg answers on 2026-10-07: shortcut → quickAdd.shortcut, recordKeybind; kürzel →
  /// yourWords.category.acronym; quiet → mediaDuringDictation.lower, stopOnSilence; export →
  /// snippets.export, yourWords.export (equal score, map order); whisperkit → none (no
  /// "WhisperKit" word in the reviewed vocabulary); the four sentences below → none or other.
  static let bothLegsTable: [Row] = [
    Row(
      language: "en", query: "shortcut", first: "recordKeybind", alsoInTopFive: ["cancelKeybind"]),
    Row(language: "de", query: "kürzel", first: "recordKeybind"),
    Row(language: "en", query: "whisperkit", first: "transcriptionEngine.allLanguages"),
    Row(language: "en", query: "quiet", first: "stopOnSilence"),
    Row(language: "en", query: "export", first: "yourWords.export"),
    Row(language: "en", query: "make it stop when I pause", first: "stopOnSilence"),
    Row(language: "en", query: "use a different microphone", first: "inputDevice"),
    Row(language: "de", query: "ein anderes Mikrofon verwenden", first: "inputDevice"),
    Row(language: "de", query: "den Signalton ausschalten", first: "recordingChimes"),
    Row(language: "en", query: "how do I change the shortcut", first: "recordKeybind"),
    Row(language: "de", query: "Tastenkürzel ändern", first: "recordKeybind"),
  ]

  @Test("each §18.1 search shows the expected setting first", arguments: queryTable)
  func queryTableRow(_ row: Row) throws {
    try check(row)
  }

  @Test("each §18.1b sentence shows the expected setting first", arguments: sentenceTable)
  func sentenceTableRow(_ row: Row) throws {
    try check(row)
  }

  func check(_ row: Row) throws {
    let results = try Self.search(row.query, row.language)
    let ids = results.map(\.entryID)
    guard let first = row.first else {
      #expect(ids.isEmpty, "\(row.testDescription) answered \(ids.prefix(5))")
      return
    }
    #expect(ids.first == first, "\(row.testDescription): top five \(ids.prefix(5))")
    for id in row.alsoInTopFive {
      #expect(ids.prefix(5).contains(id), "\(row.testDescription): \(id) not in \(ids.prefix(5))")
    }
  }

  // MARK: - Folding and typing

  @Test("case, trailing space, ß and hyphens do not change what a search finds")
  func foldingKeepsTheAnswer() throws {
    let mic = try Self.search("mic", "en").map(\.entryID)
    #expect(try Self.search("MIC", "en").map(\.entryID) == mic)
    #expect(try Self.search("Mic ", "en").map(\.entryID) == mic)
    #expect(try Self.search("self learning", "en").first?.entryID == "selfLearningDictionary")
    #expect(SearchText.words("Größe") == SearchText.words("grosse"))
    #expect(SearchText.words("self-learning") == ["self", "learning"])
  }

  @Test("an empty search shows nothing, and one letter matches only word starts")
  func emptyAndOneLetter() throws {
    #expect(try Self.search("", "en").isEmpty)
    #expect(try Self.search("   ", "en").isEmpty)
    let index = try Self.english.get()
    // "k" begins many words but sits inside many more; only word starts may count.
    for result in index.results(for: "k") {
      let place = try #require(index.places.first { $0.id == result.entryID })
      let fields = [
        place.visibleTitle, place.otherTitle, place.meaning, place.phrase, place.description,
        place.context,
      ]
      #expect(
        fields.contains { $0.keys.contains { $0.hasPrefix("k") } },
        "\(result.entryID) matched \"k\" without a word starting with k")
    }
  }

  @Test("a typo is forgiven only near a real word and only for long words")
  func typoBoundaries() throws {
    // Distance 2 from "microphone" (ten letters) is allowed; a neighbouring swap is one edit.
    #expect(try Self.search("micorphone", "en").first?.entryID == "inputDevice")
    #expect(SearchText.editDistance("micorphone", "microphone", limit: 2) == 1)
    // Four letters is too short for a typo, and three edits from anything finds nothing.
    #expect(try Self.search("dokc", "en").isEmpty)
    #expect(try Self.search("parxkxxt", "en").isEmpty)
  }

  @Test("filler is dropped but intent words stay, and a repeated word counts once")
  func fillerAndIntent() throws {
    let index = try Self.english.get()
    // "the" is English filler; "turn" is not in the reviewed English stop list; "off" is intent.
    #expect(index.tokens("turn off the sound") == ["turn", "off", "sound"])
    #expect(index.tokens("stop stop stop") == ["stop"])
    // Every word is filler: keep them all rather than search for nothing.
    #expect(index.tokens("the it") == ["the", "it"])
    // A long search may miss one word, never an intent word: every place a three-word search
    // with "not" returns must itself contain a word "not" meets.
    for result in index.results(for: "sound chime not") {
      let place = try #require(index.places.first { $0.id == result.entryID })
      let fields = [
        place.visibleTitle, place.otherTitle, place.meaning, place.phrase, place.description,
        place.context,
      ]
      #expect(
        fields.contains { SettingsSearchIndex.match("not", in: $0).0 != .none },
        "\(result.entryID) answered a search whose \"not\" it ignored")
    }
  }

  // MARK: - Hints

  @Test(
    "a choice found by a hidden word names that word as authored; a visible match shows no hint")
  func matchHints() throws {
    let parakeet = try #require(try Self.search("parakeet", "en").first)
    #expect(parakeet.entryID == "transcriptionEngine.fast")
    #expect(parakeet.hint == "Parakeet")
    let selfLearning = try #require(try Self.search("self-learning", "en").first)
    #expect(selfLearning.hint == nil)
    let dock = try #require(try Self.search("dock", "en").first)
    #expect(dock.hint == nil)
    // The hint is the vocabulary's word, never the user's spelling.
    let typo = try #require(try Self.search("PARAKEAT", "en").first)
    #expect(typo.hint == "Parakeet")
  }

  // MARK: - Languages

  @Test("the active languages are English, the app language, then supported preferences")
  func activeLanguages() {
    func active(_ app: String, _ preferred: [String]) -> [String] {
      SettingsSearchLanguages.active(appLanguage: app, preferred: preferred)
    }
    #expect(active("en", ["fr-FR", "en-US"]) == ["en", "fr"])
    #expect(active("de", ["de-DE", "pt-BR", "it-IT"]) == ["en", "de", "pt", "it"])
    #expect(active("en", ["pt-PT"]) == ["en", "pt"])
    #expect(active("en", ["zh-Hans-CN", "zh-Hant-TW", "sr-Latn-RS"]) == ["en", "zh"])
    // A language with no block never widens the search.
    #expect(active("en", ["is-IS", "sw"]) == ["en"])
    #expect(active("de", []) == ["en", "de"])
  }

  @Test("a user whose Mac prefers another language finds a setting by its name in that language")
  func extraLanguageTitle() throws {
    // The reviewed Japanese block names Theme "テーマ".
    let japanese = try Self.index("en", preferred: ["ja-JP"])
    let theme = try #require(japanese.results(for: "テーマ").first)
    #expect(theme.entryID == "theme")
    // The best-scoring authored word explains the match: the keyword カラーテーマ contains テーマ.
    #expect(theme.hint.map { $0.contains("テーマ") } == true, "\(String(describing: theme.hint))")
    #expect(try Self.search("テーマ", "en").isEmpty, "Japanese is searched only for Japanese users")
    // French filler ("le") is dropped only when French is one of the user's languages.
    let french = try Self.index("en", preferred: ["fr-FR"])
    #expect(try Self.english.get().tokens("le thème") == ["le", "theme"])
    #expect(french.tokens("le thème") == ["theme"])
  }

  @Test("Chinese, Japanese and Thai searches are split into words; Hindi marks stay in the word")
  func segmentation() {
    #expect(SearchText.words("麦克风设置").count >= 2)
    #expect(SearchText.words("マイクの設定").count >= 2)
    #expect(SearchText.words("ตั้งค่าไมโครโฟน").count >= 2)
    // "माइक्रोफ़ोन" (microphone) is one word; its vowel signs and virama are combining marks.
    #expect(SearchText.words("माइक्रोफ़ोन").count == 1)
    #expect(SearchText.words("मेरा माइक्रोफ़ोन").count == 2)
  }

  // MARK: - Loading and speed

  @Test("the index loads every searchable place from the shipped vocabulary")
  func loadsEveryPlace() throws {
    let index = try Self.english.get()
    #expect(index.places.map(\.id) == SettingsSearchCatalog.entries.map(\.id))
    let empty = FileManager.default.temporaryDirectory
      .appendingPathComponent("settings-search-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    let missing = SettingsSearchIndex.load(
      appLanguage: "en", preferredLanguages: [], bundle: try #require(Bundle(url: empty)))
    guard case .failure(.missingResource) = missing else {
      Issue.record("a bundle without the vocabulary must fail, not load an empty index")
      return
    }
  }

  /// Plan §3.2a: under 50 ms per keystroke for match and rank on this Mac. This Mac only; it
  /// says nothing about an M1.
  @Test("one keystroke's search takes under 50 ms on this Mac")
  func keystrokeTiming() throws {
    let index = try Self.index("de", preferred: ["de-DE", "fr-FR", "ja-JP", "en-US"])
    let typed = "ein anderes Mikrofon verwenden"
    var worst = Duration.zero
    let clock = ContinuousClock()
    for end in typed.indices.dropFirst() {
      let prefix = String(typed[..<end])
      let elapsed = clock.measure { _ = index.results(for: prefix) }
      worst = max(worst, elapsed)
    }
    print("SettingsSearch keystroke worst (this Mac only): \(worst)")
    #expect(worst < .milliseconds(50))
  }
}
