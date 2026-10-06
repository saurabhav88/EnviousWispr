import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A: the search catalog is the Settings Map's searchable nodes and nothing else, and
/// its join with the vocabulary fails loudly on any gap. Expectations come from the inventory
/// fixture (`Tests/Fixtures/settings-map/inventory.json`), not from the projection under test.
@Suite("Settings search catalog (#3482)", .tags(.driftGuard))
struct SettingsSearchCatalogTests {
  @Test("the catalog is exactly the inventory's mapped ids, in map order, with no structure")
  func exactProjection() throws {
    let inventory = try SettingsMapTests.inventory()
    let mapped = inventory.items.filter { $0.disposition == "mapped" }.map(\.id)
    #expect(mapped.count == 246)
    #expect(SettingsSearchCatalog.entries.count == 246)
    #expect(Set(SettingsSearchCatalog.entries.map(\.id)) == Set(mapped))
    #expect(SettingsSearchCatalog.searchableIDs == Set(mapped))
    let structural = Set(inventory.structural.map(\.id))
    #expect(Set(SettingsSearchCatalog.entries.map(\.id)).isDisjoint(with: structural))
    let mapOrder = SettingsMap.nodes.map(\.id.rawValue).filter(Set(mapped).contains)
    #expect(SettingsSearchCatalog.entries.map(\.id) == mapOrder)
  }

  @Test("each entry keeps its kind, parent, target and fallbacks, and is the map's own node")
  func preservesMetadata() throws {
    let items = Dictionary(
      uniqueKeysWithValues: try SettingsMapTests.inventory().items.map { ($0.id, $0) })
    for entry in SettingsSearchCatalog.entries {
      let item = try #require(items[entry.id])
      #expect(entry.kind.rawValue == item.kind, "\(entry.id)")
      #expect(entry.node.parent?.rawValue == item.parent, "\(entry.id)")
      #expect(entry.node.target?.rawValue == item.target, "\(entry.id)")
      #expect(entry.node.fallbacks.map(\.rawValue) == (item.fallbacks ?? []), "\(entry.id)")
      #expect(
        entry.node.destination == (try SettingsMapTests.destination(item.destination)),
        "\(entry.id)")
      let node = SettingsMap.node(entry.node.id)
      #expect(
        node.item == entry.kind && node.dictionaryTab == entry.node.dictionaryTab, "\(entry.id)")
    }
  }

  @Test("the shipped vocabulary joins every catalog entry in all 32 languages")
  func joinsTheShippedVocabulary() throws {
    let vocabulary = try SettingsSearchVocabularyTests.shipped()
    let joined = try SettingsSearchCatalog.join(vocabulary).get()
    #expect(joined.map(\.entry.id) == SettingsSearchCatalog.entries.map(\.id))
    #expect(joined.allSatisfy { $0.blocks.count == 32 })
  }

  @Test("the join names every gap: a missing entry, an orphan entry, a missing language")
  func joinFailsOnGaps() throws {
    let vocabulary = try SettingsSearchVocabularyTests.shipped()
    var entries = vocabulary.entries
    let missing = "recordingChime.dustMote"
    let shortened = "dictation.tab.engine"
    let removed = entries.removeValue(forKey: missing)
    let moved = try #require(removed)
    entries["no.such.place"] = moved
    entries[shortened]?["zh"] = nil
    let broken = SettingsSearchVocabulary(
      version: vocabulary.version, languageData: vocabulary.languageData, entries: entries,
      byteCount: vocabulary.byteCount)
    guard case .failure(.invalid(let problems)) = SettingsSearchCatalog.join(broken) else {
      Issue.record("the join accepted a broken vocabulary")
      return
    }
    #expect(problems.count == 3, "\(problems)")
    #expect(
      problems.contains { $0.hasPrefix("no.such.place: vocabulary entry with no searchable") })
    #expect(problems.contains { $0.hasPrefix("\(missing): has no vocabulary") })
    #expect(problems.contains { $0.hasPrefix("\(shortened): languages") })
  }
}
