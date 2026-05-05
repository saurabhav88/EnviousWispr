import EnviousWisprCore
import Foundation
import Testing

/// Phase 3a (#631) — pins schema migration of `frequencyUsed` and `lastUsed`.
/// Bible §9.2.
@Suite("CustomWord schema migration — Phase 3a frequency/lastUsed")
struct CustomWordSchemaTests {

  @Test("Decode pre-Phase-3a JSON (no frequencyUsed/lastUsed) defaults to 0/nil")
  func decodeOldFormatYieldsDefaults() throws {
    let json = """
      {
        "id": "550e8400-e29b-41d4-a716-446655440000",
        "canonical": "EnviousWispr",
        "aliases": ["envious wispr"],
        "category": "brand",
        "priority": 0,
        "forceReplace": false,
        "caseSensitive": false
      }
      """.data(using: .utf8)!

    let word = try JSONDecoder().decode(CustomWord.self, from: json)
    #expect(word.frequencyUsed == 0, "Missing frequencyUsed defaults to 0")
    #expect(word.lastUsed == nil, "Missing lastUsed defaults to nil")
  }

  @Test("Encode writes frequencyUsed always; lastUsed only when present")
  func encodeWritesNewFields() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let word = CustomWord(
      canonical: "Snowflake",
      frequencyUsed: 42,
      lastUsed: date
    )
    let data = try JSONEncoder().encode(word)
    let serialized = String(data: data, encoding: .utf8) ?? ""

    #expect(serialized.contains("\"frequencyUsed\":42"))
    #expect(serialized.contains("\"lastUsed\""))
  }

  @Test("Encode omits lastUsed when nil")
  func encodeOmitsNilLastUsed() throws {
    let word = CustomWord(canonical: "Test", frequencyUsed: 0, lastUsed: nil)
    let data = try JSONEncoder().encode(word)
    let serialized = String(data: data, encoding: .utf8) ?? ""

    #expect(!serialized.contains("\"lastUsed\""), "lastUsed nil → key omitted")
    #expect(serialized.contains("\"frequencyUsed\":0"), "frequencyUsed always written")
  }

  @Test("Round-trip: encode then decode preserves all persisted fields")
  func roundTripPreservesPersistedFields() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = CustomWord(
      id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
      canonical: "Kubernetes",
      aliases: ["k8s", "kuber netties"],
      category: .brand,
      priority: 7,
      forceReplace: true,
      caseSensitive: true,
      frequencyUsed: 99,
      lastUsed: date
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CustomWord.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.canonical == original.canonical)
    #expect(decoded.aliases == original.aliases)
    #expect(decoded.category == original.category)
    #expect(decoded.priority == original.priority)
    #expect(decoded.forceReplace == original.forceReplace)
    #expect(decoded.caseSensitive == original.caseSensitive)
    #expect(decoded.frequencyUsed == original.frequencyUsed)
    #expect(decoded.lastUsed == original.lastUsed)
    // Source flips to .user across persist boundary (Phase 0 §3.6, bible §19 Q12 documented scope reduction)
    #expect(decoded.source == .user)
  }

  @Test("Default init has frequencyUsed=0 and lastUsed=nil")
  func defaultInitDefaults() {
    let word = CustomWord(canonical: "Default")
    #expect(word.frequencyUsed == 0)
    #expect(word.lastUsed == nil)
  }
}
