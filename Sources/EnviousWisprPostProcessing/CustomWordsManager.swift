import Foundation
import EnviousWisprCore

/// A built-in default word shipped with the app. Identified by a stable string ID
/// for tombstone tracking across app updates.
public struct BuiltinWord: Sendable {
    public let id: String
    public let word: CustomWord
}

/// Persists custom words to disk with a two-tier architecture:
/// - **Built-in defaults**: hardcoded in the app, updatable via app updates
/// - **User words**: persisted to `custom-words.json`
///
/// Runtime merge produces the effective word list. User deletions of built-ins
/// are tracked as tombstones so they don't resurface after updates.
@MainActor
public final class CustomWordsManager {
    private let fileURL: URL

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("EnviousWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("custom-words.json")
    }

    // MARK: - Built-in Defaults

    public static let builtinDefaults: [BuiltinWord] = [
        BuiltinWord(id: "enviouswispr", word: CustomWord(
            canonical: "EnviousWispr",
            aliases: ["envious whisper", "envious wisper", "envious whispr"],
            category: .brand
        )),
        BuiltinWord(id: "enviouslabs", word: CustomWord(
            canonical: "Envious Labs",
            aliases: ["envious laps"],
            category: .brand
        )),
        BuiltinWord(id: "macos", word: CustomWord(
            canonical: "macOS",
            aliases: ["mac OS", "Mack OS"],
            category: .brand
        )),
        BuiltinWord(id: "ios", word: CustomWord(
            canonical: "iOS",
            aliases: ["I OS", "eye OS"],
            category: .brand
        )),
        BuiltinWord(id: "github", word: CustomWord(
            canonical: "GitHub",
            aliases: ["git hub", "get hub"],
            category: .brand
        )),
        BuiltinWord(id: "chatgpt", word: CustomWord(
            canonical: "ChatGPT",
            aliases: ["chat GPT", "chat G P T"],
            category: .brand
        )),
        BuiltinWord(id: "openai", word: CustomWord(
            canonical: "OpenAI",
            aliases: ["open AI", "open A I"],
            category: .brand
        )),
        BuiltinWord(id: "claude", word: CustomWord(
            canonical: "Claude",
            aliases: ["clod", "clawed"],
            category: .brand
        )),
        BuiltinWord(id: "api", word: CustomWord(
            canonical: "API",
            aliases: ["A P I"],
            category: .acronym
        )),
        BuiltinWord(id: "cli", word: CustomWord(
            canonical: "CLI",
            aliases: ["C L I"],
            category: .acronym
        )),
        BuiltinWord(id: "vscode", word: CustomWord(
            canonical: "VS Code",
            aliases: ["vs code", "vscode", "V S code"],
            category: .brand
        )),
    ]

    // MARK: - Schema

    /// Versioned wrapper for the custom words file.
    private struct CustomWordsFile: Codable, Sendable {
        var version: Int = 1
        var builtinsVersion: Int = 1
        var deletedBuiltinIds: [String] = []
        var words: [CustomWord] = []
    }

    // MARK: - Public API

    /// Load the effective word list: built-in defaults (minus tombstones) + user words.
    /// Returns nil only on unrecoverable I/O failure.
    public func load() -> [CustomWord]? {
        let file = loadFile() ?? CustomWordsFile()
        return mergedWords(file: file)
    }

    public func save(_ words: [CustomWord]) throws {
        var file = loadFile() ?? CustomWordsFile()
        let builtinCanonicals = Set(Self.builtinDefaults.map { $0.word.canonical.lowercased() })
        file.words = words
            .filter { !builtinCanonicals.contains($0.canonical.lowercased()) }
            .sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }
        try saveFile(file)
    }

    public func add(canonical: String, to words: inout [CustomWord]) throws {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !words.contains(where: {
            $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return }

        var file = loadFile() ?? CustomWordsFile()

        // If this matches a deleted built-in, restore it instead of adding a user word
        if let builtin = Self.builtinDefaults.first(where: {
            $0.word.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            file.deletedBuiltinIds.removeAll { $0 == builtin.id }
            try saveFile(file)
            words = mergedWords(file: file)
            return
        }

        file.words.append(CustomWord(canonical: trimmed))
        try saveFile(file)
        words = mergedWords(file: file)
    }

    public func add(word: CustomWord, to words: inout [CustomWord]) throws {
        guard !words.contains(where: { $0.id == word.id }) else { return }
        var file = loadFile() ?? CustomWordsFile()

        // If this matches a deleted built-in, restore it
        if let builtin = Self.builtinDefaults.first(where: {
            $0.word.canonical.lowercased() == word.canonical.lowercased()
        }) {
            file.deletedBuiltinIds.removeAll { $0 == builtin.id }
            try saveFile(file)
            words = mergedWords(file: file)
            return
        }

        file.words.append(word)
        try saveFile(file)
        words = mergedWords(file: file)
    }

    public func remove(id: UUID, from words: inout [CustomWord]) throws {
        let word = words.first { $0.id == id }
        var file = loadFile() ?? CustomWordsFile()

        // If this matches a built-in, tombstone it
        if let word = word,
           let builtin = Self.builtinDefaults.first(where: {
               $0.word.canonical.lowercased() == word.canonical.lowercased()
           }) {
            if !file.deletedBuiltinIds.contains(builtin.id) {
                file.deletedBuiltinIds.append(builtin.id)
            }
        }

        file.words.removeAll { $0.id == id }
        try saveFile(file)
        words = mergedWords(file: file)
    }

    public func update(word: CustomWord, in words: inout [CustomWord]) throws {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var sanitized = word
        sanitized.canonical = trimmed
        sanitized.aliases = sanitized.aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var file = loadFile() ?? CustomWordsFile()

        // Check if this is a built-in word being edited — store as user override
        if let existingIdx = file.words.firstIndex(where: { $0.id == word.id }) {
            file.words[existingIdx] = sanitized
        } else {
            // Editing a built-in: add as user word (overrides built-in by canonical match)
            file.words.append(sanitized)
        }
        try saveFile(file)

        // Update the in-memory array directly for the caller
        var updated = words
        updated[index] = sanitized
        words = updated
    }

    // MARK: - Private File I/O

    /// Single read path — normalizes legacy formats to CustomWordsFile.
    /// All callers (load, add, remove, save) go through this.
    private func loadFile() -> CustomWordsFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else {
            Task {
                await AppLogger.shared.log(
                    "Failed to read custom words file — returning nil to prevent data loss",
                    level: .info, category: "CustomWords"
                )
            }
            return nil
        }

        // Try new versioned wrapper first
        if let file = try? JSONDecoder().decode(CustomWordsFile.self, from: data) {
            return file
        }

        // Migrate from old [CustomWord] array format
        if let oldWords = try? JSONDecoder().decode([CustomWord].self, from: data) {
            let file = CustomWordsFile(words: oldWords)
            try? saveFile(file)
            Task {
                await AppLogger.shared.log(
                    "Migrated \(oldWords.count) custom words from [CustomWord] to versioned format",
                    level: .info, category: "CustomWords"
                )
            }
            return file
        }

        // Migrate from old [String] array format
        if let oldStrings = try? JSONDecoder().decode([String].self, from: data) {
            let migrated = oldStrings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { CustomWord(canonical: $0) }
            let file = CustomWordsFile(words: migrated)
            try? saveFile(file)
            Task {
                await AppLogger.shared.log(
                    "Migrated \(oldStrings.count) custom words from [String] to versioned format",
                    level: .info, category: "CustomWords"
                )
            }
            return file
        }

        // Corrupted — backup and start fresh
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("custom-words.json.corrupted")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        Task {
            await AppLogger.shared.log(
                "Custom words file corrupted, backed up to \(backup.lastPathComponent)",
                level: .info, category: "CustomWords"
            )
        }
        return nil
    }

    private func saveFile(_ file: CustomWordsFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Runtime Merge

    /// Merge built-in defaults with user words. Built-ins not tombstoned and not
    /// overridden by a user word (same canonical, case-insensitive) are included.
    private func mergedWords(file: CustomWordsFile) -> [CustomWord] {
        let tombstones = Set(file.deletedBuiltinIds)
        let activeBuiltins = Self.builtinDefaults
            .filter { !tombstones.contains($0.id) }
            .map(\.word)

        let userCanonicals = Set(file.words.map { $0.canonical.lowercased() })
        let nonOverriddenBuiltins = activeBuiltins.filter {
            !userCanonicals.contains($0.canonical.lowercased())
        }

        return nonOverriddenBuiltins + file.words
    }
}
