import Foundation
import NaturalLanguage

// Settings search: the pure word-matching core (#3482 plan §3.2, §3.2a, §3.7a). It builds an
// index from the Settings Map's searchable places joined to the reviewed vocabulary, and answers
// a typed search with ranked places. No UI, no navigation and no telemetry live here; the
// meaning-model second pass (§3.7a) runs on top of these word results and never delays them.
//
// Scoring follows the Phase 0 winner's word leg (bench run `r6-lexical-all`, branch
// feat/3482-settings-search-bench `scripts/eval/settings_search_bench`): the §3.2 field weights,
// plus a whole-title bonus of 150, typo targets that include the page and tab words, and -80 for
// Transcribe a File places so a choice repeated there prefers its home page.

/// How search text is folded and split into words, the same way for the places' text, the
/// vocabulary and what the user types.
enum SearchText {
  /// Case, diacritics and width removed, "ß" as "ss"; every character that is not a letter, digit
  /// or combining mark becomes a word break ("self-learning" is "self learning").
  static func normalize(_ text: String) -> String {
    let folded = text.replacingOccurrences(of: "ß", with: "ss")
      .replacingOccurrences(of: "ẞ", with: "ss")
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return String(
      String.UnicodeScalarView(folded.unicodeScalars.map { isWordScalar($0) ? $0 : " " }))
  }

  /// The folded words of a text.
  static func words(_ text: String) -> [String] {
    surfaceWords(text).map(\.folded)
  }

  /// Each folded word with the text it came from, as written. Chinese, Japanese and Thai write
  /// words without spaces, so text in those scripts is split by the system word tokenizer first.
  static func surfaceWords(_ text: String) -> [(folded: String, surface: String)] {
    var pieces: [Substring] = []
    if text.unicodeScalars.contains(where: isUnspacedScript) {
      let tokenizer = NLTokenizer(unit: .word)
      tokenizer.string = text
      tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        pieces.append(text[range])
        return true
      }
    } else {
      pieces = [text[...]]
    }
    var out: [(String, String)] = []
    for piece in pieces {
      for surface in piece.split(whereSeparator: { !$0.unicodeScalars.allSatisfy(isWordScalar) }) {
        for folded in normalize(String(surface)).split(separator: " ") {
          out.append((String(folded), String(surface)))
        }
      }
    }
    return out
  }

  /// Letters, digits and combining marks. Marks stay inside a word: Hindi vowel signs and
  /// viramas are combining marks, and breaking on them would cut every Hindi word apart.
  static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
  }

  static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
      0xFF66...0xFF9F, 0x0E00...0x0E7F, 0x20000...0x2FA1F:
      true
    default:
      false
    }
  }

  /// Optimal string alignment distance, stopping early above `limit`: a swap of two neighbouring
  /// letters is one edit.
  static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
    let x = Array(a)
    let y = Array(b)
    if abs(x.count - y.count) > limit { return limit + 1 }
    if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
    var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
    for i in 0...x.count { d[i][0] = i }
    for j in 0...y.count { d[0][j] = j }
    for i in 1...x.count {
      for j in 1...y.count {
        let cost = x[i - 1] == y[j - 1] ? 0 : 1
        d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
        if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
          d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
        }
      }
    }
    return d[x.count][y.count]
  }
}

/// Which vocabulary languages one window's search uses (plan §3.7a): English, the app language,
/// then each of the Mac's preferred languages that has a reviewed block, in order, without
/// repeats. Searching every language made English and German results worse in Phase 0, so an
/// unsupported preference never widens the set.
enum SettingsSearchLanguages {
  static func active(
    appLanguage: String, preferred: [String],
    supported: Set<String> = Set(SettingsSearchVocabulary.declaredLanguages)
  ) -> [String] {
    var result: [String] = []
    for code in ["en", appLanguage] + preferred.compactMap(blockCode) where supported.contains(code)
    {
      if !result.contains(code) { result.append(code) }
    }
    return result
  }

  /// The vocabulary block for one preferred-language identifier, or nil when none applies.
  /// Portuguese of any region is "pt"; Chinese is "zh" for Simplified script only, because the
  /// block has no reviewed Traditional words; a script the block does not use (sr-Latn) has none.
  static func blockCode(_ identifier: String) -> String? {
    let language = Locale.Language(identifier: identifier)
    guard let code = language.languageCode?.identifier.lowercased() else { return nil }
    let script = language.script?.identifier
    switch code {
    case "zh":
      // A bare "zh" names no script; macOS always writes one, so treat it as unknown.
      return script == "Hans" ? "zh" : nil
    case "sr":
      return nil
    default:
      return code
    }
  }
}

/// One place a search found.
struct SettingsSearchResult: Equatable, Sendable {
  /// The Settings Map id of the place.
  let entryID: String
  let kind: SettingsMapItemKind
  /// Matched meaningful words over all meaningful words.
  let coverage: Double
  let score: Double
  /// The authored word that explains the match when the place's visible title does not contain
  /// it, for example "Parakeet" for the engine choice titled Fast (plan §3.3). Never query text.
  let hint: String?
}

/// Each place's searchable words, built once per window life, and the search over them.
struct SettingsSearchIndex: Sendable {
  /// Where interface text comes from. Production resolves each copy owner's resource in the
  /// requested language; tests may resolve through the built app's catalog.
  struct Copy: Sendable {
    let title: @Sendable (SettingsMapTitle, String) -> String?
    let description: @Sendable (SettingsMapDescription, String) -> String?
    /// The reviewed result label of a place whose title is only known at run time, in a
    /// language; read only by the title-only index (#3545). nil: no label.
    var dynamicLabel: @Sendable (SettingsMapID, String) -> String? = { _, _ in nil }

    static let interface = Copy(
      title: { title, language in
        switch title {
        case .resource(let resource): resolve(resource, language)
        case .verbatim(let name): name
        // A runtime name (a device, a provider) is never sampled into the index.
        case .dynamic: nil
        }
      },
      description: { description, language in
        switch description {
        case .resource(let resource): resolve(resource, language)
        case .runtime: nil
        }
      },
      dynamicLabel: { id, language in
        SettingsSearchPresentation.dynamicTitle(of: id, language: language)
      })

    private static func resolve(_ resource: LocalizedStringResource, _ language: String) -> String {
      var localized = resource
      localized.locale = Locale(identifier: language)
      return String(localized: localized)
    }
  }

  /// Plan §3.2 scoring, with the Phase 0 winner's additions.
  enum Weight {
    static let meaningExact = 110.0
    static let meaningPrefix = 50.0
    static let meaningSubstring = 30.0
    static let titlePrefix = 100.0
    static let titleSubstring = 60.0
    static let phraseExact = 45.0
    static let phrasePrefix = 35.0
    static let descriptionPrefix = 20.0
    static let descriptionSubstring = 15.0
    static let contextPrefix = 10.0
    static let contextSubstring = 5.0
    static let typo = 8.0
    static let exactTitleBonus = 150.0
    static let transcribeFilePage = -80.0
  }

  static let resultCap = 30

  /// Intent and negation words from plan §3.2: never filler, never the one word a long search may
  /// miss. The vocabulary adds each active language's reviewed markers.
  static let baseMarkers: Set<String> = Set(
    [
      "stop", "change", "off", "not", "no", "never", "without", "aus", "ändern", "nicht", "niemals",
      "ohne", "kein", "keine", "keinen", "keinem", "keiner", "keines",
    ].flatMap(SearchText.words))

  /// Folded word to the authored text it came from.
  typealias Field = [String: String]

  struct Place: Sendable {
    let id: String
    let kind: SettingsMapItemKind
    /// Title words in the app language: what the result row shows.
    var visibleTitle: Field = [:]
    /// Title words in the other active languages (English under a German interface, and the
    /// extra languages' block titles).
    var otherTitle: Field = [:]
    var meaning: Field = [:]
    var phrase: Field = [:]
    var description: Field = [:]
    var context: Field = [:]
    var typoTargets: Field = [:]
    var wholeTitles: Set<String> = []
    var bias = 0.0
  }

  let places: [Place]
  let languages: [String]
  /// The interface language the index was built for ("en" or "de").
  let appLanguage: String
  let stop: Set<String>
  let markers: Set<String>

  /// Loads the bundled vocabulary and builds the index. Missing or invalid data is a typed
  /// failure, never an empty index (plan §3.2a).
  static func load(
    appLanguage: String, preferredLanguages: [String], bundle: Bundle = .module,
    copy: Copy = .interface
  ) -> Result<SettingsSearchIndex, SettingsSearchVocabularyError> {
    SettingsSearchVocabulary.load(bundle: bundle).flatMap { vocabulary in
      SettingsSearchCatalog.join(vocabulary).map { joined in
        SettingsSearchIndex(
          joined: joined, vocabulary: vocabulary, appLanguage: appLanguage,
          languages: SettingsSearchLanguages.active(
            appLanguage: appLanguage, preferred: preferredLanguages),
          copy: copy)
      }
    }
  }

  /// One searchable place as the index sees it, whatever it was read from: the Settings Map in
  /// the app, the Phase 0 bench inventory in the parity test.
  struct Document: Sendable {
    let id: String
    let kind: SettingsMapItemKind
    /// The setting a choice belongs to, for typo matching.
    let parentID: String?
    /// The interface title and description per interface language.
    let titles: [String: String]
    let descriptions: [String: String]
    /// Per interface language: the names around the place (its parent item, page and tab).
    let context: [String: [String]]
    /// Added to every score, so a choice repeated on Transcribe a File prefers its home page.
    let bias: Double
  }

  /// The map's searchable places as index documents, with their interface text in each of
  /// `interface`. `dynamicTitle` names a place whose title is only known at run time, in the
  /// language asked; nil leaves it untitled (the vocabulary's block title names it instead).
  static func documents(
    _ entries: [SettingsSearchCatalog.Entry], interface: [String], copy: Copy,
    dynamicTitle: ((SettingsMapID, String) -> String?)? = nil
  ) -> [Document] {
    entries.map { entry in
      let node = entry.node
      let ancestors = Self.ancestors(of: node)
      var titles: [String: String] = [:]
      var descriptions: [String: String] = [:]
      var context: [String: [String]] = [:]
      for language in interface {
        titles[language] = copy.title(node.title, language) ?? dynamicTitle?(node.id, language)
        descriptions[language] = node.description.flatMap { copy.description($0, language) }
        context[language] = ancestors.compactMap { copy.title($0.title, language) }
      }
      return Document(
        id: entry.id, kind: entry.kind, parentID: node.parent?.rawValue,
        titles: titles, descriptions: descriptions, context: context,
        bias: node.destination == .transcribeFile ? Weight.transcribeFilePage : 0)
    }
  }

  /// The index search answers from before the vocabulary has loaded, or when it cannot be used
  /// (#3545 plan §3.5): every searchable place by its interface title, description and page, built
  /// synchronously from the Settings Map and the app's own strings. No vocabulary words, no
  /// meaning model. A place whose title is only known at run time uses its reviewed result label.
  static func titleOnly(
    appLanguage: String, preferredLanguages: [String], copy: Copy = .interface
  ) -> SettingsSearchIndex {
    let languages = SettingsSearchLanguages.active(
      appLanguage: appLanguage, preferred: preferredLanguages)
    let interface = languages.filter(SettingsSearchVocabulary.interfaceLanguages.contains)
    let places = Self.documents(
      SettingsSearchCatalog.entries, interface: interface, copy: copy,
      dynamicTitle: copy.dynamicLabel)
    return SettingsSearchIndex(
      documents: places, blocks: [:], appLanguage: appLanguage, interface: interface,
      languages: languages, stop: [], markers: baseMarkers)
  }

  /// The Settings window's index: the map's searchable places in the active languages.
  init(
    joined: [SettingsSearchCatalog.JoinedEntry], vocabulary: SettingsSearchVocabulary,
    appLanguage: String, languages: [String], copy: Copy
  ) {
    let interface = languages.filter(SettingsSearchVocabulary.interfaceLanguages.contains)
    let documents = Self.documents(joined.map(\.entry), interface: interface, copy: copy)
    // One language's filler can be another's setting word or marker; the active union loses both.
    var markers = Self.baseMarkers
    var stop: Set<String> = []
    var guarded: Set<String> = []
    for language in languages {
      if let data = vocabulary.languageData[language] {
        markers.formUnion(data.markers.flatMap(SearchText.words))
        stop.formUnion(data.stop.flatMap(SearchText.words))
      }
      for blocks in vocabulary.entries.values {
        guard let block = blocks[language] else { continue }
        guarded.formUnion(block.title.map(Self.singleWords) ?? [])
        for word in block.words { guarded.formUnion(Self.singleWords(word)) }
      }
    }
    for document in documents {
      for title in document.titles.values { guarded.formUnion(Self.singleWords(title)) }
    }
    self.init(
      documents: documents, blocks: vocabulary.entries, appLanguage: appLanguage,
      interface: interface, languages: languages,
      stop: stop.subtracting(markers).subtracting(guarded), markers: markers)
  }

  /// The index over any documents, with the filler and intent words already decided. The scoring
  /// is the Phase 0 winner's word leg; `SettingsSearchBenchParityTests` runs this initializer on
  /// the bench's own inventory and vocabulary and compares every practice search with the bench.
  init(
    documents: [Document], blocks: [String: [String: SettingsSearchVocabulary.Block]],
    appLanguage: String, interface: [String], languages: [String], stop: Set<String>,
    markers: Set<String>
  ) {
    self.languages = languages
    self.appLanguage = appLanguage
    self.stop = stop
    self.markers = markers

    func add(_ text: String?, to field: inout Field) {
      guard let text else { return }
      for (folded, surface) in SearchText.surfaceWords(text) where field[folded] == nil {
        field[folded] = surface
      }
    }
    /// A vocabulary term: every word maps back to the whole term as authored.
    func addTerm(_ term: String, to field: inout Field) {
      for folded in SearchText.words(term) where field[folded] == nil { field[folded] = term }
    }

    var built: [Place] = []
    for document in documents {
      var place = Place(id: document.id, kind: document.kind)
      for language in interface {
        let title = document.titles[language]
        if language == appLanguage {
          add(title, to: &place.visibleTitle)
        } else {
          add(title, to: &place.otherTitle)
        }
        if let title { place.wholeTitles.insert(SearchText.words(title).joined(separator: " ")) }
        add(document.descriptions[language], to: &place.description)
        for name in document.context[language] ?? [] { add(name, to: &place.context) }
      }
      for language in languages {
        guard let block = blocks[document.id]?[language] else { continue }
        if let title = block.title {
          add(title, to: &place.otherTitle)
          place.wholeTitles.insert(SearchText.words(title).joined(separator: " "))
        }
        for word in block.words { addTerm(word, to: &place.meaning) }
        for phrase in block.phrases { addTerm(phrase, to: &place.phrase) }
      }
      place.typoTargets = place.visibleTitle.merging(place.otherTitle) { first, _ in first }
        .merging(place.meaning) { first, _ in first }
        .merging(place.context) { first, _ in first }
      place.bias = document.bias
      built.append(place)
    }
    // A choice's title words also lead a typo to its parent setting.
    let indexByID = Dictionary(
      built.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first }
    )
    for (index, document) in documents.enumerated() where document.kind == .choice {
      guard let parent = document.parentID, let parentIndex = indexByID[parent] else { continue }
      let titles = built[index].visibleTitle.merging(built[index].otherTitle) { first, _ in first }
      built[parentIndex].typoTargets.merge(titles) { first, _ in first }
    }
    places = built
  }

  /// The place's parent when that is an item (a choice's or action's setting), and the page and
  /// tab it lives on.
  private static func ancestors(of node: SettingsMapNode) -> [SettingsMapNode] {
    var result: [SettingsMapNode] = []
    var seen: Set<SettingsMapID> = [node.id]
    var current = node.parent
    var isDirectParent = true
    while let id = current, seen.insert(id).inserted, let parent = SettingsMap.byID[id] {
      if parent.structure == .page || parent.structure == .tab
        || (isDirectParent && parent.item != nil)
      {
        result.append(parent)
      }
      isDirectParent = false
      current = parent.parent
    }
    return result
  }

  private static func singleWords(_ term: String) -> [String] {
    let words = SearchText.words(term)
    return words.count == 1 ? words : []
  }

  // MARK: - Search

  /// The distinct meaningful words of a search: filler removed unless every word is filler.
  func tokens(_ query: String) -> [String] {
    var seen: Set<String> = []
    let all = SearchText.words(query).filter { seen.insert($0).inserted }
    let meaningful = all.filter { !stop.contains($0) }
    return meaningful.isEmpty ? all : meaningful
  }

  enum Strength: Int, Comparable {
    case none, substring, prefix, exact
    static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
  }

  /// How a token meets a field: an equal word, a word it begins, or (three letters or more) a
  /// word containing it ("eingang" in "Mikrofoneingang"). With the authored text it met.
  static func match(_ token: String, in field: Field) -> (Strength, String?) {
    if let surface = field[token] { return (.exact, surface) }
    var substring: String?
    for (word, surface) in field {
      if word.hasPrefix(token) { return (.prefix, surface) }
      if substring == nil, token.count >= 3, word.contains(token) { substring = surface }
    }
    return substring.map { (.substring, $0) } ?? (.none, nil)
  }

  /// A token's best field score in one place, and the hint that explains it when the visible
  /// title does not.
  private func score(_ token: String, _ place: Place) -> (score: Double, hint: String?)? {
    var best: (score: Double, hint: String?)?
    func take(_ value: Double, _ hint: String?) {
      if value > (best?.score ?? -1) { best = (value, hint) }
    }
    let visible = Self.match(token, in: place.visibleTitle)
    switch visible.0 {
    case .exact, .prefix: take(Weight.titlePrefix, nil)
    case .substring: take(Weight.titleSubstring, nil)
    case .none: break
    }
    let other = Self.match(token, in: place.otherTitle)
    switch other.0 {
    case .exact, .prefix: take(Weight.titlePrefix, other.1)
    case .substring: take(Weight.titleSubstring, other.1)
    case .none: break
    }
    let meaning = Self.match(token, in: place.meaning)
    switch meaning.0 {
    case .exact: take(Weight.meaningExact, meaning.1)
    case .prefix: take(Weight.meaningPrefix, meaning.1)
    case .substring: take(Weight.meaningSubstring, meaning.1)
    case .none: break
    }
    switch Self.match(token, in: place.phrase).0 {
    // Phrases are whole sentences; showing one as a hint would crowd the row.
    case .exact: take(Weight.phraseExact, nil)
    case .prefix: take(Weight.phrasePrefix, nil)
    default: break
    }
    let description = Self.match(token, in: place.description)
    switch description.0 {
    case .exact, .prefix: take(Weight.descriptionPrefix, description.1)
    case .substring: take(Weight.descriptionSubstring, description.1)
    case .none: break
    }
    switch Self.match(token, in: place.context).0 {
    case .exact, .prefix: take(Weight.contextPrefix, nil)
    case .substring: take(Weight.contextSubstring, nil)
    case .none: break
    }
    // The visible title explains the match whenever it matches at all.
    if visible.0 != .none, let current = best { best = (current.score, nil) }
    return best
  }

  /// The ranked places for a search (plan §3.2): coverage first, then score, then kind (setting,
  /// choice, feature, action), then map order; at most 30.
  func results(for query: String) -> [SettingsSearchResult] {
    let tokens = tokens(query)
    guard !tokens.isEmpty else { return [] }
    let wholeQuery = SearchText.words(query).joined(separator: " ")
    let joinedTokens = tokens.joined(separator: " ")
    // Typo tolerance only for a long token that matches nothing anywhere.
    let typoTokens = Set(
      tokens.filter { token in
        token.count >= 5 && !places.contains { score(token, $0) != nil }
      })
    var ranked: [(index: Int, result: SettingsSearchResult)] = []
    for (index, place) in places.enumerated() {
      var total = place.bias
      var missed: [String] = []
      var hint: String?
      var visibleExplainsAll = true
      for token in tokens {
        if let hit = score(token, place) {
          total += hit.score
          if hit.hint != nil { visibleExplainsAll = false }
          if hint == nil { hint = hit.hint }
        } else if typoTokens.contains(token), let target = typoTarget(token, place) {
          total += Weight.typo
          if !typoIsVisible(token, place) {
            if hint == nil { hint = target }
            visibleExplainsAll = false
          }
        } else {
          missed.append(token)
        }
      }
      // With three or more meaningful words one may be missing, but never an intent word.
      let allowedMisses = tokens.count >= 3 ? 1 : 0
      guard missed.count <= allowedMisses, !missed.contains(where: markers.contains) else {
        continue
      }
      if place.wholeTitles.contains(wholeQuery) || place.wholeTitles.contains(joinedTokens) {
        total += Weight.exactTitleBonus
      }
      let coverage = Double(tokens.count - missed.count) / Double(tokens.count)
      ranked.append(
        (
          index,
          SettingsSearchResult(
            entryID: place.id, kind: place.kind, coverage: coverage, score: total,
            hint: visibleExplainsAll ? nil : hint)
        ))
    }
    ranked.sort {
      if $0.result.coverage != $1.result.coverage { return $0.result.coverage > $1.result.coverage }
      if $0.result.score != $1.result.score { return $0.result.score > $1.result.score }
      let kinds = (Self.kindRank($0.result.kind), Self.kindRank($1.result.kind))
      if kinds.0 != kinds.1 { return kinds.0 < kinds.1 }
      return $0.index < $1.index
    }
    return ranked.prefix(Self.resultCap).map(\.result)
  }

  private func typoTarget(_ token: String, _ place: Place) -> String? {
    let limit = token.count >= 9 ? 2 : 1
    // Sorted so the same search always shows the same hint.
    guard
      let word = place.typoTargets.keys.sorted().first(where: {
        SearchText.editDistance(token, $0, limit: limit) <= limit
      })
    else { return nil }
    return place.typoTargets[word]
  }

  /// Whether a typo landed on a word the row already shows, so it needs no hint.
  private func typoIsVisible(_ token: String, _ place: Place) -> Bool {
    let limit = token.count >= 9 ? 2 : 1
    return place.visibleTitle.keys.contains {
      SearchText.editDistance(token, $0, limit: limit) <= limit
    }
  }

  private static func kindRank(_ kind: SettingsMapItemKind) -> Int {
    switch kind {
    case .setting: 0
    case .choice: 1
    case .feature: 2
    case .action: 3
    }
  }
}

