import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 chunk 3: the committed meaning assets are the ones the code pins, and the place vectors
/// were built from the CURRENT Settings Map and vocabulary. **When this fails, the meaning pass
/// would refuse its own files at launch (and Settings search falls back to words only), or would
/// score settings against vectors built for a different map.** Hashes are recomputed here from the
/// files; sizes come from plan §3.7a, written as literals.
@Suite("Settings search meaning assets (#3482)", .tags(.driftGuard))
struct SettingsSearchMeaningAssetsTests {
  static let directory = RepoRoot.sourceURL("Sources/EnviousWispr/Resources/SettingsSearchMeaning")
  static let regenerate =
    "scripts/settings-map/export.sh, then scripts/settings-map/meaning-assets.py place-vectors (see its header)"

  static func assets() -> SettingsSearchMeaningAssets {
    SettingsSearchMeaningAssets(directory: directory)
  }

  static func manifest() throws -> SettingsSearchMeaningAssets.Manifest {
    // Decoded WITHOUT the pin so a stale pin is reported by its own test, not by every test.
    try JSONDecoder().decode(
      SettingsSearchMeaningAssets.Manifest.self,
      from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
  }

  /// sha256 over sorted "<relative path> <file sha256>" lines: the classifier's convention, and
  /// `meaning-assets.py`'s `tree_sha256`.
  static func treeSHA256(_ root: URL) throws -> (hash: String, bytes: Int) {
    let files = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var relative: [(path: String, url: URL)] = []
    let prefix = root.resolvingSymlinksInPath().path + "/"
    for case let url as URL in files {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      relative.append((String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count)), url))
    }
    relative.sort { $0.path < $1.path }
    var lines = ""
    var total = 0
    for file in relative {
      let data = try Data(contentsOf: file.url, options: .alwaysMapped)
      total += data.count
      lines += "\(file.path) \(SettingsSearchMeaningAssets.sha256Hex(data))\n"
    }
    return (SettingsSearchMeaningAssets.sha256Hex(Data(lines.utf8)), total)
  }

  // MARK: - Pins

  @Test("the pinned manifest hash is the committed manifest's")
  func pinnedManifestHash() throws {
    let data = try Data(contentsOf: Self.directory.appendingPathComponent("manifest.json"))
    let actual = SettingsSearchMeaningAssets.sha256Hex(data)
    #expect(
      actual == SettingsSearchMeaningAssets.pinnedManifestSHA256,
      "set SettingsSearchMeaningAssets.pinnedManifestSHA256 to \(actual) (regenerate with \(Self.regenerate))"
    )
    // The production loader accepts exactly these bytes.
    _ = try Self.assets().loadManifest()
  }

  @Test("every file matches the hash and size the manifest records")
  func filesMatchTheManifest() throws {
    let manifest = try Self.manifest()
    _ = try Self.assets().verifiedData(manifest.tokenizer.file, against: manifest.tokenizer.entry)
    _ = try Self.assets().verifiedData("place-vectors.bin", against: manifest.placeVectors.bin)
    _ = try Self.assets().verifiedData("place-vectors.json", against: manifest.placeVectors.index)
    let encoder = try Self.treeSHA256(
      Self.directory.appendingPathComponent(manifest.encoder.directory))
    #expect(encoder.hash == manifest.encoder.treeSHA256, "the compiled encoder changed")
  }

  @Test("the encoder and tokenizer are the sizes plan §3.7a records")
  func sizesMatchThePlan() throws {
    let manifest = try Self.manifest()
    // Plan §3.7a: the 6-bit palettized encoder package is 88,250,831 bytes; the full multilingual
    // tokenizer files, which the compact tokenizer.unigram is built from, are 17,085,326.
    #expect(manifest.encoder.sourcePackageBytes == 88_250_831)
    #expect(manifest.tokenizer.file == "tokenizer.unigram")
    #expect(
      manifest.tokenizer.source.keys.sorted() == [
        "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json",
      ])
    #expect(manifest.tokenizer.source.values.map(\.bytes).reduce(0, +) == 17_085_326)
    #expect(manifest.tokenizer.bytes < 8_000_000, "the compact tokenizer is \(manifest.tokenizer.bytes) bytes")
    // The model contract the Swift encoder is written against.
    #expect(manifest.encoder.sequenceLength == 32)
    #expect(manifest.encoder.queryPrefix == "query: ")
    #expect(manifest.encoder.padTokenID == 1)
    #expect(manifest.encoder.dimension == 384)
    #expect(manifest.encoder.inputs == ["input_ids", "attention_mask"])
    #expect(manifest.encoder.output == "embedding")
    #expect(manifest.placeVectors.dtype == "float16")
    #expect(manifest.selfTest.count >= 3)
    #expect(manifest.selfTest.allSatisfy { $0.vector.count == 384 })
  }

  // MARK: - Built from the current map

  private static func committedExport() throws -> (data: Data, fingerprints: [String: String]) {
    let data = try Data(contentsOf: RepoRoot.sourceURL("reference/settings-map.json"))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let fingerprints = try #require(root["fingerprints"] as? [String: Any])
    return (data, fingerprints.compactMapValues { $0 as? String })
  }

  // The vectors are bound to the exact texts they embed (below), not to whole-file hashes of the
  // map, vocabulary or interface catalog: an unrelated string change anywhere in the app must not
  // demand a re-embedding. The manifest's `sources` stay as provenance only.

  @Test("the vectors are for exactly the texts of the current export, and every searchable place")
  func textsMatchTheCurrentExport() throws {
    let manifest = try Self.manifest()
    let texts = try SettingsSearchPlaceTexts(exportData: Self.committedExport().data)
    #expect(
      texts.textsSHA256 == manifest.placeVectors.textsSHA256,
      "place texts changed: \(Self.regenerate)")
    #expect(texts.rows.count == manifest.placeVectors.rows)

    let indexData = try Data(
      contentsOf: Self.directory.appendingPathComponent("place-vectors.json"))
    let index = try #require(try JSONSerialization.jsonObject(with: indexData) as? [String: Any])
    #expect(index["textsSHA256"] as? String == texts.textsSHA256)
    #expect(index["entryOrder"] as? [String] == texts.entryOrder)
    // The catalog is what search lists; the vectors must cover exactly it, in its order.
    #expect(texts.entryOrder == SettingsSearchCatalog.entries.map(\.id))
    #expect(Set(texts.entryOrder) == SettingsSearchCatalog.searchableIDs)

    let committed = try #require(index["entries"] as? [String: [String: Any]])
    for id in texts.entryOrder {
      let expected = try #require(texts.entries[id])
      let entry = try #require(committed[id], "\(id) has no vectors")
      #expect(entry["main"] as? [String: Int] == expected.main, "\(id) name rows")
      #expect(entry["languages"] as? [String: [Int]] == expected.languages, "\(id) language rows")
    }
    #expect(committed.count == texts.entryOrder.count)
  }

  // MARK: - Recipe

  @Test(
    "the text recipe keeps the bench's shape: name and description, then phrases and joined words")
  func recipeShape() throws {
    let export = try Self.committedExport().data
    let texts = try SettingsSearchPlaceTexts(exportData: export)
    // Input Device: a resource title with a description, in both interface languages.
    let id = texts.entries["inputDevice"]
    let english = try #require(id?.main["en"])
    #expect(texts.rows[english] == "Input device. Choose the microphone used for recording.")
    let german = try #require(id?.main["de"])
    #expect(texts.rows[german] == "Eingabegerät. Wähle das Mikrofon für die Aufnahme.")
    // A runtime-named place has no fixed name: its text is its description or nothing.
    let engine = try #require(texts.entries["currentEngineSection"])
    for row in engine.main.values { #expect(texts.rows[row].hasPrefix(". ") == false) }
    // Every row is nonblank and unique (a shared text is embedded once).
    #expect(
      texts.rows.allSatisfy {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == $0 && $0.isEmpty == false
      })
    #expect(Set(texts.rows).count == texts.rows.count)
  }

  @Test("an added text changes the hash, and so does which place owns it")
  func hashSeesTextsAndOwners() throws {
    let export = try Self.committedExport().data
    let base = try SettingsSearchPlaceTexts(exportData: export).textsSHA256

    func adding(_ phrase: String, to ids: [String]) throws -> Data {
      var root = try #require(try JSONSerialization.jsonObject(with: export) as? [String: Any])
      var nodes = try #require(root["nodes"] as? [[String: Any]])
      for id in ids {
        let index = try #require(nodes.firstIndex { $0["id"] as? String == id })
        var vocabulary = try #require(nodes[index]["vocabulary"] as? [String: [String: Any]])
        var english = try #require(vocabulary["en"])
        english["phrases"] = (english["phrases"] as? [String] ?? []) + [phrase]
        vocabulary["en"] = english
        nodes[index]["vocabulary"] = vocabulary
      }
      root["nodes"] = nodes
      return try JSONSerialization.data(withJSONObject: root)
    }

    let one = try SettingsSearchPlaceTexts(
      exportData: try adding("one more way to say it", to: ["inputDevice"]))
    let two = try SettingsSearchPlaceTexts(
      exportData: try adding("one more way to say it", to: ["inputDevice", "theme"]))
    #expect(one.textsSHA256 != base)
    // The same new text, shared by a second place: the same rows, owned differently.
    #expect(two.rows == one.rows)
    #expect(two.textsSHA256 != one.textsSHA256)
  }

  // MARK: - Bundle wiring

  @Test("the app target copies the asset folder into Contents/Resources by its runtime name")
  func projectWiresTheFolder() throws {
    // A source check; that the built app really holds the folder is checked by building the app
    // (the PR notes record it).
    let project = try String(contentsOf: RepoRoot.sourceURL("Project.swift"), encoding: .utf8)
    let folder = SettingsSearchMeaningAssets.folderName
    #expect(
      project.contains(".folderReference(path: \"Sources/EnviousWispr/Resources/\(folder)\")"),
      "Project.swift no longer copies Resources/\(folder) into the app")
    #expect(Self.directory.lastPathComponent == folder)
  }
}
