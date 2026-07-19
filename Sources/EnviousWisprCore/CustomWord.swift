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
  case observedAX  // auto-learned via AX observation (Phase 7, #629)
  case pack  // installed vocabulary pack (ASR-mined alias dataset, #633 Phase 9).
  // Length-gated fuzzy in WordCorrector: pack terms match only after every
  // non-pack pass misses, so user/builtin words always win (#992). Corrector
  // lane only, never polish.
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
  /// Number of `WordCorrector` applications that replaced into this canonical's
  /// spelling. Phase 3a (#631) adds the field; Phase 3b ships the writer.
  /// Pre-Phase-3a entries decode as 0.
  public var frequencyUsed: Int
  /// Timestamp of the most recent `WordCorrector` application against this term.
  /// Phase 3a (#631) adds the field; Phase 3b ships the writer. Pre-Phase-3a
  /// entries decode as nil.
  public var lastUsed: Date?
  /// Per-term similarity threshold override. When non-nil, replaces the global
  /// `WordCorrector.threshold` for this term's fuzzy-pass acceptance check.
  /// Phase 2 (#638) adds the field; Phase 4 (#634) surfaces it as
  /// "Match strictness: Loose / Default / Strict" radio. Pre-Phase-2 entries
  /// decode as nil (use global threshold).
  public var minSimilarityOverride: Double?

  public init(
    id: UUID = UUID(),
    canonical: String,
    aliases: [String] = [],
    category: WordCategory = .general,
    priority: Int = 0,
    forceReplace: Bool = false,
    caseSensitive: Bool = false,
    source: WordSource = .user,
    frequencyUsed: Int = 0,
    lastUsed: Date? = nil,
    minSimilarityOverride: Double? = nil
  ) {
    self.id = id
    self.canonical = canonical
    self.aliases = aliases
    self.category = category
    self.priority = priority
    self.forceReplace = forceReplace
    self.caseSensitive = caseSensitive
    self.source = source
    self.frequencyUsed = frequencyUsed
    self.lastUsed = lastUsed
    self.minSimilarityOverride = minSimilarityOverride
  }

  /// The same word, re-tagged as user-authored (#1680).
  ///
  /// `source` is a `let`, so re-tagging means reconstructing. Needed where a
  /// built-in becomes a user override — editing one, or replacing one through
  /// import — because the value still carries `.builtin` from `builtinDefaults`
  /// until a relaunch decodes it as `.user`. Export filters on `source ==
  /// .user`, so without this an override would be missing from its own backup
  /// until the app restarted.
  public func ownedByUser() -> CustomWord {
    guard source != .user else { return self }
    return CustomWord(
      id: id,
      canonical: canonical,
      aliases: aliases,
      category: category,
      priority: priority,
      forceReplace: forceReplace,
      caseSensitive: caseSensitive,
      source: .user,
      frequencyUsed: frequencyUsed,
      lastUsed: lastUsed,
      minSimilarityOverride: minSimilarityOverride
    )
  }

  // `source` deliberately omitted — keeps persisted JSON byte-equivalent to the
  // pre-Phase-0 schema for the source field. Bible §6.5.
  // `frequencyUsed` + `lastUsed` ARE persisted (Phase 3a, bible §9.2). Forward-
  // compatible: older app versions ignore the new keys; backward-compatible:
  // pre-Phase-3a JSON files decode the new fields via `decodeIfPresent`.
  // `minSimilarityOverride` is persisted (Phase 2, bible §8.2 item 4). Same
  // additive forward/backward-compat semantics.
  private enum CodingKeys: String, CodingKey {
    case id, canonical, aliases, category, priority, forceReplace, caseSensitive
    case frequencyUsed, lastUsed, minSimilarityOverride
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
    self.frequencyUsed = try c.decodeIfPresent(Int.self, forKey: .frequencyUsed) ?? 0
    self.lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    self.minSimilarityOverride = try c.decodeIfPresent(Double.self, forKey: .minSimilarityOverride)
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
    try c.encode(frequencyUsed, forKey: .frequencyUsed)
    try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
    try c.encodeIfPresent(minSimilarityOverride, forKey: .minSimilarityOverride)
    // source intentionally NOT encoded.
  }
}
