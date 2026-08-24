import EnviousWisprCore
import Foundation

/// Ranks a misheard spelling against the saved word library for Quick Add (#2381).
///
/// Pure policy: no UI, no Accessibility, no I/O, no clock. It is handed the two candidate
/// populations already loaded by its caller and returns an ordered list plus the one safety
/// decision the panel turns on — whether the top row may be accepted with a single Return.
///
/// **Two questions, two entry points, and they are not the same question.**
/// `rank(heard:)` answers "which saved word does this mishearing belong to", and carries the
/// measured policy below. `search(query:)` answers "find me this word", which is the panel's
/// escape hatch for a wrong ranking and must be able to reach ANY term — so it ranks the two
/// populations together with no bar-gated suppression. Collapsing them would make the escape
/// hatch unable to reach the words the ranking suppressed, which is precisely when it is needed.
///
/// **The policy is measured, not chosen by feel.** 1,648 real mishearings drawn from the stored
/// spellings themselves (111 user + 1,537 pack), scored with the shipped `WordCorrector.score`,
/// two arms per scope: WARM hides one spelling and leaves the word's others in place, COLD strips
/// every spelling so only the canonical remains. On the user's own words at `confidenceBar`:
/// 91.9% one-keypress-correct and 0% confident-and-wrong warm, 74.8% / 0% cold. Enabling the
/// shipped packs alongside took confident-and-wrong from 0 to 4 (`codecs`→`codec`,
/// `sarag`→`Suarez`, `dot md`→`dotnet`); preferring user words restored 91.9% and dropped wrong
/// to 1. Method and raw output on #2381.
public struct QuickAddRanker: Sendable {

  /// The score at or above which the top match may be preselected for a one-keypress accept.
  ///
  /// The lowest value at which confident-and-wrong is zero on the user's own words in BOTH the
  /// warm and cold arms. Below it the identical panel renders with nothing highlighted, which
  /// costs keystrokes and never writes a wrong alias. Raising it costs one-keypress accepts;
  /// lowering it re-admits confident-and-wrong, so a change here needs the sweep re-run, not an
  /// argument.
  public static let confidenceBar: Double = 0.55

  /// How many rows the panel shows by default. A presentation bound, passed by the caller and
  /// never consulted by the ranking itself — the escape hatch is `search`, which re-ranks by the
  /// query and lifts the wanted term to the top rather than needing a longer list.
  public static let defaultLimit: Int = 5

  /// One ranked row.
  public struct Candidate: Sendable, Equatable, Identifiable {
    /// The library word this row would receive the heard spelling.
    public let word: CustomWord
    /// Best `WordCorrector.score` of the ranked string against this word's canonical or any of
    /// its spellings. Raw, not rounded or bucketed.
    public let score: Double
    /// True when this word ALREADY carries the heard spelling, so accepting it would add a
    /// duplicate. The panel says "already saved" rather than writing again (#2381 §14.3).
    /// Compared on the same normalization the scoring uses.
    public let alreadyHasHeardSpelling: Bool

    public var id: UUID { word.id }
    /// A shipped pack term rather than something the user saved. Accepting one converts it to a
    /// user-owned override first (`CustomWord.ownedByUser()`), because `CustomWordsManager.update`
    /// looks the id up in the user library and returns silently when it is absent.
    public var isPackTerm: Bool { word.source == .pack }

    public init(word: CustomWord, score: Double, alreadyHasHeardSpelling: Bool) {
      self.word = word
      self.score = score
      self.alreadyHasHeardSpelling = alreadyHasHeardSpelling
    }
  }

  /// An ordered list plus the row that owns the Return key.
  public struct Ranking: Sendable, Equatable {
    /// Best first. Empty when there was nothing to rank or nothing matched.
    public let candidates: [Candidate]
    /// The row a bare Return accepts, or nil when Return must write nothing. Always the id of a
    /// member of `candidates`, so a highlight can never accept a row that is not on screen.
    public let preselectedID: UUID?

    public var preselected: Candidate? {
      guard let preselectedID else { return nil }
      return candidates.first { $0.id == preselectedID }
    }

    /// The top row's score, or nil when there are no candidates. Telemetry reports this raw.
    public var topScore: Double? { candidates.first?.score }

    public init(candidates: [Candidate], preselectedID: UUID?) {
      self.candidates = candidates
      self.preselectedID = preselectedID
    }

    public static let empty = Ranking(candidates: [], preselectedID: nil)
  }

  private let corrector = WordCorrector()

  public init() {}

  // MARK: - The heard spelling

  /// Rank a misheard spelling against the library.
  ///
  /// User words are ranked first and pack terms are consulted ONLY when no user word clears
  /// `confidenceBar` — the measured rule. A pack term then wins only by outscoring the best user
  /// word, so a weak pack match never displaces a weak-but-better user word.
  ///
  /// Preselection is the safety decision and the only thing that varies: the top row owns Return
  /// only when its score clears the bar. Below it the same list renders with nothing highlighted.
  public func rank(
    heard: String,
    userWords: [CustomWord],
    packTerms: [CustomWord],
    limit: Int = QuickAddRanker.defaultLimit
  ) -> Ranking {
    let needle = Self.normalize(heard)
    guard !needle.isEmpty else { return .empty }

    let user = score(needle: needle, against: userWords, heardNeedle: needle)
    let bestUserScore = user.first?.score ?? 0

    var ordered = user
    if bestUserScore < Self.confidenceBar {
      // Only now do packs enter, and only ahead of the user list if they actually beat it.
      let stillPack = Self.packTermsNotOverridden(by: userWords, in: packTerms)
      let pack = score(needle: needle, against: stillPack, heardNeedle: needle)
      if let bestPack = pack.first, bestPack.score > bestUserScore {
        ordered = (user + pack).sorted(by: Self.betterFirst)
      }
    }

    let shown = Array(ordered.prefix(max(0, limit)))
    guard let top = shown.first, top.score >= Self.confidenceBar else {
      return Ranking(candidates: shown, preselectedID: nil)
    }
    return Ranking(candidates: shown, preselectedID: top.id)
  }

  // MARK: - The search field

  /// Filter the whole library by what the user typed.
  ///
  /// **This FILTERS, it does not fuzzy-rank, and the difference is a safety property.** Fuzzy
  /// scoring assigns every word in the library some score, so it can never return an empty list —
  /// a query matching nothing would still render five unrelated rows with the first one owning
  /// Return, and one keypress would write the heard spelling onto a word the user never looked
  /// for. The design requires a real zero-results state, and only a filter can produce one.
  /// It is also what a search field is for: typing `kub` must reach `Kubernetes`, which scores
  /// poorly under an edit-distance measure precisely because it is a fragment.
  ///
  /// A word matches when its canonical or any of its spellings CONTAINS the query. Order is a
  /// tier — exact, then canonical prefix, then spelling prefix, then substring — and inside a tier
  /// the user's own words come before pack terms, then alphabetically. Deterministic, so a redraw
  /// cannot move a row under the highlight.
  ///
  /// `heard` is used only for `alreadyHasHeardSpelling` and for each row's `score`, which reports
  /// how well the row matches WHAT WILL BE WRITTEN rather than what was typed. The query never
  /// becomes an alias: accepting a searched row saves the ORIGINAL heard spelling, which is the
  /// difference between an escape hatch and a way to write whatever was typed.
  ///
  /// An empty query returns nothing rather than the whole library: clearing the field restores
  /// the heard ranking, so the caller switches back to `rank` rather than rendering this.
  public func search(
    query: String,
    heard: String,
    userWords: [CustomWord],
    packTerms: [CustomWord],
    limit: Int = QuickAddRanker.defaultLimit
  ) -> Ranking {
    let needle = Self.normalize(query)
    guard !needle.isEmpty else { return .empty }
    let heardNeedle = Self.normalize(heard)

    let population = userWords + Self.packTermsNotOverridden(by: userWords, in: packTerms)

    let matched =
      population
      .compactMap { word -> (tier: Int, candidate: Candidate)? in
        guard let tier = Self.matchTier(needle: needle, word: word) else { return nil }
        return (tier, candidate(for: word, rankedAgainst: heardNeedle, heardNeedle: heardNeedle))
      }
      .sorted { a, b in
        if a.tier != b.tier { return a.tier < b.tier }
        if a.candidate.isPackTerm != b.candidate.isPackTerm { return !a.candidate.isPackTerm }
        return a.candidate.word.canonical.lowercased() < b.candidate.word.canonical.lowercased()
      }
      .map(\.candidate)

    let shown = Array(matched.prefix(max(0, limit)))
    // Every row here is one the user's own query selected, so the first owns Return whatever it
    // scored against the heard string. The confidence bar governs the ranking the user did NOT
    // ask for; a list they typed is one they chose. No matches means no highlight and no write.
    return Ranking(candidates: shown, preselectedID: shown.first?.id)
  }

  /// How well `word` matches `needle`, as a tier — lower is better, nil means it does not match.
  ///
  /// 0 exact · 1 canonical prefix · 2 spelling prefix · 3 substring anywhere.
  static func matchTier(needle: String, word: CustomWord) -> Int? {
    let canonical = normalize(word.canonical)
    let spellings = word.aliases.map(normalize)

    if canonical == needle || spellings.contains(needle) { return 0 }
    if canonical.hasPrefix(needle) { return 1 }
    if spellings.contains(where: { $0.hasPrefix(needle) }) { return 2 }
    if canonical.contains(needle) || spellings.contains(where: { $0.contains(needle) }) { return 3 }
    return nil
  }

  // MARK: - Internals

  /// Lowercase and strip surrounding whitespace, which is what the sweep scored and what a real
  /// selection needs — dragging across a word routinely picks up a trailing space. Trimming a
  /// clean token is identity, so the measured figures carry over unchanged.
  static func normalize(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func score(
    needle: String,
    against words: [CustomWord],
    heardNeedle: String
  ) -> [Candidate] {
    words
      .map { candidate(for: $0, rankedAgainst: needle, heardNeedle: heardNeedle) }
      .sorted(by: Self.betterFirst)
  }

  /// One row: the best score of `needle` against any spelling of `word`, plus whether `word`
  /// already carries the heard spelling.
  private func candidate(
    for word: CustomWord,
    rankedAgainst needle: String,
    heardNeedle: String
  ) -> Candidate {
    var best = corrector.score(needle, against: Self.normalize(word.canonical))
    var carriesHeard = !heardNeedle.isEmpty && Self.normalize(word.canonical) == heardNeedle
    for alias in word.aliases {
      let lowered = Self.normalize(alias)
      best = max(best, corrector.score(needle, against: lowered))
      if !heardNeedle.isEmpty && lowered == heardNeedle { carriesHeard = true }
    }
    return Candidate(word: word, score: best, alreadyHasHeardSpelling: carriesHeard)
  }

  /// One ordering, used by every list this type produces.
  ///
  /// `Array.sorted` gives no stability guarantee, so ties need an explicit total order or a
  /// redraw can shuffle rows under a highlight — the one state where a reorder changes what
  /// Return accepts. User words break a tie ahead of pack terms; canonical breaks the rest.
  private static func betterFirst(_ a: Candidate, _ b: Candidate) -> Bool {
    if a.score != b.score { return a.score > b.score }
    if a.isPackTerm != b.isPackTerm { return !a.isPackTerm }
    return a.word.canonical < b.word.canonical
  }

  /// The pack terms the user has NOT already taken ownership of.
  ///
  /// The collision is real rather than defensive: `CustomWord.ownedByUser()` PRESERVES the id, so
  /// the moment this feature converts a pack term the same id exists in both populations with
  /// different spellings. Rendering both would give SwiftUI duplicate `Identifiable` ids and make a
  /// preselected id ambiguous, and the user's copy is the one that can actually be written —
  /// `CustomWordsManager.update` looks an id up in the user library and returns silently when it is
  /// absent.
  ///
  /// One answer, used by both entry points: two copies of this predicate is how they drift apart.
  static func packTermsNotOverridden(
    by userWords: [CustomWord],
    in packTerms: [CustomWord]
  ) -> [CustomWord] {
    let userIDs = Set(userWords.map(\.id))
    return packTerms.filter { !userIDs.contains($0.id) }
  }
}
