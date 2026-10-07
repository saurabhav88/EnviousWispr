import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 chunk 3: the in-repo tokenizer of the meaning model produces the Hugging Face ids.
/// **When this fails, a typed search is split into different pieces than the model was trained on,
/// so its vector moves and unrelated settings rank first** (the tokenizer the app already links did
/// exactly that: cosine 0.84 to 0.95 against the reference). The oracle is the Hugging Face tokenizer
/// itself, run by `scripts/settings-map/meaning-tokenizer-fixture.py`, never this code.
@Suite("Settings search Unigram tokenizer (#3482)", .tags(.productOutcome))
struct SettingsSearchUnigramTokenizerTests {
  struct Fixture: Decodable {
    struct Case: Decodable {
      let group: String
      let text: String
      let ids: [Int]
    }
    struct PlaceTexts: Decodable {
      let textsSHA256: String
      let rows: Int
      let idsHash: [String]
    }
    struct Source: Decodable {
      let prefix: String
    }
    let source: Source
    let placeTexts: PlaceTexts
    let cases: [Case]
  }

  static func tokenizer() throws -> SettingsSearchUnigramTokenizer {
    let manifest = try SettingsSearchMeaningAssetsTests.manifest()
    let url = SettingsSearchMeaningAssetsTests.directory.appendingPathComponent(
      manifest.tokenizer.file)
    return try SettingsSearchUnigramTokenizer(data: Data(contentsOf: url))
  }

  static func fixture() throws -> Fixture {
    try JSONDecoder().decode(
      Fixture.self,
      from: Data(
        contentsOf: RepoRoot.sourceURL(
          "Tests/Fixtures/settings-search/meaning-tokenizer-parity.json")
      ))
  }

  /// The same short hash the fixture script writes: SHA-256 of the comma-joined ids, 16 hex digits.
  static func idsHash(_ ids: [Int]) -> String {
    let digest = SettingsSearchMeaningAssets.sha256Hex(
      Data(ids.map(String.init).joined(separator: ",").utf8))
    return String(digest.prefix(16))
  }

  @Test("the searches that moved the vectors tokenize as Hugging Face tokenizes them")
  func knownIDs() throws {
    let tokenizer = try Self.tokenizer()
    // Written from the Hugging Face tokenizer's output; the ArgmaxOSS tokenizer returns
    // [0, 944, 1294, 12, 19111, ...] for the first one.
    #expect(
      tokenizer.encode("query: stop recording on silence")
        == [0, 41, 1294, 12, 7279, 182304, 98, 156568, 2])
    #expect(
      tokenizer.encode("query: dunkler Modus") == [0, 41, 1294, 12, 7524, 28329, 16269, 223, 2])
    #expect(tokenizer.encode("query: parakeet") == [0, 41, 1294, 12, 121, 350, 126, 2])
    #expect(tokenizer.encode("") == [0, 2])
  }

  @Test("every practice search, special case and fuzz string tokenizes to the Hugging Face ids")
  func explicitCases() throws {
    let tokenizer = try Self.tokenizer()
    let fixture = try Self.fixture()
    #expect(fixture.cases.count > 2_000)
    var groups: [String: Int] = [:]
    var mismatches: [String] = []
    for item in fixture.cases {
      groups[item.group, default: 0] += 1
      if tokenizer.encode(fixture.source.prefix + item.text) != item.ids {
        mismatches.append("\(item.group): \(item.text.prefix(40).debugDescription)")
      }
    }
    #expect(
      groups["practice"] == 699 && groups["special"]! > 40 && groups["fuzz"]! >= 1_000, "\(groups)")
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(5))")
  }

  @Test("every place text, in 32 languages, tokenizes to the Hugging Face ids")
  func everyPlaceText() throws {
    let tokenizer = try Self.tokenizer()
    let fixture = try Self.fixture()
    let export = try Data(contentsOf: RepoRoot.sourceURL("reference/settings-map.json"))
    let texts = try SettingsSearchPlaceTexts(exportData: export)
    // The fixture hashes are for exactly these texts.
    #expect(
      texts.textsSHA256 == fixture.placeTexts.textsSHA256,
      "regenerate the fixture: see meaning-tokenizer-fixture.py")
    #expect(texts.rows.count == fixture.placeTexts.rows)
    var mismatches: [String] = []
    for (index, row) in texts.rows.enumerated() {
      let ids = tokenizer.encode(fixture.source.prefix + row)
      if Self.idsHash(ids) != fixture.placeTexts.idsHash[index] {
        mismatches.append("row \(index): \(row.prefix(40).debugDescription)")
      }
    }
    #expect(
      mismatches.isEmpty,
      "\(mismatches.count) of \(texts.rows.count) differ, first: \(mismatches.prefix(5))")
  }

  // MARK: - The file

  @Test("a damaged tokenizer file is refused, never half-read")
  func damagedFilesAreRefused() throws {
    let url = SettingsSearchMeaningAssetsTests.directory.appendingPathComponent("tokenizer.unigram")
    let good = try Data(contentsOf: url)
    #expect(throws: SettingsSearchUnigramTokenizer.LoadError.self) {
      try SettingsSearchUnigramTokenizer(data: Data())
    }
    var wrongMagic = good
    wrongMagic[0] ^= 0xFF
    #expect(throws: SettingsSearchUnigramTokenizer.LoadError.self) {
      try SettingsSearchUnigramTokenizer(data: wrongMagic)
    }
    #expect(throws: SettingsSearchUnigramTokenizer.LoadError.self) {
      try SettingsSearchUnigramTokenizer(data: good.prefix(good.count - 1))
    }
    #expect(throws: SettingsSearchUnigramTokenizer.LoadError.self) {
      try SettingsSearchUnigramTokenizer(data: good + Data([0]))
    }
  }

  @Test("tokenizing a long search is fast enough not to matter")
  func longSearchesAreCheap() throws {
    let tokenizer = try Self.tokenizer()
    let text = String(
      repeating: "stop recording when I pause talking, bitte aufhören 録音を止める ", count: 20)
    let start = DispatchTime.now().uptimeNanoseconds
    _ = tokenizer.encode(text)
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    print("tokenized \(text.count) characters in \(milliseconds) ms on this Mac")
    #expect(milliseconds < 5_000, "a hang guard, not a latency bound")
  }
}
