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
