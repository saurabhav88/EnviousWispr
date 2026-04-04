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
