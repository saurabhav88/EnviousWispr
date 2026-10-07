import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A: the shipped Settings search vocabulary, loaded through the production loader and
/// validator, against independent expectations: the literal language list below, the map
/// inventory fixture (`Tests/Fixtures/settings-map/inventory.json`, never derived from the map),
/// a hand-built rejection fixture, and the review receipt in `scripts/settings-map/receipts/`.
@Suite("Settings search vocabulary (#3482)", .tags(.driftGuard))
struct SettingsSearchVocabularyTests {
  /// Plan §3.7a's declared search languages, written out independently of the source.
  static let languages = [
    "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hi", "hr", "hu", "it", "ja",
    "ko", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi", "zh",
  ]

  static func inventoryIDs() throws -> (mapped: Set<String>, exempt: Set<String>) {
    let inventory = try SettingsMapTests.inventory()
    return (
      Set(inventory.items.filter { $0.disposition == "mapped" }.map(\.id)),
      Set(inventory.items.filter { $0.disposition == "exempt" }.map(\.id))
    )
  }

  static func shipped() throws -> SettingsSearchVocabulary {
    switch SettingsSearchVocabulary.load() {
    case .success(let vocabulary): return vocabulary
    case .failure(let error): throw error
    }
  }

  static func shippedData() throws -> Data {
    try Data(contentsOf: try #require(SettingsSearchVocabulary.resourceURL()))
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - The shipped resource

  @Test("the bundled resource loads through the production loader, and is the checked-in file")
  func bundledResourceLoads() throws {
    let vocabulary = try Self.shipped()
    #expect(vocabulary.version == 1)
    let bundled = try Self.shippedData()
    let checkedIn = try Data(
      contentsOf: RepoRoot.sourceURL(
        "Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json"))
    #expect(bundled == checkedIn, "the built bundle holds a stale copy of the resource")
    #expect(vocabulary.byteCount == bundled.count)
  }

  @Test("its ids are exactly the inventory's mapped ids; the exempt ids are gone")
  func idsMatchTheInventory() throws {
    let vocabulary = try Self.shipped()
    let ids = try Self.inventoryIDs()
    #expect(!ids.mapped.isEmpty, "the inventory reader found no mapped ids")
    #expect(Set(vocabulary.entries.keys) == ids.mapped)
    #expect(Set(vocabulary.entries.keys).isDisjoint(with: ids.exempt))
  }

  @Test("every entry has exactly the 32 declared languages")
  func everyEntryHasEveryLanguage() throws {
    #expect(SettingsSearchVocabulary.declaredLanguages == Self.languages)
    let vocabulary = try Self.shipped()
    #expect(Set(vocabulary.languageData.keys) == Set(Self.languages))
    var pairs = 0
    for (id, blocks) in vocabulary.entries {
      #expect(Set(blocks.keys) == Set(Self.languages), "\(id)")
      pairs += blocks.count
    }
    #expect(!vocabulary.entries.isEmpty, "the vocabulary has no entries")
    #expect(pairs == vocabulary.entries.count * Self.languages.count)
  }

  @Test("English and German titles come from the interface; every other block has its own title")
  func contentShape() throws {
    let vocabulary = try Self.shipped()
    for (id, blocks) in vocabulary.entries {
      for (code, block) in blocks {
        if code == "en" || code == "de" {
          #expect(block.title == nil, "\(id)/\(code)")
        } else {
          #expect(block.title?.isEmpty == false, "\(id)/\(code)")
        }
        // The receipt records no phrase exemptions, so every block carries phrases.
        #expect(!block.phrases.isEmpty && block.phraseExemption == nil, "\(id)/\(code)")
      }
    }
  }

  @Test("stop lists keep negation and switching words out; markers protect them")
  func stopListsAndMarkers() throws {
    let vocabulary = try Self.shipped()
    // Literal words that must never be ignored (plan §3.7a), per language.
    let protected: [String: [String]] = [
      "en": ["not", "no", "never", "without", "off", "on", "disable", "stop", "change"],
      "de": [
        "nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines", "ohne", "aus", "an",
        "ändern", "nie", "niemals",
      ],
      "fr": ["pas", "sans", "non", "ne"],
      "es": ["no", "sin"],
      "it": ["non", "senza"],
      "pt": ["não", "sem"],
      "nl": ["niet", "geen", "zonder"],
      "pl": ["nie", "bez"],
      "ru": ["не", "нет", "без"],
    ]
    for (code, words) in protected {
      let data = try #require(vocabulary.languageData[code])
      let stop = Set(data.stop.map(SettingsSearchVocabulary.fold))
      let markers = Set(data.markers.map(SettingsSearchVocabulary.fold))
      for word in words {
        let folded = SettingsSearchVocabulary.fold(word)
        #expect(!stop.contains(folded), "\(code) stop list holds \(word)")
        #expect(markers.contains(folded), "\(code) markers miss \(word)")
      }
    }
    for code in Self.languages {
      let data = try #require(vocabulary.languageData[code])
      #expect(!data.stop.isEmpty && !data.markers.isEmpty, "\(code)")
    }
  }

  @Test("the shipped resource stays under the 3,000,000-byte budget")
  func sizeBudget() throws {
    #expect(SettingsSearchVocabulary.maximumBytes == 3_000_000)
    #expect(try Self.shippedData().count < 3_000_000)
  }

  // MARK: - Review binding

  struct Receipt: Decodable {
    struct Resource: Decodable {
      let sha256: String
      let bytes: Int
    }
    struct Review: Decodable { let kind: String }
    struct Language: Decodable {
      let language: String
      let contentSHA256: String
      let reviews: [Review]
      let phraseExemptions: [String]
    }
    struct Excluded: Decodable { let id: String }
    struct Added: Decodable {
      let id: String
      let review: String
    }
    let canonicalization: String
    let resource: Resource
    let excludedIDs: [Excluded]
    let addedIDs: [Added]
    let languages: [Language]
    /// Per searchable id, the English its translations were reviewed against.
    let reviewedSourceSHA256: [String: String]
  }

  /// One entry's English as the reference export states it: each of title and description is
  /// its kind plus its English text, resolver name, verbatim text or runtime role.
  static func sourceFingerprint(_ node: [String: Any]) throws -> String {
    func field(_ value: Any?) throws -> String {
      guard let field = value as? [String: Any] else { return "none" }
      let source = try #require(field["source"] as? String)
      let key = ["resource": "en", "dynamic": "resolver", "verbatim": "text", "runtime": "role"][
        source]
      let name = try #require(key, "unknown source \(source)")
      let text = try #require(field[name] as? String)
      try #require(!text.isEmpty)
      return source + "\u{1F}" + text
    }
    return sha256(
      Data((try field(node["title"]) + "\u{1E}" + field(node["description"])).utf8))
  }

  /// A renamed setting keeps its id and its translated vocabulary, which then describes the old
  /// name. This names every entry whose English changed since its translations were reviewed.
  @Test("each entry's translations were reviewed against the English it shows now")
  func reviewsMatchTheCurrentEnglish() throws {
    let receipt = try Self.receipt()
    let export = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: RepoRoot.sourceURL("reference/settings-map.json")))
        as? [String: Any])
    let nodes = try #require(export["nodes"] as? [[String: Any]])
    let searchable = nodes.filter { $0["searchable"] as? Bool == true }
    try #require(!searchable.isEmpty, "the export has no searchable places")
    var current: [String: String] = [:]
    for node in searchable {
      current[try #require(node["id"] as? String)] = try Self.sourceFingerprint(node)
    }
    #expect(Set(receipt.reviewedSourceSHA256.keys) == Set(current.keys))
    for (id, hash) in current.sorted(by: { $0.key < $1.key })
    where receipt.reviewedSourceSHA256[id] != hash {
      Issue.record(
        "\(id): its English changed since its translations were reviewed. Re-review its translated blocks, then set reviewedSourceSHA256.\(id) to \(hash) in scripts/settings-map/receipts/vocabulary-review.json"
      )
    }
    // Control: a changed English title changes the fingerprint.
    var renamed = try #require(searchable.first)
    var title = try #require(renamed["title"] as? [String: Any])
    if title["source"] as? String == "resource" {
      title["en"] = "Renamed"
    } else {
      title["source"] = "verbatim"
      title["text"] = "Renamed"
    }
    renamed["title"] = title
    #expect(
      try Self.sourceFingerprint(renamed) != Self.sourceFingerprint(try #require(searchable.first)))
  }

  static func receipt() throws -> Receipt {
    try JSONDecoder().decode(
      Receipt.self,
      from: Data(
        contentsOf: RepoRoot.sourceURL(
          "scripts/settings-map/receipts/vocabulary-review.json")))
  }

  /// Every way the receipt fails to describe these exact bytes and this exact content.
  static func receiptProblems(
    _ receipt: Receipt, vocabulary: SettingsSearchVocabulary, data: Data
  ) -> [String] {
    var problems: [String] = []
    if receipt.resource.sha256 != sha256(data) || receipt.resource.bytes != data.count {
      problems.append("resource hash or size")
    }
    if receipt.canonicalization != SettingsSearchVocabulary.canonicalization {
      problems.append("canonicalization")
    }
    if receipt.languages.map(\.language) != languages { problems.append("language list") }
    for language in receipt.languages
    where language.contentSHA256 != vocabulary.contentHash(language: language.language) {
      problems.append("\(language.language) content")
    }
    return problems
  }

  @Test("the review receipt names the shipped bytes and every language's reviewed content")
  func receiptBindsTheShippedContent() throws {
    let receipt = try Self.receipt()
    let vocabulary = try Self.shipped()
    #expect(
      Self.receiptProblems(receipt, vocabulary: vocabulary, data: try Self.shippedData()) == [])
    #expect(Set(receipt.excludedIDs.map(\.id)) == (try Self.inventoryIDs()).exempt)
    for language in receipt.languages {
      let kinds = Set(language.reviews.map(\.kind))
      #expect(kinds.isSuperset(of: ["phase0-content", "stop-and-markers"]), "\(language.language)")
      #expect(language.phraseExemptions.isEmpty, "\(language.language)")
    }
    // An id added after Phase 0 is bound to its own review output: hash, id and content.
    let edits = try Self.addedRecords()
    #expect(Set(receipt.addedIDs.map(\.id)) == Set(edits.keys))
    for (id, record) in edits {
      #expect(
        Self.additionProblems(
          id: id, record: record, vocabulary: vocabulary, receipts: Self.receiptsRoot)
          == [], "\(id)")
    }
    let german = try #require(receipt.languages.first { $0.language == "de" })
    #expect(german.reviews.contains { $0.kind == "german-council" })
  }

  // MARK: - Ids added after Phase 0

  struct AddedRecord: Sendable {
    let review: String
    let reviewSHA256: String
  }

  static let receiptsRoot = RepoRoot.sourceURL("scripts/settings-map/receipts")

  /// reviewed-edits.json's `added` records.
  static func addedRecords() throws -> [String: AddedRecord] {
    let data = try Data(contentsOf: receiptsRoot.appendingPathComponent("reviewed-edits.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let added = object["added"] as? [String: [String: Any]] ?? [:]
    return try added.mapValues {
      AddedRecord(
        review: try #require($0["review"] as? String),
        reviewSHA256: try #require($0["reviewSHA256"] as? String))
    }
  }

  /// Every way an added id's shipped blocks fail to be the ones its review output holds.
  static func additionProblems(
    id: String, record: AddedRecord, vocabulary: SettingsSearchVocabulary, receipts: URL
  ) -> [String] {
    let root = receipts.standardizedFileURL.path + "/"
    let url = receipts.appendingPathComponent(record.review).standardizedFileURL
    guard url.path.hasPrefix(root) else { return ["review outside receipts"] }
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      return ["review missing or empty"]
    }
    guard sha256(data) == record.reviewSHA256 else { return ["review hash differs"] }
    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return ["review is not a JSON object"]
    }
    guard document["id"] as? String == id else { return ["review names another id"] }
    guard let reviewed = document["blocks"] as? [String: [String: Any]],
      let shipped = vocabulary.entries[id]
    else { return ["review or vocabulary lacks the blocks"] }
    for code in languages {
      guard let block = shipped[code], let review = reviewed[code],
        review["title"] as? String == block.title,
        review["words"] as? [String] == block.words,
        review["phrases"] as? [String] == block.phrases,
        review["phraseExemption"] as? String == block.phraseExemption,
        Set(review.keys).isSubset(of: ["title", "words", "phrases", "phraseExemption"])
      else { return ["\(code): shipped block differs from the review"] }
    }
    return []
  }

  enum AdditionCase: String, CaseIterable, Sendable {
    case reviewed, missing, empty, wrongID, staleHash, changedContent, outsideReceipts
  }

  @Test("an added id binds to its review output", arguments: AdditionCase.allCases)
  func additionControls(additionCase: AdditionCase) throws {
    let vocabulary = try Self.fixtureVocabulary()
    let receipts = FileManager.default.temporaryDirectory
      .appendingPathComponent("vocabulary-additions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: receipts.appendingPathComponent("additions"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: receipts) }

    var blocks: [String: Any] = [:]
    for (code, block) in try #require(vocabulary.entries["alpha.one"]) {
      var review: [String: Any] = ["words": block.words, "phrases": block.phrases]
      review["title"] = block.title
      blocks[code] = review
    }
    let id = additionCase == .wrongID ? "alpha.two" : "alpha.one"
    let review = try JSONSerialization.data(withJSONObject: ["id": id, "blocks": blocks])
    let file = receipts.appendingPathComponent("additions/alpha.one.json")
    switch additionCase {
    case .missing: break
    case .empty: try Data().write(to: file)
    default: try review.write(to: file)
    }
    let record = AddedRecord(
      review: additionCase == .outsideReceipts ? "../alpha.one.json" : "additions/alpha.one.json",
      reviewSHA256: additionCase == .staleHash
        ? String(repeating: "0", count: 64) : Self.sha256(review))
    var shipped = vocabulary
    if additionCase == .changedContent {
      var entries = vocabulary.entries
      let fr = try #require(entries["alpha.one"]?["fr"])
      entries["alpha.one"]?["fr"] = .init(
        title: fr.title, words: fr.words + ["extra"], phrases: fr.phrases, phraseExemption: nil)
      shipped = SettingsSearchVocabulary(
        version: 1, languageData: vocabulary.languageData, entries: entries, byteCount: 0)
    }

    let expected: [String] =
      switch additionCase {
      case .reviewed: []
      case .missing, .empty: ["review missing or empty"]
      case .wrongID: ["review names another id"]
      case .staleHash: ["review hash differs"]
      case .changedContent: ["fr: shipped block differs from the review"]
      case .outsideReceipts: ["review outside receipts"]
      }
    #expect(
      Self.additionProblems(
        id: "alpha.one", record: record, vocabulary: shipped, receipts: receipts)
        == expected)
  }

  @Test("a receipt goes stale when one word changes")
  func staleReceiptIsCaught() throws {
    let receipt = try Self.receipt()
    let vocabulary = try Self.shipped()
    let data = try Self.shippedData()
    var entries = vocabulary.entries
    let block = try #require(entries["dictation.tab.engine"]?["fr"])
    entries["dictation.tab.engine"]?["fr"] = .init(
      title: block.title, words: block.words + ["moteur de dictée"], phrases: block.phrases,
      phraseExemption: nil)
    let changed = SettingsSearchVocabulary(
      version: vocabulary.version, languageData: vocabulary.languageData, entries: entries,
      byteCount: vocabulary.byteCount)
    #expect(Self.receiptProblems(receipt, vocabulary: changed, data: data) == ["fr content"])
    #expect(
      Self.receiptProblems(receipt, vocabulary: vocabulary, data: data + Data(" ".utf8))
        == ["resource hash or size"])
  }

  @Test("the review hash covers a language's lists and blocks in one fixed text")
  func canonicalText() throws {
    let vocabulary = try Self.fixtureVocabulary()
    #expect(SettingsSearchVocabulary.canonicalization == "length-prefixed-v1")
    #expect(
      vocabulary.canonicalText(language: "en")
        == "8:language2:en4:stop1:23:the1:a7:markers1:23:not3:off"
        + "5:entry9:alpha.one6:absent0:5:words1:17:word1en7:phrases1:111:phrase 1 en"
        + "15:phraseExemption6:absent0:"
        + "5:entry9:alpha.two6:absent0:5:words1:07:phrases1:111:phrase 2 en"
        + "15:phraseExemption6:absent0:")
    #expect(
      vocabulary.canonicalText(language: "fr").hasSuffix(
        "5:entry9:alpha.two7:present10:title 2 fr5:words1:07:phrases1:111:phrase 2 fr"
          + "15:phraseExemption6:absent0:"))
  }

  /// Pairs of contents that a separator-joined text would confuse.
  static let collisionPairs: [(String, [String], [String])] = [
    ("unit separator", ["first", "second"], ["first\u{1F}second"]),
    ("tab", ["first", "second"], ["first\tsecond"]),
    ("newline", ["first", "second"], ["first\nsecond"]),
    ("empty list against one empty-looking member", [], ["\u{1F}"]),
  ]

  @Test("different contents never share a review hash", arguments: collisionPairs.indices)
  func noHashCollisions(pair: Int) throws {
    let (name, left, right) = Self.collisionPairs[pair]
    let base = try Self.fixtureVocabulary()
    func with(_ phrases: [String]) -> SettingsSearchVocabulary {
      var entries = base.entries
      entries["alpha.one"]?["fr"] = .init(
        title: "title 1 fr", words: [], phrases: phrases, phraseExemption: nil)
      return SettingsSearchVocabulary(
        version: 1, languageData: base.languageData, entries: entries, byteCount: 0)
    }
    #expect(
      with(left).contentHash(language: "fr") != with(right).contentHash(language: "fr"), "\(name)")
  }

  // MARK: - Rejections

  static let fixtureIDs: Set<String> = ["alpha.one", "alpha.two"]

  static func fixtureText() throws -> String {
    try String(
      contentsOf: RepoRoot.sourceURL("Tests/Fixtures/settings-map/vocabulary/minimal-valid.json"),
      encoding: .utf8)
  }

  static func fixtureVocabulary() throws -> SettingsSearchVocabulary {
    try SettingsSearchVocabulary.validate(Data(try fixtureText().utf8), expectedIDs: fixtureIDs)
      .get()
  }

  static func fixtureObject() throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(try fixtureText().utf8)) as? [String: Any])
  }

  /// Applies `change` to the fixture's `alpha.one` block in `language`.
  static func editingBlock(
    _ language: String, _ object: inout [String: Any], _ change: (inout [String: Any]) -> Void
  ) {
    var entries = object["entries"] as! [[String: Any]]
    var blocks = entries[0]["blocks"] as! [[String: Any]]
    let index = blocks.firstIndex { $0["language"] as? String == language }!
    change(&blocks[index])
    entries[0]["blocks"] = blocks
    object["entries"] = entries
  }

  static func editingLanguageData(
    _ language: String, _ object: inout [String: Any], _ change: (inout [String: Any]) -> Void
  ) {
    var list = object["languageData"] as! [[String: Any]]
    let index = list.firstIndex { $0["language"] as? String == language }!
    change(&list[index])
    object["languageData"] = list
  }

  struct Rejection: CustomTestStringConvertible, Sendable {
    let name: String
    let expected: String
    let change: @Sendable (inout [String: Any]) -> Void
    var testDescription: String { name }
  }

  static let rejections: [Rejection] = [
    .init(name: "wrong schema", expected: "schema: expected") { $0["schema"] = "other" },
    .init(name: "version as text", expected: "version: expected 1") { $0["version"] = "1" },
    .init(name: "unknown root field", expected: "unknown field \"extra\"") { $0["extra"] = true },
    .init(name: "languages out of order", expected: "languages: expected exactly") {
      $0["languages"] = Array(languages.reversed())
    },
    .init(name: "words not an array", expected: "alpha.one/fr.words: not an array of strings") {
      editingBlock("fr", &$0) { $0["words"] = "moteur" }
    },
    .init(name: "blank word", expected: "alpha.one/fr.words[0]: not a nonblank string") {
      editingBlock("fr", &$0) { $0["words"] = ["  "] }
    },
    .init(name: "number as phrase", expected: "alpha.one/fr.phrases[0]: not a nonblank string") {
      editingBlock("fr", &$0) { $0["phrases"] = [3] }
    },
    .init(name: "repeated word", expected: "\"w\" appears twice") {
      editingBlock("fr", &$0) { $0["words"] = ["w", "w"] }
    },
    .init(name: "blank title", expected: "alpha.one/fr.title: missing or blank") {
      editingBlock("fr", &$0) { $0["title"] = " " }
    },
    .init(name: "English title", expected: "alpha.one/en.title: en titles come from the interface")
    {
      editingBlock("en", &$0) { $0["title"] = "Engine" }
    },
    .init(
      name: "missing phrases", expected: "alpha.one/fr.phrases: empty with no reviewed exemption"
    ) {
      editingBlock("fr", &$0) { $0["phrases"] = [String]() }
    },
    .init(name: "exemption beside phrases", expected: "phraseExemption: set although phrases exist")
    {
      editingBlock("fr", &$0) { $0["phraseExemption"] = "reviewed" }
    },
    .init(name: "missing language", expected: "alpha.one: missing languages [\"zh\"]") {
      var entries = $0["entries"] as! [[String: Any]]
      entries[0]["blocks"] = (entries[0]["blocks"] as! [[String: Any]]).filter {
        $0["language"] as? String != "zh"
      }
      $0["entries"] = entries
    },
    .init(
      name: "undeclared language",
      expected: "alpha.one.blocks[32].language: not a declared language"
    ) {
      var entries = $0["entries"] as! [[String: Any]]
      entries[0]["blocks"] =
        (entries[0]["blocks"] as! [[String: Any]]) + [
          ["language": "xx", "words": [], "phrases": ["p"]]
        ]
      $0["entries"] = entries
    },
    .init(name: "language twice", expected: "alpha.one/fr: language appears twice") {
      var entries = $0["entries"] as! [[String: Any]]
      let blocks = entries[0]["blocks"] as! [[String: Any]]
      entries[0]["blocks"] = blocks + blocks.filter { $0["language"] as? String == "fr" }
      $0["entries"] = entries
    },
    .init(name: "orphan id", expected: "alpha.three: not a searchable Settings Map id") {
      var entries = $0["entries"] as! [[String: Any]]
      entries.append(["id": "alpha.three", "blocks": entries[0]["blocks"]!])
      $0["entries"] = entries
    },
    .init(
      name: "missing id",
      expected:
        "alpha.two: has no vocabulary; run scripts/settings-map/draft-vocabulary.sh alpha.two"
    ) {
      $0["entries"] = [($0["entries"] as! [[String: Any]])[0]]
    },
    .init(name: "duplicate id", expected: "alpha.one: appears twice") {
      let entries = $0["entries"] as! [[String: Any]]
      $0["entries"] = entries + [entries[0]]
    },
    .init(name: "stop word with a space", expected: "\"two words\" is not one word") {
      editingLanguageData("fr", &$0) { $0["stop"] = ["two words"] }
    },
    .init(name: "empty markers", expected: "fr.markers: empty") {
      editingLanguageData("fr", &$0) { $0["markers"] = [String]() }
    },
    .init(
      name: "marker in the stop list", expected: "en: stop list holds protected markers [\"not\"]"
    ) {
      editingLanguageData("en", &$0) { $0["stop"] = ["the", "NOT"] }
    },
    .init(name: "missing language data", expected: "languageData: missing [\"zh\"]") {
      $0["languageData"] = ($0["languageData"] as! [[String: Any]]).filter {
        $0["language"] as? String != "zh"
      }
    },
    .init(
      name: "stop word hides a place's word",
      expected: "alpha.one/fr: \"word1fr\" is also in the fr stop list"
    ) {
      editingLanguageData("fr", &$0) { $0["stop"] = ["filler", "Word1FR"] }
    },
  ]

  @Test("the fixture itself is valid")
  func fixtureIsValid() throws {
    let vocabulary = try Self.fixtureVocabulary()
    #expect(Set(vocabulary.entries.keys) == Self.fixtureIDs)
  }

  @Test(
    "the validator rejects each malformed vocabulary, naming the problem", arguments: rejections)
  func rejects(rejection: Rejection) throws {
    var object = try Self.fixtureObject()
    rejection.change(&object)
    let data = try JSONSerialization.data(withJSONObject: object)
    guard
      case .failure(.invalid(let problems)) =
        SettingsSearchVocabulary.validate(data, expectedIDs: Self.fixtureIDs)
    else {
      Issue.record("\(rejection.name) was accepted")
      return
    }
    #expect(
      problems.contains { $0.contains(rejection.expected) },
      "\(rejection.name): \(problems)")
  }

  @Test(
    "duplicate keys are refused before a dictionary can keep only the last one",
    arguments: ["\"schema\":\"x\",", "\"\\u0073chema\":\"x\","])
  func rejectsDuplicateKeys(duplicate: String) throws {
    let text = try Self.fixtureText()
    let data = Data(
      text.replacingOccurrences(of: "{\n \"schema\"", with: "{\(duplicate)\"schema\"").utf8)
    #expect(data.count == text.utf8.count + duplicate.utf8.count - 2)
    #expect(
      SettingsSearchVocabulary.validate(data, expectedIDs: Self.fixtureIDs)
        == .failure(.invalid(["duplicate key \"schema\" in one JSON object"])))
  }

  static let wideEncodings: [(String, String.Encoding)] = [
    ("UTF-16 with BOM", .utf16), ("UTF-16BE", .utf16BigEndian), ("UTF-16LE", .utf16LittleEndian),
    ("UTF-32 with BOM", .utf32), ("UTF-32BE", .utf32BigEndian), ("UTF-32LE", .utf32LittleEndian),
  ]

  @Test(
    "only UTF-8 is read, so a repeated key cannot hide in a wider encoding",
    arguments: wideEncodings.indices)
  func rejectsWideEncodings(encoding: Int) throws {
    let (name, wide) = Self.wideEncodings[encoding]
    let text = try Self.fixtureText().replacingOccurrences(
      of: "{\n \"schema\"", with: "{\"version\":1,\"schema\"")
    let data = try #require(text.data(using: wide), "\(name)")
    #expect(
      SettingsSearchVocabulary.validate(data, expectedIDs: Self.fixtureIDs)
        == .failure(.invalid(["resource: expected UTF-8 JSON without raw NUL bytes"])), "\(name)")
    #expect(
      SettingsSearchVocabulary.validate(Data(text.utf8), expectedIDs: Self.fixtureIDs)
        == .failure(.invalid(["duplicate key \"version\" in one JSON object"])))
  }

  @Test("text that is not JSON is invalid, not empty")
  func rejectsNonJSON() {
    guard
      case .failure(.invalid(let problems)) =
        SettingsSearchVocabulary.validate(Data("{\"schema\":".utf8), expectedIDs: Self.fixtureIDs)
    else {
      Issue.record("accepted")
      return
    }
    #expect(problems.count == 1 && problems[0].hasPrefix("not JSON"))
  }

  @Test("the size limit is exactly 3,000,000 bytes")
  func sizeBoundary() throws {
    let text = try Self.fixtureText()
    let atLimit = text + String(repeating: " ", count: 3_000_000 - text.utf8.count)
    #expect(atLimit.utf8.count == 3_000_000)
    #expect(
      (try? SettingsSearchVocabulary.validate(Data(atLimit.utf8), expectedIDs: Self.fixtureIDs)
        .get()) != nil)
    #expect(
      SettingsSearchVocabulary.validate(Data((atLimit + " ").utf8), expectedIDs: Self.fixtureIDs)
        == .failure(.tooLarge(bytes: 3_000_001)))
  }

  @Test("a bundle without the resource gives a typed failure, never an empty vocabulary")
  func missingResource() {
    #expect(
      SettingsSearchVocabulary.load(
        expectedIDs: Self.fixtureIDs, bundle: Bundle(for: BundleMarker.self))
        == .failure(.missingResource))
  }

  private final class BundleMarker {}
}
