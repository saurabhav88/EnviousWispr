import EnviousWisprCore
import Foundation
import Testing

/// Phase 0 (#640) — pins on-disk schema invariance after the new `source`
/// field was added to `CustomWord`. Bible §6.5: persisted JSON shape must be
/// byte-equivalent to the pre-Phase-0 schema. `source` is excluded from
/// `CodingKeys`; anything decoded from disk gets `source: .user`.
@Suite("CustomWord source-field migration — Phase 0 schema invariance")
struct CustomWordSourceMigrationTests {

  @Test("Decode from old-format JSON (no source key) yields source: .user")
  func decodeOldFormatYieldsUserSource() throws {
    let json = """
      {
        "id": "550e8400-e29b-41d4-a716-446655440000",
        "canonical": "EnviousWispr",
        "aliases": ["envious wispr", "envious whisper"],
        "category": "brand",
        "priority": 5,
        "forceReplace": false,
        "caseSensitive": false
      }
      """.data(using: .utf8)!

    let word = try JSONDecoder().decode(CustomWord.self, from: json)
    #expect(word.canonical == "EnviousWispr")
    #expect(word.source == .user, "Decoded entries default to .user (no source on disk)")
  }

  @Test("Encode does NOT write source field — schema unchanged")
  func encodeOmitsSourceField() throws {
    let word = CustomWord(
      id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
      canonical: "Snowflake",
      aliases: ["snow flake"],
      category: .brand,
      priority: 0,
      forceReplace: false,
      caseSensitive: false,
      source: .observedAX  // runtime-only; should NOT survive encode
    )
    let data = try JSONEncoder().encode(word)
    let serialized = String(data: data, encoding: .utf8) ?? ""

    #expect(!serialized.contains("\"source\""), "Encoded JSON must not include 'source' key")
    #expect(serialized.contains("\"canonical\":\"Snowflake\""))
  }

  @Test("Round-trip equality at persisted-field level — source flips to .user")
  func roundTripEqualityAtPersistedLevel() throws {
    let original = CustomWord(canonical: "Kubeshark", source: .observedAX)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CustomWord.self, from: data)

    // All persisted fields equal:
    #expect(decoded.id == original.id)
    #expect(decoded.canonical == original.canonical)
    #expect(decoded.aliases == original.aliases)
    #expect(decoded.category == original.category)
    #expect(decoded.priority == original.priority)
    #expect(decoded.forceReplace == original.forceReplace)
    #expect(decoded.caseSensitive == original.caseSensitive)
    // Source intentionally flips to .user across the persist boundary
    // (bible §19 Q12 documented scope reduction):
    #expect(decoded.source == .user)
  }

  @Test("Default init param defaults source to .user")
  func defaultInitSourceIsUser() {
    let word = CustomWord(canonical: "Test")
    #expect(word.source == .user)
  }

  @Test("Explicit source param is honored at construction")
  func explicitSourceHonored() {
    let b = CustomWord(canonical: "Builtin", source: .builtin)
    let o = CustomWord(canonical: "Observed", source: .observedAX)
    #expect(b.source == .builtin)
    #expect(o.source == .observedAX)
  }
}
