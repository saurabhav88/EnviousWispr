import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 chunk 3: how a typed search's vector is scored against the place vectors. **When this
/// fails, the meaning pass ranks the wrong settings, or scores places in a language the user did
/// not ask for.** Vectors here are three numbers long and chosen so the cosines are known by hand.
@Suite("Settings search place vectors (#3482)", .tags(.productOutcome))
struct SettingsSearchPlaceVectorsTests {

  /// Rows: r0 (1,0,0), r1 (0,1,0), r2 (0,0,1), r3 (0.5,0.5,0), r4 (3,4,0). Both r3 and r4 are
  /// exact in half precision and not unit length.
  static let rows: [Float16] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0.5, 0.5, 0, 3, 4, 0]

  static func vectors() -> SettingsSearchPlaceVectors {
    SettingsSearchPlaceVectors(
      dimension: 3, rowCount: 5, textsSHA256: "t",
      entries: [
        "a": .init(main: ["en": 0, "de": 1], languages: ["en": [3]]),
        "b": .init(main: ["en": 2], languages: ["de": [1], "fr": [0]]),
        "c": .init(main: [:], languages: [:]),
        "d": .init(main: ["en": 4], languages: [:]),
      ], rows: rows)
  }

  static let order = ["a", "b", "c", "d"]

  private func scores(
    _ query: [Float], app: String = "en", languages: [String] = ["en"]
  ) throws -> [Double] {
    let view = try #require(
      Self.vectors().view(entryIDs: Self.order, appLanguage: app, vocabularyLanguages: languages))
    return try #require(view.similarities(query: query)).values
  }

  @Test("a place scores its best row, and a place with no row scores -1")
  func bestRowWins() throws {
    // Active: the English name row and the English words.
    // a: rows r0, r3. b: r2. c: none. d: r4 normalized to (0.6, 0.8, 0).
    // r3 normalized is (0.70711, 0.70711, 0).
    let x = try scores([1, 0, 0])
    #expect(abs(x[0] - 1.0) < 1e-6)  // r0
    #expect(abs(x[1] - 0.0) < 1e-6)
    #expect(x[2] == -1)
    #expect(abs(x[3] - 0.6) < 1e-6)
    let y = try scores([0, 1, 0])
    #expect(abs(y[0] - 0.70710678) < 1e-6)  // r3 beats r0
    #expect(abs(y[3] - 0.8) < 1e-6)  // r4 is scored as a unit vector
  }

  @Test("the typed vector's length does not matter")
  func queryIsNormalized() throws {
    let long = try scores([2, 0, 0])
    let unit = try scores([1, 0, 0])
    #expect(zip(long, unit).allSatisfy { abs($0 - $1) < 1e-6 })
  }

  @Test("only the active languages' rows are scored")
  func activeLanguagesOnly() throws {
    // German words active: b gains r1; a keeps only its English-app name row r0 (en words off).
    let german = try scores([0, 1, 0], languages: ["de"])
    #expect(abs(german[1] - 1.0) < 1e-6)  // b: r2 and r1
    #expect(abs(german[0] - 0.0) < 1e-6)  // a: r0 only
    // French words active: b gains r0.
    let french = try scores([1, 0, 0], languages: ["fr"])
    #expect(abs(french[1] - 1.0) < 1e-6)
    // No vocabulary language: only the name rows. a is r0 and b is r2.
    let none = try scores([0, 0, 1], languages: [])
    #expect(abs(none[1] - 1.0) < 1e-6 && abs(none[0]) < 1e-6)
    // The app language picks the name row: German name row of a is r1.
    let deApp = try scores([0, 1, 0], app: "de", languages: [])
    #expect(abs(deApp[0] - 1.0) < 1e-6)
    #expect(deApp[1] == -1, "b has no German name row and none of its words are active")
  }

  @Test("a place the vectors were not built for refuses the whole view")
  func unknownPlaceRefusesTheView() {
    #expect(
      Self.vectors().view(
        entryIDs: ["a", "no-such-place"], appLanguage: "en", vocabularyLanguages: ["en"]) == nil)
  }

  @Test("an unusable typed vector scores nothing")
  func unusableQueries() throws {
    let view = try #require(
      Self.vectors().view(entryIDs: Self.order, appLanguage: "en", vocabularyLanguages: ["en"]))
    #expect(view.similarities(query: [1, 0]) == nil)
    #expect(view.similarities(query: [0, 0, 0]) == nil)
    #expect(view.similarities(query: [1, .nan, 0]) == nil)
    #expect(view.similarities(query: [.infinity, 0, 0]) == nil)
  }

  // MARK: - Loading

  private struct Built {
    let assets: SettingsSearchMeaningAssets
    let manifest: SettingsSearchMeaningAssets.Manifest
  }

  /// A one-row, three-number asset folder with a matching manifest, then `mutate` may damage it.
  private func build(
    rows: Int = 1, dimension: Int = 3, binBytes: Int? = nil,
    entries: String = #"{"a":{"main":{"en":0},"languages":{}}}"#,
    corruptBinAfterHashing: Bool = false
  ) throws -> Built {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "place-vectors-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bin = Data(repeating: 0x3C, count: binBytes ?? rows * dimension * 2)
    let index = Data(
      """
      {"schema":"settings-search-place-vectors","version":1,"dimension":\(dimension),\
      "dtype":"float16","rows":\(rows),"textsSHA256":"t","entries":\(entries)}
      """.utf8)
    try bin.write(to: directory.appendingPathComponent("place-vectors.bin"))
    try index.write(to: directory.appendingPathComponent("place-vectors.json"))
    let manifestJSON = """
      {"schema":"settings-search-meaning-assets","version":1,
       "encoder":{"directory":"e.mlmodelc","treeSHA256":"x","sequenceLength":32,"queryPrefix":"query: ",\
      "padTokenID":1,"dimension":\(dimension),"inputs":["input_ids","attention_mask"],"output":"embedding",\
      "sourcePackageSHA256":"x","sourcePackageBytes":1},
       "tokenizer":{"file":"t.unigram","sha256":"x","bytes":1,"source":{}},
       "placeVectors":{"bin":{"sha256":"\(SettingsSearchMeaningAssets.sha256Hex(bin))","bytes":\(bin.count)},
        "index":{"sha256":"\(SettingsSearchMeaningAssets.sha256Hex(index))","bytes":\(index.count)},
        "textsSHA256":"t","rows":\(rows),"dimension":\(dimension),"dtype":"float16"},
       "selfTest":[],
       "sources":{"mapSHA256":"m","vocabularySHA256":"v","uiCatalogSHA256":"u"}}
      """
    if corruptBinAfterHashing {
      try Data(repeating: 0x00, count: bin.count).write(
        to: directory.appendingPathComponent("place-vectors.bin"))
    }
    let manifest = try JSONDecoder().decode(
      SettingsSearchMeaningAssets.Manifest.self, from: Data(manifestJSON.utf8))
    return Built(assets: SettingsSearchMeaningAssets(directory: directory), manifest: manifest)
  }

  @Test("matching files load")
  func loadsConsistentAssets() throws {
    let built = try build()
    let vectors = try SettingsSearchPlaceVectors.load(
      assets: built.assets, manifest: built.manifest)
    #expect(vectors.rowCount == 1 && vectors.dimension == 3)
    #expect(vectors.entries["a"]?.main == ["en": 0])
  }

  @Test("a vector file that is not the one in the manifest is refused")
  func changedVectorsAreRefused() throws {
    let built = try build(corruptBinAfterHashing: true)
    #expect(throws: SettingsSearchMeaningAssets.AssetError.hashMismatch("place-vectors.bin")) {
      try SettingsSearchPlaceVectors.load(assets: built.assets, manifest: built.manifest)
    }
  }

  @Test("an index that names a row outside the file, or a wrong file size, is refused")
  func inconsistentIndexIsRefused() throws {
    let outside = try build(entries: #"{"a":{"main":{"en":1},"languages":{}}}"#)
    #expect(throws: SettingsSearchPlaceVectors.LoadError.self) {
      try SettingsSearchPlaceVectors.load(assets: outside.assets, manifest: outside.manifest)
    }
    // One row of three half-precision numbers is 6 bytes, not 8.
    let short = try build(binBytes: 8)
    #expect(throws: SettingsSearchPlaceVectors.LoadError.self) {
      try SettingsSearchPlaceVectors.load(assets: short.assets, manifest: short.manifest)
    }
  }
}
