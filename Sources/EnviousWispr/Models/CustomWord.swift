import Foundation

enum WordCategory: String, Codable, CaseIterable, Sendable {
    case general, person, brand, acronym, domain
}

struct CustomWord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var canonical: String
    var aliases: [String]
    var category: WordCategory
    var priority: Int
    var forceReplace: Bool
    var caseSensitive: Bool

    init(
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
    var canonicals: [String] { map(\.canonical) }
}
