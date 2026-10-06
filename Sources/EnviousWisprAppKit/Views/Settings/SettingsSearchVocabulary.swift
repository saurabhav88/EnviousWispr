import CryptoKit
import Foundation

/// The Settings search vocabulary (#3482 plan §3.2a, §3.7a): for every searchable Settings Map
/// id, per declared language, the words and everyday phrases people type for that place, plus
/// each language's filler (stop) list and the intent and negation words that list must never
/// hold. Search metadata only: the interface's own text stays in the String Catalog, and English
/// and German titles come from the map's copy owners, never from this file.
///
/// `validate(_:expectedIDs:)` is the one schema authority. The production loader, the required
/// tests and vocabulary adoption all run it; nothing else decides what a valid file is.
struct SettingsSearchVocabulary: Sendable, Equatable {
  struct Block: Sendable, Equatable {
    /// The place's name in this language. Nil for the interface languages, whose titles are
    /// the map's own copy.
    let title: String?
    /// Short terms; may be empty when the title and phrases carry the place.
    let words: [String]
    let phrases: [String]
    /// Why this block has no phrases, recorded by a review. Nil whenever phrases exist.
    let phraseExemption: String?
  }

  struct LanguageData: Sendable, Equatable {
    /// Filler words search may ignore in this language.
    let stop: [String]
    /// Intent and negation words that change what a search means ("not", "off", "without");
    /// never filler.
    let markers: [String]
  }

  let version: Int
  let languageData: [String: LanguageData]
  /// Searchable map id, then language code.
  let entries: [String: [String: Block]]
  /// The resource's size in bytes, as measured on the data validated.
  let byteCount: Int

  static let schema = "settings-search-vocabulary"
  static let schemaVersion = 1
  /// Plan §3.2a: shipped, uncompressed UTF-8.
  static let maximumBytes = 3_000_000
  /// The declared search languages (plan §3.7a). Not interface languages: the app's own text
  /// ships in English and German only.
  static let declaredLanguages: [String] = [
    "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hi", "hr", "hu", "it", "ja",
    "ko", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi", "zh",
  ]
  /// Languages whose titles come from the interface's copy owners.
  static let interfaceLanguages: Set<String> = ["en", "de"]
  static let resourceName = "SettingsSearchVocabulary"

  /// What the draft command is, for messages about a missing or renamed id.
  static func draftCommand(for id: String) -> String {
    "scripts/settings-map/draft-vocabulary.sh \(id)"
  }
}

enum SettingsSearchVocabularyError: Error, Equatable, CustomStringConvertible {
  /// The resource is not in the bundle.
  case missingResource
  /// The resource could not be read.
  case unreadable(String)
  /// The resource exceeds the shipped size budget.
  case tooLarge(bytes: Int)
  /// Every problem the validator found, each naming where it is.
  case invalid([String])

  var description: String {
    switch self {
    case .missingResource: "SettingsSearchVocabulary.json is not in the AppKit bundle"
    case .unreadable(let reason): "SettingsSearchVocabulary.json could not be read: \(reason)"
    case .tooLarge(let bytes):
      "SettingsSearchVocabulary.json is \(bytes) bytes; the limit is \(SettingsSearchVocabulary.maximumBytes)"
    case .invalid(let problems): problems.joined(separator: "\n")
    }
  }
}

extension SettingsSearchVocabulary {
  /// Loads and validates the bundled resource. Never an empty vocabulary on failure: a caller
  /// gets the typed reason. PR A exposes this to tests and tooling only; the app does not load
  /// it yet (PR B owns once-per-window loading).
  static func load(
    expectedIDs: Set<String> = SettingsSearchCatalog.searchableIDs, bundle: Bundle = .module
  ) -> Result<SettingsSearchVocabulary, SettingsSearchVocabularyError> {
    guard let url = resourceURL(bundle: bundle) else { return .failure(.missingResource) }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return .failure(.unreadable(String(describing: error)))
    }
    return validate(data, expectedIDs: expectedIDs)
  }

  /// Where the bundled resource is: AppKit's own bundle, never the app's main bundle.
  static func resourceURL(bundle: Bundle = .module) -> URL? {
    bundle.url(forResource: resourceName, withExtension: "json")
  }

  /// The schema authority. Checks size, then structure (refusing duplicate keys, which a
  /// dictionary decode would silently resolve last-wins), then every field.
  static func validate(_ data: Data, expectedIDs: Set<String>)
    -> Result<SettingsSearchVocabulary, SettingsSearchVocabularyError>
  {
    guard data.count <= maximumBytes else { return .failure(.tooLarge(bytes: data.count)) }
    // The duplicate-key scan reads UTF-8; JSONSerialization would also accept UTF-16 or UTF-32,
    // whose repeated keys the scan cannot see.
    guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
      return .failure(.invalid(["resource: expected UTF-8 JSON without raw NUL bytes"]))
    }
    if let duplicate = StrictJSONKeys.firstDuplicateKey(in: data) {
      return .failure(.invalid(["duplicate key \"\(duplicate)\" in one JSON object"]))
    }
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: data)
    } catch {
      return .failure(.invalid(["not JSON: \(error.localizedDescription)"]))
    }
    var problems = Problems()
    let vocabulary = parse(root, expectedIDs: expectedIDs, byteCount: data.count, into: &problems)
    if let vocabulary, problems.list.isEmpty { return .success(vocabulary) }
    return .failure(.invalid(problems.list))
  }

  struct Problems {
    var list: [String] = []
    mutating func add(_ problem: String) { list.append(problem) }
  }

  private static func parse(
    _ root: Any, expectedIDs: Set<String>, byteCount: Int, into problems: inout Problems
  ) -> SettingsSearchVocabulary? {
    guard let object = root as? [String: Any] else {
      problems.add("root: not an object")
      return nil
    }
    checkKeys(
      object, allowed: ["schema", "version", "languages", "languageData", "entries"], at: "root",
      &problems)
    if object["schema"] as? String != schema {
      problems.add("schema: expected \"\(schema)\"")
    }
    let version = integer(object["version"])
    if version != schemaVersion {
      problems.add("version: expected \(schemaVersion)")
    }
    let languages = strings(object["languages"], at: "languages", &problems) ?? []
    if languages != declaredLanguages {
      problems.add(
        "languages: expected exactly \(declaredLanguages.joined(separator: ",")) in that order, got \(languages.joined(separator: ","))"
      )
    }
    let declared = Set(declaredLanguages)

    var languageData: [String: LanguageData] = [:]
    if let list = object["languageData"] as? [Any] {
      for (index, item) in list.enumerated() {
        let at = "languageData[\(index)]"
        guard let item = item as? [String: Any] else {
          problems.add("\(at): not an object")
          continue
        }
        checkKeys(item, allowed: ["language", "stop", "markers"], at: at, &problems)
        guard let code = item["language"] as? String, declared.contains(code) else {
          problems.add("\(at).language: not a declared language")
          continue
        }
        guard languageData[code] == nil else {
          problems.add("\(at): language \(code) appears twice")
          continue
        }
        let stop = tokens(item["stop"], at: "\(at)(\(code)).stop", &problems)
        let markers = tokens(item["markers"], at: "\(at)(\(code)).markers", &problems)
        if markers.isEmpty { problems.add("\(code).markers: empty") }
        if stop.isEmpty { problems.add("\(code).stop: empty") }
        let collisions = Set(stop.map(fold)).intersection(markers.map(fold))
        if !collisions.isEmpty {
          problems.add("\(code): stop list holds protected markers \(collisions.sorted())")
        }
        languageData[code] = LanguageData(stop: stop, markers: markers)
      }
    } else {
      problems.add("languageData: not an array")
    }
    let missingData = declared.subtracting(languageData.keys)
    if !missingData.isEmpty {
      problems.add("languageData: missing \(missingData.sorted())")
    }

    var entries: [String: [String: Block]] = [:]
    if let list = object["entries"] as? [Any] {
      for (index, item) in list.enumerated() {
        let at = "entries[\(index)]"
        guard let item = item as? [String: Any] else {
          problems.add("\(at): not an object")
          continue
        }
        checkKeys(item, allowed: ["id", "blocks"], at: at, &problems)
        guard let id = item["id"] as? String, !id.isEmpty else {
          problems.add("\(at).id: missing")
          continue
        }
        guard entries[id] == nil else {
          problems.add("\(id): appears twice")
          continue
        }
        entries[id] = blocks(item["blocks"], id: id, declared: declared, &problems)
      }
    } else {
      problems.add("entries: not an array")
    }
    // A filler list must never hide a place's own name: a one-word title or word that is also a
    // stop word in its language could never be searched for.
    for code in languageData.keys.sorted() {
      let stop = Set((languageData[code]?.stop ?? []).map(fold))
      for id in entries.keys.sorted() {
        guard let block = entries[id]?[code] else { continue }
        let single = ([block.title].compactMap { $0 } + block.words).filter {
          !$0.contains(where: \.isWhitespace)
        }
        for term in single where stop.contains(fold(term)) {
          problems.add("\(id)/\(code): \"\(term)\" is also in the \(code) stop list")
        }
      }
    }
    for id in Set(entries.keys).subtracting(expectedIDs).sorted() {
      problems.add("\(id): not a searchable Settings Map id (remove it, or it was renamed)")
    }
    for id in expectedIDs.subtracting(entries.keys).sorted() {
      problems.add(
        "\(id): has no vocabulary; run \(draftCommand(for: id)), review the draft, then adopt it")
    }
    return SettingsSearchVocabulary(
      version: version ?? 0, languageData: languageData, entries: entries, byteCount: byteCount)
  }

  private static func blocks(
    _ value: Any?, id: String, declared: Set<String>, _ problems: inout Problems
  ) -> [String: Block] {
    guard let list = value as? [Any] else {
      problems.add("\(id).blocks: not an array")
      return [:]
    }
    var result: [String: Block] = [:]
    for (index, item) in list.enumerated() {
      let at = "\(id).blocks[\(index)]"
      guard let item = item as? [String: Any] else {
        problems.add("\(at): not an object")
        continue
      }
      checkKeys(
        item, allowed: ["language", "title", "words", "phrases", "phraseExemption"], at: at,
        &problems)
      guard let code = item["language"] as? String, declared.contains(code) else {
        problems.add("\(at).language: not a declared language")
        continue
      }
      let where_ = "\(id)/\(code)"
      guard result[code] == nil else {
        problems.add("\(where_): language appears twice")
        continue
      }
      var title: String?
      if interfaceLanguages.contains(code) {
        if item["title"] != nil {
          problems.add(
            "\(where_).title: \(code) titles come from the interface copy, not this file")
        }
      } else {
        title = nonblank(item["title"])
        if title == nil { problems.add("\(where_).title: missing or blank") }
      }
      let words = strings(item["words"], at: "\(where_).words", &problems) ?? []
      let phrases = strings(item["phrases"], at: "\(where_).phrases", &problems) ?? []
      var exemption: String?
      if item["phraseExemption"] != nil {
        exemption = nonblank(item["phraseExemption"])
        if exemption == nil { problems.add("\(where_).phraseExemption: blank") }
        if !phrases.isEmpty {
          problems.add("\(where_).phraseExemption: set although phrases exist")
        }
      }
      if phrases.isEmpty && exemption == nil {
        problems.add("\(where_).phrases: empty with no reviewed exemption")
      }
      result[code] = Block(title: title, words: words, phrases: phrases, phraseExemption: exemption)
    }
    let missing = declared.subtracting(result.keys)
    if !missing.isEmpty {
      problems.add("\(id): missing languages \(missing.sorted()); run \(draftCommand(for: id))")
    }
    return result
  }

  // MARK: - Field checks

  private static func checkKeys(
    _ object: [String: Any], allowed: Set<String>, at: String, _ problems: inout Problems
  ) {
    for key in Set(object.keys).subtracting(allowed).sorted() {
      problems.add("\(at): unknown field \"\(key)\"")
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return Int(exactly: number.doubleValue)
  }

  private static func nonblank(_ value: Any?) -> String? {
    guard let text = value as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return text
  }

  /// An array of nonblank strings with no repeats. Nil (and a problem) for any other shape.
  private static func strings(_ value: Any?, at: String, _ problems: inout Problems) -> [String]? {
    guard let list = value as? [Any] else {
      problems.add("\(at): not an array of strings")
      return nil
    }
    var result: [String] = []
    for (index, element) in list.enumerated() {
      guard let text = nonblank(element) else {
        problems.add("\(at)[\(index)]: not a nonblank string")
        continue
      }
      if result.contains(text) { problems.add("\(at): \"\(text)\" appears twice") }
      result.append(text)
    }
    return result
  }

  /// Stop words and markers: single tokens. They keep the form the reviewed lists use; search
  /// compares them after folding (see `fold`), which is also how collisions are found here.
  private static func tokens(_ value: Any?, at: String, _ problems: inout Problems) -> [String] {
    let list = strings(value, at: at, &problems) ?? []
    for token in list where token.contains(where: \.isWhitespace) {
      problems.add("\(at): \"\(token)\" is not one word")
    }
    return list
  }

  /// How stop words and markers are compared here: case and diacritics removed, ß as ss. The
  /// Phase 0 Python builder folded with NFKD plus mark removal, which agrees for Latin, Greek and
  /// Cyrillic but not for every script (Hangul decomposes, kana loses its voicing marks); PR B's
  /// matcher owns the runtime folding and must test parity per script (plan §3.7a).
  static func fold(_ text: String) -> String {
    text.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "ss")
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
  }
}

// MARK: - Review binding

extension SettingsSearchVocabulary {
  /// The canonical encoding's version, recorded in review receipts.
  static let canonicalization = "length-prefixed-v1"

  /// A language's reviewed content in one canonical text, so a review receipt can name exactly
  /// what was reviewed: its stop list, markers and every entry's block, entries in id order.
  /// Every field is written as its UTF-8 byte count, a colon and the field, and every list
  /// starts with its count, so no two different contents share a text (a separator or newline
  /// inside a phrase cannot imitate a field boundary). The adoption tooling computes the same
  /// text; a receipt whose hash differs is stale.
  func canonicalText(language code: String) -> String {
    var fields = ["language", code]
    if let data = languageData[code] {
      fields += ["stop", String(data.stop.count)] + data.stop
      fields += ["markers", String(data.markers.count)] + data.markers
    }
    for id in entries.keys.sorted() {
      guard let block = entries[id]?[code] else { continue }
      fields += [
        "entry", id, block.title == nil ? "absent" : "present", block.title ?? "",
        "words", String(block.words.count),
      ] + block.words
      fields += ["phrases", String(block.phrases.count)] + block.phrases
      fields += [
        "phraseExemption", block.phraseExemption == nil ? "absent" : "present",
        block.phraseExemption ?? "",
      ]
    }
    return fields.map { "\($0.utf8.count):\($0)" }.joined()
  }

  func contentHash(language code: String) -> String {
    SHA256.hash(data: Data(canonicalText(language: code).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

/// Finds a key repeated inside one JSON object, which `JSONSerialization` would resolve
/// silently (last wins). A small structural scan over the UTF-8 text; it does not interpret
/// values, so `JSONSerialization` still decides whether the document is JSON at all.
enum StrictJSONKeys {
  static func firstDuplicateKey(in data: Data) -> String? {
    let bytes = [UInt8](data)
    var index = 0
    // One set of keys per open object; nil marks an open array.
    var stack: [Set<String>?] = []
    var expectingKey = false

    func readString() -> String? {
      // `index` sits on the opening quote.
      var buffer: [UInt8] = []
      index += 1
      while index < bytes.count {
        let byte = bytes[index]
        if byte == UInt8(ascii: "\\") {
          guard index + 1 < bytes.count else { return nil }
          buffer.append(byte)
          buffer.append(bytes[index + 1])
          index += 2
          continue
        }
        if byte == UInt8(ascii: "\"") {
          index += 1
          guard buffer.contains(UInt8(ascii: "\\")) else {
            return String(decoding: buffer, as: UTF8.self)
          }
          // Decode escapes so "a" and "a" count as the same key.
          let quoted = Data([UInt8(ascii: "\"")] + buffer + [UInt8(ascii: "\"")])
          return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed))
            as? String
        }
        buffer.append(byte)
        index += 1
      }
      return nil
    }

    while index < bytes.count {
      let byte = bytes[index]
      switch byte {
      case UInt8(ascii: "{"):
        stack.append([])
        expectingKey = true
        index += 1
      case UInt8(ascii: "["):
        stack.append(nil)
        expectingKey = false
        index += 1
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        _ = stack.popLast()
        expectingKey = false
        index += 1
      case UInt8(ascii: ","):
        expectingKey = (stack.last ?? nil) != nil
        index += 1
      case UInt8(ascii: "\""):
        guard let text = readString() else { return nil }
        if expectingKey, var keys = stack.last ?? nil {
          if keys.contains(text) { return text }
          keys.insert(text)
          stack[stack.count - 1] = keys
          expectingKey = false
        }
      default:
        index += 1
      }
    }
    return nil
  }
}
