import Foundation
import Testing

@testable import EnviousWisprCore

@Suite("CustomWord")
struct CustomWordTests {

  // MARK: - Codable round-trip

  @Test("encode then decode preserves all properties")
  func roundTrip() throws {
    let word = CustomWord(
      canonical: "ChatGPT",
      aliases: ["chatgpt", "chat gpt"],
      category: .brand,
      priority: 5,
      forceReplace: true,
      caseSensitive: true
    )

    let data = try JSONEncoder().encode(word)
    let decoded = try JSONDecoder().decode(CustomWord.self, from: data)

    #expect(decoded.id == word.id)
    #expect(decoded.canonical == "ChatGPT")
    #expect(decoded.aliases == ["chatgpt", "chat gpt"])
    #expect(decoded.category == .brand)
    #expect(decoded.priority == 5)
    #expect(decoded.forceReplace == true)
    #expect(decoded.caseSensitive == true)
  }

  @Test("decode from known JSON payload")
  func decodeStaticJSON() throws {
    let json = """
      {
          "id": "550E8400-E29B-41D4-A716-446655440000",
          "canonical": "Kubernetes",
          "aliases": ["k8s"],
          "category": "domain",
          "priority": 0,
          "forceReplace": false,
          "caseSensitive": false
      }
      """
    let data = Data(json.utf8)
    let word = try JSONDecoder().decode(CustomWord.self, from: data)

    #expect(word.canonical == "Kubernetes")
    #expect(word.aliases == ["k8s"])
    #expect(word.category == .domain)
    #expect(word.priority == 0)
    #expect(word.forceReplace == false)
    #expect(word.caseSensitive == false)
  }

  @Test("default values applied when using minimal init")
  func defaultValues() {
    let word = CustomWord(canonical: "test")

    #expect(word.canonical == "test")
    #expect(word.aliases.isEmpty)
    #expect(word.category == .general)
    #expect(word.priority == 0)
    #expect(word.forceReplace == false)
    #expect(word.caseSensitive == false)
    #expect(word.learnedAliases.isEmpty && word.learnedAt == nil && !word.isAutoLearned)
  }

  // MARK: - Learned provenance (#996)

  @Test("a pre-#996 entry with no learned keys decodes as a plain word, and the minimal payload survives encode and re-decode")
  func legacyEntryDecodesPlain() throws {
    let json = """
      {"id": "550E8400-E29B-41D4-A716-446655440000", "canonical": "Kubernetes", "aliases": ["k8s"]}
      """
    let word = try JSONDecoder().decode(CustomWord.self, from: Data(json.utf8))
    #expect(word.learnedAliases == [] && word.learnedAt == nil && !word.isAutoLearned)
    let again = try JSONDecoder().decode(CustomWord.self, from: JSONEncoder().encode(word))
    #expect(again.learnedAliases == [] && again.learnedAt == nil && again.aliases == ["k8s"])
  }

  @Test("learned marks round-trip through Codable with the date intact")
  func learnedMarksRoundTrip() throws {
    let learnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let word = CustomWord(
      canonical: "Tuist", aliases: ["twist", "to-ist"], learnedAliases: ["twist"], learnedAt: learnedAt)
    let data = try JSONEncoder().encode(word)
    let serialized = String(decoding: data, as: UTF8.self)
    #expect(serialized.contains("\"learnedAliases\"") && serialized.contains("\"learnedAt\""))
    let decoded = try JSONDecoder().decode(CustomWord.self, from: data)
    #expect(decoded.learnedAliases == ["twist"])
    #expect(decoded.learnedAt == learnedAt)
    #expect(decoded.isAutoLearned)
  }

  @Test("isAutoLearned truth table: the word was learned, or one of its sound-alikes was; a plain word is neither")
  func isAutoLearnedTruthTable() {
    let plain = CustomWord(canonical: "Plain", aliases: ["plane"])
    let learnedWord = CustomWord(canonical: "Tuist", learnedAt: Date())
    let learnedAlias = CustomWord(canonical: "Saira", aliases: ["sarah"], learnedAliases: ["sarah"])
    let both = CustomWord(canonical: "Both", aliases: ["boat"], learnedAliases: ["boat"], learnedAt: Date())
    #expect(!plain.isAutoLearned)
    #expect(learnedWord.isAutoLearned)
    #expect(learnedAlias.isAutoLearned)
    #expect(both.isAutoLearned)
  }

  @Test("ownedByUser keeps the learned marks: a restored built-in override does not lose its sparkle")
  func ownedByUserKeepsMarks() {
    let learnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let builtin = CustomWord(
      canonical: "Xcode", aliases: ["ex code"], source: .builtin,
      learnedAliases: ["ex code"], learnedAt: learnedAt)
    let owned = builtin.ownedByUser()
    #expect(owned.source == .user)
    #expect(owned.learnedAliases == ["ex code"] && owned.learnedAt == learnedAt)
    // A `.user` value returns itself unchanged, marks included.
    let user = CustomWord(canonical: "Tuist", learnedAliases: [], learnedAt: learnedAt)
    #expect(user.ownedByUser() == user)
  }

  // MARK: - WordCategory

  @Test("all word categories round-trip through Codable", arguments: WordCategory.allCases)
  func categoryRoundTrip(category: WordCategory) throws {
    let word = CustomWord(canonical: "test", category: category)
    let data = try JSONEncoder().encode(word)
    let decoded = try JSONDecoder().decode(CustomWord.self, from: data)
    #expect(decoded.category == category)
  }
}
