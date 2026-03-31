import Foundation

public enum WordCategory: String, Codable, CaseIterable, Sendable {
    case general, person, brand, acronym, domain
}

public struct CustomWord: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var canonical: String
    public var aliases: [String]
    public var category: WordCategory
    public var priority: Int
    public var forceReplace: Bool
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        canonical: String,
        aliases: [String] = [],
        category: WordCategory = .general,
        priority: Int = 0,
        forceReplace: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.canonical = canonical
        self.aliases = aliases
        self.category = category
        self.priority = priority
        self.forceReplace = forceReplace
        self.caseSensitive = caseSensitive
    }
}

extension CustomWord {
    /// Whether this word is safe for CTC vocabulary boosting.
    /// CTC-safe terms are rare proper nouns with low acoustic confuser risk.
    /// Short common English words with acoustic collisions (cloud/Claude, counsel/Council)
    /// are excluded to prevent false positives. These stay on the WordCorrector path.
    ///
    /// Known unsafe terms are blocklisted. All others pass through.
    /// This is conservative: we only block known confusers.
    public var isCTCSafe: Bool {
        let lower = canonical.lowercased()
        // Blocklist: terms with known acoustic confusers against common English words.
        // These were identified during CTC eval (21+ runs, benchmark-results/ctc-eval/).
        let unsafeTerms: Set<String> = [
            "claude",       // cloud, cloudy, clawed
            "council",      // counsel, counselor
            "beads",        // beady, beats
        ]
        return !unsafeTerms.contains(lower)
    }
}

extension Array where Element == CustomWord {
    public var canonicals: [String] { map(\.canonical) }
}
