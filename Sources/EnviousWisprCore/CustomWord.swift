import Foundation

public enum WordCategory: String, Codable, CaseIterable, Sendable {
  case general, person, brand, acronym, domain
}

/// Origin of a `CustomWord`. Runtime-only — NOT persisted to disk.
///
/// Phase 0 (#640) introduces this enum so the corrector vs polish lane split
/// can be enforced: pack-sourced terms must reach `WordCorrector` only, never
/// the polish prompt (bible §2.2). The persisted JSON shape stays unchanged
/// because `source` is excluded from `CustomWord.CodingKeys`. Anything decoded
/// from `custom-words.json` is by definition `.user`.
public enum WordSource: String, Sendable, CaseIterable {
  case builtin  // ships in app bundle (CustomWordsManager.builtinDefaults)
  case user  // user-typed via Custom Terms UI; default for any decoded CustomWord
  case pack  // installed via VocabularyPacksManager (Phase 5, #635) — runtime-only
  case observedAX  // auto-learned via AX observation (Phase 7, #629)
}

public struct CustomWord: Codable, Identifiable, Sendable, Hashable {
  public let id: UUID
  public var canonical: String
  public var aliases: [String]
  public var category: WordCategory
  public var priority: Int
  public var forceReplace: Bool
  public var caseSensitive: Bool
  /// Runtime origin tag. Excluded from on-disk serialization (see `CodingKeys`).
  /// Decoded values always have `source = .user`.
  public let source: WordSource

  public init(
    id: UUID = UUID(),
    canonical: String,
    aliases: [String] = [],
    category: WordCategory = .general,
    priority: Int = 0,
    forceReplace: Bool = false,
    caseSensitive: Bool = false,
    source: WordSource = .user
  ) {
    self.id = id
    self.canonical = canonical
    self.aliases = aliases
    self.category = category
    self.priority = priority
    self.forceReplace = forceReplace
    self.caseSensitive = caseSensitive
    self.source = source
  }

  // `source` deliberately omitted — keeps persisted JSON byte-equivalent to the
  // pre-Phase-0 schema. Bible §6.5, Codex grounded review 2026-05-05.
  private enum CodingKeys: String, CodingKey {
    case id, canonical, aliases, category, priority, forceReplace, caseSensitive
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.canonical = try c.decode(String.self, forKey: .canonical)
    self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    self.category = try c.decodeIfPresent(WordCategory.self, forKey: .category) ?? .general
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    self.forceReplace = try c.decodeIfPresent(Bool.self, forKey: .forceReplace) ?? false
    self.caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    self.source = .user
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(canonical, forKey: .canonical)
    try c.encode(aliases, forKey: .aliases)
    try c.encode(category, forKey: .category)
    try c.encode(priority, forKey: .priority)
    try c.encode(forceReplace, forKey: .forceReplace)
    try c.encode(caseSensitive, forKey: .caseSensitive)
    // source intentionally NOT encoded.
  }
}
