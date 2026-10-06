import Foundation

/// What Settings search can find (#3482 plan §3.6): the Settings Map's searchable nodes, in map
/// order, and nothing else. A projection, never a second list: every field is the map node's own,
/// so a place's kind, parent, title and description owners, destination, Dictionary tab, target
/// and fallbacks cannot drift from the map. Metadata only; it never resolves live user state.
enum SettingsSearchCatalog {
  /// One searchable place.
  struct Entry: Sendable {
    let node: SettingsMapNode
    /// The node's own item kind; only nodes that have one are projected.
    let kind: SettingsMapItemKind

    var id: String { node.id.rawValue }
  }

  /// A searchable place with its vocabulary blocks, one per declared language.
  struct JoinedEntry: Sendable {
    let entry: Entry
    let blocks: [String: SettingsSearchVocabulary.Block]
  }

  static let entries: [Entry] = SettingsMap.nodes.compactMap { node in
    node.item.map { Entry(node: node, kind: $0) }
  }

  /// The vocabulary's join keys: the stable raw map ids of the searchable places.
  static let searchableIDs: Set<String> = Set(entries.map(\.id))

  /// Joins a validated vocabulary to the catalog. Fails, naming every gap, when an id is on one
  /// side only or an entry lacks a declared language; it never drops or invents an entry.
  static func join(_ vocabulary: SettingsSearchVocabulary)
    -> Result<[JoinedEntry], SettingsSearchVocabularyError>
  {
    var problems: [String] = []
    let declared = Set(SettingsSearchVocabulary.declaredLanguages)
    for id in Set(vocabulary.entries.keys).subtracting(searchableIDs).sorted() {
      problems.append("\(id): vocabulary entry with no searchable Settings Map node")
    }
    var joined: [JoinedEntry] = []
    for entry in entries {
      guard let blocks = vocabulary.entries[entry.id] else {
        problems.append(
          "\(entry.id): has no vocabulary; run \(SettingsSearchVocabulary.draftCommand(for: entry.id))"
        )
        continue
      }
      if Set(blocks.keys) != declared {
        problems.append(
          "\(entry.id): languages \(blocks.keys.sorted()) are not the declared set")
        continue
      }
      joined.append(JoinedEntry(entry: entry, blocks: blocks))
    }
    return problems.isEmpty ? .success(joined) : .failure(.invalid(problems))
  }
}
