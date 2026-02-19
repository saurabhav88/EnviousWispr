import Foundation

/// Persists the user's custom word list to disk as JSON.
final class CustomWordStore: Sendable {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("EnviousWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("custom-words.json")
    }

    func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func save(_ words: [String]) throws {
        let data = try JSONEncoder().encode(words.sorted())
        try data.write(to: fileURL, options: .atomic)
    }

    func add(_ word: String, to words: inout [String]) throws {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !words.contains(trimmed) else { return }
        words.append(trimmed)
        try save(words)
    }

    func remove(_ word: String, from words: inout [String]) throws {
        words.removeAll { $0 == word }
        try save(words)
    }
}
