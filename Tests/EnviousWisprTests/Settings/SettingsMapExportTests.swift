import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482: the one extraction owner for Settings Map metadata outside the app. Opt-in: it runs only
/// when the runner sets `TEST_RUNNER_EW_SETTINGS_MAP_EXPORT=<output path>`.
///
/// - Full export (no id): every map node in map order, with its validated vocabulary. This is
///   `reference/settings-map.json`; `scripts/settings-map/export.sh` renders the Markdown reference
///   from it and CI compares both with the committed copies.
/// - One place (`TEST_RUNNER_EW_SETTINGS_MAP_EXPORT_ID=<id>`): that searchable node and its
///   ancestors, without vocabulary, for `scripts/settings-map/draft-vocabulary.sh`.
///
/// English and German come from the built app's compiled String Catalog, with format arguments
/// resolved; an unresolved field fails the export. A runtime-named title or runtime description
/// exports its declared resolver or role, never a sampled value, so no device name, key draft,
/// custom word or other live state can leave the machine through it.
@Suite(
  "Settings Map export (#3482, opt-in)", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_SETTINGS_MAP_EXPORT"] != nil))
struct SettingsMapExportTests {
  static let formatVersion = 2
  static let interfaceLanguages = ["en", "de"]
  /// Repo-relative owners, cited by every exported node.
  static let mapFile = "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift"
  static let resolverFile =
    "Sources/EnviousWisprAppKit/Views/Settings/SettingsMapRegistration.swift"
  static let uiCatalogFile = "Sources/EnviousWispr/Resources/Localizable.xcstrings"
  static let vocabularyFile = "Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json"

  struct ExportError: Error, CustomStringConvertible {
    let description: String
  }

  /// Tests run unhosted, so `Bundle.main` is the test runner; the compiled String Catalog lives in
  /// the app built beside the test bundle, whose name depends on the configuration
  /// (InterfaceCatalogSourceTests.builtApp: `EnviousWispr.app` or `EnviousWispr Local.app`).

  // MARK: - Copy resolution

  /// A resource's text in one interface language, from the built app's compiled catalog, with
  /// its format arguments applied. English is the resource's own resolution (the source text).
  /// German is the compiled `de.lproj` entry with the same arguments, which are recovered by
  /// matching the English text against the English entry: a missing German entry, an argument
  /// that cannot be recovered, or a leftover placeholder fails the export.
  static func resolve(_ resource: LocalizedStringResource, _ code: String) throws -> String {
    let english = String(localized: resource)
    guard !hasPlaceholder(english) else {
      throw ExportError(description: "en: unresolved placeholder in \"\(english)\"")
    }
    if code == "en" { return english }
    let app = try InterfaceCatalogSourceTests.builtApp()
    let missing = "\u{0}missing"
    func entry(_ language: String) throws -> String? {
      guard let table = Bundle(url: app.appendingPathComponent("Contents/Resources/\(language).lproj"))
      else { throw ExportError(description: "the built app has no \(language) catalog at \(app.path)") }
      let value = table.localizedString(forKey: resource.key, value: missing, table: resource.table)
      return value == missing ? nil : value
    }
    guard let template = try entry(code) else {
      throw ExportError(description: "\(code): no catalog entry for \"\(resource.key)\"")
    }
    guard hasPlaceholder(template) else { return template }
    // The English template: the en.lproj entry, else the key itself (an interpolated key).
    let englishTemplate = try entry("en") ?? resource.key
    guard let arguments = capture(english, template: englishTemplate) else {
      throw ExportError(
        description: "\(code): cannot recover the arguments of \"\(resource.key)\" from \"\(english)\"")
    }
    let text = fill(template, arguments: arguments)
    guard !hasPlaceholder(text), matches(text, template: template) else {
      throw ExportError(description: "\(code): \"\(resource.key)\" did not resolve: \"\(text)\"")
    }
    return text
  }

  static var placeholder: Regex<Substring> { /%(?:\d+\$)?(?:@|l{0,2}[duxXf]|s)/ }

  static func hasPlaceholder(_ text: String) -> Bool { text.contains(placeholder) }

  /// The 1-based argument index each placeholder of `template` refers to, in order.
  static func argumentIndexes(_ template: String) -> [Int] {
    var next = 0
    return template.matches(of: placeholder).map { match in
      let token = String(match.output)
      if let dollar = token.firstIndex(of: "$"), let index = Int(token.dropFirst().prefix(upTo: dollar)) {
        return index
      }
      next += 1
      return next
    }
  }

  static func pattern(_ template: String) -> String {
    template.split(separator: placeholder, omittingEmptySubsequences: false)
      .map { NSRegularExpression.escapedPattern(for: String($0)) }
      .joined(separator: "(.+?)")
  }

  /// Whether `text` is `template` with each placeholder filled by some nonempty text.
  static func matches(_ text: String, template: String) -> Bool {
    text.range(of: "^\(pattern(template))$", options: .regularExpression) != nil
  }

  /// The arguments, by 1-based index, that turn `template` into `text`.
  static func capture(_ text: String, template: String) -> [Int: String]? {
    guard let expression = try? NSRegularExpression(pattern: "^\(pattern(template))$"),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    var arguments: [Int: String] = [:]
    for (position, index) in argumentIndexes(template).enumerated() {
      guard let range = Range(match.range(at: position + 1), in: text) else { return nil }
      arguments[index] = String(text[range])
    }
    return arguments
  }

  static func fill(_ template: String, arguments: [Int: String]) -> String {
    let indexes = argumentIndexes(template)
    var result = ""
    var rest = Substring(template)
    for index in indexes {
      guard let match = rest.firstMatch(of: placeholder) else { break }
      result += rest[..<match.range.lowerBound] + (arguments[index] ?? String(match.output))
      rest = rest[match.range.upperBound...]
    }
    return result + rest
  }

  // MARK: - Node export

  static func title(_ title: SettingsMapTitle) throws -> [String: Any] {
    switch title {
    case .resource(let resource): try resourceObject(resource)
    case .verbatim(let text):
      [
        "source": "verbatim", "text": text,
        "note": "a shared product name, the same in every language",
      ]
    case .dynamic(let resolver):
      [
        "source": "dynamic", "runtime": true, "resolver": "\(resolver)",
        "resolvedBy": "SettingsMap.title(of:)", "owner": resolverFile,
      ]
    }
  }

  static func description(_ description: SettingsMapDescription?) throws -> Any {
    switch description {
    case .resource(let resource)?: try resourceObject(resource)
    case .runtime?:
      [
        "source": "runtime", "runtime": true,
        "role": "composed by the registering row from live state at display time; never sampled",
      ]
    case nil: NSNull()
    }
  }

  static func resourceObject(_ resource: LocalizedStringResource) throws -> [String: Any] {
    [
      "source": "resource", "key": resource.key, "table": resource.table ?? "Localizable",
      "catalog": uiCatalogFile, "en": try resolve(resource, "en"),
      "de": try resolve(resource, "de"),
    ]
  }

  static func destination(_ destination: SettingsDestination?) -> Any {
    guard let destination else { return NSNull() }
    var object: [String: Any] = ["page": destination.page.rawValue]
    switch destination {
    case .dictation(let tab): object["tab"] = tab.rawValue
    case .appSettings(let tab): object["tab"] = tab.rawValue
    default: break
    }
    return object
  }

  /// One node's metadata, without vocabulary. Enum-valued fields are the Swift case names of
  /// SettingsMapStructure, SettingsMapVisibility and SettingsMapDynamicTitle.
  static func node(_ node: SettingsMapNode) throws -> [String: Any] {
    let context = try ancestors(of: node).map(\.rawValue)
    return [
      "id": node.id.rawValue,
      "structure": "\(node.structure)",
      "kind": json(node.item?.rawValue),
      "searchable": node.item != nil,
      "parent": json(node.parent?.rawValue),
      "context": context,
      "title": try title(node.title),
      "description": try description(node.description),
      "destination": destination(node.destination),
      "dictionaryTab": json(node.dictionaryTab?.rawValue),
      "visibility": "\(node.visibility)",
      "target": json(node.target?.rawValue),
      "fallbacks": node.fallbacks.map(\.rawValue),
      "declaredIn": mapFile,
    ]
  }

  /// A node's ancestors, outermost first. A repeated id is a cycle, which fails the export
  /// instead of looping.
  static func ancestors(of node: SettingsMapNode) throws -> [SettingsMapID] {
    var chain: [SettingsMapID] = []
    var seen: Set<SettingsMapID> = [node.id]
    var parent = node.parent
    while let id = parent {
      guard seen.insert(id).inserted else {
        throw ExportError(description: "\(node.id.rawValue) sits in a cycle at \(id.rawValue)")
      }
      chain.insert(id, at: 0)
      parent = SettingsMap.node(id).parent
    }
    return chain
  }

  static func block(_ block: SettingsSearchVocabulary.Block) -> [String: Any] {
    var object: [String: Any] = ["words": block.words, "phrases": block.phrases]
    object["title"] = block.title
    object["phraseExemption"] = block.phraseExemption
    return object
  }

  static func json(_ text: String?) -> Any { text ?? NSNull() }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func serialize(_ value: Any, pretty: Bool = true) throws -> Data {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    return try JSONSerialization.data(withJSONObject: value, options: options) + Data("\n".utf8)
  }

  /// The full export: every node in map order, the validated vocabulary joined by id, and
  /// fingerprints of the three inputs. No timestamp, path outside the repo or revision.
  static func fullDocument() throws -> Data {
    let vocabulary: SettingsSearchVocabulary
    switch SettingsSearchVocabulary.load() {
    case .success(let loaded): vocabulary = loaded
    case .failure(let error): throw ExportError(description: "vocabulary: \(error)")
    }
    let joined: [SettingsSearchCatalog.JoinedEntry]
    switch SettingsSearchCatalog.join(vocabulary) {
    case .success(let entries): joined = entries
    case .failure(let error): throw ExportError(description: "join: \(error)")
    }
    let blocks = Dictionary(uniqueKeysWithValues: joined.map { ($0.entry.id, $0.blocks) })

    var metadata: [[String: Any]] = []
    var nodes: [[String: Any]] = []
    for mapNode in SettingsMap.nodes {
      let object = try node(mapNode)
      metadata.append(object)
      var exported = object
      if let entryBlocks = blocks[mapNode.id.rawValue] {
        exported["vocabulary"] = Dictionary(
          uniqueKeysWithValues: entryBlocks.map { ($0.key, block($0.value)) })
      }
      nodes.append(exported)
    }
    guard let vocabularyURL = SettingsSearchVocabulary.resourceURL() else {
      throw ExportError(description: "vocabulary resource missing from the bundle")
    }
    let document: [String: Any] = [
      "schema": "settings-map-export",
      "version": formatVersion,
      "interfaceLanguages": interfaceLanguages,
      "languages": SettingsSearchVocabulary.declaredLanguages,
      "sources": [
        "map": mapFile, "titleResolver": resolverFile, "uiCatalog": uiCatalogFile,
        "vocabulary": vocabularyFile,
      ],
      "fingerprints": [
        "mapSHA256": sha256(try serialize(metadata, pretty: false)),
        "uiCatalogSHA256": sha256(try Data(contentsOf: RepoRoot.sourceURL(uiCatalogFile))),
        "vocabularySHA256": sha256(try Data(contentsOf: vocabularyURL)),
        "vocabularyCanonicalization": SettingsSearchVocabulary.canonicalization,
      ],
      "counts": [
        "nodes": nodes.count, "searchable": joined.count,
        "vocabularyBlocks": joined.reduce(0) { $0 + $1.blocks.count },
      ],
      "languageData": SettingsSearchVocabulary.declaredLanguages.map { code in
        [
          "language": code, "stop": vocabulary.languageData[code]?.stop ?? [],
          "markers": vocabulary.languageData[code]?.markers ?? [],
        ] as [String: Any]
      },
      "nodes": nodes,
    ]
    return try serialize(document)
  }

  /// One searchable place and its ancestors, without vocabulary (a new place has none yet).
  static func placeDocument(_ id: String) throws -> Data {
    guard let entry = SettingsSearchCatalog.entries.first(where: { $0.id == id }) else {
      let structural = SettingsMap.nodes.contains { $0.id.rawValue == id }
      throw ExportError(
        description: structural
          ? "\(id) is a structural Settings Map node; it has no vocabulary"
          : "\(id) is not a searchable Settings Map id (unknown, renamed or exempt)")
    }
    let ancestors = try Self.ancestors(of: entry.node).filter { $0 != .windowSettings }
      .map { try node(SettingsMap.node($0)) }
    return try serialize([
      "schema": "settings-map-export", "version": formatVersion,
      "entries": [try node(entry.node)], "ancestors": ancestors,
    ])
  }

  @Test("export the Settings Map")
  func exportMetadata() throws {
    let environment = ProcessInfo.processInfo.environment
    let output = URL(fileURLWithPath: try #require(environment["EW_SETTINGS_MAP_EXPORT"]))
    let data: Data
    do {
      data =
        if let id = environment["EW_SETTINGS_MAP_EXPORT_ID"] {
          try Self.placeDocument(id)
        } else {
          try Self.fullDocument()
        }
    } catch let error as ExportError {
      Issue.record("\(error.description)")
      return
    }
    let staging = output.appendingPathExtension("partial")
    try data.write(to: staging)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.moveItem(at: staging, to: output)
  }

}
