import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482: the committed `reference/settings-map.json` is the compiled map's own export, and its
/// fields say what they should. Expectations come from the inventory fixture and literals here,
/// not from the exporter under test. The Markdown rendering of the same export is compared by
/// `scripts/settings-map/export.sh --check` in CI.
@Suite("Settings Map export sync (#3482)", .tags(.driftGuard))
struct SettingsMapExportSyncTests {
  static let committedPath = "reference/settings-map.json"

  static func committed() throws -> Data {
    try Data(contentsOf: RepoRoot.sourceURL(committedPath))
  }

  static func committedDocument() throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: try committed()) as? [String: Any])
  }

  static func nodes() throws -> [String: [String: Any]] {
    let list = try #require(try committedDocument()["nodes"] as? [[String: Any]])
    return Dictionary(uniqueKeysWithValues: list.map { ($0["id"] as! String, $0) })
  }

  /// What is wrong with a committed artifact against a fresh export.
  static func syncProblems(committed: Data?, fresh: Data) -> [String] {
    guard let committed else { return ["\(committedPath) is missing"] }
    return committed == fresh
      ? [] : ["\(committedPath) is stale; run scripts/settings-map/export.sh"]
  }

  @Test("the committed export is byte-identical to a fresh export of the compiled map")
  func committedMatchesFreshExport() throws {
    let fresh = try SettingsMapExportTests.fullDocument()
    #expect(Self.syncProblems(committed: try? Self.committed(), fresh: fresh) == [])
  }

  @Test("a missing or edited artifact is reported, an identical one is not")
  func staleAndMissingAreCaught() throws {
    let fresh = Data("{\"a\":1}\n".utf8)
    #expect(Self.syncProblems(committed: nil, fresh: fresh) == ["\(Self.committedPath) is missing"])
    #expect(
      Self.syncProblems(committed: Data("{\"a\":2}\n".utf8), fresh: fresh)
        == ["\(Self.committedPath) is stale; run scripts/settings-map/export.sh"])
    #expect(Self.syncProblems(committed: fresh, fresh: fresh) == [])
  }

  @Test("every map node appears once, in map order; every searchable node carries all 32 languages")
  func completeness() throws {
    let document = try Self.committedDocument()
    let list = try #require(document["nodes"] as? [[String: Any]])
    let ids = list.map { $0["id"] as? String ?? "" }
    #expect(ids == SettingsMap.nodes.map(\.id.rawValue))
    let inventory = try SettingsMapTests.inventory()
    let mapped = Set(inventory.items.filter { $0.disposition == "mapped" }.map(\.id))
    let structural = Set(inventory.structural.map(\.id))
    #expect(Set(ids) == mapped.union(structural).union(["window.settings"]))
    let searchable = list.filter { $0["searchable"] as? Bool == true }
    #expect(Set(searchable.compactMap { $0["id"] as? String }) == mapped)
    var blocks = 0
    for node in searchable {
      let vocabulary = try #require(node["vocabulary"] as? [String: Any], "\(node["id"] ?? "")")
      #expect(Set(vocabulary.keys) == Set(SettingsSearchVocabularyTests.languages))
      blocks += vocabulary.count
    }
    #expect(!searchable.isEmpty, "the export has no searchable places")
    #expect(blocks == searchable.count * SettingsSearchVocabularyTests.languages.count)
    #expect(
      list.filter { $0["searchable"] as? Bool != true }.allSatisfy { $0["vocabulary"] == nil })
  }

  @Test("English and German come from the built catalog, with format arguments filled")
  func localeLiterals() throws {
    let nodes = try Self.nodes()
    func title(_ id: String) throws -> [String: String] {
      try #require(nodes[id]?["title"] as? [String: String], "\(id)")
    }
    let s1 = try title("aiPolish.whyUse.s1Mini")
    #expect(s1["key"] == "Why use %@")
    #expect(s1["en"] == "Why use S1-mini")
    #expect(s1["de"] == "Warum S1-mini verwenden?")
    let enable = try title("enableAIPolish")
    #expect(enable["key"] == "settings.aiPolish.enable.title")
    #expect(enable["en"] == "Enable AI Polish")
    #expect(enable["de"] == "KI-Nachbearbeitung aktivieren")
    #expect(try title("dictation.tab.microphone")["de"] == "Mikrofon")
    // No exported text keeps a raw placeholder.
    let text = String(decoding: try Self.committed(), as: UTF8.self)
    for line in text.split(separator: "\n") where line.contains("\"en\"") || line.contains("\"de\"")
    {
      #expect(!line.contains("%@") && !line.contains("%lld"), "\(line)")
    }
  }

  @Test("runtime titles and descriptions export their declaration, never a value")
  func dynamicDeclarations() throws {
    let nodes = try Self.nodes()
    var dynamicCount = 0
    for mapNode in SettingsMap.nodes {
      let node = try #require(nodes[mapNode.id.rawValue])
      let title = try #require(node["title"] as? [String: Any])
      if case .dynamic(let resolver) = mapNode.title {
        dynamicCount += 1
        #expect(title["resolver"] as? String == "\(resolver)")
        #expect(title["runtime"] as? Bool == true)
        #expect(title["en"] == nil && title["de"] == nil && title["text"] == nil)
      }
      if case .runtime? = mapNode.description {
        let description = try #require(node["description"] as? [String: Any])
        #expect(description["source"] as? String == "runtime")
        #expect(description["en"] == nil && description["de"] == nil)
      }
    }
    #expect(dynamicCount > 0)
  }

  @Test("serialization is deterministic and carries no machine path, time or revision")
  func deterministic() throws {
    let first = try SettingsMapExportTests.fullDocument()
    #expect(first == (try SettingsMapExportTests.fullDocument()))
    let text = String(decoding: first, as: UTF8.self)
    for forbidden in ["/Users/", "/private/", "/var/folders/", "/Volumes/", "DerivedData"] {
      #expect(!text.contains(forbidden), "\(forbidden)")
    }
    #expect(text.firstMatch(of: /20\d\d-\d\d-\d\dT\d\d:/) == nil)
    #expect(text.firstMatch(of: /\b[0-9a-f]{40}\b/) == nil, "a 40-hex revision")
    #expect(text.hasSuffix("}\n"))
  }

  @Test("fingerprints name the exact vocabulary, interface catalog and map metadata")
  func sourceIdentity() throws {
    let document = try Self.committedDocument()
    let fingerprints = try #require(document["fingerprints"] as? [String: String])
    func sha(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    let vocabulary = try Data(contentsOf: try #require(SettingsSearchVocabulary.resourceURL()))
    #expect(fingerprints["vocabularySHA256"] == sha(vocabulary))
    #expect(
      fingerprints["vocabularySHA256"]
        == (try SettingsSearchVocabularyTests.receipt()).resource.sha256)
    #expect(
      fingerprints["uiCatalogSHA256"]
        == sha(
          try Data(
            contentsOf: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/Localizable.xcstrings")))
    )
    #expect(fingerprints["vocabularyCanonicalization"] == "length-prefixed-v1")
    let metadata = try SettingsMap.nodes.map(SettingsMapExportTests.node)
    #expect(
      fingerprints["mapSHA256"]
        == sha(try SettingsMapExportTests.serialize(metadata, pretty: false)))
    let sources = try #require(document["sources"] as? [String: String])
    for path in sources.values {
      #expect(FileManager.default.fileExists(atPath: RepoRoot.sourceURL(path).path), "\(path)")
    }
  }
}
