import EnviousWisprCore

/// The set of languages that have a vetted rule set (#1677). Production registers German, French,
/// Spanish, Italian, Portuguese, Dutch, Polish, Swedish and Ukrainian.
///
/// Owns exactly one question: "does this explicit non-English language value have a vetted rule
/// set?". It holds no resolver, no second language key and no inventory of what the neutral address
/// tables cover: neutral coverage (`addressWordPairs`, `spokenURLWords`) never registers a language
/// and never enables language passes (plan §3c). A missing entry fails closed to the neutral route.
///
/// Immutable and `Sendable`: the production table is a static constant and a test builds its own
/// value through the package initialiser, so nothing registers at runtime and nothing mutates a
/// shared registry.
package struct LanguageRuleRegistry: Sendable {

  package enum RegistryError: Error, Equatable {
    /// Two rule sets canonicalise to the same base code (for example `nb` and `no`).
    case duplicate(baseCode: String)
  }

  private let sets: [String: LanguageRuleSet]

  /// The shipped registry (#1677): German (number style, phone, clock), French, Spanish, Italian,
  /// Portuguese (signed phone path, hour-first clock), Dutch (signed phone path, clock), Polish,
  /// Swedish and Ukrainian (signed phone path). A test pins its exact members.
  package static let production: LanguageRuleRegistry = {
    var table: [String: LanguageRuleSet] = [:]
    for code in ["de", "fr", "es", "it", "pt", "nl", "pl", "sv", "uk"] {
      if let set = LanguageRuleSet(language: code) { table[set.baseCode] = set }
    }
    return LanguageRuleRegistry(validatedSets: table)
  }()

  private init(validatedSets: [String: LanguageRuleSet]) {
    self.sets = validatedSets
  }

  /// Builds a registry from rule sets whose keys were already made canonical and non-English by
  /// `LanguageRuleSet.init`. Refuses a conflicting pair rather than letting the later one win.
  package init(_ ruleSets: [LanguageRuleSet]) throws {
    var table: [String: LanguageRuleSet] = [:]
    for set in ruleSets {
      if table[set.baseCode] != nil { throw RegistryError.duplicate(baseCode: set.baseCode) }
      table[set.baseCode] = set
    }
    self.sets = table
  }

  package var count: Int { sets.count }

  /// The rule set for an explicit language value, or nil. Canonicalises through
  /// `LanguageNormalizer.baseCode`; English and rejected values never match.
  package func ruleSet(forLanguage language: String?) -> LanguageRuleSet? {
    guard let code = LanguageNormalizer.baseCode(language), code != "en" else { return nil }
    return sets[code]
  }
}
