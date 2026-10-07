import CryptoKit
import Foundation

/// The one owner of WHICH texts the meaning model embeds for each searchable place (#3482 plan
/// §3.7a, chunk 3). It is the bench's `MeaningIndex.texts` recipe (`titleDescription`, with every
/// language block's phrases and words) applied to the committed `reference/settings-map.json`,
/// which `SettingsMapExportSyncTests` keeps equal to the compiled map. The Python tool
/// (`scripts/settings-map/meaning-assets.py place-vectors`) only embeds the texts this writes;
/// `SettingsSearchPlaceVectorsTests` recomputes them and fails when the shipped vectors were
/// built from different texts.
///
/// Per searchable place:
/// - `main`, one per interface language (en, de): the place's name, then ". " and its description
///   when it has one. A place named at runtime has no fixed name, so its text is the description,
///   or nothing when it has neither.
/// - per vocabulary language: the block's translated title when it has one (languages other than
///   en and de), each phrase, and all words joined by ", ".
///
/// Rows are unique texts in first-seen order (entries in map order; per entry main en, main de,
/// then languages by code), so a text shared by several places is embedded once.
struct SettingsSearchPlaceTexts: Equatable {
  struct Entry: Equatable {
    /// Interface language code -> row.
    let main: [String: Int]
    /// Vocabulary language code -> rows.
    let languages: [String: [Int]]
  }

  /// Bump when the text recipe changes; it is hashed into `textsSHA256`.
  static let recipeVersion = 1
  static let interfaceLanguages = ["en", "de"]

  let rows: [String]
  let entryOrder: [String]
  let entries: [String: Entry]

  enum BuildError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
      switch self {
      case .invalid(let reason): "settings-map export: \(reason)"
      }
    }
  }

  init(exportData: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: exportData) as? [String: Any],
      let nodes = root["nodes"] as? [[String: Any]]
    else { throw BuildError.invalid("no nodes") }
    var rows: [String] = []
    var rowIndex: [String: Int] = [:]
    func row(_ text: String) -> Int {
      if let existing = rowIndex[text] { return existing }
      rows.append(text)
      rowIndex[text] = rows.count - 1
      return rows.count - 1
    }
    var order: [String] = []
    var entries: [String: Entry] = [:]
    for node in nodes where node["searchable"] as? Bool == true {
      guard let id = node["id"] as? String, let title = node["title"] as? [String: Any]
      else { throw BuildError.invalid("a searchable node has no id or title") }
      var main: [String: Int] = [:]
      for language in Self.interfaceLanguages {
        if let text = Self.mainText(
          title: Self.resolved(title, language), description: node["description"], language)
        {
          main[language] = row(text)
        }
      }
      let vocabulary = node["vocabulary"] as? [String: [String: Any]] ?? [:]
      var languages: [String: [Int]] = [:]
      for code in vocabulary.keys.sorted() {
        let block = vocabulary[code] ?? [:]
        var texts: [String] = []
        if let blockTitle = (block["title"] as? String).flatMap(Self.nonblank) {
          texts.append(blockTitle)
        }
        texts += (block["phrases"] as? [String] ?? []).compactMap(Self.nonblank)
        let words = (block["words"] as? [String] ?? []).compactMap(Self.nonblank)
        if words.isEmpty == false { texts.append(words.joined(separator: ", ")) }
        if texts.isEmpty == false { languages[code] = texts.map(row) }
      }
      order.append(id)
      entries[id] = Entry(main: main, languages: languages)
    }
    guard order.isEmpty == false else { throw BuildError.invalid("no searchable nodes") }
    self.rows = rows
    self.entryOrder = order
    self.entries = entries
  }

  private static func nonblank(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A title or description object's text in one language: a resource carries both languages, a
  /// verbatim product name is the same in every language, anything else (runtime) has none.
  private static func resolved(_ object: [String: Any], _ language: String) -> String? {
    switch object["source"] as? String {
    case "resource": (object[language] as? String).flatMap(nonblank)
    case "verbatim": (object["text"] as? String).flatMap(nonblank)
    default: nil
    }
  }

  private static func mainText(title: String?, description: Any?, _ language: String) -> String? {
    let described = (description as? [String: Any]).flatMap { resolved($0, language) }
    switch (title, described) {
    case (nil, nil): return nil
    case (nil, let description?): return description
    case (let title?, nil): return title
    case (let title?, let description?): return "\(title). \(description)"
    }
  }

  // MARK: - Identity

  /// SHA-256 of the rows (length-prefixed, so no text can imitate a boundary), then each place's
  /// row numbers. Recorded in the shipped index; equal only when rows AND their owners match.
  var textsSHA256: String {
    var hasher = SHA256()
    func add(_ text: String) {
      hasher.update(data: Data("\(text.utf8.count):\(text)\n".utf8))
    }
    add("recipe-\(Self.recipeVersion)")
    for text in rows { add(text) }
    add("--entries--")
    for id in entryOrder {
      guard let entry = entries[id] else { continue }
      add(id)
      for language in Self.interfaceLanguages {
        add("main.\(language)=\(entry.main[language].map(String.init) ?? "-")")
      }
      for code in entry.languages.keys.sorted() {
        add("\(code)=\(entry.languages[code, default: []].map(String.init).joined(separator: ","))")
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// What `meaning-assets.py place-vectors` reads.
  func toolJSON() throws -> Data {
    var entriesJSON: [String: Any] = [:]
    for (id, entry) in entries {
      entriesJSON[id] = ["main": entry.main, "languages": entry.languages]
    }
    return try JSONSerialization.data(
      withJSONObject: [
        "schema": "settings-search-place-texts", "recipeVersion": Self.recipeVersion,
        "textsSHA256": textsSHA256, "rows": rows, "entryOrder": entryOrder,
        "entries": entriesJSON,
      ] as [String: Any], options: [.sortedKeys])
  }
}
