import Foundation

/// Persists the user's custom word list to disk as JSON.
/// Replaces CustomWordStore with richer CustomWord entries and migration from the old [String] format.
@MainActor
final class CustomWordsManager {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("EnviousWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("custom-words.json")
    }

    func load() -> [CustomWord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        // Try new format first
        if let words = try? JSONDecoder().decode([CustomWord].self, from: data) {
            return words
        }

        // Fall back: migrate from old [String] format
        if let oldWords = try? JSONDecoder().decode([String].self, from: data) {
            let migrated = oldWords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { CustomWord(canonical: $0) }
            try? save(migrated)
            Task {
                await AppLogger.shared.log(
                    "Migrated \(oldWords.count) custom words from [String] to [CustomWord] format",
                    level: .info, category: "CustomWords"
                )
            }
            return migrated
        }

        // Corrupted file — back it up and start fresh
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("custom-words.json.corrupted")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        Task {
            await AppLogger.shared.log(
                "Custom words file corrupted, backed up to \(backup.lastPathComponent)",
                level: .info, category: "CustomWords"
            )
        }
        return []
    }

    func save(_ words: [CustomWord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = words.sorted {
            $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
        }
        let data = try encoder.encode(sorted)
        try data.write(to: fileURL, options: .atomic)
    }

    func add(canonical: String, to words: inout [CustomWord]) throws {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive duplicate check
        guard !words.contains(where: {
            $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return }
        var updated = words
        updated.append(CustomWord(canonical: trimmed))
        try save(updated)
        words = updated
    }

    func add(word: CustomWord, to words: inout [CustomWord]) throws {
        guard !words.contains(where: { $0.id == word.id }) else { return }
        var updated = words
        updated.append(word)
        try save(updated)
        words = updated
    }

    func remove(id: UUID, from words: inout [CustomWord]) throws {
        var updated = words
        updated.removeAll { $0.id == id }
        try save(updated)
        words = updated
    }

    func update(word: CustomWord, in words: inout [CustomWord]) throws {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var sanitized = word
        sanitized.canonical = trimmed
        sanitized.aliases = sanitized.aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var updated = words
        updated[index] = sanitized
        try save(updated)
        words = updated
    }
}
