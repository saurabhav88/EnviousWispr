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

extension Array where Element == CustomWord {
    public var canonicals: [String] { map(\.canonical) }
}
