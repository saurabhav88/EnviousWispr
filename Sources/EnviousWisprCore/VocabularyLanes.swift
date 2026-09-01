import Foundation

/// Phase 0 (#640) — typed propagation lanes for custom-word terms.
///
/// Bible §2.2 mandates: pack-sourced terms reach `WordCorrector` only, never
/// the polish prompt. Pre-Phase-0, `CustomWordsPropagator.update(_ words:
/// [CustomWord])` broadcast a single list to every consumer, so the law could
/// only be enforced at runtime (Layer 3 golden-string test). Phase 0 splits
/// the lane into two value types so a pack-to-prompt leak becomes a Swift
/// compile error (Layer 2).
///
/// `generation` is monotonically incremented per coordinator update and
/// shared between both lanes for a given atomic snapshot, addressing the
/// broadcast-ordering risk (R18) noted in the bible. Sub-second-scale
/// cross-actor reads can detect "I have lane A at gen N but lane B at gen
/// N-1" and choose to re-read.
public struct CorrectorVocabulary: Sendable, Equatable {
  /// All terms eligible for deterministic correction: built-in defaults +
  /// user-typed entries + installed pack terms (Phase 5).
  public let terms: [CustomWord]
  public let generation: UInt64

  public init(terms: [CustomWord], generation: UInt64) {
    self.terms = terms
    self.generation = generation
  }

  /// Empty initial value used at the former root state wire time before the first user mutation.
  public static let empty = CorrectorVocabulary(terms: [], generation: 0)
}

/// Polish-prompt vocabulary. Built-in defaults + user-typed entries only;
/// **pack-sourced terms are never included**.
///
/// The compile-time guard against pack leakage is `PromptBuildInput`'s only
/// vocab field being `polishVocabulary: PolishVocabulary` — a developer who
/// wants to leak pack terms into the polish prompt must construct a
/// `PolishVocabulary` from pack terms by hand, which a code review or the
/// `PackToPolishLeakTest` runtime assertion will catch.
public struct PolishVocabulary: Sendable, Equatable {
  public let terms: [CustomWord]
  public let generation: UInt64

  public init(terms: [CustomWord], generation: UInt64) {
    self.terms = terms
    self.generation = generation
  }

  public static let empty = PolishVocabulary(terms: [], generation: 0)
}

/// Snippet vocabulary (#628) — the THIRD lane, and it reaches neither of the other two.
///
/// A snippet trigger must never enter the polish prompt (the model would then see the words
/// the user is trying to replace) and must never enter `WordCorrector` (its passes are fuzzy,
/// and a snippet trigger that fires approximately is a defect, not a feature). Giving it its
/// own value type makes both leaks a compile error rather than a code-review promise, the same
/// reasoning Phase 0 (#640) applied to the corrector/polish split above.
///
/// `keyword` rides in this lane rather than being read live because it is a matching input:
/// the whole snapshot must be frozen together for a take, or a mid-dictation edit in Settings
/// changes the rule for text already in flight.
public struct SnippetVocabulary: Sendable, Equatable {
  public let snippets: [Snippet]
  /// The word the user must speak before a trigger. Compared through `SnippetText.normalize`.
  public let keyword: String
  public let generation: UInt64

  public init(snippets: [Snippet], keyword: String, generation: UInt64) {
    self.snippets = snippets
    self.keyword = keyword
    self.generation = generation
  }

  public static let empty = SnippetVocabulary(snippets: [], keyword: "", generation: 0)

  /// The default keyword (founder, 2026-09-01). Chosen because nothing in the text pipeline
  /// consumes a spoken "backslash" — unlike "slash", which `InverseTextNormalizer` already
  /// converts contextually for URLs, dates and ranges, so it has a second owner.
  public static let defaultKeyword = "backslash"

  /// Nothing can fire without both halves, so the expansion step is disabled rather than run
  /// as a no-op. Keeps the empty-store chain byte-identical to a build without the step (P4).
  public var canFire: Bool {
    !snippets.isEmpty && !SnippetText.normalize(keyword).isEmpty
  }
}
